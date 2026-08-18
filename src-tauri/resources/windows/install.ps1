param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter()]
    [string]$PasswordFile,

    # Эти параметры используются только при повторном запуске после UAC.
    [Parameter()]
    [string]$RealUserName,

    [Parameter()]
    [string]$RealUserProfile
)

$ErrorActionPreference = "Stop"

# ============================================================
# SETTINGS
# ============================================================

$ScriptDir = $PSScriptRoot

$ConfigSource = Join-Path $ScriptDir "RustDesk2.toml"

$ServiceName = "RustDesk"

$ProgramFilesRustDesk = Join-Path ${env:ProgramFiles} "RustDesk"
$RustDeskExe = Join-Path $ProgramFilesRustDesk "RustDesk.exe"

$UserConfigDir = $null
$UserConfig = $null
$UserPasswordConfig = $null

$SystemConfigDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
$SystemConfig = Join-Path $SystemConfigDir "RustDesk2.toml"
$SystemPasswordConfig = Join-Path $SystemConfigDir "RustDesk.toml"


# ============================================================
# ORIGINAL USER
# ============================================================

# Важно:
# После UAC $env:USERNAME уже может быть Administrator.
# Поэтому сохраняем пользователя ДО elevation.

if ([string]::IsNullOrWhiteSpace($RealUserName)) {

    $RealUserName = $env:USERNAME
}

if ([string]::IsNullOrWhiteSpace($RealUserProfile)) {

    $RealUserProfile = $env:USERPROFILE
}


# ============================================================
# PASSWORD FROM TEMP FILE
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($PasswordFile)) {

    if (-not (Test-Path -LiteralPath $PasswordFile)) {

        Write-Host ""
        Write-Host "ERROR: Password file not found." -ForegroundColor Red
        Write-Host ""

        exit 1
    }

    $RustDeskPassword = (
        Get-Content `
            -LiteralPath $PasswordFile `
            -Raw `
            -Encoding UTF8
    ).Trim()

    Remove-Item `
        -LiteralPath $PasswordFile `
        -Force `
        -ErrorAction SilentlyContinue
}


# ============================================================
# PASSWORD
# ============================================================

if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    $bytes = New-Object byte[] 12

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $RustDeskPassword = (
        [Convert]::ToBase64String($bytes) `
            -replace '[^a-zA-Z0-9]', ''
    ).Substring(0, 16)

    $PasswordGenerated = $true
}
else {

    $PasswordGenerated = $false
}


# ============================================================
# ADMIN CHECK
# ============================================================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object Security.Principal.WindowsPrincipal($identity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)


# ============================================================
# UAC ELEVATION
# ============================================================

if (-not $isAdmin) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "RustDesk installation requires Administrator privileges."
    Write-Host "Requesting UAC elevation..."
    Write-Host "============================================================"
    Write-Host ""

    $TempPasswordFile = ""

    # --------------------------------------------------------
    # Password передаём через временный файл.
    # Не помещаем пароль в command line.
    # --------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

        $TempPasswordFile = Join-Path `
            $env:TEMP `
            "rustdesk-password-$([Guid]::NewGuid().ToString('N')).txt"

        Set-Content `
            -LiteralPath $TempPasswordFile `
            -Value $RustDeskPassword `
            -Encoding UTF8
    }

    try {

        $argumentList = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
            "-RealUserName"
            "`"$RealUserName`""
            "-RealUserProfile"
            "`"$RealUserProfile`""
        )

        if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile)) {

            $argumentList += @(
                "-PasswordFile"
                "`"$TempPasswordFile`""
            )
        }

        $elevatedProcess = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $argumentList `
            -WorkingDirectory $ScriptDir `
            -PassThru

        # Важно:
        # ждём именно elevated script, чтобы Tauri получил завершение.
        $elevatedProcess.WaitForExit()

        $exitCode = $elevatedProcess.ExitCode
    }
    catch {

        Write-Host ""
        Write-Host "ERROR: Failed to start elevated PowerShell." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""

        exit 1
    }
    finally {

        if (
            -not [string]::IsNullOrWhiteSpace($TempPasswordFile) -and
            (Test-Path -LiteralPath $TempPasswordFile)
        ) {

            Remove-Item `
                -LiteralPath $TempPasswordFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    exit $exitCode
}


# ============================================================
# CONFIG PATHS
# ============================================================

$UserConfigDir = Join-Path `
    $RealUserProfile `
    "AppData\Roaming\RustDesk\config"

$UserConfig = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

$UserPasswordConfig = Join-Path `
    $UserConfigDir `
    "RustDesk.toml"


# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "          RUSTDESK WINDOWS LOCAL INSTALL"
Write-Host "                 CONFIG + PASSWORD"
Write-Host "============================================================"
Write-Host ""

Write-Host "Script directory:"
Write-Host "  $ScriptDir"

Write-Host ""
Write-Host "Real user:"
Write-Host "  $RealUserName"

Write-Host ""
Write-Host "Real user profile:"
Write-Host "  $RealUserProfile"

Write-Host ""
Write-Host "Config source:"
Write-Host "  $ConfigSource"

Write-Host ""
Write-Host "RustDesk executable:"
Write-Host "  $RustDeskExe"

Write-Host ""
Write-Host "User RustDesk2.toml:"
Write-Host "  $UserConfig"

Write-Host ""
Write-Host "System RustDesk2.toml:"
Write-Host "  $SystemConfig"

Write-Host ""


# ============================================================
# FIND LOCAL EXE BY ARCHITECTURE
# ============================================================

Write-Host "Detecting Windows architecture..."

$Architecture = $env:PROCESSOR_ARCHITECTURE

if (
    $Architecture -eq "ARM64" -or
    $env:PROCESSOR_ARCHITEW6432 -eq "ARM64"
) {

    $ExePatterns = @(
        "*arm64*.exe",
        "*aarch64*.exe"
    )

    Write-Host "Architecture: ARM64"
}
else {

    $ExePatterns = @(
        "*x86_64*.exe",
        "*x64*.exe"
    )

    Write-Host "Architecture: x64"
}


# ============================================================
# FIND RUSTDESK EXE
# ============================================================

$InstallerExe = $null

foreach ($pattern in $ExePatterns) {

    $candidate = Get-ChildItem `
        -Path $ScriptDir `
        -Filter $pattern `
        -File `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -ne $candidate) {

        $InstallerExe = $candidate.FullName
        break
    }
}


