#!/usr/bin/env bash
# lib/project.sh — Project discovery · file search · namespace · DB validation

# ─── Safe file discovery ──────────────────────────────────────────────────────
# All find commands exclude obj/, bin/, and Migrations/ to prevent EF migration
# snapshots (e.g. ApplicationDbContextModelSnapshot.cs) from being misidentified
# as source DbContext files.

find_cs_file() {
    find . -name "$1" \
        -not -path "*/obj/*" \
        -not -path "*/bin/*" \
        -not -path "*/Migrations/*" \
        2>/dev/null | head -n 1
}

find_cs_files_nul() {
    find . -name "$1" \
        -not -path "*/obj/*" \
        -not -path "*/bin/*" \
        -not -path "*/Migrations/*" \
        -print0 2>/dev/null
}

# Extract namespace from a .cs file.
# Handles file-scoped  "namespace Foo;"  and block  "namespace Foo {"  styles.
# Also strips extra whitespace variants.
extract_namespace() {
    grep -m1 '^[[:space:]]*namespace' "$1" \
        | sed 's/^[[:space:]]*namespace[[:space:]]*//; s/[[:space:]]*[;{].*//'
}

add_context_namespace() {
    local ctx_name="$1"
    local db_ctx="$2"
    local ctx_file
    ctx_file=$(find_cs_file "${db_ctx}.cs")
    if [ -n "$ctx_file" ]; then
        local ns
        ns=$(extract_namespace "$ctx_file")
        [ -n "$ns" ] && pcs_add_using "$ctx_name" "$ns"
    fi
}

# ─── DbContext discovery ──────────────────────────────────────────────────────
# Lists all *Context.cs source files (excluding Migrations snapshots),
# lets the user pick one, or choose to create a new one.
# Prints the selected context name to stdout; all prompts go to stderr.

find_existing_context() {
    local contexts=()
    while IFS= read -r -d '' f; do
        contexts+=("$(basename "$f" .cs)")
    done < <(find_cs_files_nul "*Context.cs")

    if [ "${#contexts[@]}" -eq 0 ]; then echo ""; return; fi

    echo "Found existing DbContext(s):" >&2
    for i in "${!contexts[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${contexts[$i]}" >&2
    done
    echo "  0) Create a New Context" >&2

    local ctx_choice
    read -r -p "Select context [0-${#contexts[@]}]: " ctx_choice >&2

    if [[ "$ctx_choice" =~ ^[1-9][0-9]*$ ]] \
        && [ "$ctx_choice" -ge 1 ] \
        && [ "$ctx_choice" -le "${#contexts[@]}" ]; then
        echo "${contexts[$((ctx_choice-1))]}"
    else
        echo ""
    fi
}

# ─── DbSet injection into existing context ────────────────────────────────────
# When reusing an existing context for a new model, dotnet aspnet-codegenerator
# requires a DbSet<Model> property to already exist.  This function injects any
# missing DbSet properties before scaffolding runs.

inject_dbsets_into_context() {
    local ctx_name="$1"   # CTX array name
    local db_ctx="$2"     # DbContext class name
    shift 2
    local models=("$@")
    local -n _ctx_ds="$ctx_name"

    local ctx_file
    ctx_file=$(find_cs_file "${db_ctx}.cs")
    [ -z "$ctx_file" ] && return 0

    local model_ns="${_ctx_ds[project_ns]}.Models"
    if ! grep -q "^[[:space:]]*using ${model_ns};" "$ctx_file" 2>/dev/null; then
        if [ "${_ctx_ds[dry_run]}" = "0" ]; then
            backup_file "$ctx_file"
            awk -v ns="$model_ns" '
                /^using / { last_using=NR }
                { lines[NR]=$0 }
                END {
                    if (last_using == 0) { print "using " ns ";"; print "" }
                    for (i=1; i<=NR; i++) {
                        print lines[i]
                        if (i == last_using) { print "using " ns ";" }
                    }
                }
            ' "$ctx_file" > "${ctx_file}.tmp" && mv "${ctx_file}.tmp" "$ctx_file"
            log_info "Added using ${model_ns} to ${db_ctx}."
        fi
    fi

    for model in "${models[@]}"; do
        if grep -q "DbSet<${model}>" "$ctx_file" 2>/dev/null; then
            log_info "DbSet<${model}> already in ${db_ctx}."
            continue
        fi

        if [ "${_ctx_ds[dry_run]}" = "1" ]; then
            log_dry "Would add DbSet<${model}> to ${ctx_file}"
            continue
        fi

        log_info "Adding DbSet<${model}> to ${db_ctx}..."
        backup_file "$ctx_file"

        local set_line="    public DbSet<${model}> ${model}s { get; set; } = null!;"
        awk -v line="$set_line" '
            /^[[:space:]]*\}/ && !done { print line; done=1 }
            { print }
        ' "$ctx_file" > "${ctx_file}.tmp" && mv "${ctx_file}.tmp" "$ctx_file"

        log_success "DbSet<${model}> added to ${db_ctx}."
    done
}

