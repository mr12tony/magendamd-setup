$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG
# ============================================================

$TargetVersion = "1.4.9"

# Export Server Config из RustDesk
$RustDeskConfig = "=0nI9MWTLBXTuZjQ6FDUttmN1V3Q3U0QKhmSBBla2EWQ5gFUN50ZrV2byATaMtiI6ISeltmIsIiI6ISawFmIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI5FGblJnIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI0N3boJye"

# Для первого теста можно оставить фиксированный.
# В production лучше не хранить пароль прямо в скрипте.
$RustDeskPassword = "TestPassword123!"

$ServiceName = "Rustdesk"

$InstallTimeoutSeconds = 90
$ServiceTimeoutSeconds = 45

$X64Installer = Join-Path `
    $PSScriptRoot `
    "rustdesk-1.4.9-x86_64.exe"

$Arm64Installer = Join-Path `
    $PSScriptRoot `
    "rustdesk-1.4.9-aarch64.exe"


# ============================================================
# LOG
# ============================================================

function Log {
    param([string]$Message)

    Write-Host "[RustDesk deployment] $Message"
}


function Fail {
    param([string]$Message)

    Write-Host ""
    Write-Host "[RustDesk deployment] ERROR: $Message" -ForegroundColor Red
    Write-Host ""

    exit 1
}


# ============================================================
# ADMIN
# ============================================================

function Test-Administrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


# ============================================================
# VERSION NORMALIZATION
#
# RustDesk 1.4.9 binary у тебя показывает:
#
#   1.4.9+67
#
# Для deployment сравниваем только:
#
#   1.4.9
# ============================================================

function Normalize-RustDeskVersion {

    param(
        [Parameter(Mandatory = $false)]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    if ($Version -match '(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }

    return $null
}


# ============================================================
# FIND RUSTDESK
# ============================================================

function Find-RustDeskExe {

    $paths = New-Object System.Collections.Generic.List[string]


    # --------------------------------------------------------
    # Особенно важно из 32-bit installer context.
    # --------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) {

        $paths.Add(
            (Join-Path `
                $env:ProgramW6432 `
                "RustDesk\rustdesk.exe")
        )
    }


    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {

        $paths.Add(
            (Join-Path `
                $env:ProgramFiles `
                "RustDesk\rustdesk.exe")
        )
    }


    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {

        $paths.Add(
            (Join-Path `
                ${env:ProgramFiles(x86)} `
                "RustDesk\rustdesk.exe")
        )
    }


    # Fallback
    $paths.Add(
        "C:\Program Files\RustDesk\rustdesk.exe"
    )

    $paths.Add(
        "C:\Program Files (x86)\RustDesk\rustdesk.exe"
    )


    foreach ($path in ($paths | Select-Object -Unique)) {

        if (Test-Path -LiteralPath $path) {

            Log "Found RustDesk executable: $path"

            return $path
        }
    }


    # --------------------------------------------------------
    # Registry fallback
    # --------------------------------------------------------

    $registryRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )


    foreach ($root in $registryRoots) {

        try {

            $entries = @(
                Get-ItemProperty `
                    $root `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like "RustDesk*"
                }
            )


            foreach ($entry in $entries) {

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $entry.InstallLocation
                    )
                ) {

                    $candidate = Join-Path `
                        $entry.InstallLocation `
                        "rustdesk.exe"


                    if (Test-Path -LiteralPath $candidate) {

                        Log "Found RustDesk via registry: $candidate"

                        return $candidate
                    }
                }
            }
        }
        catch {}
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


    if (-not (Test-Path -LiteralPath $Exe)) {
        return $null
    }


    # --------------------------------------------------------
    # ProductVersion
    # --------------------------------------------------------

    try {

        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
            $Exe
        )


        Log "ProductVersion raw: [$($info.ProductVersion)]"
        Log "FileVersion raw:    [$($info.FileVersion)]"


        $version = Normalize-RustDeskVersion `
            $info.ProductVersion


        if ($version) {

            Log "Normalized ProductVersion: [$version]"

            return $version
        }


        $version = Normalize-RustDeskVersion `
            $info.FileVersion


        if ($version) {

            Log "Normalized FileVersion: [$version]"

            return $version
        }
    }
    catch {

        Log "File version check failed: $($_.Exception.Message)"
    }


    # --------------------------------------------------------
    # Registry fallback
    # --------------------------------------------------------

    $registryRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )


    foreach ($root in $registryRoots) {

        try {

            $entry = Get-ItemProperty `
                $root `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like "RustDesk*"
                } |
                Select-Object -First 1


            if ($entry -and $entry.DisplayVersion) {

                Log "Registry DisplayVersion raw: [$($entry.DisplayVersion)]"

                $version = Normalize-RustDeskVersion `
                    $entry.DisplayVersion


                if ($version) {

                    Log "Normalized registry version: [$version]"

                    return $version
                }
            }
        }
        catch {}
    }


    return $null
}


# ============================================================
# ARCH
# ============================================================

function Get-RustDeskInstaller {

    $arch = $env:PROCESSOR_ARCHITECTURE
    $wowArch = $env:PROCESSOR_ARCHITEW6432


    Log "PROCESSOR_ARCHITECTURE = $arch"
    Log "PROCESSOR_ARCHITEW6432 = $wowArch"


    if (
        $arch -eq "ARM64" -or
        $wowArch -eq "ARM64"
    ) {

        Log "Detected architecture: ARM64"

        if (-not (Test-Path -LiteralPath $Arm64Installer)) {

            Fail "ARM64 installer not found: $Arm64Installer"
        }

        return $Arm64Installer
    }


    if (
        $arch -eq "AMD64" -or
        $wowArch -eq "AMD64"
    ) {

        Log "Detected architecture: x86_64"

        if (-not (Test-Path -LiteralPath $X64Installer)) {

            Fail "x86_64 installer not found: $X64Installer"
        }

        return $X64Installer
    }


    Fail "Unsupported architecture: $arch / $wowArch"
}


# ============================================================
# SERVICE PID
# ============================================================

function Get-RustDeskServicePid {

    try {

        $service = Get-CimInstance `
            Win32_Service `
            -Filter "Name='$ServiceName'" `
            -ErrorAction SilentlyContinue


        if (
            $service -and
            $service.ProcessId -and
            $service.ProcessId -ne 0
        ) {

            return [int]$service.ProcessId
        }
    }
    catch {}


    return $null
}


