!include "LogicLib.nsh"

!macro NSIS_HOOK_POSTINSTALL

    ; ========================================================
    ; 1. SAVE INSTALL TOKEN
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Saving installation token..."
    DetailPrint "=========================================="

    DetailPrint "Installer EXE:"
    DetailPrint "$EXEPATH"

    StrCpy $R0 "$INSTDIR\resources\windows\save-install-token.ps1"

    DetailPrint "Token script path:"
    DetailPrint "$R0"

    ; --------------------------------------------------------
    ; Script MUST exist for this diagnostic build.
    ; --------------------------------------------------------

    ${IfNot} ${FileExists} "$R0"

        DetailPrint "ERROR: save-install-token.ps1 not found."

        MessageBox MB_ICONSTOP \
            "save-install-token.ps1 NOT FOUND:$\r$\n$R0"

        Abort

    ${EndIf}

    DetailPrint "Token script exists."

    ; --------------------------------------------------------
    ; Run token script.
    ;
    ; $EXEPATH is passed directly as InstallerPath.
    ; Handles:
    ;
    ; magendamd-setup-qwertyiop.exe
    ; magendamd-setup-qwertyiop (1).exe
    ; magendamd-setup-qwertyiop (2).exe
    ; --------------------------------------------------------

    nsExec::ExecToLog \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$R0" -InstallerPath "$EXEPATH"'

    Pop $R1

    DetailPrint "Token script exit code: $R1"

    ; --------------------------------------------------------
    ; For now fail hard so we can diagnose this properly.
    ; --------------------------------------------------------

    ${If} $R1 != 0

        DetailPrint "ERROR: Token script failed."

        MessageBox MB_ICONSTOP \
            "Token script failed.$\r$\n$\r$\nExit code: $R1$\r$\n$\r$\nInstaller:$\r$\n$EXEPATH"

        Abort

    ${EndIf}

    DetailPrint "Token script completed successfully."


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