# Fallback:
# если рядом лежит только один EXE.

if ($null -eq $InstallerExe) {

    $allExe = @(
        Get-ChildItem `
            -Path $ScriptDir `
            -Filter "*.exe" `
            -File `
            -ErrorAction SilentlyContinue
    )

    if ($allExe.Count -eq 1) {

        $InstallerExe = $allExe[0].FullName
    }
}


if ([string]::IsNullOrWhiteSpace($InstallerExe)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk installer EXE was not found." -ForegroundColor Red
    Write-Host ""

    Write-Host "Expected files for architecture:"
    foreach ($pattern in $ExePatterns) {
        Write-Host "  $ScriptDir\$pattern"
    }

    Write-Host ""
    Write-Host "Available EXE files:"

    Get-ChildItem `
        -Path $ScriptDir `
        -Filter "*.exe" `
        -File `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "  $($_.Name)"
        }

    exit 1
}


Write-Host ""
Write-Host "RustDesk installer:"
Write-Host "  $InstallerExe"


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
# PASSWORD INFO
# ============================================================

Write-Host ""
Write-Host "Password:"

if ($PasswordGenerated) {
    Write-Host "  $RustDeskPassword"
    Write-Host "  (randomly generated)"
}
else {
    Write-Host "  $RustDeskPassword"
    Write-Host "  (provided by user)"
}

Write-Host ""


# ============================================================
# 1. STOP EXISTING RUSTDESK
# ============================================================

Write-Host "============================================================"
Write-Host "[1/8] STOPPING EXISTING RUSTDESK"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# Stop service if exists
# ------------------------------------------------------------

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Host "Current service status: $($service.Status)"

    if ($service.Status -ne "Stopped") {

        Write-Host "Stopping RustDesk service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -lt 20; $i++) {

        Start-Sleep -Milliseconds 500

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (
            $null -eq $service -or
            $service.Status -eq "Stopped"
        ) {
            break
        }
    }

    Write-Host "RustDesk service stopped."
}
else {

    Write-Host "RustDesk service not found."
}


# ------------------------------------------------------------
# Stop GUI
# ------------------------------------------------------------

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2


for ($i = 0; $i -lt 15; $i++) {

    $process = Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if ($null -eq $process) {
        break
    }

    Start-Sleep -Milliseconds 500
}


