#!/usr/bin/env bash
# tests/test_project.sh — Tests for lib/project.sh
IFS=$'\n\t'
SCAFFOLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCAFFOLD_DIR}/tests/test_runner.sh"
source "${SCAFFOLD_DIR}/lib/core.sh"
source "${SCAFFOLD_DIR}/lib/program_cs.sh"
source "${SCAFFOLD_DIR}/lib/packages.sh"
source "${SCAFFOLD_DIR}/lib/project.sh"

printf "${C_B}${C_C}\n╔══════════════════════════════════════╗\n║  test_project.sh                     ║\n╚══════════════════════════════════════╝${C_X}\n"

make_context() {
    declare -gA TEST_CTX=()
    TEST_CTX[dry_run]="0"
    TEST_CTX[project_ns]="TestApp"
    TEST_CTX[pkg_ver]="8.0.*"
    TEST_CTX[scaffolder]="legacy"
    TEST_CTX[roslyn_available]="0"
    TEST_CTX[roslyn_script_path]=""
}

# ─── extract_namespace ───────────────────────────────────────────────────────
suite "extract_namespace"
with_temp_project "ns" '
    echo "namespace MyApp.Data;"          > FileScopedNs.cs
    echo "namespace MyApp.Services {"     > BlockNs.cs
    echo "namespace   MyApp.Utilities  ;" > SpacedNs.cs

    ns1=$(extract_namespace FileScopedNs.cs)
    ns2=$(extract_namespace BlockNs.cs)
    ns3=$(extract_namespace SpacedNs.cs)

    assert_eq "file-scoped style"  "$ns1" "MyApp.Data"
    assert_eq "block style"        "$ns2" "MyApp.Services"
    assert_eq "extra spaces"       "$ns3" "MyApp.Utilities"
'

# ─── find_cs_file — directory exclusions ─────────────────────────────────────
suite "find_cs_file — exclusions"
with_temp_project "find_excl" '
    mkdir -p Data obj bin Migrations
    echo "class Real {}"         > Data/RealContext.cs
    echo "class ObjCtx {}"       > obj/ObjContext.cs
    echo "class BinCtx {}"       > bin/BinContext.cs
    echo "class SnapCtx {}"      > Migrations/RealContextModelSnapshot.cs

    r=$(find_cs_file "RealContext.cs")
    assert_contains  "finds source file"        "$r" "RealContext.cs"

    obj_r=$(find_cs_file "ObjContext.cs")
    assert_eq        "excludes obj/"            "$obj_r" ""

    bin_r=$(find_cs_file "BinContext.cs")
    assert_eq        "excludes bin/"            "$bin_r" ""

    mig_r=$(find_cs_file "RealContextModelSnapshot.cs")
    assert_eq        "excludes Migrations/"     "$mig_r" ""
'

# ─── inject_dbsets_into_context ──────────────────────────────────────────────
suite "inject_dbsets_into_context"
with_temp_project "dbsets" '
    make_context
    mkdir -p Data
    cat > Data/AppDbContext.cs << '"'"'EOF'"'"'
namespace TestApp.Data;
using Microsoft.EntityFrameworkCore;
public class AppDbContext : DbContext {
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) {}
}
EOF

    inject_dbsets_into_context "TEST_CTX" "AppDbContext" "Product" "Order"

    assert_file_contains "DbSet<Product> added"  "Data/AppDbContext.cs" "DbSet<Product>"
    assert_file_contains "DbSet<Order> added"    "Data/AppDbContext.cs" "DbSet<Order>"

    inject_dbsets_into_context "TEST_CTX" "AppDbContext" "Product"
    count=$(grep -c "DbSet<Product>" Data/AppDbContext.cs)
    assert_eq "idempotent — no duplicate DbSet" "$count" "1"
'

# ─── PROJECT_NS hyphen-to-underscore ─────────────────────────────────────────
suite "PROJECT_NS hyphen → underscore"
test_ns() {
    local result; result=$(echo "$1" | tr '-' '_')
    assert_eq "NS: $1 → $2" "$result" "$2"
}
test_ns "MyApp"        "MyApp"
test_ns "my-app"       "my_app"
test_ns "My-Cool-App"  "My_Cool_App"
test_ns "app-v2-final" "app_v2_final"
test_ns "NoHyphens"    "NoHyphens"

# ─── PKG_VER construction ────────────────────────────────────────────────────
suite "PKG_VER — no backslash, correct wildcard"
for ver in "8.0" "7.0" "9.0" "6.0"; do
    result="${ver}.*"
    assert_contains     "PKG_VER $ver ends with .*"     "$result" ".*"
    assert_not_contains "PKG_VER $ver no backslash"     "$result" '.\*'
done

# ─── Password escaping ───────────────────────────────────────────────────────
suite "Password escaping"
test_pw() {
    local raw="$1" expected="$2" label="$3"
    local escaped="${raw//\"/\\\"}"
    assert_eq "pw: $label" "$escaped" "$expected"
}
test_pw 'Simple123'    'Simple123'     "no special chars"
test_pw 'p@ss!word'    'p@ss!word'     "symbols only"
test_pw 'say "hello"'  'say \"hello\"' "embedded double-quote"
test_pw '"quoted"'     '\"quoted\"'    "leading/trailing quotes"
test_pw "plain'quote"  "plain'quote"   "single quote unchanged"

# ─── .env dry-run (no file created) ─────────────────────────────────────────
suite "load_env in dry-run"
with_temp_project "env_dry" '
    mkdir -p Testing && cat > Testing/Testing.csproj << '"'"'EOF'"'"'
<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>
EOF
    cd Testing
    make_context
    TEST_CTX[dry_run]="1"
    TEST_CTX[project_ns]="Testing"

    PROV_CHOICE="1" load_env "TEST_CTX"

    assert_file_absent  ".env NOT created in dry-run"  ".env"
    assert_eq           "db_provider set in memory"    \
        "${TEST_CTX[db_provider]}" "Microsoft.EntityFrameworkCore.SqlServer"
'

print_results
