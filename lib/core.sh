#!/usr/bin/env bash
# lib/core.sh — Logging · run() wrappers · atomic I/O · granular rollback stack
# Requires bash 4.3+ (nameref support)

# ─── Colour / Logging ────────────────────────────────────────────────────────
C_RESET="\033[0m"; C_INFO="\033[36m"; C_SUCCESS="\033[32m"
C_WARN="\033[33m"; C_ERR="\033[31m";  C_DIM="\033[2m"

log_info()    { printf "${C_INFO}[INFO]${C_RESET}    %s\n" "$1"; }
log_success() { printf "${C_SUCCESS}[OK]${C_RESET}      %s\n" "$1"; }
log_warn()    { printf "${C_WARN}[WARN]${C_RESET}    %s\n" "$1"; }
log_error()   { printf "${C_ERR}[ERROR]${C_RESET}   %s\n" "$1"; }
log_step()    { printf "\n${C_INFO}━━━  %s  ━━━${C_RESET}\n" "$1"; }
log_dry()     { printf "${C_DIM}[DRY-RUN]${C_RESET} %s\n"  "$1"; }
log_phase()   { printf "\n${C_INFO}▶  Phase: %s${C_RESET}\n" "$1"; }

# ─── run() family — explicit per-command error handling ──────────────────────
#
# DESIGN RATIONALE:
# The original script used  set -euo pipefail  which made ANY non-zero exit
# (including harmless cleanup commands) abort the entire script.  These three
# wrappers give you per-call control without a global kill switch.
#
#   run()       — execute; log warning on failure; RETURN the exit code
#   must_run()  — execute; on failure rollback everything and EXIT 1
#   safe_run()  — execute; swallow non-zero silently (for cleanup commands)

run() {
    local description="$1"; shift
    if "$@" 2>&1; then
        return 0
    else
        local code=$?
        log_warn "Non-fatal failure ($code): $description"
        return $code
    fi
}

must_run() {
    local description="$1"; shift
    if ! run "$description" "$@"; then
        log_error "Fatal failure: $description"
        rollback_all
        exit 1
    fi
}

safe_run() {
    local description="$1"; shift
    "$@" >/dev/null 2>&1 || true
}

# ─── Atomic file write ────────────────────────────────────────────────────────
# Writes to .tmp.$$ then renames — prevents half-written files on crash.
atomic_write() {
    local dest="$1"
    local tmp="${TMPDIR:-/tmp}/scaffold_write_$$.tmp"
    cat > "$tmp" && mv "$tmp" "$dest"
}

# ─── Granular Rollback Stack ─────────────────────────────────────────────────
#
# Each file modification is recorded as a typed entry on a stack.
# On failure you can roll back:
#   rollback_all   — undo every recorded change
#   rollback_phase — undo only changes since the last phase_begin() call
#
# Entry format:  "TYPE:TARGET:BACKUP"
#   file    → restore TARGET from BACKUP
#   created → delete TARGET (file was newly created, no prior version)
#   dir     → rmdir TARGET  (directory was newly created)

declare -a _CHANGE_STACK=()
declare -i _PHASE_MARK=0
_BACKUP_ROOT="${TMPDIR:-/tmp}/scaffold_bak_$$"

_ensure_backup_root() {
    [ -d "$_BACKUP_ROOT" ] || mkdir -p "$_BACKUP_ROOT"
}

# Record that a file was backed up before modification
# Usage: record_backup "path/to/file.cs"
record_backup() {
    local file="$1"
    [ -f "$file" ] || return 0
    _ensure_backup_root
    local slot
    slot="${_BACKUP_ROOT}/$(echo "$file" | tr '/' '_')_${#_CHANGE_STACK[@]}"
    cp "$file" "$slot"
    _CHANGE_STACK+=("file:${file}:${slot}")
}

# Record that a file was freshly created (rollback = delete it)
record_created() {
    _CHANGE_STACK+=("created:${1}:")
}

