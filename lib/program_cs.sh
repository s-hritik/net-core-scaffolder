#!/usr/bin/env bash
# lib/program_cs.sh — Program.cs injection layer
#
# Architecture:
#   Three named injection sites:
#     inject_after_builder   → immediately after WebApplication.CreateBuilder(...)
#     inject_before_build    → immediately before builder.Build()
#     inject_middleware      → into the middleware pipeline (7-anchor fallback chain)
#
#   Each site has:
#     • A Roslyn path  (real C# syntax tree — format-immune)
#     • An awk fallback (forgiving regex — used when dotnet-script unavailable)
#
#   Stack-push mechanic:
#     inject_after_builder inserts IMMEDIATELY after CreateBuilder on each call.
#     Each new call pushes all previous lines down by one position.
#     Therefore: the LAST inject_after_builder call ends up FIRST in the file.
#     Always call in REVERSE of the desired final order.

# ─── Roslyn rewriter ─────────────────────────────────────────────────────────

emit_roslyn_rewriter() {
    local script_path="$1"
    cat > "$script_path" << 'ROSLYN_SCRIPT'
#!/usr/bin/env dotnet-script
#r "nuget: Microsoft.CodeAnalysis.CSharp, 4.11.0"

using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

var args_list = Args.ToList();
if (args_list.Count < 2) {
    Console.Error.WriteLine("Usage: rewriter.csx <Program.cs> <operation> [params...]");
    Environment.Exit(1);
}

var filePath   = args_list[0];
var operation  = args_list[1];
var parameters = args_list.Skip(2).ToList();

var source = File.ReadAllText(filePath);
var tree   = CSharpSyntaxTree.ParseText(source);
var root   = (CompilationUnitSyntax)tree.GetRoot();

CompilationUnitSyntax AddUsing(CompilationUnitSyntax r, string ns) {
    if (r.Usings.Any(u => u.Name!.ToString() == ns)) return r;
    var directive = SyntaxFactory.UsingDirective(SyntaxFactory.ParseName(" " + ns))
        .WithTrailingTrivia(SyntaxFactory.CarriageReturnLineFeed);
    return r.AddUsings(directive);
}

bool HasText(SyntaxNode r, string text) =>
    r.DescendantNodes().OfType<ExpressionStatementSyntax>()
     .Any(e => e.ToFullString().Contains(text))
    || r.DescendantNodes().OfType<LocalDeclarationStatementSyntax>()
     .Any(e => e.ToFullString().Contains(text));

StatementSyntax ParseStatement(string code) =>
    SyntaxFactory.ParseStatement(code + Environment.NewLine);

CompilationUnitSyntax InjectAfterBuilder(CompilationUnitSyntax r, string guard, string code) {
    if (HasText(r, guard)) return r;
    var builder = r.DescendantNodes()
        .OfType<LocalDeclarationStatementSyntax>()
        .FirstOrDefault(s => s.ToFullString().Contains("WebApplication.CreateBuilder"));
    if (builder == null) return r;
    var block = builder.Ancestors().OfType<BlockSyntax>().FirstOrDefault();
    if (block == null) {
        var globalStmts = r.Members.OfType<GlobalStatementSyntax>().ToList();
        var targetIdx   = globalStmts.FindIndex(g => g.Statement == builder);
        if (targetIdx < 0) return r;
        var newStmt = SyntaxFactory.GlobalStatement(ParseStatement(code));
        return r.WithMembers(r.Members.Insert(
            r.Members.IndexOf(globalStmts[targetIdx]) + 1, newStmt));
    }
    var idx     = block.Statements.ToList().IndexOf(builder);
    var updated = block.WithStatements(block.Statements.Insert(idx + 1, ParseStatement(code)));
    return r.ReplaceNode(block, updated);
}

CompilationUnitSyntax InjectBeforeBuild(CompilationUnitSyntax r, string guard, string code) {
    if (HasText(r, guard)) return r;
    var buildCall = r.DescendantNodes()
        .OfType<LocalDeclarationStatementSyntax>()
        .FirstOrDefault(s => s.ToFullString().Contains("builder.Build()"));
    if (buildCall == null) return r;
    var block = buildCall.Ancestors().OfType<BlockSyntax>().FirstOrDefault();
    if (block == null) {
        var globalStmts = r.Members.OfType<GlobalStatementSyntax>().ToList();
        var targetIdx   = globalStmts.FindIndex(g => g.Statement == buildCall);
        if (targetIdx < 0) return r;
        return r.WithMembers(r.Members.Insert(
            r.Members.IndexOf(globalStmts[targetIdx]),
            SyntaxFactory.GlobalStatement(ParseStatement(code))));
    }
    var bidx    = block.Statements.ToList().IndexOf(buildCall);
    var updated = block.WithStatements(block.Statements.Insert(bidx, ParseStatement(code)));
    return r.ReplaceNode(block, updated);
}

static readonly string[] MiddlewareAnchors = {
    "app.UseAuthorization()", "app.UseRouting()", "app.UseStaticFiles()",
    "app.UseHttpsRedirection()", "app.MapControllers()", "app.MapRazorPages()", "app.Run()"
};

CompilationUnitSyntax InjectMiddleware(CompilationUnitSyntax r, string guard, string code) {
    if (HasText(r, guard)) return r;
    var allStmts = r.DescendantNodes().OfType<ExpressionStatementSyntax>().ToList();
    ExpressionStatementSyntax anchor = null;
    bool insertBefore = false;
    foreach (var a in MiddlewareAnchors) {
        anchor = allStmts.FirstOrDefault(s => s.ToFullString().Contains(a));
        if (anchor != null) {
            insertBefore = a == "app.UseAuthorization()" || a == "app.MapControllers()"
                        || a == "app.MapRazorPages()"    || a == "app.Run()";
            break;
        }
    }
    if (anchor == null) {
        Console.Error.WriteLine($"[WARN] No middleware anchor found for: {code}");
        return r;
    }
    var parentBlock = anchor.Ancestors().OfType<BlockSyntax>().FirstOrDefault();
    if (parentBlock == null) {
        var globalStmts = r.Members.OfType<GlobalStatementSyntax>().ToList();
        var targetIdx   = globalStmts.FindIndex(g => g.Statement == anchor);
        if (targetIdx < 0) return r;
        var insertIdx = insertBefore
            ? r.Members.IndexOf(globalStmts[targetIdx])
            : r.Members.IndexOf(globalStmts[targetIdx]) + 1;
        return r.WithMembers(r.Members.Insert(
            insertIdx, SyntaxFactory.GlobalStatement(ParseStatement(code))));
    }
    var pstmts  = parentBlock.Statements.ToList();
    var pidx    = pstmts.IndexOf(anchor);
    var ins     = insertBefore ? pidx : pidx + 1;
    var upd     = parentBlock.WithStatements(parentBlock.Statements.Insert(ins, ParseStatement(code)));
    return r.ReplaceNode(parentBlock, upd);
}

switch (operation) {
    case "add-using":
        root = AddUsing(root, parameters[0]);
        break;
    case "inject-after-builder":
        root = InjectAfterBuilder(root, parameters[0], parameters[1]);
        break;
    case "inject-before-build":
        root = InjectBeforeBuild(root, parameters[0], parameters[1]);
        break;
    case "inject-middleware":
        root = InjectMiddleware(root, parameters[0], parameters[1]);
        break;
    default:
        Console.Error.WriteLine($"Unknown operation: {operation}");
        Environment.Exit(1);
        break;
}

File.WriteAllText(filePath, root.NormalizeWhitespace().ToFullString());
Console.WriteLine($"[ROSLYN] Applied: {operation}");
ROSLYN_SCRIPT
}