# ============================================================
# STOP GUI ONLY
# ============================================================

function Stop-RustDeskGui {

    Log "Checking RustDesk GUI..."


    $servicePid = Get-RustDeskServicePid


    if ($servicePid) {
        Log "RustDesk Service PID: $servicePid"
    }


    $processes = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue
    )


    $guiProcesses = @(
        $processes |
        Where-Object {

            if (
                $servicePid -and
                $_.Id -eq $servicePid
            ) {
                return $false
            }


            # Не трогаем Session 0 / service-side process.
            return $_.SessionId -ne 0
        }
    )


    if ($guiProcesses.Count -eq 0) {

        Log "RustDesk GUI is not running."

        return
    }


    foreach ($process in $guiProcesses) {

        Log (
            "Closing RustDesk GUI: " +
            "PID=$($process.Id), Session=$($process.SessionId)"
        )


        # Graceful close.
        try {

            if ($process.MainWindowHandle -ne 0) {

                $null = $process.CloseMainWindow()

                try {
                    $process.WaitForExit(5000)
                }
                catch {}
            }
        }
        catch {}


        # Проверяем, остался ли процесс.
        $remaining = Get-Process `
            -Id $process.Id `
            -ErrorAction SilentlyContinue


        if ($remaining) {

            Log "GUI PID $($process.Id) still running. Force closing..."

            Stop-Process `
                -Id $process.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }


    Start-Sleep -Milliseconds 750


    # --------------------------------------------------------
    # Verification
    # --------------------------------------------------------

    $servicePid = Get-RustDeskServicePid


    $remainingGui = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue |
        Where-Object {

            if (
                $servicePid -and
                $_.Id -eq $servicePid
            ) {
                return $false
            }

            return $_.SessionId -ne 0
        }
    )


    if ($remainingGui.Count -gt 0) {

        foreach ($process in $remainingGui) {

            Log (
                "Remaining GUI/helper PID=" +
                "$($process.Id)"
            )
        }


        Fail "RustDesk GUI could not be stopped."
    }


    Log "RustDesk GUI stopped."
}


# ============================================================
# WAIT INSTALL RESULT
# ============================================================

function Wait-ForRustDeskInstallation {

    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$InstallerProcess
    )


    Log (
        "Waiting for RustDesk $TargetVersion " +
        "(timeout ${InstallTimeoutSeconds}s)..."
    )


    for (
        $second = 1;
        $second -le $InstallTimeoutSeconds;
        $second++
    ) {

        $exe = Find-RustDeskExe


        if ($exe) {

            $version = Get-RustDeskVersion `
                -Exe $exe


            Log (
                "[$second/$InstallTimeoutSeconds] " +
                "Detected version: [$version], " +
                "expected: [$TargetVersion]"
            )


            if ($version -eq $TargetVersion) {

                Log "Required RustDesk $TargetVersion detected."

                return $exe
            }
        }
        else {

            if (($second % 5) -eq 0) {

                Log (
                    "[$second/$InstallTimeoutSeconds] " +
                    "rustdesk.exe not found yet."
                )
            }
        }


        # Installer diagnostics only every 5 sec.
        if (($second % 5) -eq 0) {

            try {

                $InstallerProcess.Refresh()


                if ($InstallerProcess.HasExited) {

                    Log (
                        "Installer process exited. " +
                        "Exit code: $($InstallerProcess.ExitCode)"
                    )
                }
                else {

                    Log (
                        "Installer PID $($InstallerProcess.Id) " +
                        "still running."
                    )
                }
            }
            catch {}
        }


        Start-Sleep -Seconds 1
    }


    return $null
}


