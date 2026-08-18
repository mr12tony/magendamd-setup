param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter(Position = 1)]
    [string]$RustDeskConfig,

    [Parameter()]
    [string]$ArgsFile
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptPath = $PSCommandPath
$ScriptDir  = Split-Path -Parent $ScriptPath

$RustDeskX64 = Join-Path $ScriptDir "rustdesk-x86_64.exe"
$RustDeskArm = Join-Path $ScriptDir "rustdesk-aarch64.exe"

$RustDeskExe = Join-Path ${env:ProgramFiles} "RustDesk\rustdesk.exe"

$ServiceName = "Rustdesk"

# Лог пишем в TEMP
$LogFile = Join-Path $env:TEMP "rustdesk-install.log"

# ============================================================
# LOG
# ============================================================

function Write-Log {
    param(
        [string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

    try {
        Add-Content `
            -LiteralPath $LogFile `
            -Value $line `
            -Encoding UTF8 `
            -ErrorAction SilentlyContinue
    }
    catch {
    }

    Write-Output $line
}

function Write-Section {
    param(
        [string]$Name
    )

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "[$Name]"
    Write-Log "============================================================"
}

# ============================================================
# ADMIN CHECK
# ============================================================

function Test-Administrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ============================================================
# START
# ============================================================

Write-Section "START"

Write-Log "RustDesk installer started."
Write-Log "Script: $ScriptPath"
Write-Log "ScriptDir: $ScriptDir"
Write-Log "LogFile: $LogFile"
Write-Log "User: $env:USERNAME"
Write-Log "Is administrator: $(Test-Administrator)"

# ============================================================
# ELEVATION
# ============================================================

if (-not (Test-Administrator)) {

    Write-Section "ELEVATION"

    Write-Log "Current PowerShell is NOT elevated."
    Write-Log "Requesting Administrator privileges through UAC..."

    $TempArgsFile = Join-Path `
        $env:TEMP `
        "rustdesk-install-$([Guid]::NewGuid().ToString('N')).json"

    try {

        # ----------------------------------------------------
        # SAVE PASSWORD + CONFIG
        # ----------------------------------------------------

        $data = @{
            Password = $RustDeskPassword
            Config   = $RustDeskConfig
        }

        $data |
            ConvertTo-Json -Compress |
            Set-Content `
                -LiteralPath $TempArgsFile `
                -Encoding UTF8

        Write-Log "Temporary arguments file created."
        Write-Log "ArgsFile: $TempArgsFile"

        # ----------------------------------------------------
        # START ELEVATED POWERSHELL
        # ----------------------------------------------------

        $psArguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$ScriptPath`""
            "-ArgsFile"
            "`"$TempArgsFile`""
        )

        Write-Log "Starting elevated PowerShell..."

        $process = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $psArguments `
            -PassThru `
            -WorkingDirectory $ScriptDir

        if ($null -eq $process) {

            Write-Log "ERROR: Failed to start elevated PowerShell."

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue

            exit 1
        }

        Write-Log "Elevated PowerShell started."
        Write-Log "Elevated PID: $($process.Id)"

        # ----------------------------------------------------
        # WAIT
        # ----------------------------------------------------

        Write-Log "Waiting for elevated PowerShell..."

        $process.WaitForExit()

        $exitCode = $process.ExitCode

        Write-Log "Elevated PowerShell finished."
        Write-Log "Elevated process exit code: $exitCode"

        # ----------------------------------------------------
        # CLEANUP
        # ----------------------------------------------------

        if (Test-Path -LiteralPath $TempArgsFile) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        # ----------------------------------------------------
        # RETURN RESULT
        # ----------------------------------------------------

        if ($exitCode -eq 0) {

            Write-Log "Elevated installation completed successfully."

            exit 0
        }

        Write-Log "ERROR: Elevated installation failed."

        exit $exitCode
    }
    catch {

        Write-Log "ERROR during elevation:"
        Write-Log $_.Exception.Message

        if ($null -ne $TempArgsFile) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        exit 1
    }
}

# ============================================================
# ELEVATED INSTANCE
# ============================================================

Write-Section "ELEVATED INSTANCE"

Write-Log "Running as Administrator."

# ============================================================
# LOAD ARGUMENTS
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($ArgsFile)) {

    Write-Log "Loading arguments from temporary file:"
    Write-Log $ArgsFile

    if (-not (Test-Path -LiteralPath $ArgsFile)) {

        Write-Log "ERROR: Arguments file does not exist."

        exit 1
    }

    try {

        $json = Get-Content `
            -LiteralPath $ArgsFile `
            -Raw `
            -Encoding UTF8

        $data = $json | ConvertFrom-Json

        if ($null -eq $data) {

            Write-Log "ERROR: Arguments JSON is empty."

            exit 1
        }

        $RustDeskPassword = [string]$data.Password
        $RustDeskConfig   = [string]$data.Config

        Write-Log "Password loaded: YES"
        Write-Log "Config loaded: YES"
        Write-Log "Config length: $($RustDeskConfig.Length)"

        Remove-Item `
            -LiteralPath $ArgsFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {

        Write-Log "ERROR loading arguments:"
        Write-Log $_.Exception.Message

        exit 1
    }
}

# ============================================================
# VERIFY ADMIN
# ============================================================

if (-not (Test-Administrator)) {

    Write-Log "ERROR: Elevated instance is not Administrator."

    exit 1
}

Write-Log "Administrator privileges confirmed."

# ============================================================
# ARCHITECTURE
# ============================================================

Write-Section "ARCHITECTURE"

$arch1 = $env:PROCESSOR_ARCHITECTURE
$arch2 = $env:PROCESSOR_ARCHITEW6432

Write-Log "PROCESSOR_ARCHITECTURE: $arch1"
Write-Log "PROCESSOR_ARCHITEW6432: $arch2"

$selectedInstaller = $null

if (
    $arch1 -eq "AMD64" -or
    $arch2 -eq "AMD64"
) {

    Write-Log "Detected architecture: AMD64"

    $selectedInstaller = $RustDeskX64
}
elseif (
    $arch1 -eq "ARM64" -or
    $arch2 -eq "ARM64"
) {

    Write-Log "Detected architecture: ARM64"

    $selectedInstaller = $RustDeskArm
}
else {

    Write-Log "ERROR: Unsupported architecture."

    exit 1
}

Write-Log "Selected installer: $selectedInstaller"

# ============================================================
# CHECK INSTALLER
# ============================================================

if (-not (Test-Path -LiteralPath $selectedInstaller)) {

    Write-Log "ERROR: RustDesk installer not found."

    exit 1
}

$installerFile = Get-Item -LiteralPath $selectedInstaller

Write-Log "Installer exists."
Write-Log "Installer size: $([math]::Round($installerFile.Length / 1MB, 2)) MB"

# ============================================================
# CLEANUP (УДАЛЕНИЕ СТАРОЙ УСТАНОВКИ ИЛИ СЛУЖБЫ)
# ============================================================

Write-Section "CLEANUP"

# 1. Попытка вызвать штатный деинсталлятор, если программа уже была установлена
if (Test-Path -LiteralPath $RustDeskExe) {
    Write-Log "Existing RustDesk installation detected. Running uninstaller..."
    try {
        $uninstallProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList "--uninstall" `
            -PassThru `
            -ErrorAction SilentlyContinue
        
        if ($null -ne $uninstallProcess) {
            $uninstallProcess.WaitForExit(10000)
            Write-Log "Uninstaller executed."
        }
    }
    catch {
        Write-Log "WARNING: Uninstaller failed or timed out."
    }
}

# 2. Остановка всех процессов rustdesk
Write-Log "Stopping RustDesk processes..."

Get-Process `
    -Name "rustdesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

Write-Log "RustDesk processes stopped."

# 3. Остановка и удаление службы Windows
Write-Log "Checking RustDesk service..."

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Log "RustDesk service exists. Current status: $($service.Status)"

    if ($service.Status -eq "Running") {

        Write-Log "Stopping RustDesk service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }

    Write-Log "Deleting RustDesk service..."

    & sc.exe delete $ServiceName 2>&1 |
        ForEach-Object {
            Write-Log "SC DELETE: $_"
        }

    Start-Sleep -Seconds 3
}
else {

    Write-Log "RustDesk service does not exist."
}

# 4. Удаление старых файлов из Program Files
$oldInstallDir = Join-Path ${env:ProgramFiles} "RustDesk"

if (Test-Path -LiteralPath $oldInstallDir) {

    Write-Log "Removing old RustDesk installation files..."

    try {

        Remove-Item `
            -LiteralPath $oldInstallDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Write-Log "Old RustDesk installation files removed."
    }
    catch {

        Write-Log "WARNING: Could not completely remove old installation directory."
        Write-Log $_.Exception.Message
    }

    Start-Sleep -Seconds 2
}

