#!/usr/bin/env bash
# options/opt_dbfirst.sh — Option 1: Reverse-engineer DB into Models + DbContext

run_dbfirst() {
    local ctx_name="$1"
    local -n _ctx_df="$ctx_name"

    log_step "DB-First Scaffold"
    phase_begin

    local DB_CONTEXT
    DB_CONTEXT=$(find_existing_context)
    [ -z "$DB_CONTEXT" ] && read -r -p "Enter NEW DbContext Name: " DB_CONTEXT
    DB_CONTEXT="${DB_CONTEXT:-AppDbContext}"

    ensure_package "$ctx_name" \
        "Microsoft.EntityFrameworkCore.Design" \
        "${_ctx_df[db_provider]}"

    if [ "${_ctx_df[dry_run]}" = "0" ]; then
        safe_run "Shutdown build server" dotnet build-server shutdown
        safe_run "Clean project"        dotnet clean -v q

        must_run "Restore packages"    dotnet restore --nologo -v q

        log_info "Reverse-engineering DB → Models + DbContext..."
        mkdir -p Data
        # FIX: --context-dir Data ensures context lands in Data/ not Models/
        must_run "Scaffold DbContext" \
            dotnet ef dbcontext scaffold \
                "${_ctx_df[conn_str]}" \
                "${_ctx_df[db_provider]}" \
                -c "$DB_CONTEXT" \
                -o Models \
                --context-dir Data \
                --force \
                --no-onconfiguring
    else
        log_dry "Would run: dotnet ef dbcontext scaffold ... -c $DB_CONTEXT"
        log_dry "  Output: Models/ (context in Data/)"
    fi

    fix_ef_namespace "$ctx_name"
    setup_program_cs "$ctx_name" "$DB_CONTEXT"

    log_warn "DB-First scaffolding complete!"
    log_info "Run migrations if needed:"
    printf "    dotnet ef migrations add InitialCreate\n"
    printf "    dotnet ef database update\n"
}