$process = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -ne $process) {

    Write-Host ""
    Write-Host "ERROR: RustDesk GUI could not be stopped." -ForegroundColor Red
    Write-Host ""

    exit 1
}

Write-Host "RustDesk GUI stopped."


# ============================================================
# 2. INSTALL RUSTDESK FROM LOCAL EXE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[2/8] INSTALLING RUSTDESK FROM LOCAL EXE"
Write-Host "============================================================"
Write-Host ""

Write-Host "Installer:"
Write-Host "  $InstallerExe"

Write-Host ""
Write-Host "Starting silent RustDesk installation..."


# ------------------------------------------------------------
# Start installer and WAIT for it.
#
# Это важный момент:
# раньше Start-Process запускался без -Wait, после чего
# скрипт мог перейти дальше до окончания установки.
# ------------------------------------------------------------

$installerProcess = Start-Process `
    -FilePath $InstallerExe `
    -ArgumentList "--silent-install" `
    -Wait `
    -PassThru `
    -WindowStyle Hidden


Write-Host ""
Write-Host "Installer exit code:"
Write-Host "  $($installerProcess.ExitCode)"


# ------------------------------------------------------------
# Installer иногда возвращает код, отличный от 0,
# даже если установка успешно завершена.
# Поэтому главным критерием является наличие RustDesk.exe.
# ------------------------------------------------------------

Write-Host ""
Write-Host "Waiting for RustDesk installation to become available..."


$installed = $false

for ($i = 0; $i -lt 30; $i++) {

    if (Test-Path -LiteralPath $RustDeskExe) {

        $installed = $true
        break
    }

    Start-Sleep -Seconds 1
}


if (-not $installed) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe was not installed." -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $RustDeskExe"

    exit 1
}


Write-Host "RustDesk.exe installed."


# ============================================================
# 3. VERIFY INSTALLATION
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[3/8] VERIFYING RUSTDESK INSTALLATION"
Write-Host "============================================================"
Write-Host ""


if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe not found." -ForegroundColor Red
    Write-Host $RustDeskExe
    Write-Host ""

    exit 1
}


Write-Host "RustDesk executable verified:"
Write-Host "  $RustDeskExe"


# ============================================================
# 4. INSTALL / VERIFY SERVICE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[4/8] INSTALLING / VERIFYING RUSTDESK SERVICE"
Write-Host "============================================================"
Write-Host ""


$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


if ($null -eq $service) {

    Write-Host "RustDesk service does not exist."
    Write-Host "Installing service..."

    $serviceInstall = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Host ""
    Write-Host "Service installer exit code:"
    Write-Host "  $($serviceInstall.ExitCode)"

    Start-Sleep -Seconds 3
}


# ------------------------------------------------------------
# Wait for service registration
# ------------------------------------------------------------

$service = $null

for ($i = 0; $i -lt 20; $i++) {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {
        break
    }

    Start-Sleep -Seconds 1
}


if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service was not created." -ForegroundColor Red
    Write-Host ""

    exit 1
}


Write-Host "RustDesk service exists."


# ============================================================
# 5. INSTALL CONFIGURATION
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[5/8] INSTALLING RUSTDESK2.TOML"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# USER DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $UserConfigDir)) {

    New-Item `
        -Path $UserConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# SYSTEM DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SystemConfigDir)) {

    New-Item `
        -Path $SystemConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# USER BACKUP
# ------------------------------------------------------------

if (Test-Path -LiteralPath $UserConfig) {

    $UserBackup = "$UserConfig.backup"

    Copy-Item `
        -LiteralPath $UserConfig `
        -Destination $UserBackup `
        -Force

    Write-Host "User backup:"
    Write-Host "  $UserBackup"
}


# ------------------------------------------------------------
# SYSTEM BACKUP
# ------------------------------------------------------------

