!include "LogicLib.nsh"
!include "FileFunc.nsh"


; ============================================================
; PREINSTALL
;
; Selects the most recently modified install config next to the installer:
;
;   install.json
;   install (N).json
;   install-N.json
;
; The installer's filename and duplicate-download suffix are irrelevant.
;
; If found:
;   copy to C:\ProgramData\Magendamd\install.json
;
; If not found:
;   do nothing and continue installation.
;   Deep-link logic will be used later.
; ============================================================

Function MagendaIsInstallConfigFilename
    ; Stack input: filename. Stack output: 1 if supported, otherwise 0.
    Exch $0
    Push $1
    Push $2

    StrCmpS $0 "install.json" filename_valid

    StrCpy $1 $0 9
    StrCmpS $1 "install (" filename_parentheses
    StrCpy $1 $0 8
    StrCmpS $1 "install-" filename_dash filename_invalid

    filename_parentheses:
        StrCpy $1 $0 6 -6
        StrCmpS $1 ").json" 0 filename_invalid
        StrCpy $1 $0 "" 9
        StrLen $2 $1
        IntOp $2 $2 - 6
        StrCpy $1 $1 $2
        Goto filename_digits

    filename_dash:
        StrCpy $1 $0 5 -5
        StrCmpS $1 ".json" 0 filename_invalid
        StrCpy $1 $0 "" 8
        StrLen $2 $1
        IntOp $2 $2 - 5
        StrCpy $1 $1 $2

    filename_digits:
        StrCmp $1 "" filename_invalid
    filename_digit_loop:
        StrCpy $2 $1 1
        StrCmp $2 "" filename_valid
        StrCmpS $2 "0" filename_next_digit
        StrCmpS $2 "1" filename_next_digit
        StrCmpS $2 "2" filename_next_digit
        StrCmpS $2 "3" filename_next_digit
        StrCmpS $2 "4" filename_next_digit
        StrCmpS $2 "5" filename_next_digit
        StrCmpS $2 "6" filename_next_digit
        StrCmpS $2 "7" filename_next_digit
        StrCmpS $2 "8" filename_next_digit
        StrCmpS $2 "9" filename_next_digit filename_invalid
    filename_next_digit:
        StrCpy $1 $1 "" 1
        Goto filename_digit_loop

    filename_valid:
        StrCpy $0 1
        Goto filename_done
    filename_invalid:
        StrCpy $0 0
    filename_done:
        Pop $2
        Pop $1
        Exch $0
FunctionEnd

Function MagendaFindNewestInstallConfig
    ; Stack input: directory. Stack output: full path, or an empty string.
    ; Preserve the installer's registers, including across the filename helper.
    Exch $0
    Push $1
    Push $2
    Push $3
    Push $4
    Push $5
    Push $6
    Push $7
    Push $8

    StrCpy $3 ""
    StrCpy $6 0
    StrCpy $7 0

    ClearErrors
    FindFirst $1 $2 "$0\install*.json"
    IfErrors config_scan_done

    config_scan_loop:
        StrCmp $2 "" config_scan_close
        ; Ignore directories even when their names match the JSON pattern.
        IfFileExists "$0\$2\*.*" config_scan_next 0

        Push $2
        Call MagendaIsInstallConfigFilename
        Pop $8
        StrCmp $8 1 0 config_scan_next

        ClearErrors
        GetFileTime "$0\$2" $4 $5
        IfErrors config_time_error
        StrCmp $3 "" config_use_candidate

        ; FILETIME is two unsigned DWORDs: compare high first, then low.
        IntCmpU $4 $6 config_compare_low config_scan_next config_use_candidate
    config_compare_low:
        ; Keep the first match if timestamps are identical.
        IntCmpU $5 $7 config_scan_next config_scan_next config_use_candidate

    config_use_candidate:
        StrCpy $3 "$0\$2"
        StrCpy $6 $4
        StrCpy $7 $5

    config_scan_next:
        FindNext $1 $2
        IfErrors config_scan_close
        Goto config_scan_loop

    config_time_error:
        DetailPrint "WARNING: Cannot read modification time for $0\$2. Skipping config import."
        ; Do not silently import an older config when a candidate cannot be dated.
        StrCpy $3 ""
    config_scan_close:
        FindClose $1
    config_scan_done:
        ClearErrors
        StrCpy $0 $3
        Pop $8
        Pop $7
        Pop $6
        Pop $5
        Pop $4
        Pop $3
        Pop $2
        Pop $1
        Exch $0
FunctionEnd

!macro NSIS_HOOK_PREINSTALL

    DetailPrint ""
    DetailPrint "=========================================="
    DetailPrint " Checking for install configuration..."
    DetailPrint "=========================================="

    ${GetParent} "$EXEPATH" $0

    DetailPrint "Installer path: $EXEPATH"
    DetailPrint "Searching for the newest install config in: $0"

    Push $0
    Call MagendaFindNewestInstallConfig
    Pop $2

    DetailPrint "Selected install config: $2"


    ; --------------------------------------------------------
    ; Copy only if file exists.
    ; --------------------------------------------------------

    ${If} ${FileExists} "$2"

        DetailPrint "Companion install config found."

        ; ----------------------------------------------------
        ; Resolve real ProgramData path.
        ;
        ; Example:
        ; C:\ProgramData
        ; ----------------------------------------------------

        ReadEnvStr $5 "ProgramData"

        ${If} $5 == ""

            DetailPrint "WARNING: ProgramData environment variable not found."
            DetailPrint "Skipping companion install config."

        ${Else}

            StrCpy $6 "$5\Magendamd"
            StrCpy $7 "$6\install.json"

            DetailPrint "ProgramData: $5"
            DetailPrint "Create folder: $6"
            DetailPrint "Copy to: $7"

            ; Create:
            ; C:\ProgramData\Magendamd
            ;
            ; If it already exists, nothing bad happens.
            CreateDirectory "$6"

            ClearErrors

            ; Copy:
            ;
            ; install.json
            ; install (1).json
            ; install-N.json
            ;
            ; ->
            ;
            ; C:\ProgramData\Magendamd\install.json
            ;
            ; Existing install.json will be overwritten.
            CopyFiles /SILENT \
                "$2" \
                "$7"

            ${If} ${Errors}

                DetailPrint "WARNING: Failed to copy install config."

                ; Do NOT abort installation.
                ; Deep-link logic remains available as fallback.

            ${Else}

                DetailPrint "Install config copied successfully."
                DetailPrint "Destination: $7"

            ${EndIf}

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