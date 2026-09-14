!include "LogicLib.nsh"
!include "FileFunc.nsh"


; ============================================================
; PREINSTALL
;
; Looks for a companion install config next to the installer:
;
;   MagendaSupport.exe      -> install.json
;   MagendaSupport (1).exe  -> install (1).json
;   MagendaSupport (2).exe  -> install (2).json
;
; If found:
;   copy to C:\ProgramData\Magendamd\install.json
;
; If not found:
;   do nothing and continue installation.
;   Deep-link logic will be used later.
; ============================================================

!macro NSIS_HOOK_PREINSTALL

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Checking for install configuration..."
    DetailPrint "=========================================="

    ; --------------------------------------------------------
    ; $EXEPATH:
    ; C:\Users\User\Downloads\MagendaSupport (2).exe
    ; --------------------------------------------------------

    ${GetParent} "$EXEPATH" $0
    ${GetBaseName} "$EXEPATH" $1

    DetailPrint "Installer path: $EXEPATH"
    DetailPrint "Installer directory: $0"
    DetailPrint "Installer base name: $1"


    ; --------------------------------------------------------
    ; Default companion filename:
    ;
    ; MagendaSupport.exe -> install.json
    ; --------------------------------------------------------

    StrCpy $2 "$0\install.json"


    ; --------------------------------------------------------
    ; Detect browser duplicate suffix.
    ;
    ; Examples:
    ;
    ; MagendaSupport
    ; MagendaSupport (1)
    ; MagendaSupport (2)
    ;
    ; "MagendaSupport" = 14 characters
    ; --------------------------------------------------------

    StrCpy $3 $1 14
    StrCpy $4 $1 "" 14

    ${If} $3 == "MagendaSupport"

        ; $4:
        ;
        ; ""
        ; " (1)"
        ; " (2)"

        ${If} $4 != ""

            StrCpy $2 "$0\install$4.json"

        ${EndIf}

    ${EndIf}


    DetailPrint "Looking for companion config:"
    DetailPrint "$2"


    ; --------------------------------------------------------
    ; Copy only if file exists.
    ; --------------------------------------------------------

    ${If} ${FileExists} "$2"

        DetailPrint "Companion install config found."

        CreateDirectory "$COMMONAPPDATA\Magendamd"

        ClearErrors

        CopyFiles /SILENT \
            "$2" \
            "$COMMONAPPDATA\Magendamd\install.json"

        ${If} ${Errors}

            DetailPrint "WARNING: Failed to copy install config."

            ; Не Abort.
            ; Установка продолжается, чтобы остался fallback
            ; через deep link.

        ${Else}

            DetailPrint "Install config copied successfully."
            DetailPrint "$COMMONAPPDATA\Magendamd\install.json"

        ${EndIf}

    ${Else}

        DetailPrint "Companion install config not found."
        DetailPrint "Continuing without it."

    ${EndIf}


    DetailPrint ""
    DetailPrint "Install config check completed."
    DetailPrint ""

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

    DetailPrint "MyApp uninstall started."
    DetailPrint "RustDesk will remain installed."

!macroend