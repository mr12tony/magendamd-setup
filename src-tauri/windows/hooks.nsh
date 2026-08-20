!include "LogicLib.nsh"

!macro NSIS_HOOK_POSTINSTALL

    ; ========================================================
    ; 1. SAVE INSTALL TOKEN
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Processing installation token..."
    DetailPrint "=========================================="

    DetailPrint "Installer path:"
    DetailPrint "$EXEPATH"

    StrCpy $R0 "$INSTDIR\resources\windows\save-install-token.ps1"

    ${IfNot} ${FileExists} "$R0"

        DetailPrint "WARNING: save-install-token.ps1 not found."
        DetailPrint "Continuing installation without token."

    ${Else}

        ; ----------------------------------------------------
        ; Pass installer path as a NORMAL script argument.
        ;
        ; This correctly handles:
        ;
        ; C:\Users\Alex\Downloads\
        ; magendamd-setup-qwertyiop (1).exe
        ; ----------------------------------------------------

        nsExec::ExecToLog \
            'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$R0" -InstallerPath "$EXEPATH"'

        Pop $R1

        DetailPrint "Token script exit code: $R1"

        ${If} $R1 == 0

            DetailPrint "Installation token saved successfully."

        ${ElseIf} $R1 == 2

            DetailPrint "WARNING: Installer filename contains no token."
            DetailPrint "Continuing installation without token."

        ${Else}

            DetailPrint "WARNING: Could not save installation token."
            DetailPrint "Continuing installation without token."

        ${EndIf}

    ${EndIf}


    ; ========================================================
    ; 2. RUSTDESK DEPLOYMENT
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
    ; 3. START RUSTDESK GUI
    ; ========================================================

    DetailPrint ""
    DetailPrint "Starting RustDesk GUI..."

    ${If} ${FileExists} "$PROGRAMFILES64\RustDesk\rustdesk.exe"

        DetailPrint "RustDesk GUI:"
        DetailPrint "$PROGRAMFILES64\RustDesk\rustdesk.exe"

        Exec '"$PROGRAMFILES64\RustDesk\rustdesk.exe"'

    ${ElseIf} ${FileExists} "$PROGRAMFILES\RustDesk\rustdesk.exe"

        DetailPrint "RustDesk GUI:"
        DetailPrint "$PROGRAMFILES\RustDesk\rustdesk.exe"

        Exec '"$PROGRAMFILES\RustDesk\rustdesk.exe"'

    ${Else}

        DetailPrint "WARNING: RustDesk GUI executable not found."

        MessageBox MB_ICONEXCLAMATION \
            "RustDesk configured, but GUI executable was not found."

    ${EndIf}


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