# ─── Design-Time Factory ─────────────────────────────────────────────────────
# Generates an IDesignTimeDbContextFactory for the given DbContext.
# This prevents 'aspnet-codegenerator' from failing to resolve DbContextOptions
# when it executes Program.cs from an unexpected working directory.

ensure_designtime_factory() {
    local ctx_name="$1"
    local db_ctx="$2"
    local -n _ctx_df="$ctx_name"

    local factory_file="Data/${db_ctx}Factory.cs"
    if [ -f "$factory_file" ]; then
        return 0
    fi

    if [ "${_ctx_df[dry_run]}" = "1" ]; then
        log_dry "Would create IDesignTimeDbContextFactory: ${factory_file}"
        return 0
    fi

    log_info "Pre-generating design-time factory '${db_ctx}Factory'..."
    mkdir -p Data
    record_dir_created "Data"

    {
        echo "using Microsoft.EntityFrameworkCore;"
        echo "using Microsoft.EntityFrameworkCore.Design;"
        echo "using System;"
        echo ""
        echo "namespace ${_ctx_df[project_ns]}.Data;"
        echo ""
        echo "public class ${db_ctx}Factory : IDesignTimeDbContextFactory<${db_ctx}>"
        echo "{"
        echo "    public ${db_ctx} CreateDbContext(string[] args)"
        echo "    {"
        echo "        var optionsBuilder = new DbContextOptionsBuilder<${db_ctx}>();"
        echo "        var connStr = Environment.GetEnvironmentVariable(\"SCAFFOLD_CONN_STR\");"
        echo "        if (string.IsNullOrEmpty(connStr))"
        echo "        {"
        echo "            throw new InvalidOperationException(\"SCAFFOLD_CONN_STR environment variable is missing. Run via the scaffold tool.\");"
        echo "        }"
        echo "        optionsBuilder.${_ctx_df[db_use_method]}(connStr);"
        echo "        return new ${db_ctx}(optionsBuilder.Options);"
        echo "    }"
        echo "}"
    } | atomic_write "$factory_file"
    
    record_created "$factory_file"
}

# ─── Multi-project solution awareness ────────────────────────────────────────
# If a .sln is present and contains multiple .csproj files, prompts the user
# to pick which project to scaffold.  cd's into that project directory.
#
# FIX: Uses absolute paths (via pwd) so relative dirname can never fail under
#      strict mode.
# FIX: Guards the cd with a DRY_RUN check — dry-run never changes directory.

resolve_project_dir() {
    local ctx_name="$1"
    local -n _ctx_rpd="$ctx_name"
    local dry="${_ctx_rpd[dry_run]:-0}"

    local sln_count
    sln_count=$(find . -maxdepth 1 -name "*.sln" 2>/dev/null | wc -l | tr -d ' ')
    [ "$sln_count" -eq 0 ] && return 0

    local -a projs=()
    while IFS= read -r -d '' p; do
        projs+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")")
    done < <(find . -name "*.csproj" -not -path "*/obj/*" -print0 2>/dev/null)

    local csproj_count="${#projs[@]}"

    if [ "$csproj_count" -gt 1 ]; then
        printf "\n${C_INFO}Multiple projects found in solution:${C_RESET}\n" >&2
        for i in "${!projs[@]}"; do
            printf "  %d) %s\n" "$((i+1))" "${projs[$i]}" >&2
        done

        if [ "$dry" = "1" ]; then
            log_dry "Would cd into selected project directory."
            return 0
        fi

        local proj_choice
        read -r -p "Select project to scaffold [1-${csproj_count}]: " proj_choice >&2
        if [[ "$proj_choice" =~ ^[1-9][0-9]*$ ]] \
            && [ "$proj_choice" -ge 1 ] \
            && [ "$proj_choice" -le "$csproj_count" ]; then
            local proj_dir
            proj_dir="$(dirname "${projs[$((proj_choice-1))]}")"
            log_info "Switching to project: $proj_dir"
            cd "$proj_dir" || { log_error "Cannot enter: $proj_dir"; exit 1; }
        else
            log_error "Invalid project selection."
            exit 1
        fi

    elif [ "$csproj_count" -eq 1 ]; then
        local proj_dir current_dir
        proj_dir="$(dirname "${projs[0]}")"
        current_dir="$(pwd)"
        if [ "$proj_dir" != "$current_dir" ]; then
            log_info "Entering project: $proj_dir"
            if [ "$dry" = "0" ]; then
                cd "$proj_dir" || { log_error "Cannot enter: $proj_dir"; exit 1; }
            else
                log_dry "Would cd into: $proj_dir"
            fi
        fi
    fi
}

