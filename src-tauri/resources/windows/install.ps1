#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Password
)

$ErrorActionPreference = "Stop"

# ==========================================================
# RustDesk Windows installer for Tauri
#
# Usage:
#
#   powershell.exe -ExecutionPolicy Bypass `
#       -File install.ps1 -Password "YOUR_PASSWORD"
#
# Files:
#
#   install.ps1
#   rustdesk-x86_64.exe
#   rustdesk-aarch64.exe
#
# Installation:
#
#   C:\Program Files\RustDesk
#
# Configuration:
#
#   C:\ProgramData\RustDesk\config\RustDesk2.toml
#
# ==========================================================


# ==========================================================
# PATHS
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$AppDir = Join-Path $env:ProgramFiles "RustDesk"

$RustDeskExe = Join-Path $AppDir "RustDesk.exe"

$ProgramDataRustDesk = Join-Path $env:ProgramData "RustDesk"

$ConfigDir = Join-Path $ProgramDataRustDesk "config"

$RustDeskConfig = Join-Path $ConfigDir "RustDesk2.toml"

$InstallLog = Join-Path $env:TEMP "rustdesk-install.log"


# ==========================================================
# CONFIGURATION
# ==========================================================

$RendezvousServer = "rustdesk.magendamd.com"

$RelayServer = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="


# ==========================================================
# LOGGING
# ==========================================================

function Log {
    param(
        [AllowEmptyString()]
        [string]$Message = ""
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
        # Logging must never stop installation.
    }
}


function Section {
    param(
        [string]$Name
    )

    Log ""
    Log "=================================================="
    Log "[$Name]"
    Log "=================================================="
}


# ==========================================================
# ADMIN CHECK
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
# REQUEST ADMINISTRATOR PRIVILEGES
# ==========================================================

if (-not (Test-IsAdministrator)) {

    Write-Host ""
    Write-Host "Administrator privileges are required."
    Write-Host "Requesting UAC..."
    Write-Host ""

    try {

        $Arguments = @(
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
            -ArgumentList $Arguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        $ExitCode = $ElevatedProcess.ExitCode

        Write-Host ""
        Write-Host "Elevated PowerShell finished."
        Write-Host "Exit code: $ExitCode"

        exit $ExitCode
    }
    catch {

        Write-Host ""
        Write-Host "ERROR: Administrator authorization failed."
        Write-Host $_.Exception.Message

        exit 1
    }
}


# ==========================================================
# START
# ==========================================================

Section "START"

Log "RustDesk Windows installer"

Log "Running as administrator: YES"

Log "Script directory: $ScriptDir"

Log "Install directory: $AppDir"

Log "Config directory: $ConfigDir"


# ==========================================================
# WINDOWS IDENTITY
# ==========================================================

Section "USER"

$WindowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

Log "Windows identity: $($WindowsIdentity.Name)"

Log "User profile: $env:USERPROFILE"


# ==========================================================
# ARCHITECTURE
# ==========================================================

Section "ARCHITECTURE"

$Architecture = $env:PROCESSOR_ARCHITECTURE

if ($env:PROCESSOR_ARCHITEW6432) {
    $Architecture = $env:PROCESSOR_ARCHITEW6432
}

$Architecture = $Architecture.ToUpperInvariant()

switch ($Architecture) {

    "AMD64" {

        $BundledExe = Join-Path `
            $ScriptDir `
            "rustdesk-x86_64.exe"
    }

    "ARM64" {

        $BundledExe = Join-Path `
            $ScriptDir `
            "rustdesk-aarch64.exe"
    }

    default {

        Log "ERROR: Unsupported Windows architecture:"
        Log $Architecture

        exit 1
    }
}

Log "Architecture: $Architecture"

Log "Bundled RustDesk: $BundledExe"


if (-not (Test-Path -LiteralPath $BundledExe -PathType Leaf)) {

    Log "ERROR: RustDesk executable not found."

    Log "Expected:"
    Log $BundledExe

    exit 1
}


# ==========================================================
# STOP EXISTING RUSTDESK PROCESSES
# ==========================================================

Section "STOP OLD RUSTDESK"

Log "Stopping RustDesk processes..."

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    ForEach-Object {

        Log "Stopping RustDesk PID: $($_.Id)"

        try {

            Stop-Process `
                -Id $_.Id `
                -Force `
                -ErrorAction SilentlyContinue

        }
        catch {
        }
    }

Start-Sleep -Seconds 2


# ==========================================================
# STOP EXISTING SERVICES
# ==========================================================

Section "STOP OLD SERVICES"

$ServiceNames = @(
    "RustDesk"
    "RustDeskService"
)

foreach ($ServiceName in $ServiceNames) {

    $Service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $Service) {

        Log "Found service: $ServiceName"

        try {

            if ($Service.Status -ne "Stopped") {

                Log "Stopping service: $ServiceName"

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

Section "REMOVE OLD SERVICES"

foreach ($ServiceName in $ServiceNames) {

    $Service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $Service) {

        Log "Removing service: $ServiceName"

        try {

            & sc.exe delete $ServiceName *> $null

        }
        catch {
        }
    }
}

Start-Sleep -Seconds 2


# ==========================================================
# REMOVE OLD INSTALLATION
# ==========================================================

Section "REMOVE OLD INSTALLATION"

if (Test-Path -LiteralPath $AppDir) {

    Log "Removing old installation:"
    Log $AppDir

    try {

        Remove-Item `
            -LiteralPath $AppDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

    }
    catch {

        Log "ERROR: Could not remove old RustDesk installation."

        Log $_.Exception.Message

        exit 1
    }
}


# ==========================================================
# REMOVE OLD CONFIGURATION
# ==========================================================

Section "REMOVE OLD CONFIGURATION"

if (Test-Path -LiteralPath $ProgramDataRustDesk) {

    Log "Removing old ProgramData configuration:"

    Log $ProgramDataRustDesk

    try {

        Remove-Item `
            -LiteralPath $ProgramDataRustDesk `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

    }
    catch {
    }
}


# ==========================================================
# CREATE INSTALLATION DIRECTORY
# ==========================================================

Section "INSTALL"

Log "Creating installation directory..."

New-Item `
    -ItemType Directory `
    -Path $AppDir `
    -Force |
    Out-Null


# ==========================================================
# COPY RUSTDESK
# ==========================================================

Log "Installing RustDesk executable..."

Copy-Item `
    -LiteralPath $BundledExe `
    -Destination $RustDeskExe `
    -Force


if (-not (Test-Path -LiteralPath $RustDeskExe -PathType Leaf)) {

    Log "ERROR: RustDesk.exe was not installed."

    exit 1
}

Log "RustDesk executable installed successfully."

Log "Executable:"
Log $RustDeskExe


# ==========================================================
# CREATE CONFIGURATION DIRECTORY
# ==========================================================

Section "CONFIGURATION"

Log "Creating configuration directory..."

New-Item `
    -ItemType Directory `
    -Path $ConfigDir `
    -Force |
    Out-Null


# ==========================================================
# CREATE RUSTDESK CONFIG
# ==========================================================

Log "Writing RustDesk2.toml..."

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
    -LiteralPath $RustDeskConfig `
    -Value $ConfigContent `
    -Encoding UTF8


if (-not (Test-Path -LiteralPath $RustDeskConfig -PathType Leaf)) {

    Log "ERROR: RustDesk2.toml was not created."

    exit 1
}


Log "RustDesk2.toml created:"
Log $RustDeskConfig


# ==========================================================
# VERIFY CONFIGURATION
# ==========================================================

Log "Verifying configuration..."

$Config = Get-Content `
    -LiteralPath $RustDeskConfig `
    -Raw


if ($Config -notmatch [regex]::Escape(
    "rendezvous_server = '$RendezvousServer`:21116'"
)) {

    Log "ERROR: rendezvous_server is missing."

    exit 1
}


