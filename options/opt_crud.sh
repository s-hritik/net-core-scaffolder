#!/usr/bin/env bash
# options/opt_crud.sh — Options 2/3/4/7: Web API · MVC · Razor Pages · Blazor

# ─── Scaffolder dispatch ──────────────────────────────────────────────────────

_scaffold_controller() {
    local ctx_name="$1" model="$2" db_ctx="$3" choice="$4" use_ef="$5"
    local -n _ctx_sc="$ctx_name"

    [ "${_ctx_sc[dry_run]}" = "1" ] && { log_dry "Would scaffold controller: $model (option $choice)"; return 0; }

    if [ "${_ctx_sc[scaffolder]}" = "new" ]; then
        case "$choice" in
            2) must_run "Scaffold API controller" \
                   dotnet scaffold controller --model "$model" --dataContext "$db_ctx" \
                       --restController --force --project . ;;
            3) must_run "Scaffold MVC controller" \
                   dotnet scaffold controller --model "$model" --dataContext "$db_ctx" \
                       --force --project . ;;
        esac
    else
        if [[ "$use_ef" =~ ^[Yy]$ ]]; then
            case "$choice" in
                2) must_run "Scaffold API controller" \
                       dotnet aspnet-codegenerator controller \
                           -name "${model}sController" -m "$model" -dc "$db_ctx" \
                           -api -async -outDir Controllers -f ;;
                3) must_run "Scaffold MVC controller" \
                       dotnet aspnet-codegenerator controller \
                           -name "${model}sController" -m "$model" -dc "$db_ctx" \
                           --relativeFolderPath Controllers \
                           --useDefaultLayout --referenceScriptLibraries -f ;;
            esac
        else
            case "$choice" in
                2) must_run "Scaffold empty API controller" \
                       dotnet aspnet-codegenerator controller \
                           -name "${model}sController" -api -outDir Controllers -f ;;
                3) must_run "Scaffold empty MVC controller" \
                       dotnet aspnet-codegenerator controller \
                           -name "${model}sController" -actions -outDir Controllers -f
                   log_info "Generating standard Views for '${model}'..."
                   local VNAME VTMPL
                   for PAIR in "Index:List" "Details:Details" "Create:Create" \
                               "Edit:Edit" "Delete:Delete"; do
                       VNAME="${PAIR%%:*}"; VTMPL="${PAIR##*:}"
                       must_run "Scaffold view $VNAME" \
                           dotnet aspnet-codegenerator view "$VNAME" "$VTMPL" \
                               -m "$model" -outDir "Views/${model}s" -udl -f
                   done ;;
            esac
        fi
    fi
}

_scaffold_razorpage() {
    local ctx_name="$1" model="$2" db_ctx="$3" use_ef="$4"
    local -n _ctx_rp="$ctx_name"

    [ "${_ctx_rp[dry_run]}" = "1" ] && { log_dry "Would scaffold Razor Pages: $model"; return 0; }

    if [ "${_ctx_rp[scaffolder]}" = "new" ]; then
        must_run "Scaffold Razor Pages" \
            dotnet scaffold razorpage --model "$model" --dataContext "$db_ctx" \
                --force --project .
    else
        if [[ "$use_ef" =~ ^[Yy]$ ]]; then
            must_run "Scaffold Razor Pages (EF)" \
                dotnet aspnet-codegenerator razorpage \
                    -m "$model" -dc "$db_ctx" -udl \
                    -outDir "Pages/${model}s" --referenceScriptLibraries -f
        else
            must_run "Scaffold Razor Pages (no EF)" \
                dotnet aspnet-codegenerator razorpage \
                    -n "$model" -outDir "Pages/${model}s" -f
        fi
    fi
}

