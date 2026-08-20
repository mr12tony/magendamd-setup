$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG
# ============================================================

$TargetVersion = "1.4.9"

# СЮДА вставишь Export Server Config из RustDesk
$RustDeskConfig = "=0nI9MWTLBXTuZjQ6FDUttmN1V3Q3U0QKhmSBBla2EWQ5gFUN50ZrV2byATaMtiI6ISeltmIsIiI6ISawFmIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI5FGblJnIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI0N3boJye"

# Только для тестирования.
$RustDeskPassword = "TestPassword123!"

$ServiceName = "Rustdesk"

$X64Installer = Join-Path $PSScriptRoot "rustdesk-1.4.9-x86_64.exe"
$ArmInstaller = Join-Path $PSScriptRoot "rustdesk-1.4.9-aarch64.exe"


# ============================================================
# LOG
# ============================================================

function Log {
    param([string]$Message)

    Write-Host "[RustDesk deployment] $Message"
}

function Fail {
    param([string]$Message)

    Write-Error "[RustDesk deployment] $Message"
    exit 1
}


# ============================================================
# ADMIN CHECK
# ============================================================

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-Administrator)) {
    Fail "Administrator privileges are required."
}


# ============================================================
# FIND RUSTDESK
# ============================================================

function Find-RustDeskExe {

    $paths = @(
        "$env:ProgramFiles\RustDesk\rustdesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
    )

    foreach ($path in $paths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    # Дополнительная попытка через uninstall registry.

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($registryPath in $registryPaths) {

        $entry = Get-ItemProperty `
            $registryPath `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -like "RustDesk*"
            } |
            Select-Object -First 1

        if ($entry -and $entry.InstallLocation) {

            $exe = Join-Path `
                $entry.InstallLocation `
                "rustdesk.exe"

            if (Test-Path $exe) {
                return $exe
            }
        }
    }

    return $null
}


# ============================================================
# VERSION
# ============================================================

function Get-RustDeskVersion {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    # Сначала используем сам RustDesk.

    try {
        $result = & $Exe --version 2>&1

        $text = ($result -join " ").Trim()

        if ($text -match '(\d+\.\d+\.\d+)') {
            return $Matches[1]
        }
    }
    catch {}

    # Fallback: Windows FileVersionInfo.

    try {
        $version = (
            [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)
        ).FileVersion

        if ($version -match '(\d+\.\d+\.\d+)') {
            return $Matches[1]
        }
    }
    catch {}

    return $null
}


# ============================================================
# ARCHITECTURE
# ============================================================

function Get-RustDeskInstaller {

    # ARM64 Windows.
    if (
        $env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or
        $env:PROCESSOR_ARCHITEW6432 -eq "ARM64"
    ) {
        Log "Windows architecture: ARM64"

        if (-not (Test-Path $ArmInstaller)) {
            Fail "ARM64 RustDesk installer not found: $ArmInstaller"
        }

        return $ArmInstaller
    }

    # AMD64/x64 Windows.
    if (
        $env:PROCESSOR_ARCHITECTURE -eq "AMD64" -or
        $env:PROCESSOR_ARCHITEW6432 -eq "AMD64"
    ) {
        Log "Windows architecture: x86_64"

        if (-not (Test-Path $X64Installer)) {
            Fail "x86_64 RustDesk installer not found: $X64Installer"
        }

        return $X64Installer
    }

    Fail "Unsupported Windows architecture."
}


# ============================================================
# SERVICE PID
# ============================================================

function Get-RustDeskServicePid {

    $service = Get-CimInstance Win32_Service `
        -Filter "Name='$ServiceName'" `
        -ErrorAction SilentlyContinue

    if (
        $service -and
        $service.ProcessId -and
        $service.ProcessId -ne 0
    ) {
        return [int]$service.ProcessId
    }

    return $null
}


# ============================================================
# CLOSE GUI ONLY
# ============================================================