# ─── DB connectivity validation ──────────────────────────────────────────────
# Uses nc (netcat) or bash /dev/tcp — no dotnet-script dependency.
# Priority: nc -z  →  /dev/tcp  →  warn and continue

validate_db_connection() {
    local ctx_name="$1"
    local -n _ctx_db="$ctx_name"

    local conn_str="${_ctx_db[conn_str]:-}"
    local provider="${_ctx_db[db_provider]:-}"

    if [ "${_ctx_db[dry_run]}" = "1" ]; then
        log_dry "Would validate DB connection"
        return 0
    fi

    log_info "Validating database connectivity..."

    local host="" port=""

    case "$provider" in
        *SqlServer*)
            host=$(echo "$conn_str" | grep -oiE 'Server=([^;,]+)' | head -1 | sed 's/[Ss]erver=//')
            host=$(echo "$host" | sed 's/,.*//')
            port=$(echo "$conn_str" | grep -oiE 'Server=[^;]+,[0-9]+' | grep -oE '[0-9]+$' || echo "1433")
            ;;
        *PostgreSQL*|*Npgsql*)
            host=$(echo "$conn_str" | grep -oiE 'Host=([^;]+)' | head -1 | sed 's/[Hh]ost=//')
            port=$(echo "$conn_str" | grep -oiE 'Port=([0-9]+)' | head -1 | sed 's/[Pp]ort=//')
            port="${port:-5432}"
            ;;
        *Sqlite*)
            log_info "SQLite — no connectivity check needed."
            return 0
            ;;
        *)
            log_warn "Unknown provider — skipping connectivity check."
            return 0
            ;;
    esac

    host="${host:-localhost}"
    port="${port:-1433}"

    local connected=0
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && connected=1 || true
    elif (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
        connected=1
    else
        log_warn "Cannot verify DB connectivity (nc unavailable). Proceeding anyway."
        return 0
    fi

    if [ "$connected" -eq 1 ]; then
        log_success "Database reachable at ${host}:${port}."
    else
        log_error "Cannot reach database at ${host}:${port}."
        log_error "Check your .env connection string and ensure the DB server is running."
        exit 1
    fi
}

# ─── DB provider selection ────────────────────────────────────────────────────
# Populates the CTX array with provider-specific values.

select_db_provider() {
    local ctx_name="$1"
    local -n _ctx_prov="$ctx_name"

    printf "\n${C_INFO}Select Database Provider:${C_RESET}\n"
    printf "  1) SQL Server  (Microsoft.EntityFrameworkCore.SqlServer)\n"
    printf "  2) PostgreSQL  (Npgsql.EntityFrameworkCore.PostgreSQL)\n"
    printf "  3) SQLite      (Microsoft.EntityFrameworkCore.Sqlite)\n"
    read -r -p "Provider [1-3, default: 1]: " PROV_CHOICE
    PROV_CHOICE="${PROV_CHOICE:-1}"

    case "$PROV_CHOICE" in
        2)
            _ctx_prov[db_provider]="Npgsql.EntityFrameworkCore.PostgreSQL"
            _ctx_prov[db_use_method]="UseNpgsql"
            _CONN_NEEDS_CREDS="yes"
            _CONN_USER_HINT="postgres"
            ;;
        3)
            _ctx_prov[db_provider]="Microsoft.EntityFrameworkCore.Sqlite"
            _ctx_prov[db_use_method]="UseSqlite"
            _CONN_NEEDS_CREDS="no"
            _CONN_USER_HINT=""
            ;;
        *)
            _ctx_prov[db_provider]="Microsoft.EntityFrameworkCore.SqlServer"
            _ctx_prov[db_use_method]="UseSqlServer"
            _CONN_NEEDS_CREDS="yes"
            _CONN_USER_HINT="sa"
            ;;
    esac
}