init_roslyn_script() {
    local -n ctx="$1"
    local path
    path="$(mktemp "${TMPDIR:-/tmp}/scaffold_rewriter_${$}_XXXXXX.csx")"
    emit_roslyn_rewriter "$path"
    ctx[roslyn_script_path]="$path"
    ctx[roslyn_available]="1"
}

# ─── awk fallback (forgiving regex — format-immune for common patterns) ───────

awk_fallback_op() {
    local op="$1"
    local p1="$2"
    local p2="${3:-}"

    case "$op" in
        add-using)
            [ -f "Program.cs" ] || return 0
            if grep -q "^[[:space:]]*using ${p1};" "Program.cs"; then return 0; fi
            { printf 'using %s;\n' "$p1"; cat "Program.cs"; } > "Program.cs.tmp" \
                && mv "Program.cs.tmp" "Program.cs"
            ;;
        inject-after-builder)
            [ -f "Program.cs" ] || return 0
            if grep -qF "$p1" "Program.cs"; then return 0; fi
            awk -v ln="$p2" \
                '/var[ \t]+builder[ \t]*=[ \t]*WebApplication\.CreateBuilder\(/ && !done {
                    print; print ln; done=1; next
                } { print }' "Program.cs" > "Program.cs.tmp" \
                && mv "Program.cs.tmp" "Program.cs"
            ;;
        inject-before-build)
            [ -f "Program.cs" ] || return 0
            if grep -qF "$p1" "Program.cs"; then return 0; fi
            awk -v ln="$p2" \
                '/var[ \t]+app[ \t]*=[ \t]*builder\.Build\(\)/ && !done {
                    print ln; done=1
                } { print }' "Program.cs" > "Program.cs.tmp" \
                && mv "Program.cs.tmp" "Program.cs"
            ;;
        inject-middleware)
            [ -f "Program.cs" ] || return 0
            if grep -qF "$p1" "Program.cs"; then return 0; fi
            local -a CHAIN=(
                "before:app\\.UseAuthorization\\(\\)"
                "after:app\\.UseRouting\\(\\)"
                "after:app\\.UseStaticFiles\\(\\)"
                "after:app\\.UseHttpsRedirection\\(\\)"
                "before:app\\.MapControllers\\(\\)"
                "before:app\\.MapRazorPages\\(\\)"
                "before:app\\.Run\\(\\)"
            )
            local entry pos pat
            for entry in "${CHAIN[@]}"; do
                pos="${entry%%:*}"; pat="${entry#*:}"
                if grep -qE "$pat" "Program.cs"; then
                    if [ "$pos" = "before" ]; then
                        awk -v p="$pat" -v ln="$p2" \
                            '$0 ~ p && !done { print ln; done=1 } { print }' \
                            "Program.cs" > "Program.cs.tmp"
                    else
                        awk -v p="$pat" -v ln="$p2" \
                            '{ print } $0 ~ p && !done { print ln; done=1 }' \
                            "Program.cs" > "Program.cs.tmp"
                    fi
                    mv "Program.cs.tmp" "Program.cs"
                    return 0
                fi
            done
            log_warn "No middleware anchor found for: ${p2}"
            ;;
    esac
}

