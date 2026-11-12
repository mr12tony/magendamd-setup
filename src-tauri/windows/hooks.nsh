!include "LogicLib.nsh"
!include "FileFunc.nsh"

; Installation configuration is resolved by the application launched from
; .onInstSuccess with --installer-path. Do not copy companion JSON to ProgramData:
; the active token is saved only after the registration API accepts it.
; The hook clears the legacy machine token; the app clears the user's token
; and registration under its lock before attempting the new connection.
; Do not log the installer path: its filename may contain a permanent token.

!macro MAGENDA_CLEAR_LEGACY_TOKEN
    ReadEnvStr $0 "ProgramData"
    ${If} $0 == ""
        SetErrorLevel 2
        MessageBox MB_ICONSTOP "Cannot locate ProgramData to clear the previous installation token." /SD IDOK
        Abort
    ${EndIf}

    ${If} ${FileExists} "$0\Magendamd\install.json"
        ClearErrors
        Delete "$0\Magendamd\install.json"
        ${If} ${Errors}
            SetErrorLevel 2
            MessageBox MB_ICONSTOP "Cannot clear the previous installation token. Close MagendaSupport and try again." /SD IDOK
            Abort
        ${EndIf}
    ${EndIf}
    DetailPrint "Previous machine-wide installation token cleared."
!macroend

!macro NSIS_HOOK_POSTINSTALL

    ; ========================================================
    ; 1. RUSTDESK DEPLOYMENT
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Configuring RustDesk..."
    DetailPrint "=========================================="

    StrCpy $0 "$INSTDIR\resources\windows\configure-rustdesk.ps1"

    ${IfNot} ${FileExists} "$0"

        MessageBox MB_ICONSTOP \
            "RustDesk configuration script not found."

        Abort

    ${EndIf}

    DetailPrint "Running RustDesk deployment..."

    nsExec::ExecToLog \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$0"'

    Pop $1

    ${If} $1 != 0

        DetailPrint "RustDesk deployment FAILED."
        DetailPrint "PowerShell exit code: $1"

        MessageBox MB_ICONSTOP \
            "RustDesk deployment failed. Exit code: $1"

        Abort

    ${EndIf}

    DetailPrint ""
    DetailPrint "RustDesk verified."
    DetailPrint "RustDesk deployment completed successfully."

    ; A normal install/reinstall starts a new token lookup from the installer
    ; filename or companion JSON. Remove the legacy machine-wide fallback.
    ; Updater installs keep the saved token and registration untouched.
    ${If} $UpdateMode <> 1
        !insertmacro MAGENDA_CLEAR_LEGACY_TOKEN
    ${EndIf}


    ; ========================================================
    ; 2. START RUSTDESK GUI
    ; ========================================================

    ; DetailPrint ""
    ; DetailPrint "Starting RustDesk GUI..."

    ; ${If} ${FileExists} "$PROGRAMFILES64\RustDesk\rustdesk.exe"

    ;     DetailPrint "RustDesk GUI:"
    ;     DetailPrint "$PROGRAMFILES64\RustDesk\rustdesk.exe"

    ;     Exec '"$PROGRAMFILES64\RustDesk\rustdesk.exe"'

    ; ${ElseIf} ${FileExists} "$PROGRAMFILES\RustDesk\rustdesk.exe"

    ;     DetailPrint "RustDesk GUI:"
    ;     DetailPrint "$PROGRAMFILES\RustDesk\rustdesk.exe"

    ;     Exec '"$PROGRAMFILES\RustDesk\rustdesk.exe"'

    ; ${Else}

    ;     DetailPrint "WARNING: RustDesk GUI executable not found."

    ;     MessageBox MB_ICONEXCLAMATION \
    ;         "RustDesk configured, but GUI executable was not found."

    ; ${EndIf}


    ; ========================================================
    ; DONE
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Installation post-processing completed"
    DetailPrint "=========================================="
    DetailPrint ""

!macroend


!macro NSIS_HOOK_PREUNINSTALL

    DetailPrint "MagendaSupport uninstall started."
    DetailPrint "RustDesk will remain installed."

    ${If} $UpdateMode <> 1
        DetailPrint "Clearing registration for the Windows desktop user..."
        ; This payload lives inside uninstall.exe and survives a missing,
        ; damaged or quarantined application. No WebView or installed resources.
        InitPluginsDir
        SetOutPath "$PLUGINSDIR"
        ClearErrors
        File /oname=magenda-uninstall-cleanup.exe "${MAGENDA_CLEANUP_PATH}"
        ${If} ${Errors}
            StrCpy $1 2
        ${Else}
            StrCpy $2 ""
            ${If} $DeleteAppDataCheckboxState = 1
                StrCpy $2 "--delete-app-data"
            ${EndIf}
            ClearErrors
            ExecWait '"$PLUGINSDIR\magenda-uninstall-cleanup.exe" --product-name "${PRODUCTNAME}" --manufacturer "${MANUFACTURER}" --bundle-id "${BUNDLEID}" $2' $1
            ${If} ${Errors}
                StrCpy $1 2
            ${EndIf}
        ${EndIf}
        Delete "$PLUGINSDIR\magenda-uninstall-cleanup.exe"

        ${If} $1 != 0
            DetailPrint "Registration cleanup failed. Exit code: $1"
            SetErrorLevel 2
            MessageBox MB_ICONSTOP "Cannot clear the previous user data (code $1). Close MagendaSupport and retry uninstalling from the Windows desktop of the user who connected the device." /SD IDOK
            Abort
        ${EndIf}

        !insertmacro MAGENDA_CLEAR_LEGACY_TOKEN
        DetailPrint "Previous user token and registration cleared."
    ${EndIf}

!macroend
