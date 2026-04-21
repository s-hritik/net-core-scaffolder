#!/usr/bin/env bash
# lib/packages.sh — NuGet package installation · dotnet local tool management

# ─── NuGet package installer ─────────────────────────────────────────────────
#
# FIX: Uses exact  Include="<pkg>"  attribute matching.
#      Old code used  grep -qi "$pkg"  which gave false positives when a
#      package name was a substring of another package name.
#
# FIX: [[ "$pkg" == Microsoft.* ]]  — no backslash before *.
#      In bash [[]], \* is a literal asterisk not a glob.

ensure_package() {
    local ctx_name="$1"; shift
    local -n _ctx_pkg="$ctx_name"
    local csproj="${_ctx_pkg[csproj]}"
    local pkg_ver="${_ctx_pkg[pkg_ver]:-8.0.*}"
    local dry="${_ctx_pkg[dry_run]:-0}"

    for pkg in "$@"; do
        if grep -qi "Include=\"${pkg}\"" "$csproj" 2>/dev/null; then
            log_info "Already installed: $pkg"
            continue
        fi

        if [ "$dry" = "1" ]; then
            log_dry "  INSTALL PACKAGE: $pkg"
            continue
        fi

        log_info "Installing NuGet: $pkg ..."
        if [[ "$pkg" == Microsoft.* ]] || [[ "$pkg" == Npgsql.* ]]; then
            run "Install $pkg @ $pkg_ver" \
                dotnet add package "$pkg" --version "$pkg_ver" \
                || run "Install $pkg (latest)" dotnet add package "$pkg"
        else
            must_run "Install $pkg" dotnet add package "$pkg"
        fi
    done
}

# Convenience: ensure DotNetEnv (called from program_cs.sh so needs its own ref)
from_packages::ensure_dotnetenv() {
    ensure_package "$1" "DotNetEnv"
}

# ─── Local tool manifest (never global) ──────────────────────────────────────
#
# FIX: Old script used  dotnet tool install --global  which mutates the
#      developer's entire machine and can version-conflict with other projects.
#      Local manifests (.config/dotnet-tools.json) pin versions to the repo.
#
# dotnet-aspnet-codegenerator requires version-matched install.
# dotnet-script enables the Roslyn-backed Program.cs rewriter.

check_tools() {
    local ctx_name="$1"
    local -n _ctx_t="$ctx_name"
    local dry="${_ctx_t[dry_run]:-0}"
    local scaffolder="${_ctx_t[scaffolder]:-legacy}"
    local sdk_ver="${_ctx_t[sdk_ver]:-8.0}"
    local pkg_ver="${_ctx_t[pkg_ver]:-8.0.*}"

    log_step "Local Tool Manifest"

    if [ "$dry" = "1" ]; then
        log_dry "Would ensure: dotnet-ef, codegenerator, dotnet-script in .config/dotnet-tools.json"
        return 0
    fi

    if [ ! -f ".config/dotnet-tools.json" ]; then
        log_info "Creating local tool manifest..."
        run "Create tool manifest" dotnet new tool-manifest --force || true
    fi

    local gen_tool
    if [ "$scaffolder" = "new" ]; then
        gen_tool="Microsoft.dotnet-scaffold"
    else
        gen_tool="dotnet-aspnet-codegenerator"
    fi

    for tool in "dotnet-ef" "$gen_tool" "dotnet-script"; do
        if dotnet tool list 2>/dev/null | grep -q "$tool"; then
            log_info "Tool OK: $tool"
            continue
        fi

        log_info "Installing local tool: $tool"

        if [ "$tool" = "dotnet-aspnet-codegenerator" ]; then
            run "Install codegenerator @ ${pkg_ver}" \
                dotnet tool install dotnet-aspnet-codegenerator --version "$pkg_ver" \
            || run "Install codegenerator (latest)" \
                dotnet tool install dotnet-aspnet-codegenerator \
            || run "Update codegenerator" \
                dotnet tool update dotnet-aspnet-codegenerator \
            || log_warn "Could not install codegenerator. Run: dotnet tool install dotnet-aspnet-codegenerator --version ${sdk_ver}"
        else
            run "Install $tool" dotnet tool install "$tool" \
            || run "Update $tool"  dotnet tool update "$tool" \
            || log_warn "Could not install '$tool'. Run: dotnet tool install $tool"
        fi
    done

    # Check if Roslyn rewriter is available and initialise it
    if dotnet tool list 2>/dev/null | grep -q "dotnet-script" \
        || command -v dotnet-script >/dev/null 2>&1; then
        init_roslyn_script "$ctx_name"
        log_success "Roslyn-backed Program.cs rewriter active."
    else
        _ctx_t[roslyn_available]="0"
        log_warn "Roslyn rewriter unavailable — using awk fallback."
    fi
}

# ─── Pre-scaffold build sequence ─────────────────────────────────────────────
# Shuts down stale build servers, restores, builds to produce fresh metadata
# that dotnet aspnet-codegenerator needs to resolve types.

pre_scaffold_build() {
    local ctx_name="$1"
    local -n _ctx_build="$ctx_name"

    [ "${_ctx_build[dry_run]}" = "1" ] && return 0

    log_info "Shutting down stale build servers..."
    safe_run "Shutdown build server" dotnet build-server shutdown

    safe_run "Clean project"         dotnet clean -v q

    log_info "Restoring packages..."
    must_run "Restore packages"  dotnet restore --nologo -v q

    log_info "Building project (fresh metadata for codegenerator)..."
    must_run "Build project"     \
        dotnet build --nologo -v m -nodeReuse:false -p:UseSharedCompilation=false
}