# ─── Dispatch: Roslyn if available, awk fallback otherwise ───────────────────

_roslyn_op() {
    local -n _ctx_r="$1"; shift
    local script="${_ctx_r[roslyn_script_path]}"
    local avail="${_ctx_r[roslyn_available]}"

    if [ "$avail" = "1" ] && [ -n "$script" ] && [ -f "$script" ]; then
        dotnet script "$script" -- "Program.cs" "$@" 2>&1 \
            | grep -v "^\[WARN\]\|not cacheable\|Unable to cache" || true
    else
        awk_fallback_op "$@"
    fi
}

# ─── Public Program.cs API ───────────────────────────────────────────────────
# All public functions take CTX name as $1.

pcs_add_using() {
    local -n _ctx_u="$1"; local ns="$2"
    [ -f "Program.cs" ] || return 0
    if [ "${_ctx_u[dry_run]}" = "1" ]; then log_dry "  ADD USING: $ns"; return 0; fi
    backup_file "Program.cs"
    _roslyn_op "$1" "add-using" "$ns"
}

pcs_inject_after_builder() {
    local -n _ctx_a="$1"; local guard="$2"; local code="$3"
    [ -f "Program.cs" ] || return 0
    if [ "${_ctx_a[dry_run]}" = "1" ]; then log_dry "  INJECT AFTER BUILDER: $code"; return 0; fi
    backup_file "Program.cs"
    _roslyn_op "$1" "inject-after-builder" "$guard" "$code"
}

pcs_inject_before_build() {
    local -n _ctx_b="$1"; local guard="$2"; local code="$3"
    [ -f "Program.cs" ] || return 0
    if [ "${_ctx_b[dry_run]}" = "1" ]; then log_dry "  INJECT BEFORE BUILD: $code"; return 0; fi
    backup_file "Program.cs"
    _roslyn_op "$1" "inject-before-build" "$guard" "$code"
}

pcs_inject_middleware() {
    local -n _ctx_m="$1"; local guard="$2"; local code="$3"
    [ -f "Program.cs" ] || return 0
    if [ "${_ctx_m[dry_run]}" = "1" ]; then log_dry "  INJECT MIDDLEWARE: $code"; return 0; fi
    backup_file "Program.cs"
    _roslyn_op "$1" "inject-middleware" "$guard" "$code"
}

