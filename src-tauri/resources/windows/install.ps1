#requires -Version 5.1

<#
.SYNOPSIS
    RustDesk Windows installer for Tauri

.DESCRIPTION
    Installs bundled RustDesk binary, configures password and
    custom rendezvous/relay server.

    Tauri launches:

        powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File install.ps1 -Password "..."

    The script automatically requests Administrator privileges.

    Bundled files:

        resources/windows/rustdesk-x86_64.exe
        resources/windows/rustdesk-aarch64.exe
#>

$ErrorActionPreference = "Stop"

# ==========================================================
# ARGUMENTS
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Password
)

# ==========================================================
# SCRIPT DIRECTORY
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ==========================================================
# CONSTANTS
# ==========================================================

$InstallRoot = Join-Path $env:ProgramData "RustDesk"

$InstallLog = Join-Path $InstallRoot "install.log"

$UserStdOutLog = Join-Path $InstallRoot "rustdesk-user.stdout.log"

$UserStdErrLog = Join-Path $InstallRoot "rustdesk-user.stderr.log"

$AppDir = Join-Path $env:ProgramFiles "RustDesk"

$RustDeskExe = Join-Path $AppDir "RustDesk.exe"

$RendezvousServer = "rustdesk.magendamd.com"

$RelayServer = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# LOG DIRECTORY
# ==========================================================

try {

    New-Item `
        -ItemType Directory `
        -Path $InstallRoot `
        -Force `
        | Out-Null

}
catch {
    # Logging may not be available yet.
}

# ==========================================================
# LOGGING
# ==========================================================

function Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $Line

    try {
        Add-Content `
            -Path $InstallLog `
            -Value $Line `
            -Encoding UTF8
    }
    catch {
        # Never fail installation because logging failed.
    }
}

# ==========================================================
# ERROR HANDLER
# ==========================================================

function Write-FatalError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Message = $ErrorRecord.Exception.Message

    $Position = $ErrorRecord.InvocationInfo.PositionMessage

    $Stack = $ErrorRecord.ScriptStackTrace

    Write-Host ""
    Write-Host "========================================"
    Write-Host "RUSTDESK INSTALLATION FAILED"
    Write-Host "========================================"
    Write-Host ""

    Write-Host "Error:"
    Write-Host $Message

    Write-Host ""

    Write-Host "Location:"
    Write-Host $Position

    Write-Host ""

    Write-Host "Stack:"
    Write-Host $Stack

    Write-Host ""

    Write-Host "Installer log:"
    Write-Host "  $InstallLog"

    try {

        Add-Content `
            -Path $InstallLog `
            -Value ""

        Add-Content `
            -Path $InstallLog `
            -Value "========================================"

        Add-Content `
            -Path $InstallLog `
            -Value "FATAL ERROR"

        Add-Content `
            -Path $InstallLog `
            -Value "========================================"

        Add-Content `
            -Path $InstallLog `
            -Value "Error: $Message"

        Add-Content `
            -Path $InstallLog `
            -Value "Location: $Position"

        Add-Content `
            -Path $InstallLog `
            -Value "Stack: $Stack"

    }
    catch {
    }

    Write-Host ""

    if (Test-Path $UserStdErrLog) {

        Write-Host "RustDesk stderr:"
        Get-Content $UserStdErrLog -ErrorAction SilentlyContinue

        Write-Host ""
    }

    exit 1
}

# ==========================================================
# ADMINISTRATOR CHECK
# ==========================================================

function Test-IsAdministrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ==========================================================
# UAC ELEVATION
# ==========================================================

if (-not (Test-IsAdministrator)) {

    Log "Administrator privileges required."

    Log "Requesting UAC elevation..."

    try {

        $ArgumentList = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
            "-Password"
            "`"$Password`""
        )

        $ElevatedProcess = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $ArgumentList `
            -Verb RunAs `
            -Wait `
            -PassThru

        $ExitCode = $ElevatedProcess.ExitCode

        Log "Elevated installer exit code: $ExitCode"

        exit $ExitCode
    }
    catch {

        Write-Host ""
        Write-Host "Administrator authorization failed."
        Write-Host $_.Exception.Message

        exit 1
    }
}

# ==========================================================
# GLOBAL ERROR TRAP
# ==========================================================

trap {
    Write-FatalError $_
}

# ==========================================================
# HEADER
# ==========================================================

Write-Host ""

Write-Host "========================================"
Write-Host "RustDesk Windows installer"
Write-Host "========================================"
Write-Host ""

Log "Running as administrator: YES"

Log "Script directory: $ScriptDir"

Log "Install directory: $AppDir"

# ==========================================================
# CURRENT INTERACTIVE USER
# ==========================================================

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$CurrentUserFull = $CurrentIdentity.Name

$CurrentUser = $CurrentIdentity.Name.Split("\")[-1]

Log "Current Windows identity: $CurrentUserFull"

# ==========================================================
# USER PROFILE
# ==========================================================

$UserProfile = $env:USERPROFILE

Log "User profile: $UserProfile"

# ==========================================================
# RUSTDESK USER CONFIG
# ==========================================================

$UserConfigDir = Join-Path `
    $UserProfile `
    "AppData\Roaming\RustDesk"

$UserRustDesk2 = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

Log "User config: $UserRustDesk2"

# ==========================================================
# ARCHITECTURE
# ==========================================================

$Architecture = $env:PROCESSOR_ARCHITECTURE

if ($env:PROCESSOR_ARCHITEW6432) {

    $Architecture = $env:PROCESSOR_ARCHITEW6432
}

switch ($Architecture.ToUpperInvariant()) {

    "AMD64" {

        $BundledExe = Join-Path `
            $ScriptDir `
            "rustdesk-x86_64.exe"

        break
    }

    "ARM64" {

        $BundledExe = Join-Path `
            $ScriptDir `
            "rustdesk-aarch64.exe"

        break
    }

    default {

        throw "Unsupported Windows architecture: $Architecture"
    }
}

Log "Architecture: $Architecture"

Log "Bundled RustDesk: $BundledExe"

# ==========================================================
# VALIDATE BUNDLED FILE
# ==========================================================

if (-not (Test-Path -LiteralPath $BundledExe -PathType Leaf)) {

    throw "RustDesk executable not found: $BundledExe"
}

# ==========================================================
# STOP RUSTDESK PROCESSES
# ==========================================================

Log "Stopping RustDesk processes..."

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    ForEach-Object {

        Log "Stopping RustDesk PID $($_.Id)"

        Stop-Process `
            -Id $_.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

