$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$TargetVersion = "1.4.9"

# Вставь сюда Export Server Config из RustDesk.
$RustDeskConfig = "=0nI9MWTLBXTuZjQ6FDUttmN1V3Q3U0QKhmSBBla2EWQ5gFUN50ZrV2byATaMtiI6ISeltmIsIiI6ISawFmIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI5FGblJnIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI0N3boJye"

# Для тестов.
# В production лучше не хранить пароль прямо в .ps1.
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
# LOGGING
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
# Example:
#
# 1.4.9+67 -> 1.4.9
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
# FIND INSTALLED RUSTDESK
# ============================================================

function Find-RustDeskExe {

    $paths = New-Object System.Collections.Generic.List[string]

    # Important for 32-bit installer context on x64 Windows.
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) {
        $paths.Add(
            (Join-Path $env:ProgramW6432 "RustDesk\rustdesk.exe")
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $paths.Add(
            (Join-Path $env:ProgramFiles "RustDesk\rustdesk.exe")
        )
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $paths.Add(
            (Join-Path ${env:ProgramFiles(x86)} "RustDesk\rustdesk.exe")
        )
    }

    $paths.Add("C:\Program Files\RustDesk\rustdesk.exe")
    $paths.Add("C:\Program Files (x86)\RustDesk\rustdesk.exe")

    foreach ($path in ($paths | Select-Object -Unique)) {

        if (Test-Path -LiteralPath $path) {

            Log "Found RustDesk executable: $path"

            return $path
        }
    }

    # Registry fallback
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
# GET INSTALLED VERSION
# ============================================================

function Get-RustDeskVersion {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    if (-not (Test-Path -LiteralPath $Exe)) {
        return $null
    }

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

    # Registry fallback
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
# ARCHITECTURE
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
# RUSTDESK SERVICE PID
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
# CLOSE USER GUI ONLY
# ============================================================

function Stop-RustDeskGui {

    Log "Checking RustDesk GUI..."

    $servicePid = Get-RustDeskServicePid

    if ($servicePid) {
        Log "RustDesk Service PID: $servicePid"
    }

    # ========================================================
    # Snapshot of current RustDesk user processes
    #
    # Important:
    # We only close processes that existed when this function
    # started. RustDesk Service may spawn another user/helper
    # process afterwards.
    # ========================================================

    $guiProcesses = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue |
        Where-Object {

            # Never touch Service PID.
            if (
                $servicePid -and
                $_.Id -eq $servicePid
            ) {
                return $false
            }

            # Session 0 belongs to services/system processes.
            return $_.SessionId -ne 0
        }
    )

    if ($guiProcesses.Count -eq 0) {

        Log "RustDesk GUI is not running."

        return
    }

    Log (
        "Found $($guiProcesses.Count) " +
        "RustDesk user process(es)."
    )

    # ========================================================
    # Close only processes from the initial snapshot
    # ========================================================

    foreach ($process in $guiProcesses) {

        $pid = $process.Id

        Log (
            "Closing RustDesk GUI/user process: " +
            "PID=$pid, Session=$($process.SessionId)"
        )

        # ----------------------------------------------------
        # Graceful close
        # ----------------------------------------------------

        try {

            if ($process.MainWindowHandle -ne 0) {

                Log "Requesting graceful close: PID=$pid"

                $closed = $process.CloseMainWindow()

                Log "CloseMainWindow returned: $closed"

                if ($closed) {

                    try {
                        $process.WaitForExit(3000)
                    }
                    catch {}
                }
            }
            else {

                Log (
                    "PID $pid has no main window. " +
                    "Skipping graceful close."
                )
            }
        }
        catch {

            Log "Graceful close failed for PID=$pid"
        }

        # ----------------------------------------------------
        # Is ORIGINAL process still alive?
        # ----------------------------------------------------

        $stillRunning = Get-Process `
            -Id $pid `
            -ErrorAction SilentlyContinue

        if ($stillRunning) {

            Log (
                "Original GUI PID $pid still running. " +
                "Force closing..."
            )

            try {

                Stop-Process `
                    -Id $pid `
                    -Force `
                    -ErrorAction Stop
            }
            catch {

                Log (
                    "Could not force-close PID $pid. " +
                    "Continuing."
                )
            }
        }

        # ----------------------------------------------------
        # Verify ORIGINAL PID only
        # ----------------------------------------------------

        Start-Sleep -Milliseconds 300

        $stillRunning = Get-Process `
            -Id $pid `
            -ErrorAction SilentlyContinue

        if ($stillRunning) {

            Log (
                "WARNING: original RustDesk PID $pid " +
                "is still running."
            )
        }
        else {

            Log "Original RustDesk PID $pid stopped."
        }
    }

    # ========================================================
    # Small stabilization delay
    # ========================================================

    Start-Sleep -Seconds 1

    # ========================================================
    # Diagnostic only:
    #
    # RustDesk Service may spawn a new user/helper process.
    # This is NOT considered an error.
    # ========================================================

    $servicePid = Get-RustDeskServicePid

    $newProcesses = @(
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

    if ($newProcesses.Count -gt 0) {

        foreach ($process in $newProcesses) {

            Log (
                "RustDesk user/helper currently present: " +
                "PID=$($process.Id), " +
                "Session=$($process.SessionId)"
            )
        }

        Log (
            "RustDesk Service may recreate user/helper " +
            "processes. Continuing deployment."
        )
    }
    else {

        Log "No RustDesk user processes currently running."
    }

    # ========================================================
    # Critical verification:
    #
    # Service must still be alive.
    # ========================================================

    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "RustDesk Service stopped unexpectedly " +
            "while closing GUI."
        )
    }

    Log "RustDesk GUI close phase completed."
    Log "RustDesk Service remains RUNNING."
}


# ============================================================
# WAIT FOR INSTALLED VERSION
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
# STOP HANGING INSTALLER
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
                "RustDesk is installed, but installer " +
                "PID $($InstallerProcess.Id) is still running."
            )

            Log "Stopping hanging installer process..."

            Stop-Process `
                -Id $InstallerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue

            Start-Sleep -Milliseconds 500

            Log "Hanging installer stopped."
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

    if ($existingExe) {

        $installedVersion = Get-RustDeskVersion `
            -Exe $existingExe

        Log "Installed RustDesk: $existingExe"
        Log "Installed version: [$installedVersion]"
        Log "Required version:  [$TargetVersion]"

        if ($installedVersion -eq $TargetVersion) {

            Log "Correct RustDesk version already installed."
            Log "Skipping installation."

            return $existingExe
        }

        Log (
            "Version mismatch: " +
            "$installedVersion -> $TargetVersion"
        )

        Stop-RustDeskGui
    }
    else {

        Log "RustDesk is not installed."
    }

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

    # Important:
    # rustdesk.exe/version can already be visible while
    # the installer is still finalizing service registration.
    Log "Waiting for installer/service finalization..."

    Start-Sleep -Seconds 5

    return $installedExe
}


# ============================================================
# SERVICE STATE
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


# ============================================================
# ENSURE SERVICE
# ============================================================

function Ensure-RustDeskService {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    Log "Checking RustDesk Service..."

    # ========================================================
    # 1. Initial wait
    # ========================================================

    Log "Waiting for RustDesk service initialization..."

    Start-Sleep -Seconds 5

    # ========================================================
    # 2. Service exists?
    # ========================================================

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    # ========================================================
    # 3. Missing -> install
    # ========================================================

    if (-not $service) {

        Log "RustDesk Service does not exist."
        Log "Installing RustDesk Service..."

        try {

            & $Exe --install-service

            Log "--install-service exit code: $LASTEXITCODE"
        }
        catch {

            Log (
                "--install-service exception: " +
                $_.Exception.Message
            )
        }

        Log "Waiting for Service registration..."

        for ($i = 1; $i -le 20; $i++) {

            Start-Sleep -Seconds 1

            $service = Get-Service `
                -Name $ServiceName `
                -ErrorAction SilentlyContinue

            if ($service) {

                Log "RustDesk Service registered."

                break
            }

            Log "Waiting for Service registration: $i/20"
        }

        if (-not $service) {

            Fail "RustDesk Service was not created."
        }
    }
    else {

        Log "RustDesk Service already exists."
    }


    # ========================================================
    # 4. Observe first — don't immediately call Start-Service
    # ========================================================

    Log "Waiting for RustDesk Service state..."

    for ($i = 1; $i -le 15; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (-not $service) {

            Log "Service temporarily unavailable: $i/15"

            Start-Sleep -Seconds 1

            continue
        }

        Log "RustDesk Service status: $($service.Status)"

        if ($service.Status -eq "Running") {

            Log "RustDesk Service is RUNNING."

            Start-Sleep -Seconds 3

            return
        }

        if (
            $service.Status -eq "StartPending" -or
            $service.Status -eq "StopPending"
        ) {

            Log "Service is transitioning. Waiting..."

            Start-Sleep -Seconds 1

            continue
        }

        Start-Sleep -Seconds 1
    }


    # ========================================================
    # 5. Examine final state after wait
    # ========================================================

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {

        Fail "RustDesk Service disappeared."
    }

    if ($service.Status -eq "Running") {

        Log "RustDesk Service is RUNNING."

        Start-Sleep -Seconds 3

        return
    }

    if ($service.Status -ne "Stopped") {

        Fail (
            "RustDesk Service is in unexpected state: " +
            "$($service.Status)"
        )
    }


    # ========================================================
    # 6. Actually start it
    # ========================================================

    Log "RustDesk Service is STOPPED."
    Log "Starting RustDesk Service..."

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop

        Log "Start-Service command accepted."
    }
    catch {

        # Do not fail immediately.
        # RustDesk/SCM can still transition to Running.
        Log "Start-Service returned an error."

        # Avoid dumping localized Windows error text into NSIS.
    }


    # ========================================================
    # 7. Wait for RUNNING
    # ========================================================

    for (
        $i = 1;
        $i -le $ServiceTimeoutSeconds;
        $i++
    ) {

        Start-Sleep -Seconds 1

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (
            $service -and
            $service.Status -eq "Running"
        ) {

            Log "RustDesk Service is RUNNING."

            Log "Waiting for RustDesk IPC initialization..."

            Start-Sleep -Seconds 3

            return
        }

        if ($service -and (($i % 5) -eq 0)) {

            Log (
                "Waiting for RUNNING: " +
                "$($service.Status) " +
                "($i/$ServiceTimeoutSeconds)"
            )
        }
    }


    # ========================================================
    # 8. Fallback through sc.exe
    # ========================================================

    Log "Start-Service did not produce RUNNING state."
    Log "Trying sc.exe start Rustdesk..."

    try {

        & sc.exe start $ServiceName | Out-Null
    }
    catch {}

    for ($i = 1; $i -le 15; $i++) {

        Start-Sleep -Seconds 1

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (
            $service -and
            $service.Status -eq "Running"
        ) {

            Log "RustDesk Service is RUNNING."

            Log "Waiting for RustDesk IPC initialization..."

            Start-Sleep -Seconds 3

            return
        }
    }


    # ========================================================
    # 9. Diagnostics
    # ========================================================

    Log "RustDesk Service failed to reach RUNNING."

    try {

        $service = Get-CimInstance `
            Win32_Service `
            -Filter "Name='$ServiceName'" `
            -ErrorAction SilentlyContinue

        if ($service) {

            Log "Service State:     [$($service.State)]"
            Log "Service StartMode: [$($service.StartMode)]"
            Log "Service PID:       [$($service.ProcessId)]"
            Log "Service Path:      [$($service.PathName)]"
        }
    }
    catch {}

    Fail "RustDesk Service could not be started."
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
            "First --config attempt failed. " +
            "Exit code: $LASTEXITCODE"
        )

        Start-Sleep -Seconds 3

        Log "Retrying --config..."

        & $Exe --config $RustDeskConfig

        if ($LASTEXITCODE -ne 0) {

            Fail (
                "--config failed twice. " +
                "Exit code: $LASTEXITCODE"
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
            "First --password attempt failed. " +
            "Exit code: $LASTEXITCODE"
        )

        Start-Sleep -Seconds 3

        Log "Retrying --password..."

        & $Exe --password $RustDeskPassword

        if ($LASTEXITCODE -ne 0) {

            Fail (
                "--password failed twice. " +
                "Exit code: $LASTEXITCODE"
            )
        }
    }

    Log "--password completed."

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
# FINAL VERIFICATION
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

    # EXE
    if (-not (Test-Path -LiteralPath $Exe)) {

        Fail "rustdesk.exe does not exist."
    }

    Log "Executable: $Exe"

    # Version
    $version = Get-RustDeskVersion `
        -Exe $Exe

    Log "Version: [$version]"

    if ($version -ne $TargetVersion) {

        Fail (
            "Version verification failed. " +
            "Expected [$TargetVersion], got [$version]."
        )
    }

    # Service
    if (-not (Test-RustDeskServiceRunning)) {

        Fail "RustDesk Service is not RUNNING."
    }

    Log "Service: RUNNING"

    # ID with retry
    $rustDeskId = $null

    for ($i = 1; $i -le 10; $i++) {

        $rustDeskId = Get-RustDeskId `
            -Exe $Exe

        if (
            -not [string]::IsNullOrWhiteSpace(
                $rustDeskId
            )
        ) {
            break
        }

        Log "RustDesk ID not ready. Retrying $i/10..."

        Start-Sleep -Seconds 2
    }

    if ([string]::IsNullOrWhiteSpace($rustDeskId)) {

        Fail "RustDesk ID is empty."
    }

    Log "RustDesk ID: $rustDeskId"

    # Read-back server settings
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

    # 1. Admin
    if (-not (Test-Administrator)) {

        Fail "Administrator privileges are required."
    }

    Log "Administrator privileges: OK"

    # 2. Install/update/downgrade
    $RustDeskExe = Install-Or-Update-RustDesk

    if (
        [string]::IsNullOrWhiteSpace($RustDeskExe) -or
        -not (Test-Path -LiteralPath $RustDeskExe)
    ) {

        Fail "rustdesk.exe could not be found."
    }

    # 3. Service
    Ensure-RustDeskService `
        -Exe $RustDeskExe

    # 4. Close GUI only
    Stop-RustDeskGui

    # 5. Service must remain alive
    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "Service stopped unexpectedly " +
            "after closing GUI."
        )
    }

    Log "RustDesk Service remains RUNNING."

    # 6. Config
    Apply-RustDeskConfig `
        -Exe $RustDeskExe

    # 7. Password
    Apply-RustDeskPassword `
        -Exe $RustDeskExe

    # 8. Verify
    Verify-RustDesk `
        -Exe $RustDeskExe

    Log ""
    Log "============================================"
    Log "RustDesk deployment SUCCESS"
    Log "============================================"
    Log ""

    # GUI intentionally NOT started here.
    # NSIS should start it after exit 0.

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