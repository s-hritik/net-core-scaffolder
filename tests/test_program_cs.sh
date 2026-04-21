#!/usr/bin/env bash
# tests/test_program_cs.sh — Tests for all Program.cs injection primitives
IFS=$'\n\t'
SCAFFOLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCAFFOLD_DIR}/tests/test_runner.sh"
source "${SCAFFOLD_DIR}/lib/core.sh"
source "${SCAFFOLD_DIR}/lib/packages.sh"
source "${SCAFFOLD_DIR}/lib/program_cs.sh"

printf "${C_B}${C_C}\n╔══════════════════════════════════════╗\n║  test_program_cs.sh                  ║\n╚══════════════════════════════════════╝${C_X}\n"

# ─── Helpers ─────────────────────────────────────────────────────────────────
make_standard_program() {
    cat > Program.cs << 'EOF'
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
var app = builder.Build();
app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();
app.Run();
EOF
}

make_minimal_program() {
    cat > Program.cs << 'EOF'
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
app.UseHttpsRedirection();
app.MapControllers();
app.Run();
EOF
}

make_context() {
    declare -gA TEST_CTX=()
    TEST_CTX[dry_run]="0"
    TEST_CTX[db_use_method]="UseSqlServer"
    TEST_CTX[project_ns]="TestApp"
    TEST_CTX[roslyn_available]="0"
    TEST_CTX[roslyn_script_path]=""
}

# ─── add_using ───────────────────────────────────────────────────────────────
suite "pcs_add_using"
with_temp_project "add_using" '
    make_context
    make_standard_program

    pcs_add_using "TEST_CTX" "System.Text.Json"
    assert_file_contains "inserts namespace" "Program.cs" "using System.Text.Json;"

    pcs_add_using "TEST_CTX" "System.Text.Json"
    count=$(grep -c "using System.Text.Json;" Program.cs)
    assert_eq "idempotent — no duplicate" "$count" "1"

    pcs_add_using "TEST_CTX" "System.Collections.Generic"
    assert_file_contains "second using added" "Program.cs" "using System.Collections.Generic;"
'

# ─── inject_after_builder — formatting variants ───────────────────────────────
suite "awk_fallback_op inject-after-builder — format variants"

test_inject_after() {
    local label="$1" program_content="$2"
    local dir; dir=$(mktemp -d "/tmp/pcs_test_XXXXXX")
    pushd "$dir" > /dev/null
    echo "$program_content" > Program.cs
    awk_fallback_op "inject-after-builder" "Env.Load();" "Env.Load();"
    local found; found=$(grep -c "Env.Load();" Program.cs || echo 0)
    popd > /dev/null; rm -rf "$dir"
    [ "$found" -ge 1 ] && pass "$label" || fail "$label" "Env.Load(); not injected"
}

test_inject_after "standard format" \
    'var builder = WebApplication.CreateBuilder(args);
var app = builder.Build(); app.Run();'

test_inject_after "minified (no spaces)" \
    'var builder=WebApplication.CreateBuilder(args);
var app = builder.Build(); app.Run();'

test_inject_after "extra spaces around =" \
    'var builder   =   WebApplication.CreateBuilder(args);
var app = builder.Build(); app.Run();'

test_inject_after "no args variant (.NET 9)" \
    'var builder = WebApplication.CreateBuilder();
var app = builder.Build(); app.Run();'

suite "awk_fallback_op inject-after-builder — idempotent"
with_temp_project "idem_after" '
    make_standard_program
    awk_fallback_op "inject-after-builder" "Env.Load();" "Env.Load();"
    awk_fallback_op "inject-after-builder" "Env.Load();" "Env.Load();"
    count=$(grep -c "Env.Load();" Program.cs)
    assert_eq "no duplicate after two calls" "$count" "1"
'

# ─── inject_before_build ─────────────────────────────────────────────────────
suite "awk_fallback_op inject-before-build"
with_temp_project "before_build" '
    make_standard_program
    awk_fallback_op "inject-before-build" "AddRazorPages" "builder.Services.AddRazorPages();"

    assert_file_contains "line inserted" "Program.cs" "builder.Services.AddRazorPages();"

    razor_line=$(grep -n "AddRazorPages" Program.cs | cut -d: -f1)
    build_line=$(grep -n "builder.Build()" Program.cs | cut -d: -f1)
    [ "$razor_line" -lt "$build_line" ] \
        && pass  "appears before builder.Build()" \
        || fail  "appears before builder.Build()" "razor=$razor_line build=$build_line"

    awk_fallback_op "inject-before-build" "AddRazorPages" "builder.Services.AddRazorPages();"
    count=$(grep -c "AddRazorPages" Program.cs)
    assert_eq "idempotent" "$count" "1"
'

# ─── inject_middleware — all 7 anchors ───────────────────────────────────────
suite "awk_fallback_op inject-middleware — 7 anchors"