Start-Sleep -Seconds 2

# ==========================================================
# STOP SERVICES
# ==========================================================

Log "Stopping RustDesk services..."

$ServiceNames = @(
    "RustDesk",
    "RustDeskService",
    "RustDeskSvc"
)

foreach ($ServiceName in $ServiceNames) {

    $Service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $Service) {

        Log "Found service: $ServiceName"

        try {

            if ($Service.Status -ne "Stopped") {

                Stop-Service `
                    -Name $ServiceName `
                    -Force `
                    -ErrorAction SilentlyContinue

            }

        }
        catch {
        }
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD SERVICES
# ==========================================================

Log "Removing old RustDesk services..."

foreach ($ServiceName in $ServiceNames) {

    try {

        $Service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($null -ne $Service) {

            Log "Deleting service: $ServiceName"

            & sc.exe delete $ServiceName *> $null
        }

    }
    catch {
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD INSTALLATION
# ==========================================================

Log "Removing old RustDesk installation..."

if (Test-Path -LiteralPath $AppDir) {

    try {

        Remove-Item `
            -LiteralPath $AppDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Log "Old installation removed."

    }
    catch {

        throw "Unable to remove old RustDesk installation: $($_.Exception.Message)"
    }
}

# ==========================================================
# REMOVE OLD USER CONFIG
# ==========================================================

Log "Removing old RustDesk user configuration..."

if (Test-Path -LiteralPath $UserConfigDir) {

    try {

        Remove-Item `
            -LiteralPath $UserConfigDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

    }
    catch {
    }
}

# ==========================================================
# REMOVE OLD SYSTEM CONFIG
# ==========================================================

$SystemPaths = @(
    (Join-Path $env:ProgramData "RustDesk"),
    (Join-Path $env:ProgramData "RustDesk\config")
)

foreach ($Path in $SystemPaths) {

    if (
        (Test-Path -LiteralPath $Path) -and
        ($Path -ne $InstallRoot)
    ) {

        Log "Removing old system data: $Path"

        try {

            Remove-Item `
                -LiteralPath $Path `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue

        }
        catch {
        }
    }
}

# ==========================================================
# RE-CREATE INSTALL LOG DIRECTORY
# ==========================================================

New-Item `
    -ItemType Directory `
    -Path $InstallRoot `
    -Force `
    | Out-Null

Log "Installer log: $InstallLog"

# ==========================================================
# REMOVE OLD RUSTDESK LOGS
# ==========================================================

Remove-Item `
    -LiteralPath $UserStdOutLog `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    -LiteralPath $UserStdErrLog `
    -Force `
    -ErrorAction SilentlyContinue

# ==========================================================
# CREATE APP DIRECTORY
# ==========================================================

Log "Creating RustDesk installation directory..."

New-Item `
    -ItemType Directory `
    -Path $AppDir `
    -Force `
    | Out-Null

# ==========================================================
# INSTALL RUSTDESK
# ==========================================================

Log "Installing RustDesk.exe..."

Copy-Item `
    -LiteralPath $BundledExe `
    -Destination $RustDeskExe `
    -Force `
    -ErrorAction Stop

if (-not (Test-Path -LiteralPath $RustDeskExe -PathType Leaf)) {

    throw "RustDesk.exe was not installed."
}

Log "RustDesk executable installed."

# ==========================================================
# CREATE USER CONFIG DIRECTORY
# ==========================================================

Log "Creating user configuration directory..."

New-Item `
    -ItemType Directory `
    -Path $UserConfigDir `
    -Force `
    | Out-Null

# ==========================================================
# START RUSTDESK
# ==========================================================

Log "Starting RustDesk..."

$RustDeskProcess = Start-Process `
    -FilePath $RustDeskExe `
    -WorkingDirectory $AppDir `
    -PassThru `
    -RedirectStandardOutput $UserStdOutLog `
    -RedirectStandardError $UserStdErrLog

Log "RustDesk temporary PID: $($RustDeskProcess.Id)"

# ==========================================================
# WAIT FOR CONFIGURATION
# ==========================================================

Log "Waiting for RustDesk2.toml..."

$Deadline = (Get-Date).AddSeconds(45)

while (-not (Test-Path -LiteralPath $UserRustDesk2)) {

    if ((Get-Date) -gt $Deadline) {

        Log "RustDesk2.toml was not created."

        if (Test-Path -LiteralPath $UserStdErrLog) {

            Log "RustDesk stderr:"

            Get-Content `
                -LiteralPath $UserStdErrLog `
                -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Log $_
                }
        }

        throw "RustDesk2.toml was not created within 45 seconds."
    }

    Start-Sleep -Milliseconds 500
}

Log "RustDesk2.toml created."

# ==========================================================
# PASSWORD
# ==========================================================

Log "Applying RustDesk password..."

$PasswordOutput = & $RustDeskExe `
    "--password" `
    $Password `
    2>&1

$PasswordExitCode = $LASTEXITCODE

if ($PasswordExitCode -ne 0) {

    Log "Password command exit code: $PasswordExitCode"

    if ($PasswordOutput) {

        $PasswordOutput |
            ForEach-Object {
                Log "$_"
            }
    }

    throw "RustDesk password configuration failed with exit code $PasswordExitCode."
}

Log "Password applied."

# ==========================================================
# NETWORK CONFIGURATION
# ==========================================================

Log "Applying network configuration..."

$ConfigContent = @"
rendezvous_server = '$RendezvousServer:21116'
nat_type = 1
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
relay-server = '$RelayServer'
custom-rendezvous-server = '$RendezvousServer'
key = '$RustDeskKey'
"@

Set-Content `
    -LiteralPath $UserRustDesk2 `
    -Value $ConfigContent `
    -Encoding UTF8 `
    -Force

Log "RustDesk2.toml written."

# ==========================================================
# VERIFY NETWORK CONFIG
# ==========================================================

Log "Verifying RustDesk2.toml..."

$Config = Get-Content `
    -LiteralPath $UserRustDesk2 `
    -Raw

if (
    $Config -notmatch `
        [regex]::Escape("rendezvous_server = '$RendezvousServer`:21116'")
) {

    throw "rendezvous_server was not configured correctly."
}

if (
    $Config -notmatch `
        [regex]::Escape("custom-rendezvous-server = '$RendezvousServer'")
) {

    throw "custom-rendezvous-server was not configured correctly."
}

if (
    $Config -notmatch `
        [regex]::Escape("relay-server = '$RelayServer'")
) {

    throw "relay-server was not configured correctly."
}

if (
    $Config -notmatch `
        [regex]::Escape("key = '$RustDeskKey'")
) {

    throw "RustDesk key was not configured correctly."
}

Log "Network configuration verified."

# ==========================================================
# STOP TEMPORARY RUSTDESK
# ==========================================================

Log "Stopping temporary RustDesk..."

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ==========================================================
# START FINAL RUSTDESK
# ==========================================================

Log "Starting final RustDesk process..."

$FinalProcess = Start-Process `
    -FilePath $RustDeskExe `
    -WorkingDirectory $AppDir `
    -PassThru

Log "Final RustDesk PID: $($FinalProcess.Id)"

Start-Sleep -Seconds 3

# ==========================================================
# GET RUSTDESK ID
# ==========================================================

Log "Getting RustDesk ID..."

$RustDeskId = ""

for ($i = 0; $i -lt 30; $i++) {

    try {

        $Output = & $RustDeskExe `
            "--get-id" `
            2>$null

        $GetIdExitCode = $LASTEXITCODE

        if ($GetIdExitCode -eq 0 -and $Output) {

            $RustDeskId = (
                $Output -join ""
            ).Trim()
        }

    }
    catch {

        $RustDeskId = ""
    }

    if (-not [string]::IsNullOrWhiteSpace($RustDeskId)) {

        break
    }

    Start-Sleep -Seconds 1
}

if ([string]::IsNullOrWhiteSpace($RustDeskId)) {

    Log "RustDesk ID is empty."

    if (Test-Path -LiteralPath $UserStdErrLog) {

        Log "RustDesk stderr:"

        Get-Content `
            -LiteralPath $UserStdErrLog `
            -ErrorAction SilentlyContinue |
            ForEach-Object {
                Log $_
            }
    }

    throw "RustDesk ID could not be obtained."
}

Log "RustDesk ID: $RustDeskId"

# ==========================================================
# FINAL CONFIG VERIFICATION
# ==========================================================

if (-not (Test-Path -LiteralPath $UserRustDesk2)) {

    throw "RustDesk2.toml disappeared after configuration."
}

# ==========================================================
# RESULT
# ==========================================================

Write-Host ""

Write-Host "========================================"
Write-Host "RustDesk installation completed"
Write-Host "========================================"
Write-Host ""

Write-Host "User:"
Write-Host "  $CurrentUserFull"

Write-Host ""

Write-Host "Architecture:"
Write-Host "  $Architecture"

Write-Host ""

Write-Host "RustDesk ID:"
Write-Host "  $RustDeskId"

Write-Host ""

Write-Host "Network:"
Write-Host "  $RendezvousServer"

Write-Host ""

Write-Host "Relay:"
Write-Host "  $RelayServer"

Write-Host ""

Write-Host "Password:"
Write-Host "  configured"

Write-Host ""

Write-Host "User config:"
Write-Host "  $UserRustDesk2"

Write-Host ""

Write-Host "Installer log:"
Write-Host "  $InstallLog"

Write-Host ""

Write-Host "RustDesk stdout:"
Write-Host "  $UserStdOutLog"

Write-Host ""

Write-Host "RustDesk stderr:"
Write-Host "  $UserStdErrLog"

Write-Host ""

Write-Host "========================================"

Log "RustDesk installation completed successfully."

exit 0