# ============================================================
# INSTALL
# ============================================================

Write-Section "INSTALL"

Write-Log "Starting RustDesk installer WITHOUT -Wait."

try {

    $installerProcess = Start-Process `
        -FilePath $selectedInstaller `
        -ArgumentList "--silent-install" `
        -PassThru

    Write-Log "RustDesk installer process started. PID: $($installerProcess.Id)"
}
catch {

    Write-Log "ERROR starting RustDesk installer:"
    Write-Log $_.Exception.Message

    exit 1
}

# ============================================================
# WAIT FOR INSTALLATION
# ============================================================

Write-Log "Waiting for RustDesk installation to appear..."

$found = $false

for ($i = 0; $i -lt 60; $i++) {

    if (Test-Path -LiteralPath $RustDeskExe) {

        $found = $true

        Write-Log "RustDesk executable detected at: $RustDeskExe"

        break
    }

    Start-Sleep -Seconds 1
}

if (-not $found) {

    Write-Log "ERROR: RustDesk executable was not detected after 60 seconds."

    try {

        if (-not $installerProcess.HasExited) {

            Stop-Process `
                -Id $installerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
    }

    exit 1
}

Write-Log "RustDesk installation detected successfully."
Start-Sleep -Seconds 3

# ============================================================
# VERIFY EXECUTABLE
# ============================================================