if ($Config -notmatch [regex]::Escape(
    "relay-server = '$RelayServer'"
)) {

    Log "ERROR: relay-server is missing."

    exit 1
}


if ($Config -notmatch [regex]::Escape(
    "custom-rendezvous-server = '$RendezvousServer'"
)) {

    Log "ERROR: custom-rendezvous-server is missing."

    exit 1
}


if ($Config -notmatch [regex]::Escape(
    "key = '$RustDeskKey'"
)) {

    Log "ERROR: RustDesk key is missing."

    exit 1
}


Log "RustDesk configuration verified."


# ==========================================================
# PASSWORD
# ==========================================================

Section "PASSWORD"

Log "Applying RustDesk permanent password..."

try {

    $PasswordOutput = & $RustDeskExe `
        --password $Password `
        2>&1

    $PasswordExitCode = $LASTEXITCODE

}
catch {

    Log "ERROR: Failed to execute RustDesk --password."

    Log $_.Exception.Message

    exit 1
}


Log "RustDesk --password exit code: $PasswordExitCode"


if ($PasswordExitCode -ne 0) {

    Log "ERROR: RustDesk password configuration failed."

    if ($PasswordOutput) {
        Log (($PasswordOutput -join "`r`n"))
    }

    exit 1
}


Log "RustDesk password applied successfully."


# ==========================================================
# INSTALL SERVICE
# ==========================================================

Section "SERVICE INSTALL"

Log "Installing RustDesk service..."