# ============================================================
# STOP INSTALLER IF IT REMAINS ALIVE
# ============================================================

function Stop-HangingInstaller {

    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$InstallerProcess
    )


    try {

        $InstallerProcess.Refresh()


        if (-not $InstallerProcess.HasExited) {

            Log (
                "RustDesk already installed, but installer " +
                "PID $($InstallerProcess.Id) is still running."
            )


            Stop-Process `
                -Id $InstallerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue


            Start-Sleep -Milliseconds 500


            Log "Hanging installer process stopped."
        }
        else {

            Log (
                "Installer exited normally. Exit code: " +
                "$($InstallerProcess.ExitCode)"
            )
        }
    }
    catch {

        Log (
            "Could not inspect installer process: " +
            $_.Exception.Message
        )
    }
}


# ============================================================
# INSTALL / UPDATE / DOWNGRADE
# ============================================================

function Install-Or-Update-RustDesk {

    $existingExe = Find-RustDeskExe


    # --------------------------------------------------------
    # Existing RustDesk
    # --------------------------------------------------------

    if ($existingExe) {

        $installedVersion = Get-RustDeskVersion `
            -Exe $existingExe


        Log "Installed RustDesk: $existingExe"
        Log "Installed version: [$installedVersion]"
        Log "Required version:  [$TargetVersion]"


        if ($installedVersion -eq $TargetVersion) {

            Log "Correct RustDesk version is already installed."
            Log "Skipping RustDesk installation."

            return $existingExe
        }


        Log (
            "Version mismatch: " +
            "$installedVersion -> $TargetVersion"
        )


        # GUI закрываем перед upgrade/downgrade.
        Stop-RustDeskGui
    }
    else {

        Log "RustDesk is not installed."
    }


    # --------------------------------------------------------
    # Installer
    # --------------------------------------------------------

    $installer = Get-RustDeskInstaller


    Log "Using installer:"
    Log $installer


    try {

        $installerProcess = Start-Process `
            -FilePath $installer `
            -ArgumentList "--silent-install" `
            -PassThru
    }
    catch {

        Fail (
            "Could not start RustDesk installer: " +
            $_.Exception.Message
        )
    }


    Log "RustDesk installer PID: $($installerProcess.Id)"


    # --------------------------------------------------------
    # IMPORTANT:
    #
    # Не ждём installer exit.
    # Ждём реальный installed rustdesk.exe нужной версии.
    # --------------------------------------------------------

    $installedExe = Wait-ForRustDeskInstallation `
        -InstallerProcess $installerProcess


    if (-not $installedExe) {

        try {

            $installerProcess.Refresh()


            if (-not $installerProcess.HasExited) {

                Stop-Process `
                    -Id $installerProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {}


        Fail (
            "RustDesk $TargetVersion was not detected " +
            "within $InstallTimeoutSeconds seconds."
        )
    }


    Stop-HangingInstaller `
        -InstallerProcess $installerProcess


    $actualVersion = Get-RustDeskVersion `
        -Exe $installedExe


    if ($actualVersion -ne $TargetVersion) {

        Fail (
            "Version verification failed. " +
            "Expected [$TargetVersion], got [$actualVersion]."
        )
    }


    Log "RustDesk installation/update successful."

    return $installedExe
}


# ============================================================
# SERVICE
# ============================================================

function Test-RustDeskServiceRunning {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue


    return (
        $service -and
        $service.Status -eq "Running"
    )
}


function Ensure-RustDeskService {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )


    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue


    # --------------------------------------------------------
    # Install Service if missing
    # --------------------------------------------------------

    if (-not $service) {

        Log "RustDesk Service does not exist."
        Log "Installing RustDesk Service..."


        & $Exe --install-service


        if ($LASTEXITCODE -ne 0) {

            Fail (
                "--install-service failed. " +
                "Exit code: $LASTEXITCODE"
            )
        }


        for ($i = 0; $i -lt 15; $i++) {

            $service = Get-Service `
                -Name $ServiceName `
                -ErrorAction SilentlyContinue


            if ($service) {
                break
            }


            Start-Sleep -Seconds 1
        }


        if (-not $service) {
            Fail "RustDesk Service was not created."
        }


        Log "RustDesk Service created."
    }
    else {

        Log "RustDesk Service already exists."
    }


    # --------------------------------------------------------
    # Start service
    # --------------------------------------------------------

    $service.Refresh()


    if ($service.Status -ne "Running") {

        Log "Starting RustDesk Service..."


        try {

            Start-Service `
                -Name $ServiceName `
                -ErrorAction Stop
        }
        catch {

            Fail (
                "Could not start RustDesk Service: " +
                $_.Exception.Message
            )
        }
    }


    # --------------------------------------------------------
    # Wait RUNNING
    # --------------------------------------------------------

    Log "Waiting for RustDesk Service = RUNNING..."


    for (
        $i = 0;
        $i -lt $ServiceTimeoutSeconds;
        $i++
    ) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue


        if (
            $service -and
            $service.Status -eq "Running"
        ) {

            Log "RustDesk Service is RUNNING."


            # Важная пауза для IPC.
            Start-Sleep -Seconds 3


            return
        }


        Start-Sleep -Seconds 1
    }


    Fail "RustDesk Service did not become RUNNING."
}


# ============================================================
# CONFIG
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

        Fail "RustDeskConfig is not configured."
    }


    if (-not (Test-RustDeskServiceRunning)) {

        Fail "Service is not running before --config."
    }


    Log "Applying RustDesk self-hosted config..."


    & $Exe --config $RustDeskConfig


    if ($LASTEXITCODE -ne 0) {

        Log (
            "First --config attempt failed: " +
            "$LASTEXITCODE"
        )


        Start-Sleep -Seconds 3


        Log "Retrying --config..."


        & $Exe --config $RustDeskConfig


        if ($LASTEXITCODE -ne 0) {

            Fail (
                "--config failed twice. Exit code: " +
                "$LASTEXITCODE"
            )
        }
    }


    Log "--config completed."

    Start-Sleep -Seconds 2
}


# ============================================================
# PASSWORD
# ============================================================

function Apply-RustDeskPassword {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )


    if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {

        Fail "RustDeskPassword is empty."
    }


    if (-not (Test-RustDeskServiceRunning)) {

        Fail "Service is not running before --password."
    }


    Log "Applying permanent password..."


    & $Exe --password $RustDeskPassword


    if ($LASTEXITCODE -ne 0) {

        Log (
            "First --password attempt failed: " +
            "$LASTEXITCODE"
        )


        Start-Sleep -Seconds 3


        Log "Retrying --password..."


        & $Exe --password $RustDeskPassword


        if ($LASTEXITCODE -ne 0) {

            Fail (
                "--password failed twice. Exit code: " +
                "$LASTEXITCODE"
            )
        }
    }


    Log "--password completed."

    Start-Sleep -Seconds 2
}


# ============================================================
# READ OPTIONS
# ============================================================

function Get-RustDeskOption {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string]$Option
    )


    try {

        $result = & $Exe `
            --option `
            $Option `
            2>&1


        if ($LASTEXITCODE -ne 0) {
            return $null
        }


        return ($result -join "").Trim()
    }
    catch {

        return $null
    }
}


# ============================================================
# GET ID
# ============================================================

function Get-RustDeskId {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )


    try {

        $result = & $Exe --get-id 2>&1


        if ($LASTEXITCODE -ne 0) {
            return $null
        }


        return ($result -join "").Trim()
    }
    catch {

        return $null
    }
}


# ============================================================
# VERIFY
# ============================================================

function Verify-RustDesk {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )


    Log ""
    Log "============================================"
    Log "Final RustDesk verification"
    Log "============================================"


    # --------------------------------------------------------
    # EXE
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $Exe)) {

        Fail "rustdesk.exe does not exist."
    }


    Log "Executable: $Exe"


    # --------------------------------------------------------
    # VERSION
    # --------------------------------------------------------

    $version = Get-RustDeskVersion `
        -Exe $Exe


    Log "Version: [$version]"


    if ($version -ne $TargetVersion) {

        Fail (
            "Version verification failed. " +
            "Expected [$TargetVersion], got [$version]."
        )
    }


    # --------------------------------------------------------
    # SERVICE
    # --------------------------------------------------------

    if (-not (Test-RustDeskServiceRunning)) {

        Fail "RustDesk Service is not RUNNING."
    }


    Log "Service: RUNNING"


    # --------------------------------------------------------
    # ID
    # --------------------------------------------------------

    $rustDeskId = $null


    for ($i = 0; $i -lt 10; $i++) {

        $rustDeskId = Get-RustDeskId `
            -Exe $Exe


        if (
            -not [string]::IsNullOrWhiteSpace(
                $rustDeskId
            )
        ) {
            break
        }


        Log "RustDesk ID not ready. Retrying..."

        Start-Sleep -Seconds 2
    }


    if ([string]::IsNullOrWhiteSpace($rustDeskId)) {

        Fail "RustDesk ID is empty."
    }


    Log "RustDesk ID: $rustDeskId"


    # --------------------------------------------------------
    # OPTIONS
    # --------------------------------------------------------

    $idServer = Get-RustDeskOption `
        -Exe $Exe `
        -Option "custom-rendezvous-server"


    $relayServer = Get-RustDeskOption `
        -Exe $Exe `
        -Option "relay-server"


    $key = Get-RustDeskOption `
        -Exe $Exe `
        -Option "key"


    Log "custom-rendezvous-server = [$idServer]"
    Log "relay-server             = [$relayServer]"


    if ([string]::IsNullOrWhiteSpace($key)) {

        Log "key                      = [EMPTY]"
    }
    else {

        Log "key                      = [configured]"
    }


    if (-not (Test-RustDeskServiceRunning)) {

        Fail "RustDesk Service stopped during configuration."
    }


    Log "Final verification SUCCESS."
}


