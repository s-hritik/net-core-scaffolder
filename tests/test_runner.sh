#!/usr/bin/env bash
# tests/test_runner.sh — Lightweight test framework
# Source this file in any test script to get assert helpers + reporting.
IFS=$'\n\t'

_PASS=0; _FAIL=0; _SKIP=0
_FAILURES=()
_CURRENT_SUITE=""

C_G="\033[32m"; C_R="\033[31m"; C_Y="\033[33m"
C_C="\033[36m"; C_B="\033[1m";  C_D="\033[2m"; C_X="\033[0m"

suite() { _CURRENT_SUITE="$1"; printf "\n${C_C}${C_B}▶  %s${C_X}\n" "$1"; }
pass()  { _PASS=$((_PASS+1));  printf "  ${C_G}✓${C_X} %s\n" "$1"; }
fail()  { _FAIL=$((_FAIL+1));  _FAILURES+=("${_CURRENT_SUITE} › $1 | $2"); printf "  ${C_R}✗${C_X} ${C_B}%s${C_X}\n    ${C_D}→ %s${C_X}\n" "$1" "$2"; }
skip()  { _SKIP=$((_SKIP+1));  printf "  ${C_Y}◌${C_X} SKIP: %s\n" "$1"; }

assert_eq()             { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected='$3' got='$2'"; }
assert_ne()             { [ "$2" != "$3" ] && pass "$1" || fail "$1" "should differ but both='$2'"; }
assert_contains()       { echo "$2" | grep -qF "$3" && pass "$1" || fail "$1" "«$3» not in output"; }
assert_not_contains()   { echo "$2" | grep -qF "$3" && fail "$1" "«$3» should NOT appear" || pass "$1"; }
assert_file_exists()    { [ -f "$2" ] && pass "$1" || fail "$1" "file missing: $2"; }
assert_file_absent()    { [ ! -f "$2" ] && pass "$1" || fail "$1" "file should not exist: $2"; }
assert_file_contains()  { grep -qF "$3" "$2" 2>/dev/null && pass "$1" || fail "$1" "«$3» not in file $2"; }
assert_file_not_contains() { grep -qF "$3" "$2" 2>/dev/null && fail "$1" "«$3» should NOT be in $2" || pass "$1"; }
assert_exit_ok()        { [ "$2" -eq 0 ] && pass "$1" || fail "$1" "expected exit 0, got $2"; }
assert_exit_fail()      { [ "$2" -ne 0 ] && pass "$1" || fail "$1" "expected non-zero, got $2"; }
assert_dir_exists()     { [ -d "$2" ] && pass "$1" || fail "$1" "dir missing: $2"; }

# Create an isolated temp project dir, run a test body, then clean up
with_temp_project() {
    local test_name="$1"; shift
    local body="$1"
    local dir
    dir=$(mktemp -d "/tmp/scaffold_test_XXXXXX")
    pushd "$dir" > /dev/null
    eval "$body"
    local rc=$?
    popd > /dev/null
    rm -rf "$dir"
    return $rc
}

print_results() {
    local total=$((_PASS + _FAIL + _SKIP))
    local score=0
    [ "$total" -gt 0 ] && score=$(( (_PASS * 100) / total ))

    printf "\n${C_B}${C_C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_X}\n"
    printf "${C_B}  Results${C_X}\n"
    printf "${C_C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_X}\n"
    printf "  Total  : ${C_B}%d${C_X}\n" "$total"
    printf "  ${C_G}Passed : %d${C_X}\n" "$_PASS"
    printf "  ${C_R}Failed : %d${C_X}\n" "$_FAIL"
    printf "  ${C_Y}Skipped: %d${C_X}\n" "$_SKIP"

    if [ "${#_FAILURES[@]}" -gt 0 ]; then
        printf "\n${C_R}${C_B}  Failures:${C_X}\n"
        for entry in "${_FAILURES[@]}"; do
            local tname="${entry%% |*}"
            local reason="${entry##* | }"
            printf "  ${C_R}✗${C_X} %-55s ${C_D}%s${C_X}\n" "$tname" "$reason"
        done
    fi

    printf "\n  ${C_B}Score: %d / %d  (%d%%)${C_X}\n\n" "$_PASS" "$total" "$score"
    [ "$_FAIL" -eq 0 ]
}