# Record that a directory was freshly created (rollback = remove it if empty)
record_dir_created() {
    _CHANGE_STACK+=("dir:${1}:")
}

# Set the current rollback mark (call at the start of each phase)
phase_begin() {
    _PHASE_MARK=${#_CHANGE_STACK[@]}
}

# Convenience: backup a file AND record it in one call
backup_file() {
    record_backup "$1"
}

# Apply a single rollback entry
_apply_rollback() {
    local entry="$1"
    local type="${entry%%:*}"
    local rest="${entry#*:}"
    local target="${rest%%:*}"
    local backup="${rest#*:}"

    case "$type" in
        file)
            if [ -f "$backup" ]; then
                mv "$backup" "$target"
                log_warn "  Restored: $target"
            fi
            ;;
        created)
            if [ -f "$target" ]; then
                rm -f "$target"
                log_warn "  Removed:  $target"
            fi
            ;;
        dir)
            if [ -d "$target" ] && [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
                rmdir "$target"
                log_warn "  Removed dir: $target"
            fi
            ;;
    esac
}

# Roll back only the current phase (since last phase_begin)
rollback_phase() {
    log_warn "Rolling back phase..."
    local i
    for (( i=${#_CHANGE_STACK[@]}-1; i>=_PHASE_MARK; i-- )); do
        _apply_rollback "${_CHANGE_STACK[$i]}"
    done
    _CHANGE_STACK=("${_CHANGE_STACK[@]:0:$_PHASE_MARK}")
}

# Roll back ALL recorded changes
rollback_all() {
    if [ ${#_CHANGE_STACK[@]} -eq 0 ]; then return 0; fi
    log_warn "Rolling back all changes..."
    local i
    for (( i=${#_CHANGE_STACK[@]}-1; i>=0; i-- )); do
        _apply_rollback "${_CHANGE_STACK[$i]}"
    done
    _CHANGE_STACK=()
    [ -d "$_BACKUP_ROOT" ] && rm -rf "$_BACKUP_ROOT"
}

# Clean up backup root on successful completion
cleanup_backups() {
    [ -d "$_BACKUP_ROOT" ] && rm -rf "$_BACKUP_ROOT"
    _CHANGE_STACK=()
}

# ─── appsettings.json protection ─────────────────────────────────────────────
# The codegenerator injects a temporary ConnectionStrings block.
# We snapshot before and restore after every scaffold invocation.
protect_appsettings() {
    record_backup "appsettings.json"
}

restore_appsettings() {
    local slot
    for entry in "${_CHANGE_STACK[@]}"; do
        [[ "$entry" == file:appsettings.json:* ]] || continue
        slot="${entry##*:}"
        if [ -f "$slot" ]; then
            cp "$slot" "appsettings.json"
            log_info "appsettings.json restored."
        fi
        return 0
    done
}

# ─── Context (CTX) struct ─────────────────────────────────────────────────────
#
# Instead of scattered globals, every piece of project state lives in one
# associative array.  Functions receive it by nameref (bash 4.3+).
#
# Usage inside a function:
#   my_fn() {
#       local -n ctx="$1"
#       echo "${ctx[project_ns]}"
#   }
#   my_fn CTX

declare -A CTX=()

ctx_init() {
    CTX[dry_run]="${DRY_RUN:-0}"
    CTX[csproj]=""
    CTX[project_name]=""
    CTX[project_ns]=""
    CTX[tfm]=""
    CTX[sdk_ver]=""
    CTX[sdk_major]="8"
    CTX[pkg_ver]="8.0.*"
    CTX[scaffolder]="legacy"
    CTX[db_use_method]="UseSqlServer"
    CTX[db_provider]="Microsoft.EntityFrameworkCore.SqlServer"
    CTX[conn_str]=""
    CTX[roslyn_available]="0"
    CTX[roslyn_script_path]=""
}

ctx_dump() {
    log_info "Context:"
    local key
    for key in "${!CTX[@]}"; do
        printf "  %-20s = %s\n" "$key" "${CTX[$key]}"
    done
}