Write-Section "VERIFY"

$installedFile = Get-Item -LiteralPath $RustDeskExe

Write-Log "RustDesk executable: $RustDeskExe"
Write-Log "Installed size: $([math]::Round($installedFile.Length / 1MB, 2)) MB"

# ============================================================
# CONFIG (ПРИМЕНЯЕМ КОНФИГ ДО СТАРА СЛУЖБЫ)
# ============================================================

Write-Section "CONFIG"

if (-not [string]::IsNullOrWhiteSpace($RustDeskConfig)) {

    Write-Log "Applying RustDesk configuration..."

    try {

        # 1. Запись конфига через CLI
        $configProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--config",
                $RustDeskConfig
            ) `
            -PassThru `
            -Wait

        Write-Log "RustDesk --config exit code: $($configProcess.ExitCode)"

        # 2. Прямая запись в системный каталог ProgramData (для гарантии подхвата)
        $programDataConfigDir = Join-Path ${env:ProgramData} "RustDesk\config"

        if (-not (Test-Path -LiteralPath $programDataConfigDir)) {
            New-Item -Path $programDataConfigDir -ItemType Directory -Force | Out-Null
        }

        $tomlPath = Join-Path $programDataConfigDir "RustDesk2.toml"
        $tomlContent = "config = '$RustDeskConfig'"
        Set-Content -Path $tomlPath -Value $tomlContent -Encoding UTF8 -Force

        Write-Log "Forced config file created at: $tomlPath"
    }
    catch {

        Write-Log "WARNING: Failed to apply configuration."
        Write-Log $_.Exception.Message
    }
}
else {

    Write-Log "Config is empty. Skipping configuration."
}

