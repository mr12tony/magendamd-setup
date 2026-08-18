#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$Server = "rustdesk.magendamd.com",

    [string]$Key = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG
# ============================================================

$ServiceName = "RustDesk"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$SourceExe = Join-Path $ScriptDir "rustdesk-x86_64.exe"

$InstallDir = "C:\Program Files\RustDesk"
$Exe = Join-Path $InstallDir "RustDesk.exe"

$ProgramDataDir = "C:\ProgramData\RustDesk"

$ServiceProfileRoot =
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"

$ServiceConfigDir =
    Join-Path $ServiceProfileRoot "config"

$ServiceConfig =
    Join-Path $ServiceConfigDir "RustDesk2.toml"

$UserAppData =
    Join-Path $env:APPDATA "RustDesk"

$LogFile =
    Join-Path $ScriptDir "install-rustdesk.log"

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "Gray"
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $line -ForegroundColor $Color

    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch {}
}

function Section {
    param([string]$Name)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Name -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Fail {
    param([string]$Message)

    Write-Log "ERROR: $Message" "Red"
    exit 1
}

# ============================================================
# ADMIN CHECK
# ============================================================

$isAdmin =
    ([Security.Principal.WindowsPrincipal]
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "Запусти PowerShell от имени администратора." -ForegroundColor Red
    exit 1
}

# ============================================================
# START
# ============================================================

Section "RUSTDESK WINDOWS INSTALLER"

Write-Log "Running as administrator: YES" "Green"
Write-Log "Windows identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Script directory: $ScriptDir"
Write-Log "Source EXE: $SourceExe"
Write-Log "Install directory: $InstallDir"
Write-Log "Service config: $ServiceConfig"

# ============================================================
# VALIDATION
# ============================================================

Section "VALIDATION"

if (-not (Test-Path -LiteralPath $SourceExe)) {
    Fail "Не найден $SourceExe"
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    Fail "Пароль пустой."
}

if ($Password.Length -lt 6) {
    Fail "Пароль должен содержать минимум 6 символов."
}

Write-Log "Source RustDesk found." "Green"
Write-Log "Server: $Server"
Write-Log "Password length: $($Password.Length)"

# ============================================================
# STOP EVERYTHING
# ============================================================

Section "STOP OLD RUSTDESK"

Write-Log "Stopping RustDesk processes..."

Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

Write-Log "Stopping RustDesk service..."

Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ============================================================
# REMOVE OLD SERVICE
# ============================================================

Section "REMOVE OLD SERVICE"

if (Test-Path -LiteralPath $Exe) {

    Write-Log "Removing old RustDesk service..."

    try {
        & $Exe --uninstall-service 2>&1 | Out-Null
    }
    catch {}

    Start-Sleep -Seconds 3
}

# Fallback: Windows service removal
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Log "Service still exists. Removing through SC..."

    & sc.exe stop $ServiceName 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    & sc.exe delete $ServiceName 2>&1 | Out-Null

    Start-Sleep -Seconds 3
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Fail "Не удалось удалить старую службу RustDesk."
}

Write-Log "Old service removed." "Green"

# ============================================================
# REMOVE OLD USER CONFIG
# ============================================================

Section "REMOVE OLD CONFIGURATION"

$pathsToRemove = @(
    "$env:APPDATA\RustDesk",
    "$env:LOCALAPPDATA\RustDesk",
    "$env:PROGRAMDATA\RustDesk",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"
)

foreach ($path in $pathsToRemove) {

    if (Test-Path -LiteralPath $path) {

        Write-Log "Removing: $path"

        try {
            Remove-Item `
                -LiteralPath $path `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        catch {
            Write-Log "WARNING: Could not completely remove $path : $($_.Exception.Message)" "Yellow"
        }
    }
}

# ============================================================
# REMOVE OLD INSTALLATION
# ============================================================

Section "REMOVE OLD INSTALLATION"

if (Test-Path -LiteralPath $InstallDir) {

    Write-Log "Removing $InstallDir"

    Remove-Item `
        -LiteralPath $InstallDir `
        -Recurse `
        -Force `
        -ErrorAction Stop
}

# ============================================================
# CREATE INSTALLATION
# ============================================================

Section "INSTALL RUSTDESK"

New-Item `
    -ItemType Directory `
    -Path $InstallDir `
    -Force |
    Out-Null

Write-Log "Copying RustDesk.exe..."

Copy-Item `
    -LiteralPath $SourceExe `
    -Destination $Exe `
    -Force

if (-not (Test-Path -LiteralPath $Exe)) {
    Fail "RustDesk.exe не удалось установить."
}

Write-Log "RustDesk executable installed." "Green"

# ============================================================
# CREATE SERVICE
# ============================================================

Section "INSTALL WINDOWS SERVICE"

Write-Log "Installing RustDesk service..."

try {
    & $Exe --install-service 2>&1 |
        ForEach-Object {
            Write-Log "$_"
        }
}
catch {
    Write-Log "RustDesk install-service exception: $($_.Exception.Message)" "Yellow"
}

Start-Sleep -Seconds 3

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Fail "RustDesk service не была создана."
}

Write-Log "RustDesk service registered." "Green"

# ============================================================
# VERIFY SERVICE CONFIGURATION
# ============================================================

Section "VERIFY WINDOWS SERVICE"

& sc.exe qc $ServiceName

