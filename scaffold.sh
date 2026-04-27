#!/usr/bin/env bash
# scaffold.sh — .NET Scaffolding Master  v5.0
# Entry point: parses args · loads libs · resolves project · shows menu · dispatches
#
# Architecture:
#   lib/core.sh         — logging, run() wrappers, atomic I/O, rollback stack, CTX struct
#   lib/program_cs.sh   — Program.cs injection primitives (Roslyn + awk fallback)
#   lib/packages.sh     — NuGet + dotnet local tool management
#   lib/project.sh      — project discovery, file search, .env, DB validation
#   options/opt_*.sh    — one file per menu option (self-contained, independently testable)

# ─── Bash version guard ───────────────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf "[ERROR] bash 4.3+ required (you have %s)\n" "$BASH_VERSION" >&2
    printf "macOS users: brew install bash && sudo bash -c 'echo /opt/homebrew/bin/bash >> /etc/shells'\n" >&2
    exit 1
fi

# ─── Strict mode (IFS only — no set -e, no set -u) ───────────────────────────
# set -e is intentionally ABSENT.  All error handling is done explicitly
# via run() / must_run() / safe_run() in lib/core.sh.
# set -u is intentionally ABSENT.  Unset variables are handled with ${var:-default}.
IFS=$'\n\t'

# ─── Locate script directory (works even when called via symlink) ─────────────
SCAFFOLD_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

# ─── Source libraries ─────────────────────────────────────────────────────────
source "${SCAFFOLD_DIR}/lib/core.sh"
source "${SCAFFOLD_DIR}/lib/program_cs.sh"
source "${SCAFFOLD_DIR}/lib/packages.sh"
source "${SCAFFOLD_DIR}/lib/project.sh"

# ─── Source option handlers ───────────────────────────────────────────────────
source "${SCAFFOLD_DIR}/options/opt_dbfirst.sh"
source "${SCAFFOLD_DIR}/options/opt_crud.sh"
source "${SCAFFOLD_DIR}/options/opt_identity.sh"
source "${SCAFFOLD_DIR}/options/opt_partialview.sh"

# ─── Parse CLI arguments ──────────────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h)
            printf "Usage: scaffold [--dry-run|-n]\n\n"
            printf "  --dry-run  Show what would happen without modifying any files.\n\n"
            printf "Options:\n"
            printf "  1) DB-First          Reverse-engineer existing DB into Models + DbContext\n"
            printf "  2) Web API           Full CRUD API Controllers\n"
            printf "  3) MVC               Full CRUD Controllers + Razor Views\n"
            printf "  4) Razor Pages       Full CRUD Razor Pages\n"
            printf "  5) Identity          Complete Auth UI + Program.cs wiring\n"
            printf "  6) Partial View      Empty or Strongly-Typed partial view\n"
            printf "  7) Blazor            Full CRUD Blazor pages (.NET 9+ only)\n"
            exit 0
            ;;
    esac
done

# ─── Interrupt / crash handler ────────────────────────────────────────────────
_on_interrupt() {
    printf "\n${C_ERR}[!] Interrupted.${C_RESET}\n"
    restore_appsettings
    rollback_all
    exit 1
}
trap '_on_interrupt' SIGINT SIGTERM

# ─── Banner ───────────────────────────────────────────────────────────────────
clear
echo "═══════════════════════════════════════════════"
printf " ${C_INFO}🚀  .NET Scaffolding Master  v5.0${C_RESET}\n"
[ "$DRY_RUN" -eq 1 ] && printf " ${C_DIM}    ── DRY-RUN MODE — nothing will be written ──${C_RESET}\n"
echo "═══════════════════════════════════════════════"

# ─── Initialise context struct ────────────────────────────────────────────────
ctx_init
CTX[dry_run]="$DRY_RUN"

# ─── Project resolution ───────────────────────────────────────────────────────
resolve_project_dir "CTX"

CSPROJ="$(find . -maxdepth 1 -name "*.csproj" 2>/dev/null | head -n 1 || true)"
if [ -z "$CSPROJ" ]; then
    log_error "No .csproj found. Run from inside a project folder or solution root."
    exit 1
fi
CSPROJ="$(basename "$CSPROJ")"
CTX[csproj]="$CSPROJ"
CTX[project_name]="$(basename "$CSPROJ" .csproj)"
CTX[project_ns]="$(echo "${CTX[project_name]}" | tr '-' '_')"

# ─── Parse target framework ───────────────────────────────────────────────────
TFM="$(awk -F'[<>]' '/TargetFramework/ {print $3; exit}' "$CSPROJ" || true)"
SDK_VER="$(echo "$TFM" | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
SDK_MAJOR="$(echo "${SDK_VER:-8.0}" | cut -d. -f1)"
CTX[tfm]="$TFM"
CTX[sdk_ver]="${SDK_VER:-8.0}"
CTX[sdk_major]="$SDK_MAJOR"
CTX[pkg_ver]="${SDK_VER:-8.0}.*"

if [ "${SDK_MAJOR:-8}" -ge 9 ] 2>/dev/null; then
    CTX[scaffolder]="new"
    log_info "SDK .NET ${SDK_VER} → dotnet scaffold (Roslyn-backed)"
else
    CTX[scaffolder]="legacy"
    log_info "SDK .NET ${SDK_VER} → dotnet aspnet-codegenerator"
fi

log_info "Project: ${CTX[project_name]}  |  TFM: $TFM  |  Pkg: ${CTX[pkg_ver]}"

# ─── .env + DB provider ───────────────────────────────────────────────────────
load_env "CTX"

# ─── Local dotnet tools ───────────────────────────────────────────────────────
check_tools "CTX"

# ─── DB connectivity check ────────────────────────────────────────────────────
[ "${CTX[dry_run]}" = "0" ] && validate_db_connection "CTX"

# ─── Main menu ────────────────────────────────────────────────────────────────
printf "\nSelect an action:\n"
printf "  1) DB-First          (Scaffold DbContext + Models from existing DB)\n"
printf "  2) Web API           (Full CRUD API Controllers)\n"
printf "  3) MVC               (Full CRUD Controllers + Razor Views)\n"
printf "  4) Razor Pages       (Full CRUD Razor Pages)\n"
printf "  5) Identity          (Complete Auth UI + full Program.cs wiring)\n"
printf "  6) Partial View      (Empty or Strongly-Typed)\n"
printf "  7) Blazor Components (Full CRUD Blazor pages — .NET 9+ only)\n"
printf "  8) Exit\n"
read -r -p "Choice [1-8]: " CHOICE

[ "$CHOICE" = "8" ] && exit 0

# ─── Dispatch to option handler ───────────────────────────────────────────────
case $CHOICE in
    1)   run_dbfirst     "CTX" ;;
    2|3|4|7) run_crud    "CTX" "$CHOICE" ;;
    5)   run_identity    "CTX" ;;
    6)   run_partialview "CTX" ;;
    *)   log_error "Invalid choice: $CHOICE"; exit 1 ;;
esac

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_backups
[ -n "${CTX[roslyn_script_path]:-}" ] && rm -f "${CTX[roslyn_script_path]}"

printf "\n"
if [ "${CTX[dry_run]}" = "1" ]; then
    log_warn "DRY-RUN complete — no files were modified."
else
    log_success "✅  Operation complete. Run 'dotnet build' to verify."
fi
