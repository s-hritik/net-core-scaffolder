#!/usr/bin/env bash
# options/opt_identity.sh — Option 5: ASP.NET Core Identity UI + Program.cs wiring

run_identity() {
    local ctx_name="$1"
    local -n _ctx_id="$ctx_name"

    log_step "Identity Scaffold"
    phase_begin

    ensure_package "$ctx_name" \
        "Microsoft.AspNetCore.Identity.UI" \
        "Microsoft.AspNetCore.Identity.EntityFrameworkCore" \
        "Microsoft.VisualStudio.Web.CodeGeneration.Design" \
        "Microsoft.EntityFrameworkCore.SqlServer" \
        "Microsoft.EntityFrameworkCore.Tools"

    local DB_CONTEXT
    DB_CONTEXT=$(find_existing_context)
    [ -z "$DB_CONTEXT" ] \
        && read -r -p "Enter NEW DbContext Name [e.g. ApplicationDbContext]: " DB_CONTEXT

    # Identity file selection menu
    local -a ID_FILES=(
        "Account.AccessDenied"                    "Account.ConfirmEmail"
        "Account.ConfirmEmailChange"              "Account.ExternalLogin"
        "Account.ForgotPassword"                  "Account.ForgotPasswordConfirmation"
        "Account.Lockout"                         "Account.Login"
        "Account.LoginWith2fa"                    "Account.LoginWithRecoveryCode"
        "Account.Logout"                          "Account.Manage.ChangePassword"
        "Account.Manage.DeletePersonalData"       "Account.Manage.Disable2fa"
        "Account.Manage.DownloadPersonalData"     "Account.Manage.Email"
        "Account.Manage.EnableAuthenticator"      "Account.Manage.ExternalLogins"
        "Account.Manage.GenerateRecoveryCodes"    "Account.Manage.Index"
        "Account.Manage.PersonalData"             "Account.Manage.ResetAuthenticator"
        "Account.Manage.SetPassword"              "Account.Manage.ShowRecoveryCodes"
        "Account.Manage.TwoFactorAuthentication"  "Account.Manage._Layout"
        "Account.Manage._ManageNav"               "Account.Manage._StatusMessage"
        "Account.Register"                        "Account.RegisterConfirmation"
        "Account.ResendEmailConfirmation"         "Account.ResetPassword"
        "Account.ResetPasswordConfirmation"       "Account.StatusMessage"
    )

    printf "\n${C_INFO}─── Select Identity Files to Override ───${C_RESET}\n"
    printf "  %3d) %-46s\n" 0 "ALL FILES"
    local i
    for (( i=0; i < ${#ID_FILES[@]}; i+=2 )); do
        printf "  %3d) %-46s" $((i+1)) "${ID_FILES[$i]}"
        if [ $((i+1)) -lt "${#ID_FILES[@]}" ]; then
            printf "  %3d) %s\n" $((i+2)) "${ID_FILES[$i+1]}"
        else
            printf "\n"
        fi
    done

    printf "\n"
    local FILE_CHOICES
    read -r -p "Numbers separated by spaces (or 0 for ALL): " FILE_CHOICES

    local FILE_FLAG="" SELECTED_FILES=""
    if [[ " ${FILE_CHOICES} " != *" 0 "* ]] && [ -n "$FILE_CHOICES" ]; then
        local num local_idx
        for num in ${FILE_CHOICES// /$' \n'}; do
            local_idx=$((num - 1))
            if [[ "$local_idx" -ge 0 && "$local_idx" -lt "${#ID_FILES[@]}" ]] \
                && [ -n "${ID_FILES[$local_idx]:-}" ]; then
                SELECTED_FILES="${SELECTED_FILES:+${SELECTED_FILES};}${ID_FILES[$local_idx]}"
            fi
        done
        [ -n "$SELECTED_FILES" ] && FILE_FLAG="--files $SELECTED_FILES"
        log_info "Selected: $SELECTED_FILES"
    else
        log_info "Scaffolding ALL Identity files..."
    fi

    if [ "${_ctx_id[dry_run]}" = "0" ]; then
        safe_run "Shutdown build server" dotnet build-server shutdown
        safe_run "Clean project"        dotnet clean -v q
        must_run "Restore packages"    dotnet restore --nologo -v q
    fi

    protect_appsettings

    if [ "${_ctx_id[dry_run]}" = "1" ]; then
        log_dry "Would scaffold Identity: $DB_CONTEXT ${FILE_FLAG}"
    else
        if [ "${_ctx_id[scaffolder]}" = "new" ]; then
            # shellcheck disable=SC2086
            must_run "Scaffold Identity" \
                dotnet scaffold identity --dbContext "$DB_CONTEXT" $FILE_FLAG --force --project .
        else
            # shellcheck disable=SC2086
            must_run "Scaffold Identity" \
                dotnet aspnet-codegenerator identity -dc "$DB_CONTEXT" $FILE_FLAG --force
        fi
    fi

    restore_appsettings

    # Normalize: codegenerator places context in Areas/Identity/Data/ — move to Data/
    local BAD_PATH="Areas/Identity/Data/${DB_CONTEXT}.cs"
    local PROJECT_NS="${_ctx_id[project_ns]}"

    if [ -f "$BAD_PATH" ]; then
        log_info "Relocating DbContext from Areas/Identity/Data/ → Data/ ..."
        if [ "${_ctx_id[dry_run]}" = "1" ]; then
            log_dry "Would move ${BAD_PATH} → Data/${DB_CONTEXT}.cs"
        else
            mkdir -p Data
            mv "$BAD_PATH" "Data/${DB_CONTEXT}.cs"
            sed -i.bak \
                "s|namespace ${PROJECT_NS}.Areas.Identity.Data|namespace ${PROJECT_NS}.Data|" \
                "Data/${DB_CONTEXT}.cs" \
                && rm -f "Data/${DB_CONTEXT}.cs.bak"

            local STARTUP_FILE
            STARTUP_FILE=$(find Areas -name "IdentityHostingStartup.cs" 2>/dev/null | head -n 1 || true)
            if [ -n "$STARTUP_FILE" ]; then
                sed -i.bak \
                    "s|using ${PROJECT_NS}.Areas.Identity.Data;|using ${PROJECT_NS}.Data;|" \
                    "$STARTUP_FILE" \
                    && rm -f "${STARTUP_FILE}.bak"
            fi
        fi
    fi

    fix_ef_namespace "$ctx_name"
    setup_identity_program_cs "$ctx_name" "$DB_CONTEXT"

    if [ "${_ctx_id[dry_run]}" = "0" ]; then
        must_run "Refresh dependencies" dotnet restore
    fi

    log_warn "Identity scaffolding complete!"
    log_info "Run migrations to create Identity schema:"
    printf "    dotnet ef migrations add CreateIdentitySchema\n"
    printf "    dotnet ef database update\n"
}