Write-Host ""

$qc = & sc.exe qc $ServiceName 2>&1 | Out-String

if ($qc -notmatch "RustDesk.exe") {
    Fail "Windows service не указывает на RustDesk.exe."
}

if ($qc -notmatch "--service") {
    Fail "Windows service не содержит параметр --service."
}

if ($qc -notmatch "LocalSystem") {
    Write-Log "WARNING: Service account is not detected as LocalSystem." "Yellow"
}
else {
    Write-Log "Service account: LocalSystem" "Green"
}

# ============================================================
# CREATE CONFIG DIRECTORY
# ============================================================

Section "CREATE SERVICE CONFIG"

New-Item `
    -ItemType Directory `
    -Path $ServiceConfigDir `
    -Force |
    Out-Null

# ============================================================
# WRITE CONFIG
# ============================================================

Section "WRITE RUSTDESK2.TOML"

$config = @"
rendezvous_server = '$Server:21116'
nat_type = 1
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
relay-server = '$Server'
custom-rendezvous-server = '$Server'
key = '$Key'
"@

Set-Content `
    -LiteralPath $ServiceConfig `
    -Value $config `
    -Encoding UTF8 `
    -Force

if (-not (Test-Path -LiteralPath $ServiceConfig)) {
    Fail "RustDesk2.toml не создан."
}

Write-Log "Config created:" "Green"
Write-Host $config

# ============================================================
# ACL
# ============================================================

Section "CONFIG PERMISSIONS"

Write-Log "Setting service configuration permissions..."

& icacls.exe $ServiceConfig `
    /inheritance:r `
    /grant:r "SYSTEM:F" `
    /grant:r "Administrators:F" `
    /grant:r "LOCAL SERVICE:F" `
    2>&1 |
    ForEach-Object {
        Write-Log "$_"
    }

# ============================================================
# START SERVICE
# ============================================================

Section "START RUSTDESK SERVICE"

Write-Log "Starting service..."

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
}
catch {
    Write-Log "Start-Service failed: $($_.Exception.Message)" "Red"
}

Start-Sleep -Seconds 5

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Fail "RustDesk service исчезла после запуска."
}

Write-Log "Service status: $($service.Status)"

# ============================================================
# PASSWORD
# ============================================================

Section "SET PERMANENT PASSWORD"

if ($service.Status -eq "Running") {

    Write-Log "RustDesk service is running."

    Write-Log "Setting password..."

    try {

        & $Exe --password $Password 2>&1 |
            ForEach-Object {
                Write-Log "$_"
            }

        Write-Log "Password command exit code: $LASTEXITCODE"
    }
    catch {

        Write-Log "Password command exception: $($_.Exception.Message)" "Yellow"
    }

}
else {

    Write-Log "Service is NOT running." "Red"
    Write-Log "Password was NOT applied because RustDesk service failed to start." "Red"
}

# ============================================================
# REWRITE CONFIG AFTER PASSWORD
# ============================================================

Section "RESTORE CONFIG AFTER PASSWORD"

# Password operation can cause RustDesk to touch configuration.
# Re-write the network configuration while RustDesk is stopped.

Write-Log "Stopping service before final config..."

Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

Get-Process -Name RustDesk -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3

New-Item `
    -ItemType Directory `
    -Path $ServiceConfigDir `
    -Force |
    Out-Null

Set-Content `
    -LiteralPath $ServiceConfig `
    -Value $config `
    -Encoding UTF8 `
    -Force

Write-Log "Final RustDesk2.toml written." "Green"

# ============================================================
# FINAL START
# ============================================================

Section "FINAL SERVICE START"

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
}
catch {
    Write-Log "FINAL START FAILED: $($_.Exception.Message)" "Red"
}

Start-Sleep -Seconds 7

# ============================================================
# FINAL RESULT
# ============================================================

Section "FINAL RESULT"

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Fail "RustDesk service отсутствует."
}

Write-Host ""
Write-Host "SERVICE:" -ForegroundColor Cyan

$service |
    Format-List Name,Status,StartType

Write-Host ""
Write-Host "SERVICE CONFIG:" -ForegroundColor Cyan

& sc.exe qc $ServiceName

Write-Host ""
Write-Host "SERVICE STATE:" -ForegroundColor Cyan

& sc.exe queryex $ServiceName

Write-Host ""
Write-Host "CONFIG:" -ForegroundColor Cyan

if (Test-Path -LiteralPath $ServiceConfig) {
    Get-Content $ServiceConfig -Raw
}
else {
    Write-Host "CONFIG NOT FOUND" -ForegroundColor Red
}

# ============================================================
# LOG
# ============================================================

$finalServiceLog =
    "$ServiceProfileRoot\log\service\rustdesk_rCURRENT.log"

if (Test-Path -LiteralPath $finalServiceLog) {

    Write-Host ""
    Write-Host "SERVICE LOG:" -ForegroundColor Cyan

    Get-Content $finalServiceLog -Tail 50
}

# ============================================================
# SUCCESS / FAILURE
# ============================================================

if ($service.Status -eq "Running") {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "             RUSTDESK INSTALLATION OK" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green

    Write-Log "INSTALLATION SUCCESS." "Green"

    exit 0
}
else {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "          RUSTDESK SERVICE FAILED TO START" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red

    Write-Log "INSTALLATION FAILED: service is not running." "Red"

    exit 1
}