try {

    $ServiceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru `
        -NoNewWindow

}
catch {

    Log "ERROR: Failed to start RustDesk service installer."

    Log $_.Exception.Message

    exit 1
}


Log "Service installer exit code: $($ServiceProcess.ExitCode)"


# ==========================================================
# WAIT FOR SERVICE
# ==========================================================

Log "Waiting for RustDesk service..."


$Service = $null

$Deadline = (Get-Date).AddSeconds(30)


while ($null -eq $Service) {

    $Service = Get-Service `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if ($null -ne $Service) {
        break
    }

    if ((Get-Date) -gt $Deadline) {

        Log "ERROR: RustDesk service was not created."

        Log "Trying to list RustDesk services..."

        Get-Service |
            Where-Object {
                $_.Name -like "*RustDesk*" -or
                $_.DisplayName -like "*RustDesk*"
            } |
            ForEach-Object {

                Log "Service:"
                Log "  Name: $($_.Name)"
                Log "  Status: $($_.Status)"
            }

        exit 1
    }

    Start-Sleep -Seconds 1
}


Log "RustDesk service found."

Log "Service name: $($Service.Name)"

Log "Status: $($Service.Status)"


# ==========================================================
# SERVICE AUTOSTART
# ==========================================================

Section "SERVICE AUTOSTART"

Log "Configuring RustDesk service for automatic startup..."


try {

    Set-Service `
        -Name "RustDesk" `
        -StartupType Automatic

}
catch {

    Log "ERROR: Failed to configure automatic startup."

    Log $_.Exception.Message

    exit 1
}


Log "Service StartupType set to Automatic."


# ==========================================================
# START / RESTART SERVICE
# ==========================================================

Section "SERVICE START"

Log "Starting RustDesk service..."


try {

    $Service = Get-Service `
        -Name "RustDesk" `
        -ErrorAction Stop


    if ($Service.Status -ne "Stopped") {

        Log "Stopping service before restart..."

        Stop-Service `
            -Name "RustDesk" `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }


    Start-Service `
        -Name "RustDesk"


}
catch {

    Log "ERROR: Failed to start RustDesk service."

    Log $_.Exception.Message

    exit 1
}


# ==========================================================
# WAIT FOR RUNNING
# ==========================================================

Log "Waiting for RustDesk service to become Running..."


$Deadline = (Get-Date).AddSeconds(30)

do {

    Start-Sleep -Seconds 1

    $Service = Get-Service `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if ($null -eq $Service) {
        continue
    }

    if ($Service.Status -eq "Running") {
        break
    }

}
while ((Get-Date) -lt $Deadline)


if ($null -eq $Service) {

    Log "ERROR: RustDesk service disappeared."

    exit 1
}


Log "RustDesk service status: $($Service.Status)"


if ($Service.Status -ne "Running") {

    Log "ERROR: RustDesk service is not running."

    exit 1
}


# ==========================================================
# FINAL VERIFICATION
# ==========================================================

Section "FINAL VERIFICATION"

if (-not (Test-Path -LiteralPath $RustDeskExe -PathType Leaf)) {

    Log "ERROR: RustDesk executable is missing."

    exit 1
}

Log "RustDesk executable: OK"

if (-not (Test-Path -LiteralPath $RustDeskConfig -PathType Leaf)) {

    Log "ERROR: RustDesk configuration is missing."

    exit 1
}

Log "RustDesk configuration: OK"

$Service = Get-Service `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue


if ($null -eq $Service) {

    Log "ERROR: RustDesk service is missing."

    exit 1
}


Log "RustDesk service: $($Service.Status)"


if ($Service.Status -ne "Running") {

    Log "ERROR: RustDesk service is not running."

    exit 1
}


# ==========================================================
# SHOW CONFIG
# ==========================================================

Section "CONFIGURATION RESULT"

Log "RustDesk2.toml:"

Get-Content `
    -LiteralPath $RustDeskConfig |
    ForEach-Object {

        # Do not print the key itself into the log.
        if ($_ -match "^key\s*=") {
            Log "key = [configured]"
        }
        else {
            Log $_
        }
    }


# ==========================================================
# RESULT
# ==========================================================

Section "SUCCESS"

Log "RustDesk installation completed successfully."

Log "Architecture: $Architecture"

Log "Executable: $RustDeskExe"

Log "Configuration: $RustDeskConfig"

Log "Service: RustDesk"

Log "Service status: $($Service.Status)"

Log "Service startup: Automatic"

Log "Installer log: $InstallLog"

Write-Host ""
Write-Host "========================================"
Write-Host "RustDesk installation completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Architecture:"
Write-Host "  $Architecture"
Write-Host ""
Write-Host "Executable:"
Write-Host "  $RustDeskExe"
Write-Host ""
Write-Host "Configuration:"
Write-Host "  $RustDeskConfig"
Write-Host ""
Write-Host "Service:"
Write-Host "  RustDesk"
Write-Host ""
Write-Host "Service status:"
Write-Host "  $($Service.Status)"
Write-Host ""
Write-Host "Password:"
Write-Host "  configured"
Write-Host ""
Write-Host "Installer log:"
Write-Host "  $InstallLog"
Write-Host ""
Write-Host "========================================"

exit 0