_scaffold_blazor() {
    local ctx_name="$1" model="$2" db_ctx="$3"
    local -n _ctx_bl="$ctx_name"

    [ "${_ctx_bl[dry_run]}" = "1" ] && { log_dry "Would scaffold Blazor (.NET 9+ only): $model"; return 0; }

    # FIX: dotnet aspnet-codegenerator has no 'blazor' subcommand in .NET 8.
    # Blazor scaffolding only exists in dotnet scaffold (.NET 9+).
    if [ "${_ctx_bl[scaffolder]}" = "new" ]; then
        ensure_package "$ctx_name" "Microsoft.AspNetCore.Components.Web"
        must_run "Scaffold Blazor" \
            dotnet scaffold blazor --model "$model" --dataContext "$db_ctx" \
                --force --project .
    else
        log_error "Blazor scaffolding requires .NET 9+ (your project targets .NET ${_ctx_bl[sdk_ver]})."
        log_error "Use option 3 (MVC) or option 4 (Razor Pages) for .NET 8."
        return 1
    fi
}

# ─── AutoMapper wiring ────────────────────────────────────────────────────────

_setup_automapper() {
    local ctx_name="$1"
    local -n _ctx_am="$ctx_name"
    local project_ns="${_ctx_am[project_ns]}"

    ensure_package "$ctx_name" "AutoMapper.Extensions.Microsoft.DependencyInjection"

    if [ ! -f "Mapping/MappingProfile.cs" ]; then
        if [ "${_ctx_am[dry_run]}" = "1" ]; then
            log_dry "Would create Mapping/MappingProfile.cs"
        else
            log_info "Creating Mapping/MappingProfile.cs..."
            mkdir -p Mapping
            record_dir_created "Mapping"
            atomic_write "Mapping/MappingProfile.cs" << EOF
using AutoMapper;

namespace ${project_ns}.Mapping;

public class MappingProfile : Profile
{
    public MappingProfile()
    {
    }
}
EOF
            record_created "Mapping/MappingProfile.cs"
        fi
    fi

    if ! grep -q "AddAutoMapper" Program.cs 2>/dev/null; then
        # AppDomain overload works across all AutoMapper versions including v13+
        pcs_inject_after_builder "$ctx_name" \
            "AddAutoMapper_unique" \
            "builder.Services.AddAutoMapper(AppDomain.CurrentDomain.GetAssemblies());"
        pcs_add_using "$ctx_name" "${project_ns}.Mapping"
    fi
}

# ─── Main handler ─────────────────────────────────────────────────────────────