if (Test-Path -LiteralPath $SystemConfig) {

    $SystemBackup = "$SystemConfig.backup"

    Copy-Item `
        -LiteralPath $SystemConfig `
        -Destination $SystemBackup `
        -Force

    Write-Host "System backup:"
    Write-Host "  $SystemBackup"
}


# ------------------------------------------------------------
# USER CONFIG
# ------------------------------------------------------------

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $UserConfig `
    -Force


Write-Host ""
Write-Host "User RustDesk2.toml installed:"
Write-Host "  $UserConfig"


# ------------------------------------------------------------
# SYSTEM CONFIG
# ------------------------------------------------------------

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $SystemConfig `
    -Force


Write-Host ""
Write-Host "System RustDesk2.toml installed:"
Write-Host "  $SystemConfig"


# ------------------------------------------------------------
# VERIFY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $UserConfig)) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk2.toml was not installed." -ForegroundColor Red

    exit 1
}


if (-not (Test-Path -LiteralPath $SystemConfig)) {

    Write-Host ""
    Write-Host "ERROR: System RustDesk2.toml was not installed." -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "RustDesk2.toml installed successfully."


# ============================================================
# 6. START GUI AS REAL USER
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[6/8] STARTING RUSTDESK GUI"
Write-Host "============================================================"
Write-Host ""

Write-Host "Starting RustDesk as:"
Write-Host "  $RealUserName"


# ------------------------------------------------------------
# Для elevated PowerShell обычный Start-Process запускает
# приложение с elevated token.
#
# Нам нужен GUI именно в интерактивной сессии пользователя.
#
# Используем временную Scheduled Task:
# она запускает RustDesk в пользовательской сессии.
# ------------------------------------------------------------

$TaskName = "RustDesk-Temporary-Launch-$([Guid]::NewGuid().ToString('N'))"

$taskAction = New-ScheduledTaskAction `
    -Execute $RustDeskExe

$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $RealUserName `
    -LogonType Interactive `
    -RunLevel Limited

$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries


Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $taskAction `
    -Principal $taskPrincipal `
    -Settings $taskSettings `
    -Force |
    Out-Null


try {

    Start-ScheduledTask `
        -TaskName $TaskName

}
finally {

    # Удаляем задачу позже.
    # Сам RustDesk уже будет работать в пользовательской сессии.
}


Write-Host "Waiting for RustDesk GUI..."


$guiRunning = $false

for ($i = 0; $i -lt 20; $i++) {

    Start-Sleep -Seconds 1

    # Ищем процесс RustDesk именно в пользовательской session.
    $processes = Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    foreach ($p in $processes) {

        try {

            $owner = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" |
                Invoke-CimMethod -MethodName GetOwner `
                -ErrorAction SilentlyContinue)

            if (
                $null -ne $owner -and
                $owner.User -eq $RealUserName
            ) {

                $guiRunning = $true
                break
            }

        }
        catch {
            continue
        }
    }

    if ($guiRunning) {
        break
    }
}


# ------------------------------------------------------------
# Удаляем временную task.
# ------------------------------------------------------------

Unregister-ScheduledTask `
    -TaskName $TaskName `
    -Confirm:$false `
    -ErrorAction SilentlyContinue


if (-not $guiRunning) {

    Write-Host ""
    Write-Host "ERROR: RustDesk GUI did not start for user $RealUserName." -ForegroundColor Red
    Write-Host ""

    exit 1
}


Write-Host "RustDesk GUI is running."


# ============================================================
# 7. WAIT + APPLY PASSWORD + VERIFY
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[7/8] APPLYING PASSWORD"
Write-Host "============================================================"
Write-Host ""

Write-Host "Waiting 5 seconds for RustDesk initialization..."

Start-Sleep -Seconds 5


Write-Host ""
Write-Host "Executing:"
Write-Host "  RustDesk.exe --password ********"
Write-Host ""


# ------------------------------------------------------------
# Password command выполняем elevated.
#
# GUI уже запущен в правильной пользовательской сессии.
# ------------------------------------------------------------

$passwordProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--password",
        $RustDeskPassword
    ) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden


Write-Host "RustDesk --password exit code:"
Write-Host "  $($passwordProcess.ExitCode)"


if ($passwordProcess.ExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: RustDesk --password failed." -ForegroundColor Red
    Write-Host ""

    exit 1
}


Write-Host ""
Write-Host "Password applied successfully."


# ------------------------------------------------------------
# WAIT FOR USER RustDesk.toml
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking User RustDesk.toml..."


$UserPasswordConfigFound = $false

for ($i = 0; $i -lt 15; $i++) {

    if (Test-Path -LiteralPath $UserPasswordConfig) {

        $file = Get-Item `
            -LiteralPath $UserPasswordConfig `
            -ErrorAction SilentlyContinue

        if (
            $null -ne $file -and
            $file.Length -gt 0
        ) {

            $UserPasswordConfigFound = $true
            break
        }
    }

    Start-Sleep -Seconds 1
}


# ------------------------------------------------------------
# USER RustDesk.toml
# ------------------------------------------------------------

if (-not $UserPasswordConfigFound) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk.toml was not created or is empty." -ForegroundColor Red
    Write-Host ""

    Write-Host "Expected:"
    Write-Host "  $UserPasswordConfig"

    exit 1
}


$userPasswordFile = Get-Item `
    -LiteralPath $UserPasswordConfig


Write-Host ""
Write-Host "User RustDesk.toml verified:"
Write-Host "  $UserPasswordConfig"

Write-Host "Size:"
Write-Host "  $($userPasswordFile.Length) bytes"


# ------------------------------------------------------------
# SYSTEM RustDesk.toml
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking System RustDesk.toml..."


$SystemPasswordConfigFound = $false

for ($i = 0; $i -lt 15; $i++) {

    if (Test-Path -LiteralPath $SystemPasswordConfig) {

        $file = Get-Item `
            -LiteralPath $SystemPasswordConfig `
            -ErrorAction SilentlyContinue

        if (
            $null -ne $file -and
            $file.Length -gt 0
        ) {

            $SystemPasswordConfigFound = $true
            break
        }
    }

    Start-Sleep -Seconds 1
}


if ($SystemPasswordConfigFound) {

    $systemPasswordFile = Get-Item `
        -LiteralPath $SystemPasswordConfig

    Write-Host ""
    Write-Host "System RustDesk.toml verified:"
    Write-Host "  $SystemPasswordConfig"

    Write-Host "Size:"
    Write-Host "  $($systemPasswordFile.Length) bytes"
}
else {

    Write-Host ""
    Write-Host "WARNING: System RustDesk.toml was not found." -ForegroundColor Yellow
}