test_middleware_anchor() {
    local label="$1" anchor_line="$2"
    local dir; dir=$(mktemp -d "/tmp/pcs_mw_XXXXXX")
    pushd "$dir" > /dev/null
    printf 'var builder = WebApplication.CreateBuilder(args);\nvar app = builder.Build();\n%s\napp.Run();\n' \
        "$anchor_line" > Program.cs
    awk_fallback_op "inject-middleware" "app.UseAuthentication();" "app.UseAuthentication();"
    local found; found=$(grep -c "app.UseAuthentication();" Program.cs || echo 0)
    popd > /dev/null; rm -rf "$dir"
    [ "$found" -ge 1 ] && pass "anchor: $label" || fail "anchor: $label" "UseAuthentication not injected"
}

test_middleware_anchor "UseAuthorization"    "app.UseAuthorization();"
test_middleware_anchor "UseRouting"          "app.UseRouting();"
test_middleware_anchor "UseStaticFiles"      "app.UseStaticFiles();"
test_middleware_anchor "UseHttpsRedirection" "app.UseHttpsRedirection();"
test_middleware_anchor "MapControllers"      "app.MapControllers();"
test_middleware_anchor "MapRazorPages"       "app.MapRazorPages();"
test_middleware_anchor "app.Run() only"      ""

suite "awk_fallback_op inject-middleware — idempotent"
with_temp_project "idem_mw" '
    make_standard_program
    awk_fallback_op "inject-middleware" "app.UseAuthentication();" "app.UseAuthentication();"
    awk_fallback_op "inject-middleware" "app.UseAuthentication();" "app.UseAuthentication();"
    count=$(grep -c "app.UseAuthentication();" Program.cs)
    assert_eq "no duplicate" "$count" "1"
'

# ─── Identity middleware ordering ────────────────────────────────────────────
suite "Identity: UseAuthentication BEFORE UseAuthorization"
with_temp_project "auth_order" '
    make_context
    make_standard_program
    TEST_CTX[db_use_method]="UseSqlServer"

    setup_identity_program_cs "TEST_CTX" "AppDbContext"

    auth_line=$(grep -n "UseAuthentication" Program.cs | head -1 | cut -d: -f1)
    authz_line=$(grep -n "UseAuthorization" Program.cs | head -1 | cut -d: -f1)

    [ -n "$auth_line" ] && [ -n "$authz_line" ] && [ "$auth_line" -lt "$authz_line" ] \
        && pass  "UseAuthentication before UseAuthorization" \
        || fail  "UseAuthentication before UseAuthorization" "auth=$auth_line authz=$authz_line"
'

# ─── Minimal template (no UseAuthorization) ──────────────────────────────────
suite "Identity on minimal template — fallback anchor"
with_temp_project "minimal_identity" '
    make_context
    make_minimal_program
    TEST_CTX[db_use_method]="UseSqlServer"

    setup_identity_program_cs "TEST_CTX" "AppDbContext"

    assert_file_contains "UseAuthentication injected via fallback" \
        "Program.cs" "app.UseAuthentication();"

    has_authz=$(grep -c "UseAuthorization" Program.cs 2>/dev/null | tr -d '[:space:]' || echo "0")
    has_auth=$(grep -c "UseAuthentication" Program.cs 2>/dev/null | tr -d '[:space:]' || echo "0")
    [ "${has_authz:-0}" -eq 0 ] && [ "${has_auth:-0}" -ge 1 ] \
        && pass  "injected without needing Authz anchor" \
        || fail  "injected without needing Authz anchor" "authz=$has_authz auth=$has_auth"
'

# ─── setup_program_cs injection order ────────────────────────────────────────
suite "setup_program_cs — correct final order in file"
with_temp_project "setup_pcs_order" '
    make_context
    make_standard_program
    TEST_CTX[db_use_method]="UseSqlServer"

    setup_program_cs "TEST_CTX" "AppDbContext"

    assert_file_contains "Env.Load() present"      "Program.cs" "Env.Load();"
    assert_file_contains "connString present"       "Program.cs" "SCAFFOLD_CONN_STR"
    assert_file_contains "AddDbContext present"     "Program.cs" "AddDbContext<AppDbContext>"
    assert_file_contains "UseSqlServer present"     "Program.cs" "UseSqlServer(connString)"

    env_line=$(grep -n "Env.Load();" Program.cs | head -1 | cut -d: -f1)
    conn_line=$(grep -n "SCAFFOLD_CONN_STR" Program.cs | head -1 | cut -d: -f1)
    ctx_line=$(grep -n "AddDbContext<AppDbContext>" Program.cs | head -1 | cut -d: -f1)

    [ "$env_line" -lt "$conn_line" ] \
        && pass  "Env.Load before connString" \
        || fail  "Env.Load before connString" "env=$env_line conn=$conn_line"

    [ "$conn_line" -lt "$ctx_line" ] \
        && pass  "connString before AddDbContext" \
        || fail  "connString before AddDbContext" "conn=$conn_line ctx=$ctx_line"
'

print_results
