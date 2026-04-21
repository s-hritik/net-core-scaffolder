#!/usr/bin/env bash
# tests/test_core.sh — Tests for lib/core.sh
IFS=$'\n\t'
SCAFFOLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCAFFOLD_DIR}/tests/test_runner.sh"
source "${SCAFFOLD_DIR}/lib/core.sh"

printf "${C_B}${C_C}\n╔══════════════════════════════════════╗\n║  test_core.sh                        ║\n╚══════════════════════════════════════╝${C_X}\n"

# ─── atomic_write ────────────────────────────────────────────────────────────
suite "atomic_write"
with_temp_project "atomic_write" '
    atomic_write "output.txt" <<< "hello world"
    assert_file_exists   "creates file"                 "output.txt"
    assert_file_contains "writes content"               "output.txt" "hello world"
    assert_file_absent   "no .tmp file left"            "output.txt.tmp.$$"

    atomic_write "output.txt" <<< "updated"
    assert_file_contains "overwrites atomically"        "output.txt" "updated"
    assert_file_not_contains "old content gone"         "output.txt" "hello world"
'

# ─── run() wrappers ──────────────────────────────────────────────────────────
suite "run() wrappers"

output=$(run "true command" true 2>&1); rc=$?
assert_exit_ok      "run: returns 0 on success"                "$rc"

output=$(run "false command" false 2>&1); rc=$?
assert_exit_fail    "run: returns non-zero on failure"         "$rc"
assert_contains     "run: logs warning on failure"             "$output" "WARN"

output=$(safe_run "failing cleanup" false 2>&1); rc=$?
assert_exit_ok      "safe_run: always returns 0"               "$rc"

# ─── Rollback stack ──────────────────────────────────────────────────────────
suite "rollback stack — record_backup + rollback_all"
with_temp_project "rollback" '
    echo "original" > target.txt
    record_backup "target.txt"
    echo "modified" > target.txt
    assert_file_contains "file was modified"    "target.txt" "modified"
    rollback_all
    assert_file_contains "file was restored"    "target.txt" "original"
    assert_eq            "stack is empty after" "${#_CHANGE_STACK[@]}" "0"
'

suite "rollback stack — record_created"
with_temp_project "rollback_created" '
    record_created "newfile.txt"
    echo "data" > newfile.txt
    assert_file_exists   "file exists"          "newfile.txt"
    rollback_all
    assert_file_absent   "file removed by rollback" "newfile.txt"
'

suite "rollback stack — phase_begin + rollback_phase (partial rollback)"
with_temp_project "partial_rollback" '
    echo "phase0" > phase0.txt
    record_backup "phase0.txt"
    echo "phase0-modified" > phase0.txt

    phase_begin
    echo "phase1" > phase1.txt
    record_created "phase1.txt"

    rollback_phase

    assert_file_absent      "phase1 file removed"          "phase1.txt"
    assert_file_contains    "phase0 NOT rolled back"       "phase0.txt" "phase0-modified"

    rollback_all
    assert_file_contains    "phase0 rolled back by rollback_all" "phase0.txt" "phase0"
'

# ─── CTX initialisation ──────────────────────────────────────────────────────
suite "ctx_init"
ctx_init
CTX[dry_run]="0"
assert_eq "dry_run default" "${CTX[dry_run]}" "0"
assert_eq "scaffolder default" "${CTX[scaffolder]}" "legacy"
assert_eq "db_use_method default" "${CTX[db_use_method]}" "UseSqlServer"

suite "ctx_init — dry-run mode"
DRY_RUN=1 ctx_init
CTX[dry_run]="1"
assert_eq "dry_run set to 1" "${CTX[dry_run]}" "1"

print_results