# ============================================================
# MAIN
# ============================================================

try {

    Log ""
    Log "============================================"
    Log "RustDesk deployment started"
    Log "Target version: $TargetVersion"
    Log "============================================"
    Log ""


    # --------------------------------------------------------
    # Admin
    # --------------------------------------------------------

    if (-not (Test-Administrator)) {

        Fail "Administrator privileges are required."
    }


    Log "Administrator privileges: OK"


    # --------------------------------------------------------
    # Install/update
    # --------------------------------------------------------

    $RustDeskExe = Install-Or-Update-RustDesk


    if (
        [string]::IsNullOrWhiteSpace($RustDeskExe) -or
        -not (Test-Path -LiteralPath $RustDeskExe)
    ) {

        Fail "rustdesk.exe could not be found."
    }


    # --------------------------------------------------------
    # Service
    # --------------------------------------------------------

    Ensure-RustDeskService `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # GUI
    #
    # Service НЕ останавливаем.
    # --------------------------------------------------------

    Stop-RustDeskGui


    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "Service stopped unexpectedly " +
            "after closing GUI."
        )
    }


    Log "RustDesk Service remains RUNNING."


    # --------------------------------------------------------
    # Config
    # --------------------------------------------------------

    Apply-RustDeskConfig `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # Password
    # --------------------------------------------------------

    Apply-RustDeskPassword `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # Verify
    # --------------------------------------------------------

    Verify-RustDesk `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # DONE
    #
    # GUI здесь НЕ стартуем.
    # NSIS должен сделать это после exit 0.
    # --------------------------------------------------------

    Log ""
    Log "============================================"
    Log "RustDesk deployment SUCCESS"
    Log "============================================"
    Log ""


    exit 0
}
catch {

    Log ""
    Log "============================================"
    Log "UNHANDLED ERROR"
    Log "============================================"


    Log $_.Exception.Message


    if ($_.ScriptStackTrace) {

        Log $_.ScriptStackTrace
    }


    exit 1
}