# ============================================================
# PASSWORD (УСТАНАВЛИВАЕМ ПАРОЛЬ ДО СТАРТА СЛУЖБЫ)
# ============================================================

Write-Section "PASSWORD"

if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    Write-Log "Applying RustDesk permanent password..."

    try {

        $passwordProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--password",
                $RustDeskPassword
            ) `
            -PassThru `
            -Wait

        Write-Log "RustDesk --password exit code: $($passwordProcess.ExitCode)"
    }
    catch {

        Write-Log "WARNING: Failed to apply password."
        Write-Log $_.Exception.Message
    }
}
else {

    Write-Log "Password is empty. Skipping password."
}

# ============================================================
# SERVICE INSTALL
# ============================================================

Write-Section "SERVICE INSTALL"

Write-Log "Installing RustDesk service..."

try {

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -PassThru

    Write-Log "Service installation process started. PID: $($serviceProcess.Id)"
}
catch {

    Write-Log "ERROR installing RustDesk service:"
    Write-Log $_.Exception.Message

    exit 1
}

# ============================================================
# WAIT FOR SERVICE
# ============================================================

Write-Log "Waiting for RustDesk service..."

$serviceFound = $false

for ($i = 0; $i -lt 30; $i++) {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        $serviceFound = $true

        Write-Log "RustDesk service found."
        Write-Log "Status: $($service.Status)"

        break
    }

    Start-Sleep -Seconds 1
}

try {

    if (-not $serviceProcess.HasExited) {

        Stop-Process `
            -Id $serviceProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
catch {
}

if (-not $serviceFound) {

    Write-Log "ERROR: RustDesk service was not created."

    exit 1
}

# ============================================================
# SERVICE AUTOSTART & START
# ============================================================

Write-Section "SERVICE AUTOSTART & START"

Write-Log "Configuring RustDesk service for automatic startup..."

try {

    Set-Service `
        -Name $ServiceName `
        -StartupType Automatic `
        -ErrorAction Stop

    Write-Log "Service StartupType set to Automatic."
}
catch {

    & sc.exe config $ServiceName start= auto 2>&1 | ForEach-Object { Write-Log "SC CONFIG: $_" }
}

# Запуск / Перезапуск службы, чтобы подхватить настойки из RustDesk2.toml
Write-Log "Starting/Restarting RustDesk service..."

try {

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service.Status -eq "Running") {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
    }
    else {
        Start-Service -Name $ServiceName -ErrorAction Stop
    }

    Write-Log "Service start command issued."
}
catch {

    Write-Log "WARNING: Failed to start/restart service via cmdlet. Trying sc.exe start..."
    & sc.exe start $ServiceName 2>&1 | ForEach-Object { Write-Log "SC START: $_" }
}

# Ожидание подтверждения статуса Running
$running = $false

for ($i = 0; $i -lt 20; $i++) {

    Start-Sleep -Seconds 1

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($null -ne $service -and $service.Status -eq "Running") {
        $running = $true
        break
    }
}

if ($running) {
    Write-Log "RustDesk service is active and running."
}
else {
    Write-Log "WARNING: RustDesk service is not in Running state."
}

# ============================================================
# FINAL
# ============================================================

Write-Section "FINAL"

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Log "ERROR: RustDesk executable is missing."

    exit 1
}

$finalService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $finalService) {

    Write-Log "ERROR: RustDesk service not found."

    exit 1
}

Write-Log "RustDesk executable: OK"
Write-Log "RustDesk service status: $($finalService.Status)"

Write-Log "Installation completed successfully."

Write-Section "END"

exit 0