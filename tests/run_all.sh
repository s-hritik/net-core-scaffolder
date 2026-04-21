#!/usr/bin/env bash
# tests/run_all.sh — Run all test suites and report combined results
IFS=$'\n\t'
SCAFFOLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf "${C_B:-}\033[36m\n╔══════════════════════════════════════════════╗\n║  scaffold.sh — Complete Test Suite           ║\n╚══════════════════════════════════════════════╝\033[0m${C_X:-}\n"

TOTAL_PASS=0; TOTAL_FAIL=0; SUITE_RESULTS=()

run_suite() {
    local file="$1"
    local name
    name="$(basename "$file")"
    local output exit_code

    output=$(bash "$file" 2>&1)
    exit_code=$?

    local pass fail
    pass=$(echo "$output" | grep -c "✓" 2>/dev/null || true)
    fail=$(echo "$output" | grep -c "✗" 2>/dev/null || true)
    pass=${pass:-0}
    fail=${fail:-0}
    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))

    if [ "$exit_code" -eq 0 ]; then
        printf "\033[32m✓\033[0m  %-40s  %d passed\n" "$name" "$pass"
    else
        printf "\033[31m✗\033[0m  %-40s  %d passed, %d FAILED\n" "$name" "$pass" "$fail"
        echo "$output" | grep "✗" | sed 's/^/    /'
    fi
    SUITE_RESULTS+=("$exit_code")
}

for test_file in "${SCAFFOLD_DIR}/tests"/test_*.sh; do
    run_suite "$test_file"
done

TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
SCORE=0
[ "$TOTAL" -gt 0 ] && SCORE=$(( (TOTAL_PASS * 100) / TOTAL ))

printf "\n\033[1m\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
printf "  Total: \033[1m%d\033[0m  |  \033[32mPassed: %d\033[0m  |  \033[31mFailed: %d\033[0m  |  Score: \033[1m%d%%\033[0m\n\n" \
    "$TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL" "$SCORE"

[ "$TOTAL_FAIL" -gt 0 ] && exit 1 || exit 0
