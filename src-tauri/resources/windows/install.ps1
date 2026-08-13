param(
    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [string]$Config
)

$ErrorActionPreference = "Stop"

# ============================================================
# Paths
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$RustDeskDir = Join-Path $env:ProgramFiles "RustDesk"
$RustDeskExe = Join-Path $RustDeskDir "RustDesk.exe"

# ============================================================
# Administrator
# ============================================================

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object Security.Principal.WindowsPrincipal(
    $currentIdentity
)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {

    Write-Host "Requesting administrator privileges..."

    $arguments = @(
        "-NoProfile"
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        "`"$($MyInvocation.MyCommand.Path)`""
        "-Password"
        "`"$Password`""
        "-Config"
        "`"$Config`""
    )

    $elevatedProcess = Start-Process `
        -FilePath "powershell.exe" `
        -Verb RunAs `
        -ArgumentList ($arguments -join " ") `
        -Wait `
        -PassThru

    if ($elevatedProcess.ExitCode -ne 0) {
        throw "Elevated installation failed with exit code $($elevatedProcess.ExitCode)"
    }

    exit 0
}

Write-Host "Running as administrator"

# ============================================================
# Architecture
# ============================================================

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

switch ($architecture.ToString()) {

    "X64" {
        $Installer = Join-Path $ScriptDir "rustdesk-x86_64.exe"
    }

    "Arm64" {
        $Installer = Join-Path $ScriptDir "rustdesk-aarch64.exe"
    }

    default {
        throw "Unsupported Windows architecture: $architecture"
    }
}

Write-Host "Architecture: $architecture"
Write-Host "Installer: $Installer"

if (-not (Test-Path $Installer)) {
    throw "RustDesk installer not found: $Installer"
}

# ============================================================
# Stop existing RustDesk
# ============================================================

Write-Host "Stopping existing RustDesk..."

Get-Process "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

$service = Get-Service `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    if ($service.Status -ne "Stopped") {

        Write-Host "Stopping RustDesk service..."

        Stop-Service `
            -Name "RustDesk" `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 2

# ============================================================
# Install RustDesk
# ============================================================

Write-Host "Installing RustDesk..."

# ВАЖНО:
# Здесь специально НЕТ -Wait.
# RustDesk installer может не завершить процесс так,
# как ожидает Start-Process -Wait.
#
# Вместо этого ниже ждём фактического появления RustDesk.exe.

$installProcess = Start-Process `
    -FilePath $Installer `
    -ArgumentList "--silent-install" `
    -PassThru

Write-Host "RustDesk installer started. PID: $($installProcess.Id)"

# ============================================================
# Wait for RustDesk.exe
# ============================================================

Write-Host "Waiting for RustDesk.exe..."

$found = $false

for ($i = 0; $i -lt 60; $i++) {

    if (Test-Path $RustDeskExe) {

        $found = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $found) {

    if (-not $installProcess.HasExited) {

        Stop-Process `
            -Id $installProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

    throw "RustDesk.exe was not found after 60 seconds"
}

Write-Host "RustDesk.exe found:"
Write-Host $RustDeskExe

# ============================================================
# Service
# ============================================================

Write-Host "Checking RustDesk service..."

$service = Get-Service `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Host "RustDesk service not found."
    Write-Host "Installing RustDesk service..."

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru

    Write-Host "Service installer exit code: $($serviceProcess.ExitCode)"

    if ($serviceProcess.ExitCode -ne 0) {
        throw "Failed to install RustDesk service"
    }

    Start-Sleep -Seconds 3

    $service = Get-Service `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue
}

if ($null -eq $service) {
    throw "RustDesk service was not found"
}

# ============================================================
# Start service
# ============================================================

Write-Host "Starting RustDesk service..."

if ($service.Status -ne "Running") {

    Start-Service `
        -Name "RustDesk"
}

# Wait until service is running

for ($i = 0; $i -lt 30; $i++) {

    $service.Refresh()

    if ($service.Status -eq "Running") {
        break
    }

    Start-Sleep -Seconds 1
}

$service.Refresh()

if ($service.Status -ne "Running") {
    throw "RustDesk service failed to start"
}

Write-Host "RustDesk service is running"

Start-Sleep -Seconds 2

# ============================================================
# Apply Config
# ============================================================

Write-Host "Applying RustDesk config..."

$configProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--config"
        $Config
    ) `
    -Wait `
    -PassThru `
    -NoNewWindow

Write-Host "Config exit code: $($configProcess.ExitCode)"

if ($configProcess.ExitCode -ne 0) {
    throw "Failed to apply RustDesk config"
}

Write-Host "RustDesk config applied"

# ============================================================
# Set Password
# ============================================================

Write-Host "Setting RustDesk password..."

$passwordProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--password"
        $Password
    ) `
    -Wait `
    -PassThru `
    -NoNewWindow

Write-Host "Password exit code: $($passwordProcess.ExitCode)"

if ($passwordProcess.ExitCode -ne 0) {
    throw "Failed to set RustDesk password"
}

Write-Host "RustDesk password configured"

# ============================================================
# Restart Service
# ============================================================

Write-Host "Restarting RustDesk service..."

Restart-Service `
    -Name "RustDesk" `
    -Force

# Wait for Running

$service = Get-Service `
    -Name "RustDesk"

for ($i = 0; $i -lt 30; $i++) {

    $service.Refresh()

    if ($service.Status -eq "Running") {
        break
    }

    Start-Sleep -Seconds 1
}

$service.Refresh()

if ($service.Status -ne "Running") {
    throw "RustDesk service failed to restart"
}

Write-Host "RustDesk service restarted successfully"

Start-Sleep -Seconds 3

# ============================================================
# Get ID AFTER restart
# ============================================================

Write-Host "Getting RustDesk ID..."

$idFile = Join-Path $env:TEMP "rustdesk-id-$PID.txt"

Remove-Item `
    $idFile `
    -Force `
    -ErrorAction SilentlyContinue

$idProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList "--get-id" `
    -Wait `
    -PassThru `
    -RedirectStandardOutput $idFile `
    -NoNewWindow

if ($idProcess.ExitCode -ne 0) {
    throw "RustDesk --get-id failed with exit code $($idProcess.ExitCode)"
}

$RustDeskId = (
    Get-Content `
        $idFile `
        -Raw
).Trim()

Remove-Item `
    $idFile `
    -Force `
    -ErrorAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($RustDeskId)) {
    throw "Failed to get RustDesk ID"
}

# ============================================================
# Result
# ============================================================

Write-Host ""
Write-Host "=========================================="
Write-Host "RustDesk installation completed"
Write-Host "Architecture: $architecture"
Write-Host "RustDesk ID: $RustDeskId"
Write-Host "Password: $Password"
Write-Host "=========================================="

exit 0