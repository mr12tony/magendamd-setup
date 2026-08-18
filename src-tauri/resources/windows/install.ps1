#requires -Version 5.1

$ErrorActionPreference = "Stop"

# ==========================================================
# RustDesk Windows installer for Tauri
#
# Tauri runs:
#
#   powershell.exe -ExecutionPolicy Bypass -File install.ps1 PASSWORD
#
# The script itself requests Administrator privileges.
#
# RustDesk:
#   1.4.9
#
# IMPORTANT:
#   Network configuration is written directly to RustDesk2.toml.
# ==========================================================

# ==========================================================
# ARGUMENTS
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Password
)

# ==========================================================
# PATHS
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$AppDir = Join-Path $env:ProgramFiles "RustDesk"

$RustDeskExe = Join-Path $AppDir "RustDesk.exe"

$UserConfigDir = Join-Path $env:APPDATA "RustDesk"

$UserRustDesk2 = Join-Path $UserConfigDir "RustDesk2.toml"

$UserLog = Join-Path $env:TEMP "rustdesk-user.log"

$InstallLog = Join-Path $env:TEMP "rustdesk-install.log"

# ==========================================================
# RUSTDESK CONFIG
# ==========================================================

$RendezvousServer = "rustdesk.magendamd.com"
$RelayServer = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# LOGGING
# ==========================================================

function Log {
    param(
        [string]$Message
    )

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $Line

    try {
        Add-Content -Path $InstallLog -Value $Line
    }
    catch {
        # Ignore logging errors
    }
}

# ==========================================================
# ADMIN CHECK
# ==========================================================