function Stop-RustDeskGui {

    Log "Checking RustDesk GUI..."

    $servicePid = Get-RustDeskServicePid

    $processes = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue
    )

    $guiProcesses = @(
        $processes |
        Where-Object {
            -not $servicePid -or $_.Id -ne $servicePid
        }
    )

    if ($guiProcesses.Count -eq 0) {
        Log "RustDesk GUI is not running."
        return
    }

    foreach ($process in $guiProcesses) {

        Log "Closing RustDesk GUI PID $($process.Id)..."

        try {
            if ($process.MainWindowHandle -ne 0) {
                $null = $process.CloseMainWindow()

                try {
                    $process.WaitForExit(5000)
                }
                catch {}
            }

            if (-not $process.HasExited) {

                Log "GUI PID $($process.Id) did not exit gracefully."

                Stop-Process `
                    -Id $process.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {
            Log "Failed to close PID $($process.Id): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 1

    Log "RustDesk GUI closed."

    # Service специально не останавливаем.
}


# ============================================================
# INSTALL / UPDATE
# ============================================================

function Install-Or-Update-RustDesk {

    $exe = Find-RustDeskExe

    if ($exe) {

        $installedVersion = Get-RustDeskVersion -Exe $exe

        Log "Installed RustDesk: $exe"
        Log "Installed version: $installedVersion"
        Log "Required version:  $TargetVersion"

        if ($installedVersion -eq $TargetVersion) {

            Log "RustDesk $TargetVersion is already installed."
            return $exe
        }

        Log "RustDesk version mismatch."
        Log "Updating to $TargetVersion..."

        # Перед update закрываем GUI,
        # Service специально не трогаем сами.
        Stop-RustDeskGui
    }
    else {
        Log "RustDesk is not installed."
    }

    $installer = Get-RustDeskInstaller

    Log "Using installer:"
    Log $installer

    $process = Start-Process `
        -FilePath $installer `
        -ArgumentList "--silent-install" `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        Fail "RustDesk installer exit code: $($process.ExitCode)"
    }

    Log "RustDesk installer completed."

    # Ждём появления установленного EXE.

    $exe = $null

    for ($i = 0; $i -lt 30; $i++) {

        $exe = Find-RustDeskExe

        if ($exe) {
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $exe) {
        Fail "rustdesk.exe was not found after installation."
    }

    $actualVersion = Get-RustDeskVersion -Exe $exe

    Log "Version after installation: $actualVersion"

    if ($actualVersion -ne $TargetVersion) {
        Fail "Expected RustDesk $TargetVersion but found $actualVersion."
    }

    return $exe
}


# ============================================================
# ENSURE SERVICE
# ============================================================

function Ensure-RustDeskService {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {

        Log "RustDesk Service not found."
        Log "Installing service..."

        $process = Start-Process `
            -FilePath $Exe `
            -ArgumentList "--install-service" `
            -Wait `
            -PassThru

        if ($process.ExitCode -ne 0) {
            Fail "RustDesk --install-service failed."
        }

        Start-Sleep -Seconds 2
    }

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {
        Fail "RustDesk Service was not created."
    }

    if ($service.Status -ne "Running") {

        Log "Starting RustDesk Service..."

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop
    }

    for ($i = 0; $i -lt 30; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($service.Status -eq "Running") {

            Log "RustDesk Service is RUNNING."

            # Даём IPC и конфигурации подняться.
            Start-Sleep -Seconds 3

            return
        }

        Start-Sleep -Seconds 1
    }

    Fail "RustDesk Service did not reach RUNNING state."
}


# ============================================================
# APPLY CONFIG
# ============================================================

function Apply-RustDeskConfig {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    if (
        [string]::IsNullOrWhiteSpace($RustDeskConfig) -or
        $RustDeskConfig -eq "YOUR_EXPORTED_CONFIG"
    ) {
        Fail "Set RustDeskConfig before building installer."
    }

    Log "Applying RustDesk self-hosted config..."

    & $Exe --config $RustDeskConfig

    if ($LASTEXITCODE -ne 0) {
        Fail "RustDesk --config failed: $LASTEXITCODE"
    }

    Start-Sleep -Seconds 2
}


# ============================================================
# APPLY PASSWORD
# ============================================================

function Apply-RustDeskPassword {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    Log "Applying RustDesk permanent password..."

    & $Exe --password $RustDeskPassword

    if ($LASTEXITCODE -ne 0) {
        Fail "RustDesk --password failed: $LASTEXITCODE"
    }

    Start-Sleep -Seconds 2
}


# ============================================================
# READ OPTION
# ============================================================

function Get-RustDeskOption {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string]$Option
    )

    try {

        $value = & $Exe --option $Option 2>&1

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        return ($value -join "").Trim()
    }
    catch {
        return $null
    }
}


# ============================================================
# FINAL VERIFY
# ============================================================

function Verify-RustDesk {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    Log "Final verification..."

    $version = Get-RustDeskVersion -Exe $Exe

    if ($version -ne $TargetVersion) {
        Fail "Version verification failed: $version"
    }

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {
        Fail "RustDesk Service disappeared."
    }

    if ($service.Status -ne "Running") {
        Fail "RustDesk Service is not running."
    }

    $id = (& $Exe --get-id 2>&1 | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($id)) {
        Fail "RustDesk returned empty ID."
    }

    Log "RustDesk ID: $id"

    # Диагностический read-back.
    # Потом можем сделать строгие Expected/Actual сравнения.

    $idServer = Get-RustDeskOption `
        -Exe $Exe `
        -Option "custom-rendezvous-server"

    $relay = Get-RustDeskOption `
        -Exe $Exe `
        -Option "relay-server"

    $key = Get-RustDeskOption `
        -Exe $Exe `
        -Option "key"

    Log "ID Server: $idServer"
    Log "Relay:     $relay"
    Log "Key:       $key"

    Log "Verification completed."
}


# ============================================================
# MAIN
# ============================================================

Log "============================================"
Log "RustDesk deployment started"
Log "============================================"

# 1. Найти / установить / обновить до 1.4.9
$RustDeskExe = Install-Or-Update-RustDesk

# 2. Service существует и Running
Ensure-RustDeskService -Exe $RustDeskExe

# 3. Перед конфигурацией закрываем только GUI.
Stop-RustDeskGui

# 4. Service при этом НЕ останавливаем.
$service = Get-Service -Name $ServiceName

if ($service.Status -ne "Running") {
    Fail "RustDesk Service stopped unexpectedly."
}

# 5. Config
Apply-RustDeskConfig -Exe $RustDeskExe

# 6. Password
Apply-RustDeskPassword -Exe $RustDeskExe

# 7. Final verification
Verify-RustDesk -Exe $RustDeskExe

Log "============================================"
Log "RustDesk deployment SUCCESS"
Log "============================================"

exit 0