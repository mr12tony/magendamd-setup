$ErrorActionPreference = "SilentlyContinue"

Write-Host ""
Write-Host "============================================"
Write-Host " MagendaSupport / RustDesk FULL CLEANUP"
Write-Host "============================================"
Write-Host ""

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Remove-PathSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Host "Removing:"
        Write-Host $Path

        Remove-Item `
            -LiteralPath $Path `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Stop-ProcessSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Get-Process `
        -Name $Name `
        -ErrorAction SilentlyContinue |
        Stop-Process `
            -Force `
            -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# Require Administrator
# ------------------------------------------------------------

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$Principal = New-Object `
    Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdmin = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdmin) {
    Write-Host ""
    Write-Host "ERROR: Run PowerShell as Administrator."
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------
# Stop MagendaSupport
# ------------------------------------------------------------

Write-Host "Stopping MagendaSupport..."
Write-Host ""

Stop-ProcessSafe "MagendaSupport"
Stop-ProcessSafe "magenda-support"
Stop-ProcessSafe "magendamd-setup"

# ------------------------------------------------------------
# Stop RustDesk GUI / processes
# ------------------------------------------------------------

Write-Host "Stopping RustDesk processes..."
Write-Host ""

Stop-ProcessSafe "RustDesk"
Stop-ProcessSafe "RustDesk_service"

taskkill /F /IM RustDesk.exe *> $null
taskkill /F /IM RustDesk_service.exe *> $null

# ------------------------------------------------------------
# Stop and remove RustDesk service
# ------------------------------------------------------------

Write-Host "Removing RustDesk service..."
Write-Host ""

sc.exe stop RustDesk *> $null
Start-Sleep -Seconds 2

sc.exe delete RustDesk *> $null

sc.exe stop Rustdesk *> $null
sc.exe delete Rustdesk *> $null

Start-Sleep -Seconds 1

# ------------------------------------------------------------
# RustDesk uninstall registry entries
# ------------------------------------------------------------

Write-Host "Checking RustDesk uninstall entries..."
Write-Host ""

$UninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

foreach ($Root in $UninstallRoots) {

    if (-not (Test-Path $Root)) {
        continue
    }

    Get-ChildItem $Root |
        ForEach-Object {

            $Item = Get-ItemProperty `
                $_.PSPath `
                -ErrorAction SilentlyContinue

            if ($Item.DisplayName -like "*RustDesk*") {

                Write-Host "Found:"
                Write-Host $Item.DisplayName

                if ($Item.QuietUninstallString) {
                    Write-Host "Running quiet uninstall..."

                    Start-Process `
                        "cmd.exe" `
                        -ArgumentList "/c $($Item.QuietUninstallString)" `
                        -Wait `
                        -WindowStyle Hidden `
                        -ErrorAction SilentlyContinue
                }
                elseif ($Item.UninstallString) {
                    Write-Host "Running uninstall..."

                    Start-Process `
                        "cmd.exe" `
                        -ArgumentList "/c $($Item.UninstallString)" `
                        -Wait `
                        -WindowStyle Hidden `
                        -ErrorAction SilentlyContinue
                }
            }
        }
}

# ------------------------------------------------------------
# Stop again after uninstall
# ------------------------------------------------------------

Stop-ProcessSafe "RustDesk"
Stop-ProcessSafe "RustDesk_service"

sc.exe stop RustDesk *> $null
sc.exe delete RustDesk *> $null

# ------------------------------------------------------------
# Remove RustDesk application files
# ------------------------------------------------------------

Write-Host ""
Write-Host "Removing RustDesk files..."
Write-Host ""

$RustDeskPaths = @(
    "$env:ProgramFiles\RustDesk",
    "${env:ProgramFiles(x86)}\RustDesk",

    "$env:ProgramData\RustDesk",

    "$env:APPDATA\RustDesk",
    "$env:LOCALAPPDATA\RustDesk"
)

foreach ($Path in $RustDeskPaths) {
    Remove-PathSafe $Path
}

# ------------------------------------------------------------
# Remove RustDesk configuration from current user
# ------------------------------------------------------------

Remove-PathSafe "$env:APPDATA\RustDesk"
Remove-PathSafe "$env:LOCALAPPDATA\RustDesk"

# ------------------------------------------------------------
# Remove RustDesk service-account configuration
# ------------------------------------------------------------

$ServiceProfiles = @(
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Local\RustDesk",

    "C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\RustDesk",
    "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\RustDesk",

    "C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk",
    "C:\Windows\System32\config\systemprofile\AppData\Local\RustDesk"
)

foreach ($Path in $ServiceProfiles) {
    Remove-PathSafe $Path
}

# ------------------------------------------------------------
# Remove RustDesk registry keys
# ------------------------------------------------------------

Write-Host ""
Write-Host "Removing RustDesk registry keys..."
Write-Host ""

$RustDeskRegistryPaths = @(
    "HKCU:\Software\RustDesk",
    "HKLM:\Software\RustDesk",
    "HKLM:\Software\WOW6432Node\RustDesk"
)

foreach ($RegPath in $RustDeskRegistryPaths) {

    if (Test-Path $RegPath) {
        Write-Host "Removing:"
        Write-Host $RegPath

        Remove-Item `
            $RegPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# Remove MagendaSupport application data
# ------------------------------------------------------------

Write-Host ""
Write-Host "Removing MagendaSupport data..."
Write-Host ""

$MagendaPaths = @(
    "$env:ProgramData\Magendamd",
    "$env:APPDATA\MagendaSupport",
    "$env:LOCALAPPDATA\MagendaSupport",

    "$env:APPDATA\com.mr12tony.magendamd-setup",
    "$env:LOCALAPPDATA\com.mr12tony.magendamd-setup"
)

foreach ($Path in $MagendaPaths) {
    Remove-PathSafe $Path
}

# ------------------------------------------------------------
# Remove MagendaSupport installed application folders
# ------------------------------------------------------------

$MagendaInstallPaths = @(
    "$env:ProgramFiles\MagendaSupport",
    "${env:ProgramFiles(x86)}\MagendaSupport",

    "$env:LOCALAPPDATA\Programs\MagendaSupport"
)

foreach ($Path in $MagendaInstallPaths) {
    Remove-PathSafe $Path
}

# ------------------------------------------------------------
# MagendaSupport uninstall registry entries
# ------------------------------------------------------------

Write-Host ""
Write-Host "Removing MagendaSupport uninstall entries..."
Write-Host ""

foreach ($Root in $UninstallRoots) {

    if (-not (Test-Path $Root)) {
        continue
    }

    Get-ChildItem $Root |
        ForEach-Object {

            $Item = Get-ItemProperty `
                $_.PSPath `
                -ErrorAction SilentlyContinue

            if (
                $Item.DisplayName -like "*MagendaSupport*" -or
                $Item.DisplayName -like "*Magenda Support*"
            ) {

                Write-Host "Removing registry entry:"
                Write-Host $Item.DisplayName

                Remove-Item `
                    $_.PSPath `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
}

# ------------------------------------------------------------
# Remove deep-link protocol
# ------------------------------------------------------------

Write-Host ""
Write-Host "Removing magendasupport:// protocol..."
Write-Host ""

$ProtocolKeys = @(
    "HKCU:\Software\Classes\magendasupport",
    "HKLM:\Software\Classes\magendasupport"
)

foreach ($Key in $ProtocolKeys) {

    if (Test-Path $Key) {
        Remove-Item `
            $Key `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Host "Removed:"
        Write-Host $Key
    }
}

# ------------------------------------------------------------
# Remove shortcuts
# ------------------------------------------------------------

Write-Host ""
Write-Host "Removing shortcuts..."
Write-Host ""

$ShortcutPaths = @(
    "$env:PUBLIC\Desktop\MagendaSupport.lnk",
    "$env:USERPROFILE\Desktop\MagendaSupport.lnk",

    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\MagendaSupport.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\MagendaSupport.lnk"
)

foreach ($Path in $ShortcutPaths) {
    Remove-PathSafe $Path
}

# ------------------------------------------------------------
# Final process/service cleanup
# ------------------------------------------------------------

Stop-ProcessSafe "RustDesk"
Stop-ProcessSafe "MagendaSupport"

sc.exe stop RustDesk *> $null
sc.exe delete RustDesk *> $null

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================"
Write-Host " CLEANUP COMPLETE"
Write-Host "============================================"
Write-Host ""

Write-Host "RustDesk service:"
sc.exe query RustDesk

Write-Host ""
Write-Host "ProgramData Magenda config exists:"
Test-Path "C:\ProgramData\Magendamd"

Write-Host ""
Write-Host "RustDesk LocalService config exists:"
Test-Path `
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"

Write-Host ""
Write-Host "MagendaSupport process:"
Get-Process MagendaSupport -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "RustDesk process:"
Get-Process RustDesk -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "For the cleanest test, reboot Windows before reinstalling."
Write-Host ""