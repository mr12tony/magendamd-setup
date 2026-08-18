param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword
)

$ErrorActionPreference = "Stop"

# ============================================================
# SETTINGS
# ============================================================

$ConfigSource = Join-Path $PSScriptRoot "RustDesk2.toml"

$ServiceName = "RustDesk"
$RustDeskExe = "C:\Program Files\RustDesk\RustDesk.exe"


# ============================================================
# PASSWORD
# ============================================================

if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    # Генерируем случайный пароль:
    # 16 символов, hex
    $RustDeskPassword = -join (
        1..16 | ForEach-Object {
            "{0:x}" -f (Get-Random -Minimum 0 -Maximum 16)
        }
    )

    $PasswordGenerated = $true

}
else {

    $PasswordGenerated = $false
}


# ============================================================
# CURRENT USER CONFIG
# ============================================================

$UserConfigDir = Join-Path $env:APPDATA "RustDesk\config"
$UserConfig = Join-Path $UserConfigDir "RustDesk2.toml"


# ============================================================
# SYSTEM / SERVICE CONFIG
# ============================================================

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

    Write-Host ""
    Write-Host "ERROR: Run PowerShell as Administrator." -ForegroundColor Red
    Write-Host ""

    exit 1
}


# ============================================================
# CHECK RUSTDESK
# ============================================================

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe not found:" -ForegroundColor Red
    Write-Host $RustDeskExe
    Write-Host ""

    exit 1
}


# ============================================================
# CHECK CONFIG
# ============================================================

if (-not (Test-Path -LiteralPath $ConfigSource)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk2.toml not found:" -ForegroundColor Red
    Write-Host $ConfigSource
    Write-Host ""

    exit 1
}


# ============================================================
# START
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "             RUSTDESK CONFIG + PASSWORD"
Write-Host "============================================================"
Write-Host ""

Write-Host "RustDesk:"
Write-Host "  $RustDeskExe"

Write-Host ""
Write-Host "Config source:"
Write-Host "  $ConfigSource"

Write-Host ""
Write-Host "User config:"
Write-Host "  $UserConfig"

Write-Host ""
Write-Host "System config:"
Write-Host "  $SystemConfig"

Write-Host ""

if ($PasswordGenerated) {

    Write-Host "Password mode: GENERATED"

}
else {

    Write-Host "Password mode: PROVIDED AS ARGUMENT"

}

Write-Host ""


# ============================================================
# 1. STOP SERVICE
# ============================================================

Write-Host "[1/6] Stopping RustDesk service..."

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Host "Current service status: $($service.Status)"

    if ($service.Status -ne "Stopped") {

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -lt 15; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (
            $null -eq $service -or
            $service.Status -eq "Stopped"
        ) {
            break
        }

        Start-Sleep -Seconds 1
    }

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (
        $null -ne $service -and
        $service.Status -ne "Stopped"
    ) {

        Write-Host ""
        Write-Host "ERROR: RustDesk service could not be stopped." -ForegroundColor Red

        exit 1
    }

    Write-Host "Service stopped."

}
else {

    Write-Host "RustDesk service not found."
}


# ============================================================
# 2. STOP GUI
# ============================================================

Write-Host ""
Write-Host "[2/6] Stopping RustDesk GUI..."

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2


for ($i = 0; $i -lt 10; $i++) {

    $process = Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if ($null -eq $process) {
        break
    }

    Start-Sleep -Seconds 1
}


$process = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -ne $process) {

    Write-Host ""
    Write-Host "ERROR: RustDesk GUI process is still running." -ForegroundColor Red

    exit 1
}

Write-Host "RustDesk GUI stopped."


# ============================================================
# 3. INSTALL CONFIG
# ============================================================

Write-Host ""
Write-Host "[3/6] Installing RustDesk2.toml..."


# ------------------------------------------------------------
# USER CONFIG DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $UserConfigDir)) {

    New-Item `
        -Path $UserConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# SYSTEM CONFIG DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SystemConfigDir)) {

    New-Item `
        -Path $SystemConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# BACKUP USER CONFIG
# ------------------------------------------------------------

if (Test-Path -LiteralPath $UserConfig) {

    $UserBackup = "$UserConfig.backup"

    Copy-Item `
        -LiteralPath $UserConfig `
        -Destination $UserBackup `
        -Force

    Write-Host "User config backup:"
    Write-Host "  $UserBackup"
}


# ------------------------------------------------------------
# BACKUP SYSTEM CONFIG
# ------------------------------------------------------------

if (Test-Path -LiteralPath $SystemConfig) {

    $SystemBackup = "$SystemConfig.backup"

    Copy-Item `
        -LiteralPath $SystemConfig `
        -Destination $SystemBackup `
        -Force

    Write-Host "System config backup:"
    Write-Host "  $SystemBackup"
}


# ------------------------------------------------------------
# COPY USER CONFIG
# ------------------------------------------------------------

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $UserConfig `
    -Force

Write-Host ""
Write-Host "User config installed:"
Write-Host "  $UserConfig"


# ------------------------------------------------------------
# COPY SYSTEM CONFIG
# ------------------------------------------------------------

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $SystemConfig `
    -Force

Write-Host ""
Write-Host "System config installed:"
Write-Host "  $SystemConfig"


# ============================================================
# VERIFY CONFIG
# ============================================================

Write-Host ""
Write-Host "===== USER CONFIG ====="
Write-Host ""

Get-Content `
    -LiteralPath $UserConfig `
    -Raw


Write-Host ""
Write-Host "===== SYSTEM CONFIG ====="
Write-Host ""

Get-Content `
    -LiteralPath $SystemConfig `
    -Raw


# ============================================================
# 4. APPLY PASSWORD
# ============================================================

Write-Host ""
Write-Host "[4/6] Applying RustDesk password..."

$passwordProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--password",
        $RustDeskPassword
    ) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden


Write-Host "RustDesk --password exit code: $($passwordProcess.ExitCode)"


if ($passwordProcess.ExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: RustDesk password command failed." -ForegroundColor Red

    exit 1
}

Write-Host "Password applied successfully."


# ============================================================
# 5. START SERVICE
# ============================================================

Write-Host ""
Write-Host "[5/6] Starting RustDesk service..."

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service does not exist." -ForegroundColor Red

    exit 1
}

Start-Service `
    -Name $ServiceName


$running = $false

for ($i = 0; $i -lt 20; $i++) {

    Start-Sleep -Seconds 1

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (
        $null -ne $service -and
        $service.Status -eq "Running"
    ) {

        $running = $true
        break
    }
}


if (-not $running) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service failed to start." -ForegroundColor Red

    Get-Service `
        -Name $ServiceName |
        Format-List Name,Status,StartType

    exit 1
}


Write-Host "RustDesk service is RUNNING."


# ============================================================
# 6. GUI
# ============================================================

Write-Host ""
Write-Host "[6/6] GUI is NOT started automatically."


# ============================================================
# FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                         DONE"
Write-Host "============================================================"
Write-Host ""

Write-Host "Service:"
Get-Service `
    -Name $ServiceName |
    Format-List Name,Status,StartType

Write-Host ""
Write-Host "User config:"
Write-Host "  $UserConfig"

Write-Host ""
Write-Host "System config:"
Write-Host "  $SystemConfig"

Write-Host ""

if ($PasswordGenerated) {
    Write-Host "GENERATED PASSWORD:" -ForegroundColor Yellow
    Write-Host $RustDeskPassword -ForegroundColor Yellow
}
else {
    Write-Host "Password was provided as command-line argument."
}

Write-Host ""
Write-Host "GUI was not started."

Write-Host ""
Write-Host "============================================================"