# ─── .env file management ─────────────────────────────────────────────────────
# First-run: prompts for DB credentials, writes .env, sources it.
# Subsequent runs: loads existing .env.
# Dry-run: sets in-memory values without writing anything to disk.

load_env() {
    local ctx_name="$1"
    local -n _ctx_env="$ctx_name"
    local dry="${_ctx_env[dry_run]:-0}"
    local project_ns="${_ctx_env[project_ns]}"

    if [ "$dry" = "1" ] && [ ! -f .env ]; then
        log_dry "Would create .env (skipping in dry-run)"
        _ctx_env[conn_str]=""
        _ctx_env[db_provider]="Microsoft.EntityFrameworkCore.SqlServer"
        _ctx_env[db_use_method]="UseSqlServer"
        return 0
    fi

    if [ ! -f .env ]; then
        log_step ".env First-Run Setup"
        select_db_provider "$ctx_name"

        local DB_NAME DB_USER DB_PASS_RAW DB_PASS CONN
        read -r -p "  Database Name: " DB_NAME

        if [ "${_CONN_NEEDS_CREDS}" = "yes" ]; then
            read -r -p "  Database User [${_CONN_USER_HINT}]: " DB_USER
            DB_USER="${DB_USER:-${_CONN_USER_HINT}}"
            read -r -s -p "  Database Password: " DB_PASS_RAW
            echo ""
            # FIX: Escape double-quotes in password to protect .env format
            DB_PASS="${DB_PASS_RAW//\"/\\\"}"

            if [ "$PROV_CHOICE" = "2" ]; then
                CONN="Host=localhost;Database=${DB_NAME};Username=${DB_USER};Password=${DB_PASS};"
            else
                CONN="Server=localhost;Database=${DB_NAME};User Id=${DB_USER};Password=${DB_PASS};TrustServerCertificate=True;"
            fi
        else
            CONN="Data Source=${DB_NAME}.db;"
        fi

        atomic_write ".env" << EOF
SCAFFOLD_CONN_STR="${CONN}"
SCAFFOLD_DB_PROVIDER="${_ctx_env[db_provider]}"
SCAFFOLD_DB_USE_METHOD="${_ctx_env[db_use_method]}"
EOF
        log_success ".env created."

    else
        log_info ".env exists — loading."
    fi

    # Populate context from .env without sourcing (prevents variable expansion of passwords with $)
    if [ -f .env ]; then
        _ctx_env[conn_str]=$(grep '^SCAFFOLD_CONN_STR=' .env | head -n1 | sed -e 's/^SCAFFOLD_CONN_STR=//' -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
        _ctx_env[db_provider]=$(grep '^SCAFFOLD_DB_PROVIDER=' .env | head -n1 | sed -e 's/^SCAFFOLD_DB_PROVIDER=//' -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
        _ctx_env[db_use_method]=$(grep '^SCAFFOLD_DB_USE_METHOD=' .env | head -n1 | sed -e 's/^SCAFFOLD_DB_USE_METHOD=//' -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
    fi

    # Provide defaults if missing
    _ctx_env[db_provider]="${_ctx_env[db_provider]:-Microsoft.EntityFrameworkCore.SqlServer}"
    _ctx_env[db_use_method]="${_ctx_env[db_use_method]:-UseSqlServer}"

    # Export explicitly to ensure child 'dotnet' processes inherit them
    # This prevents DbContext activation failures during scaffolding.
    export SCAFFOLD_CONN_STR="${_ctx_env[conn_str]}"
    export SCAFFOLD_DB_PROVIDER="${_ctx_env[db_provider]}"
    export SCAFFOLD_DB_USE_METHOD="${_ctx_env[db_use_method]}"

    # .gitignore
    if [ ! -f .gitignore ] && [ "$dry" = "0" ]; then
        safe_run "Create .gitignore" dotnet new gitignore
    fi
    if ! grep -q "^\.env$" .gitignore 2>/dev/null; then
        if [ "$dry" = "1" ]; then
            log_dry "Would add .env to .gitignore"
        else
            echo ".env" >> .gitignore
            log_info "Added .env to .gitignore."
        fi
    fi
}
