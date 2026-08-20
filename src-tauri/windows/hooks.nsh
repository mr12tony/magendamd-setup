!include "LogicLib.nsh"

!macro NSIS_HOOK_POSTINSTALL

    ; ========================================================
    ; 1. EXTRACT INSTALL TOKEN
    ;
    ; Supported:
    ;
    ; magendamd-setup-abc123.exe
    ; magendamd-setup-abc123 (1).exe
    ; magendamd-setup-abc123 (2).exe
    ;
    ; Result:
    ; abc123
    ;
    ; Saved to:
    ; C:\ProgramData\Magendamd\install.json
    ;
    ; Token extraction failure does NOT abort installation.
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Extracting installation token..."
    DetailPrint "=========================================="

    DetailPrint "Installer path: $EXEPATH"

    ; --------------------------------------------------------
    ; ProgramData
    ; --------------------------------------------------------

    SetShellVarContext all

    StrCpy $R9 "$LOCALAPPDATA\Magendamd"

    CreateDirectory "$R9"

    DetailPrint "Token directory:"
    DetailPrint "$R9"

    ; --------------------------------------------------------
    ; Extract token from installer filename
    ;
    ; PowerShell prints ONLY token to stdout.
    ;
    ; Examples:
    ;
    ; magendamd-setup-qwertyiop.exe
    ; -> qwertyiop
    ;
    ; magendamd-setup-qwertyiop (2).exe
    ; -> qwertyiop
    ; --------------------------------------------------------

    nsExec::ExecToStack \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$name=[System.IO.Path]::GetFileNameWithoutExtension(''$EXEPATH''); if($name -match ''^magendamd-setup-([A-Za-z0-9_-]+)(?: \(\d+\))?$''){ [Console]::Out.Write($Matches[1]); exit 0 } else { exit 2 }"'

    ; first Pop = exit code
    ; second Pop = stdout

    Pop $R0
    Pop $R1

    DetailPrint "Token extraction exit code: $R0"

    ; --------------------------------------------------------
    ; If token found
    ; --------------------------------------------------------

    ${If} $R0 == 0

        ${If} $R1 != ""

            DetailPrint "Installation token extracted."

            ; ------------------------------------------------
            ; Write JSON directly from NSIS
            ;
            ; {"install_token":"qwertyiop"}
            ; ------------------------------------------------

            FileOpen $R2 "$R9\install.json" w

            ${If} $R2 == ""

                DetailPrint "WARNING: Could not open install.json."

            ${Else}

                FileWrite $R2 '{"install_token":"$R1"}'
                FileClose $R2

                ${If} ${FileExists} "$R9\install.json"

                    DetailPrint "Installation token saved successfully."
                    DetailPrint "Token file:"
                    DetailPrint "$R9\install.json"

                ${Else}

                    DetailPrint "WARNING: install.json was not created."

                ${EndIf}

            ${EndIf}

        ${Else}

            DetailPrint "WARNING: Token extraction returned empty token."

        ${EndIf}

    ${Else}

        DetailPrint "WARNING: Installation token was not found."
        DetailPrint "Expected filename:"
        DetailPrint "magendamd-setup-TOKEN.exe"
        DetailPrint "Continuing installation without enrollment token."

    ${EndIf}


    ; ========================================================
    ; 2. RUSTDESK DEPLOYMENT
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Configuring RustDesk..."
    DetailPrint "=========================================="

    StrCpy $0 "$INSTDIR\resources\windows\configure-rustdesk.ps1"

    ; --------------------------------------------------------
    ; Verify PowerShell deployment script exists
    ; --------------------------------------------------------

    ${IfNot} ${FileExists} "$0"

        MessageBox MB_ICONSTOP \
            "RustDesk configuration script not found."

        Abort

    ${EndIf}

    ; --------------------------------------------------------
    ; Run RustDesk deployment
    ; --------------------------------------------------------

    DetailPrint "Running RustDesk deployment..."

    nsExec::ExecToLog \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$0"'

    Pop $1

    ; --------------------------------------------------------
    ; RustDesk deployment is mandatory
    ; --------------------------------------------------------

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


; ============================================================
; UNINSTALL
; ============================================================

!macro NSIS_HOOK_PREUNINSTALL

    DetailPrint "MyApp uninstall started."
    DetailPrint "RustDesk will remain installed."

!macroend