#!/usr/bin/env bash
# options/opt_partialview.sh — Option 6: Empty or Strongly-Typed Partial View

run_partialview() {
    local ctx_name="$1"
    local -n _ctx_pv="$ctx_name"

    log_step "Partial View"
    phase_begin

    ensure_package "$ctx_name" "Microsoft.VisualStudio.Web.CodeGeneration.Design"

    local PARTIAL_NAME PARTIAL_MODEL PARTIAL_DIR
    read -r -p "Partial View Name (e.g. _UserCard): " PARTIAL_NAME
    read -r -p "Model Name (blank for empty partial): " PARTIAL_MODEL
    read -r -p "Output directory [Views/Shared]: "      PARTIAL_DIR
    PARTIAL_DIR="${PARTIAL_DIR:-Views/Shared}"

    if [ "${_ctx_pv[dry_run]}" = "1" ]; then
        log_dry "Would scaffold partial '${PARTIAL_NAME}' in '${PARTIAL_DIR}'"
        [ -n "$PARTIAL_MODEL" ] && log_dry "  Strongly typed: @model ${_ctx_pv[project_ns]}.Models.${PARTIAL_MODEL}"
        return 0
    fi

    mkdir -p "$PARTIAL_DIR"
    record_dir_created "$PARTIAL_DIR"

    if [ -z "$PARTIAL_MODEL" ]; then
        must_run "Scaffold empty partial" \
            dotnet aspnet-codegenerator view "$PARTIAL_NAME" Empty \
                -partial -outDir "$PARTIAL_DIR" -f
    else
        must_run "Scaffold typed partial" \
            dotnet aspnet-codegenerator view "$PARTIAL_NAME" Empty \
                -partial -m "$PARTIAL_MODEL" -outDir "$PARTIAL_DIR" -f
    fi

    log_success "Partial view '${PARTIAL_NAME}' created in '${PARTIAL_DIR}'."
}
