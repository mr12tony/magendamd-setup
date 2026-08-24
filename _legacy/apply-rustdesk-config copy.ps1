$ErrorActionPreference = "Stop"

# ============================================================
# SETTINGS
# ============================================================

$ConfigSource = Join-Path $PSScriptRoot "RustDesk2.toml"

$ServiceName = "RustDesk"
$RustDeskExe = "C:\Program Files\RustDesk\RustDesk.exe"

# Текущий пользователь
$UserConfigDir = Join-Path $env:APPDATA "RustDesk\config"
$UserConfig = Join-Path $UserConfigDir "RustDesk2.toml"

# Системный RustDesk Service
$SystemConfigDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
$SystemConfig = Join-Path $SystemConfigDir "RustDesk2.toml"


# ============================================================
# CHECK ADMIN
# ============================================================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Host "ERROR: Run PowerShell as Administrator." -ForegroundColor Red
    exit 1
}


# ============================================================
# CHECK CONFIG
# ============================================================

if (-not (Test-Path $ConfigSource)) {
    Write-Host "ERROR: RustDesk2.toml not found:" -ForegroundColor Red
    Write-Host $ConfigSource
    exit 1
}

Write-Host ""
Write-Host "===== RUSTDESK CONFIG UPDATE ====="
Write-Host ""


# ============================================================
# STOP SERVICE
# ============================================================

Write-Host "[1/5] Stopping RustDesk service..."

$service = Get-Service $ServiceName -ErrorAction SilentlyContinue

if ($null -ne $service) {

    if ($service.Status -ne "Stopped") {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    }

    # Ждём полной остановки
    for ($i = 0; $i -lt 15; $i++) {

        $service = Get-Service $ServiceName -ErrorAction SilentlyContinue

        if ($null -eq $service -or $service.Status -eq "Stopped") {
            break
        }

        Start-Sleep -Seconds 1
    }

    Write-Host "Service stopped."
}
else {
    Write-Host "Service not found."
}


# ============================================================
# STOP GUI
# ============================================================

Write-Host "[2/5] Stopping RustDesk GUI..."

Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

Write-Host "RustDesk processes stopped."


# ============================================================
# COPY CONFIG
# ============================================================

Write-Host "[3/5] Installing RustDesk2.toml..."


# ------------------------------------------------------------
# CURRENT USER
# ------------------------------------------------------------

if (-not (Test-Path $UserConfigDir)) {
    New-Item `
        -Path $UserConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $UserConfig `
    -Force

Write-Host "User config:"
Write-Host "  $UserConfig"


# ------------------------------------------------------------
# SYSTEM / LOCAL SERVICE
# ------------------------------------------------------------

if (-not (Test-Path $SystemConfigDir)) {
    New-Item `
        -Path $SystemConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $SystemConfig `
    -Force

Write-Host "System config:"
Write-Host "  $SystemConfig"


# ============================================================
# SHOW CONFIG
# ============================================================

Write-Host ""
Write-Host "Installed configuration:"
Write-Host ""

Write-Host "--- USER ---"
Get-Content $UserConfig -Raw

Write-Host "--- SYSTEM ---"
Get-Content $SystemConfig -Raw


# ============================================================
# START SERVICE
# ============================================================

Write-Host "[4/5] Starting RustDesk service..."

$service = Get-Service $ServiceName -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Start-Service $ServiceName

    Start-Sleep -Seconds 3

    $service = Get-Service $ServiceName

    Write-Host "Service status: $($service.Status)"
}
else {
    Write-Host "WARNING: RustDesk service does not exist."
}


# ============================================================
# GUI
# ============================================================

Write-Host "[5/5] GUI is NOT started automatically."

Write-Host ""
Write-Host "===== DONE ====="
Write-Host ""