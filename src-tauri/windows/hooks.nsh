!include "LogicLib.nsh"

!macro NSIS_HOOK_POSTINSTALL

    ; ========================================================
    ; 1. EXTRACT INSTALL TOKEN
    ;
    ; Supported filenames:
    ;
    ; magendamd-setup-abc123.exe
    ; magendamd-setup-abc123 (1).exe
    ; magendamd-setup-abc123 (2).exe
    ;
    ; Result:
    ; abc123
    ;
    ; Token is saved to:
    ;
    ; C:\ProgramData\Magendamd\install.json
    ;
    ; IMPORTANT:
    ; Failure to extract token does NOT abort installation.
    ; RustDesk deployment will continue.
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Extracting installation token..."
    DetailPrint "=========================================="

    DetailPrint "Installer path: $EXEPATH"

    ; Persistent application data directory
    CreateDirectory "$PROGRAMDATA\Magendamd"


    ; --------------------------------------------------------
    ; Pass paths safely to PowerShell using environment vars.
    ;
    ; This avoids quoting problems with filenames such as:
    ;
    ; magendamd-setup-token (1).exe
    ; --------------------------------------------------------

    System::Call 'Kernel32::SetEnvironmentVariable(t "MAGENDAMD_INSTALLER", t "$EXEPATH") i .r0'

    System::Call 'Kernel32::SetEnvironmentVariable(t "MAGENDAMD_TOKEN_FILE", t "$PROGRAMDATA\Magendamd\install.json") i .r0'


    ; --------------------------------------------------------
    ; Extract token.
    ;
    ; Regex:
    ;
    ; ^magendamd-setup-(.+?)(?: \(\d+\))?$
    ;
    ; Examples:
    ;
    ; magendamd-setup-ABC.exe
    ; -> ABC
    ;
    ; magendamd-setup-ABC (1).exe
    ; -> ABC
    ;
    ; magendamd-setup-ABC (22).exe
    ; -> ABC
    ;
    ; JSON:
    ;
    ; {"install_token":"ABC"}
    ;
    ; Token itself is intentionally NOT printed to installer log.
    ; --------------------------------------------------------

    nsExec::ExecToLog \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$name=[System.IO.Path]::GetFileNameWithoutExtension($env:MAGENDAMD_INSTALLER); if($name -match ''^magendamd-setup-(.+?)(?: \(\d+\))?$''){ $token=$Matches[1].Trim(); if([string]::IsNullOrWhiteSpace($token)){ exit 3 }; $obj=@{install_token=$token}; $json=$obj | ConvertTo-Json -Compress; [System.IO.File]::WriteAllText($env:MAGENDAMD_TOKEN_FILE,$json,(New-Object System.Text.UTF8Encoding($false))); exit 0 } else { exit 2 }"'

    Pop $2


    ; --------------------------------------------------------
    ; Token extraction is optional.
    ;
    ; Do NOT abort RustDesk installation if filename does not
    ; contain a token.
    ; --------------------------------------------------------

    ${If} $2 == 0

        ${If} ${FileExists} "$PROGRAMDATA\Magendamd\install.json"

            DetailPrint "Installation token extracted successfully."
            DetailPrint "Token saved to:"
            DetailPrint "$PROGRAMDATA\Magendamd\install.json"

        ${Else}

            DetailPrint "WARNING: Token extraction returned success,"
            DetailPrint "but install.json was not created."

        ${EndIf}

    ${Else}

        DetailPrint "WARNING: Installation token was not found."
        DetailPrint "Continuing installation without enrollment token."

    ${EndIf}


    ; --------------------------------------------------------
    ; Remove temporary environment variables.
    ; --------------------------------------------------------

    System::Call 'Kernel32::SetEnvironmentVariable(t "MAGENDAMD_INSTALLER", t "") i .r0'

    System::Call 'Kernel32::SetEnvironmentVariable(t "MAGENDAMD_TOKEN_FILE", t "") i .r0'


    ; ========================================================
    ; 2. RUSTDESK DEPLOYMENT
    ; ========================================================

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Configuring RustDesk..."
    DetailPrint "=========================================="

    StrCpy $0 "$INSTDIR\resources\windows\configure-rustdesk.ps1"


    ; --------------------------------------------------------
    ; Verify PowerShell deployment script exists.
    ; --------------------------------------------------------

    ${IfNot} ${FileExists} "$0"

        MessageBox MB_ICONSTOP \
            "RustDesk configuration script not found."

        Abort

    ${EndIf}


    ; --------------------------------------------------------
    ; Run RustDesk deployment.
    ;
    ; configure-rustdesk.ps1 currently handles:
    ;
    ; - RustDesk detection
    ; - x64 / ARM64 installer selection
    ; - install/update to 1.4.9
    ; - GUI shutdown
    ; - Service management
    ; - LocalService RustDesk2.toml
    ; - user RustDesk2.toml
    ; - password
    ; - final verification
    ; --------------------------------------------------------

    DetailPrint "Running RustDesk deployment..."

    nsExec::ExecToLog \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$0"'

    Pop $1


    ; --------------------------------------------------------
    ; RustDesk deployment is mandatory.
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


    ; --------------------------------------------------------
    ; Prefer 64-bit Program Files.
    ; --------------------------------------------------------

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
;
; Current policy:
; - uninstall MyApp
; - DO NOT uninstall RustDesk
; - DO NOT delete enrollment token yet
;
; We can change this later.
; ============================================================

!macro NSIS_HOOK_PREUNINSTALL

    DetailPrint "MyApp uninstall started."
    DetailPrint "RustDesk will remain installed."

!macroend