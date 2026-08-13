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
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

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

    Start-Process `
        -FilePath "powershell.exe" `
        -Verb RunAs `
        -ArgumentList ($arguments -join " ")

    exit 0
}

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

Write-Host "Stopping RustDesk..."

Get-Process "RustDesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

$service = Get-Service `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    if ($service.Status -ne "Stopped") {
        Stop-Service `
            -Name "RustDesk" `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 2

# ============================================================
# Install
# ============================================================

Write-Host "Installing RustDesk..."

$installProcess = Start-Process `
    -FilePath $Installer `
    -ArgumentList "--silent-install" `
    -Wait `
    -PassThru

Write-Host "Installer exit code: $($installProcess.ExitCode)"

if ($installProcess.ExitCode -ne 0) {
    throw "RustDesk installation failed with exit code $($installProcess.ExitCode)"
}

# ============================================================
# Wait for RustDesk.exe
# ============================================================

Write-Host "Waiting for RustDesk..."

$found = $false

for ($i = 0; $i -lt 30; $i++) {

    if (Test-Path $RustDeskExe) {
        $found = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $found) {
    throw "RustDesk.exe was not found after installation"
}

# ============================================================
# Service
# ============================================================

Write-Host "Checking RustDesk service..."

$service = Get-Service `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Host "Installing RustDesk service..."

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru

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

Start-Service `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3

# ============================================================
# Config
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

# ============================================================
# Password
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

# ============================================================
# Get ID
# ============================================================

Write-Host "Getting RustDesk ID..."

$idProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList "--get-id" `
    -Wait `
    -PassThru `
    -RedirectStandardOutput "$env:TEMP\rustdesk-id.txt" `
    -NoNewWindow

$RustDeskId = (
    Get-Content "$env:TEMP\rustdesk-id.txt" -Raw
).Trim()

Remove-Item `
    "$env:TEMP\rustdesk-id.txt" `
    -Force `
    -ErrorAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($RustDeskId)) {
    throw "Failed to get RustDesk ID"
}

# ============================================================
# Restart service
# ============================================================

Write-Host "Restarting RustDesk service..."

Restart-Service `
    -Name "RustDesk" `
    -Force

Start-Sleep -Seconds 3

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