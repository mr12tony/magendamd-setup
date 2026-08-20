!include "LogicLib.nsh"

!macro NSIS_HOOK_POSTINSTALL

    DetailPrint "Configuring RustDesk..."

    StrCpy $0 "$INSTDIR\resources\windows\configure-rustdesk.ps1"

    ${IfNot} ${FileExists} "$0"
        MessageBox MB_ICONSTOP "RustDesk configuration script not found."
        Abort
    ${EndIf}

    nsExec::ExecToLog \
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$0"'

    Pop $1

    ${If} $1 != 0
        MessageBox MB_ICONSTOP \
            "RustDesk deployment failed. Exit code: $1"
        Abort
    ${EndIf}

    DetailPrint "RustDesk verified."
    DetailPrint "Starting RustDesk GUI..."

    ${If} ${FileExists} "$PROGRAMFILES64\RustDesk\rustdesk.exe"

        Exec '"$PROGRAMFILES64\RustDesk\rustdesk.exe"'

    ${ElseIf} ${FileExists} "$PROGRAMFILES\RustDesk\rustdesk.exe"

        Exec '"$PROGRAMFILES\RustDesk\rustdesk.exe"'

    ${Else}

        MessageBox MB_ICONEXCLAMATION \
            "RustDesk configured, but GUI executable was not found."

    ${EndIf}

!macroend