# ─── High-level Program.cs wiring ────────────────────────────────────────────

fix_ef_namespace() {
    local ctx_name="$1"
    [ -f "Program.cs" ] || return 0
    pcs_add_using "$ctx_name" "Microsoft.EntityFrameworkCore"
}

# Wire .env + DbContext into Program.cs (options 1, 2, 3, 4)
#
# INJECTION ORDER (reversed because each call pushes previous lines down):
#   Call 3: AddDbContext    → ends up last  (uses connString — defined above it) ✓
#   Call 2: connString      → ends up middle
#   Call 1: Env.Load()      → ends up first (runs before everything else)       ✓
#
setup_program_cs() {
    local ctx_name="$1"   # name of the CTX associative array
    local db_context="$2"
    local -n _ctx_pc="$ctx_name"

    [ -z "$db_context" ] && return 0
    [ -f "Program.cs" ]  || return 0

    log_step "Wiring Program.cs → DbContext: $db_context"
    phase_begin

    local method="${_ctx_pc[db_use_method]:-UseSqlServer}"

    from_packages::ensure_dotnetenv "$ctx_name"

    pcs_add_using "$ctx_name" "DotNetEnv"
    pcs_add_using "$ctx_name" "Microsoft.EntityFrameworkCore"

    # Reversed call order — see comment above
    pcs_inject_after_builder "$ctx_name" \
        "AddDbContext<${db_context}>" \
        "builder.Services.AddDbContext<${db_context}>(options => options.${method}(connString));"
    pcs_inject_after_builder "$ctx_name" \
        "var connString" \
        'var connString = Environment.GetEnvironmentVariable("SCAFFOLD_CONN_STR");'
    pcs_inject_after_builder "$ctx_name" \
        "Env.Load(" \
        'Env.Load(System.IO.Path.Combine(builder.Environment.ContentRootPath, ".env"));'

    ensure_designtime_factory "$ctx_name" "$db_context"

    log_success "Program.cs configured for '${db_context}'."
}

# Wire full Identity stack into Program.cs (option 5)
setup_identity_program_cs() {
    local ctx_name="$1"
    local db_context="$2"
    local -n _ctx_id="$ctx_name"

    [ -z "$db_context" ] && return 0
    [ -f "Program.cs" ]  || return 0

    log_step "Wiring Program.cs → Identity: $db_context"
    phase_begin

    local method="${_ctx_id[db_use_method]:-UseSqlServer}"

    from_packages::ensure_dotnetenv "$ctx_name"

    pcs_add_using "$ctx_name" "DotNetEnv"
    pcs_add_using "$ctx_name" "Microsoft.EntityFrameworkCore"
    pcs_add_using "$ctx_name" "Microsoft.AspNetCore.Identity"

    # Reversed call order — ends up: Env.Load → connString → DbContext → DefaultIdentity
    pcs_inject_after_builder "$ctx_name" \
        "AddDefaultIdentity<IdentityUser>" \
        "builder.Services.AddDefaultIdentity<IdentityUser>(options => options.SignIn.RequireConfirmedAccount = true).AddEntityFrameworkStores<${db_context}>();"
    pcs_inject_after_builder "$ctx_name" \
        "AddDbContext<${db_context}>" \
        "builder.Services.AddDbContext<${db_context}>(options => options.${method}(connString));"
    pcs_inject_after_builder "$ctx_name" \
        "var connString" \
        'var connString = Environment.GetEnvironmentVariable("SCAFFOLD_CONN_STR");'
    pcs_inject_after_builder "$ctx_name" \
        "Env.Load(" \
        'Env.Load(System.IO.Path.Combine(builder.Environment.ContentRootPath, ".env"));'

    pcs_inject_before_build "$ctx_name" \
        "AddRazorPages" \
        "builder.Services.AddRazorPages();"

    pcs_inject_middleware "$ctx_name" \
        "app.UseAuthentication();" \
        "app.UseAuthentication();"

    # MapRazorPages must go AFTER UseAuthorization — inject it at the end
    # of the middleware pipeline (before app.Run)
    if [ -f "Program.cs" ] && ! grep -q "app.MapRazorPages()" "Program.cs"; then
        pcs_inject_middleware "$ctx_name" \
            "app.MapRazorPages();" \
            "app.MapRazorPages();"
    fi

    ensure_designtime_factory "$ctx_name" "$db_context"

    log_success "Program.cs fully wired for Identity with '${db_context}'."
}