# ============================================================
# 8. START SERVICE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[8/8] STARTING RUSTDESK SERVICE"
Write-Host "============================================================"
Write-Host ""


$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service does not exist." -ForegroundColor Red
    Write-Host ""

    exit 1
}


if ($service.Status -ne "Running") {

    Write-Host "Starting RustDesk service..."

    Start-Service `
        -Name $ServiceName
}


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
    Write-Host ""

    Get-Service `
        -Name $ServiceName |
        Format-List Name,Status,StartType

    exit 1
}


Write-Host "RustDesk service is RUNNING."


# ============================================================
# FINAL GUI CHECK
# ============================================================

$finalGui = $false

$processes = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue


foreach ($p in $processes) {

    try {

        $owner = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" |
            Invoke-CimMethod -MethodName GetOwner `
            -ErrorAction SilentlyContinue)

        if (
            $null -ne $owner -and
            $owner.User -eq $RealUserName
        ) {

            $finalGui = $true
            break
        }

    }
    catch {
        continue
    }
}


# ============================================================
# FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                         DONE"
Write-Host "============================================================"
Write-Host ""

Write-Host "RustDesk:"
Write-Host "  $RustDeskExe"

Write-Host ""
Write-Host "Installer:"
Write-Host "  $InstallerExe"

Write-Host ""
Write-Host "Architecture:"
Write-Host "  $Architecture"

Write-Host ""
Write-Host "Real user:"
Write-Host "  $RealUserName"

Write-Host ""
Write-Host "User RustDesk2.toml:"
Write-Host "  $UserConfig"

Write-Host ""
Write-Host "System RustDesk2.toml:"
Write-Host "  $SystemConfig"

Write-Host ""
Write-Host "User RustDesk.toml:"
Write-Host "  $UserPasswordConfig"

Write-Host ""
Write-Host "System RustDesk.toml:"
Write-Host "  $SystemPasswordConfig"

Write-Host ""
Write-Host "Service:"

Get-Service `
    -Name $ServiceName |
    Format-List Name,Status,StartType

Write-Host ""
Write-Host "GUI user:"
Write-Host "  $RealUserName"

if ($finalGui) {

    Write-Host "GUI:"
    Write-Host "  RUNNING"
}
else {

    Write-Host "GUI:"
    Write-Host "  WARNING: NOT DETECTED" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Password:"
Write-Host "  $RustDeskPassword"

if ($PasswordGenerated) {
    Write-Host "  (randomly generated)"
}
else {
    Write-Host "  (provided by user)"
}

Write-Host ""
Write-Host "============================================================"
Write-Host ""