run_crud() {
    local ctx_name="$1"
    local choice="$2"
    local -n _ctx_cr="$ctx_name"

    log_step "CRUD Scaffold  (option $choice)"
    phase_begin

    local USE_EF
    read -r -p "Use Entity Framework for Data Access? (Y/n): " USE_EF
    USE_EF="${USE_EF:-Y}"

    local DB_CONTEXT=""
    if [[ "$USE_EF" =~ ^[Yy]$ ]]; then
        DB_CONTEXT=$(find_existing_context)
        [ -z "$DB_CONTEXT" ] && read -r -p "Enter NEW DbContext Name: " DB_CONTEXT
        ensure_package "$ctx_name" \
            "Microsoft.VisualStudio.Web.CodeGeneration.Design" \
            "Microsoft.EntityFrameworkCore.Design" \
            "Microsoft.EntityFrameworkCore.Tools" \
            "${_ctx_cr[db_provider]}"
    else
        ensure_package "$ctx_name" "Microsoft.VisualStudio.Web.CodeGeneration.Design"
    fi

    local USE_AUTOMAPPER="N"
    if [ "$choice" -eq 2 ]; then
        read -r -p "Install and configure AutoMapper for DTOs? (Y/n): " USE_AUTOMAPPER
        USE_AUTOMAPPER="${USE_AUTOMAPPER:-Y}"
    fi

    local -a MODELS=()
    IFS=' ' read -r -p "Model name(s) separated by spaces: " -a MODELS
    if [ "${#MODELS[@]}" -eq 0 ] || [ -z "${MODELS[0]:-}" ]; then
        log_error "No model names provided. Re-run and enter at least one model."
        exit 1
    fi

    # Auto-generate stubs for missing model files
    local MODEL MODEL_FILE
    for MODEL in "${MODELS[@]}"; do
        MODEL_FILE=$(find_cs_file "${MODEL}.cs")
        if [ -z "$MODEL_FILE" ]; then
            log_warn "Model '${MODEL}.cs' not found — generating stub..."
            if [ "${_ctx_cr[dry_run]}" = "1" ]; then
                log_dry "Would create Models/${MODEL}.cs"
            else
                mkdir -p Models
                record_dir_created "Models"
                atomic_write "Models/${MODEL}.cs" << EOF
namespace ${_ctx_cr[project_ns]}.Models;

public class ${MODEL}
{
    public int Id { get; set; }
}
EOF
                record_created "Models/${MODEL}.cs"
            fi
        fi
    done

    # EF: create or update DbContext
    if [[ "$USE_EF" =~ ^[Yy]$ ]]; then
        local CTX_FILE
        CTX_FILE=$(find_cs_file "${DB_CONTEXT}.cs")
        if [ -z "$CTX_FILE" ]; then
            if [ "${_ctx_cr[dry_run]}" = "1" ]; then
                log_dry "Would create Data/${DB_CONTEXT}.cs with DbSet<> for: ${MODELS[*]}"
            else
                log_info "Pre-generating DbContext stub '${DB_CONTEXT}'..."
                mkdir -p Data
                record_dir_created "Data"
                local M
                {
                    echo "using Microsoft.EntityFrameworkCore;"
                    echo "using ${_ctx_cr[project_ns]}.Models;"
                    echo ""
                    echo "namespace ${_ctx_cr[project_ns]}.Data;"
                    echo ""
                    echo "public class ${DB_CONTEXT} : DbContext"
                    echo "{"
                    echo "    public ${DB_CONTEXT}(DbContextOptions<${DB_CONTEXT}> options)"
                    echo "        : base(options) { }"
                    echo ""
                    for M in "${MODELS[@]}"; do
                        echo "    public DbSet<${M}> ${M}s { get; set; } = null!;"
                    done
                    echo "}"
                } | atomic_write "Data/${DB_CONTEXT}.cs"
                record_created "Data/${DB_CONTEXT}.cs"
            fi
        fi
        # FIX: Inject missing DbSets into existing context before scaffolding
        inject_dbsets_into_context "$ctx_name" "$DB_CONTEXT" "${MODELS[@]}"
        fix_ef_namespace "$ctx_name"
        setup_program_cs "$ctx_name" "$DB_CONTEXT"
    fi

    # AutoMapper
    if [ "$choice" -eq 2 ] && [[ "$USE_AUTOMAPPER" =~ ^[Yy]$ ]]; then
        _setup_automapper "$ctx_name"
    fi

    pre_scaffold_build "$ctx_name"
    protect_appsettings

    for MODEL in "${MODELS[@]}"; do
        log_info "Scaffolding '${MODEL}'..."
        case "$choice" in
            2|3) _scaffold_controller "$ctx_name" "$MODEL" "${DB_CONTEXT:-}" "$choice" "$USE_EF" ;;
            4)   _scaffold_razorpage  "$ctx_name" "$MODEL" "${DB_CONTEXT:-}" "$USE_EF" ;;
            7)
                if [[ "$USE_EF" =~ ^[Yy]$ ]]; then
                    _scaffold_blazor "$ctx_name" "$MODEL" "$DB_CONTEXT"
                else
                    log_error "Blazor requires Entity Framework. Skipping '${MODEL}'."
                    continue
                fi ;;
        esac
    done

    restore_appsettings

    if [[ "$USE_EF" =~ ^[Yy]$ ]]; then
        log_warn "Scaffolding complete (Code-First)!"
        log_info "Run migrations:"
        printf "    dotnet ef migrations add InitialCreate\n"
        printf "    dotnet ef database update\n"
    else
        log_success "Scaffolding complete (disconnected — no EF)."
    fi
}