function Test-IsAdministrator {

    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ==========================================================
# REQUEST ADMIN
# ==========================================================

if (-not (Test-IsAdministrator)) {

    Log "Administrator privileges required."

    Log "Requesting UAC elevation..."

    $Arguments = @(
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        "`"$PSCommandPath`""
        "-Password"
        "`"$Password`""
    )

    try {

        Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $Arguments `
            -Verb RunAs `
            -Wait

        exit $LASTEXITCODE
    }
    catch {

        Write-Host ""
        Write-Host "ERROR: Administrator authorization failed."
        Write-Host $_.Exception.Message

        exit 1
    }
}

# ==========================================================
# ROOT / ADMIN PHASE
# ==========================================================

Log "========================================"
Log "RustDesk installer"
Log "========================================"

Log "Running as administrator: YES"

Log "Script directory: $ScriptDir"

# ==========================================================
# CURRENT USER
# ==========================================================

$CurrentUser = [Environment]::UserName

$CurrentUserFull = [Security.Principal.WindowsIdentity]::GetCurrent().Name

Log "Current Windows user: $CurrentUserFull"

# ==========================================================
# ARCHITECTURE
# ==========================================================

$Architecture = $env:PROCESSOR_ARCHITECTURE

if ($env:PROCESSOR_ARCHITEW6432) {
    $Architecture = $env:PROCESSOR_ARCHITEW6432
}

switch ($Architecture.ToUpperInvariant()) {

    "AMD64" {
        $BundledExe = Join-Path $ScriptDir "rustdesk-x86_64.exe"
    }

    "ARM64" {
        $BundledExe = Join-Path $ScriptDir "rustdesk-aarch64.exe"
    }

    default {

        Log "ERROR: Unsupported architecture: $Architecture"

        exit 1
    }
}

Log "Architecture: $Architecture"

Log "RustDesk binary: $BundledExe"

if (-not (Test-Path $BundledExe)) {

    Log "ERROR: RustDesk executable not found."

    Log $BundledExe

    exit 1
}

# ==========================================================
# STOP RUSTDESK
# ==========================================================

Log "Stopping RustDesk..."

Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ==========================================================
# STOP SERVICE
# ==========================================================

Log "Stopping RustDesk service..."

$ServiceNames = @(
    "RustDesk"
    "RustDeskService"
)

foreach ($ServiceName in $ServiceNames) {

    $Service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($Service) {

        Log "Stopping service: $ServiceName"

        try {
            Stop-Service `
                -Name $ServiceName `
                -Force `
                -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

# ==========================================================
# REMOVE OLD SERVICE
# ==========================================================

Log "Removing old RustDesk services..."

foreach ($ServiceName in $ServiceNames) {

    try {

        sc.exe delete $ServiceName `
            *> $null

    }
    catch {
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD APP
# ==========================================================

Log "Removing old RustDesk installation..."

if (Test-Path $AppDir) {

    try {

        Remove-Item `
            -Path $AppDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

    }
    catch {

        Log "WARNING: failed to completely remove old RustDesk."

        Log $_.Exception.Message
    }
}

# ==========================================================
# REMOVE OLD USER CONFIG
# ==========================================================

Log "Removing old RustDesk user configuration..."

if (Test-Path $UserConfigDir) {

    Remove-Item `
        -Path $UserConfigDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

# ==========================================================
# REMOVE OLD SYSTEM CONFIG
# ==========================================================

$SystemConfigPaths = @(
    "$env:ProgramData\RustDesk"
    "$env:ProgramData\RustDesk\config"
)

foreach ($Path in $SystemConfigPaths) {

    if (Test-Path $Path) {

        Log "Removing: $Path"

        Remove-Item `
            -Path $Path `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

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
# COPY RUSTDESK
# ==========================================================

Log "Installing RustDesk.exe..."

Copy-Item `
    -Path $BundledExe `
    -Destination $RustDeskExe `
    -Force

if (-not (Test-Path $RustDeskExe)) {

    Log "ERROR: RustDesk.exe was not installed."

    exit 1
}

Log "RustDesk executable installed."

# ==========================================================
# CREATE USER CONFIG
# ==========================================================

Log "Preparing user configuration..."

New-Item `
    -ItemType Directory `
    -Path $UserConfigDir `
    -Force `
    | Out-Null

# ==========================================================
# START RUSTDESK
#
# Important:
# RustDesk must run as the interactive user.
# ==========================================================

Log "Starting RustDesk as current user..."

$RustDeskProcess = Start-Process `
    -FilePath $RustDeskExe `
    -WorkingDirectory $AppDir `
    -PassThru `
    -RedirectStandardOutput $UserLog `
    -RedirectStandardError $UserLog

Log "RustDesk PID: $($RustDeskProcess.Id)"

# ==========================================================
# WAIT FOR CONFIG
# ==========================================================

Log "Waiting for RustDesk configuration..."

$Deadline = (Get-Date).AddSeconds(45)

while (-not (Test-Path $UserRustDesk2)) {

    if ((Get-Date) -gt $Deadline) {

        Log "ERROR: RustDesk2.toml was not created."

        if (Test-Path $UserLog) {

            Write-Host ""
            Write-Host "RustDesk log:"
            Get-Content $UserLog
        }

        exit 1
    }

    Start-Sleep -Milliseconds 500
}

Log "RustDesk configuration created."

# ==========================================================
# PASSWORD
# ==========================================================

Log "Applying RustDesk password..."

try {

    & $RustDeskExe `
        --password $Password `
        *> $null

}
catch {

    Log "ERROR: password configuration failed."

    Log $_.Exception.Message

    exit 1
}

Log "Password applied."

# ==========================================================
# NETWORK CONFIGURATION
#
# DO NOT USE:
#
#   RustDesk.exe --config ...
#
# We write the working TOML directly.
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
    -Path $UserRustDesk2 `
    -Value $ConfigContent `
    -Encoding UTF8

# ==========================================================
# VERIFY CONFIG
# ==========================================================

Log "Checking RustDesk2.toml..."

$Config = Get-Content `
    -Path $UserRustDesk2 `
    -Raw

if ($Config -notmatch "rendezvous_server = '$RendezvousServer`:21116'") {

    Log "ERROR: rendezvous_server was not configured."

    exit 1
}

if ($Config -notmatch "custom-rendezvous-server = '$RendezvousServer'") {

    Log "ERROR: custom rendezvous server was not configured."

    exit 1
}

if ($Config -notmatch "relay-server = '$RelayServer'") {

    Log "ERROR: relay server was not configured."

    exit 1
}

if ($Config -notmatch "key = '$RustDeskKey'") {

    Log "ERROR: RustDesk key was not configured."

    exit 1
}

Log "Network configuration verified."

# ==========================================================
# STOP TEMPORARY RUSTDESK
# ==========================================================

Log "Stopping temporary RustDesk..."

Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ==========================================================
# START RUSTDESK AGAIN
# ==========================================================

Log "Starting RustDesk again..."

$FinalProcess = Start-Process `
    -FilePath $RustDeskExe `
    -WorkingDirectory $AppDir `
    -PassThru

Log "RustDesk PID: $($FinalProcess.Id)"

Start-Sleep -Seconds 3

# ==========================================================
# GET ID
# ==========================================================

Log "Getting RustDesk ID..."

$RustDeskId = ""

for ($i = 0; $i -lt 30; $i++) {

    try {

        $Output = & $RustDeskExe `
            --get-id `
            2>$null

        $RustDeskId = (
            $Output -join ""
        ).Trim()

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

    Log "ERROR: RustDesk ID is empty."

    exit 1
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
Write-Host "  $UserConfigDir"

Write-Host ""

Write-Host "Installer log:"
Write-Host "  $InstallLog"

Write-Host ""

Write-Host "========================================"

exit 0