$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$TargetVersion = "1.4.9"

$RustDeskIdServer = "rustdesk.magendamd.com"
$RustDeskRelayServer = "rustdesk.magendamd.com"
$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

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
# FIND RUSTDESK
# ============================================================

function Find-RustDeskExe {

    $paths = New-Object System.Collections.Generic.List[string]

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

    try {

        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)

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
# SERVICE HELPERS
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
# CLOSE GUI ONLY
# ============================================================

function Stop-RustDeskGui {

    Log "Checking RustDesk GUI..."

    $servicePid = Get-RustDeskServicePid

    if ($servicePid) {
        Log "RustDesk Service PID: $servicePid"
    }

    $guiProcesses = @(
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

    if ($guiProcesses.Count -eq 0) {

        Log "RustDesk GUI is not running."

        return
    }

    Log "Found $($guiProcesses.Count) RustDesk user process(es)."

    foreach ($process in $guiProcesses) {

        $processId = $process.Id

        Log (
            "Closing RustDesk GUI/user process: " +
            "PID=$processId, Session=$($process.SessionId)"
        )

        try {

            if ($process.MainWindowHandle -ne 0) {

                Log "Requesting graceful close: PID=$processId"

                $closed = $process.CloseMainWindow()

                Log "CloseMainWindow returned: $closed"

                if ($closed) {

                    try {
                        $process.WaitForExit(3000)
                    }
                    catch {}
                }
            }
        }
        catch {}

        $stillRunning = Get-Process `
            -Id $processId `
            -ErrorAction SilentlyContinue

        if ($stillRunning) {

            Log "Original GUI PID $processId still running. Force closing..."

            try {

                Stop-Process `
                    -Id $processId `
                    -Force `
                    -ErrorAction Stop
            }
            catch {

                Log "Could not force-close PID $processId. Continuing."
            }
        }
    }

    Start-Sleep -Seconds 1

    # RustDesk Service may recreate user-side helpers.
    # This is diagnostic only, not a fatal condition.
    $servicePid = Get-RustDeskServicePid

    $currentUserProcesses = @(
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

    foreach ($process in $currentUserProcesses) {

        Log (
            "RustDesk user/helper currently present: " +
            "PID=$($process.Id), Session=$($process.SessionId)"
        )
    }

    if (-not (Test-RustDeskServiceRunning)) {

        Fail "RustDesk Service stopped while closing GUI."
    }

    Log "RustDesk GUI close phase completed."
    Log "RustDesk Service remains RUNNING."
}


# ============================================================
# WAIT FOR INSTALLATION
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

        if (($second % 5) -eq 0) {

            try {

                $InstallerProcess.Refresh()

                if ($InstallerProcess.HasExited) {

                    Log (
                        "Installer exited. " +
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

            Log "Stopping hanging RustDesk installer..."

            Stop-Process `
                -Id $InstallerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue

            Start-Sleep -Milliseconds 500
        }
    }
    catch {}
}


# ============================================================
# INSTALL / UPDATE / DOWNGRADE
# ============================================================

function Install-Or-Update-RustDesk {

    $existingExe = Find-RustDeskExe

    if ($existingExe) {

        $installedVersion = Get-RustDeskVersion `
            -Exe $existingExe

        Log "Installed version: [$installedVersion]"
        Log "Required version:  [$TargetVersion]"

        if ($installedVersion -eq $TargetVersion) {

            Log "Correct RustDesk version already installed."

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

        Fail "Could not start RustDesk installer."
    }

    Log "RustDesk installer PID: $($installerProcess.Id)"

    $installedExe = Wait-ForRustDeskInstallation `
        -InstallerProcess $installerProcess

    if (-not $installedExe) {

        Stop-HangingInstaller `
            -InstallerProcess $installerProcess

        Fail (
            "RustDesk $TargetVersion was not detected " +
            "within timeout."
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

    Log "Waiting for installer/service finalization..."

    Start-Sleep -Seconds 5

    return $installedExe
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

    Start-Sleep -Seconds 5

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {

        Log "RustDesk Service does not exist."
        Log "Installing RustDesk Service..."

        try {
            & $Exe --install-service | Out-Null
        }
        catch {}

        for ($i = 1; $i -le 20; $i++) {

            Start-Sleep -Seconds 1

            $service = Get-Service `
                -Name $ServiceName `
                -ErrorAction SilentlyContinue

            if ($service) {
                break
            }
        }

        if (-not $service) {
            Fail "RustDesk Service was not created."
        }
    }

    Log "RustDesk Service exists."

    # First observe service state because installer may start it itself.
    for ($i = 1; $i -le 15; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (
            $service -and
            $service.Status -eq "Running"
        ) {

            Log "RustDesk Service is RUNNING."

            Start-Sleep -Seconds 3

            return
        }

        if ($service) {
            Log "RustDesk Service status: $($service.Status)"
        }

        Start-Sleep -Seconds 1
    }

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {
        Fail "RustDesk Service disappeared."
    }

    if ($service.Status -eq "Running") {

        Start-Sleep -Seconds 3

        return
    }

    if ($service.Status -eq "Stopped") {

        Log "Starting RustDesk Service..."

        try {

            Start-Service `
                -Name $ServiceName `
                -ErrorAction Stop
        }
        catch {

            Log "Start-Service returned an error. Waiting anyway..."
        }
    }

    for ($i = 1; $i -le $ServiceTimeoutSeconds; $i++) {

        Start-Sleep -Seconds 1

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (
            $service -and
            $service.Status -eq "Running"
        ) {

            Log "RustDesk Service is RUNNING."

            Start-Sleep -Seconds 3

            return
        }
    }

    Fail "RustDesk Service could not be started."
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

        return ($result -join "").Trim()
    }
    catch {

        return $null
    }
}


# ============================================================
# SET OPTION + STRICT READ-BACK
# ============================================================

function Set-RustDeskOption {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "RustDesk Service is not running " +
            "before setting '$Name'."
        )
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {

        Fail "Value for RustDesk option '$Name' is empty."
    }

    Log "Setting RustDesk option '$Name'..."

    for ($attempt = 1; $attempt -le 3; $attempt++) {

        Log "Option '$Name' attempt $attempt/3..."

        try {

            & $Exe `
                --option `
                $Name `
                $Value `
                | Out-Null
        }
        catch {

            Log "RustDesk option write threw an exception."
        }

        Start-Sleep -Seconds 2

        $actual = Get-RustDeskOption `
            -Exe $Exe `
            -Option $Name

        Log "Expected '$Name': [$Value]"
        Log "Actual   '$Name': [$actual]"

        if ($actual -eq $Value) {

            Log "RustDesk option '$Name' verified."

            return
        }

        Start-Sleep -Seconds 2
    }

    Fail "RustDesk option '$Name' verification failed."
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

    Log "Applying RustDesk permanent password..."

    $success = $false

    for ($attempt = 1; $attempt -le 3; $attempt++) {

        Log "Password attempt $attempt/3..."

        try {

            & $Exe `
                --password `
                $RustDeskPassword `
                | Out-Null

            $success = $true
        }
        catch {

            Log "Password command threw an exception."

            $success = $false
        }

        if ($success) {

            Start-Sleep -Seconds 2

            Log "Password command completed."

            return
        }

        Start-Sleep -Seconds 2
    }

    Fail "RustDesk password command failed."
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

        return ($result -join "").Trim()
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

    Log ""
    Log "============================================"
    Log "Final RustDesk verification"
    Log "============================================"

    $version = Get-RustDeskVersion `
        -Exe $Exe

    if ($version -ne $TargetVersion) {

        Fail (
            "Version verification failed. " +
            "Expected [$TargetVersion], got [$version]."
        )
    }

    Log "Version: [$version]"

    if (-not (Test-RustDeskServiceRunning)) {

        Fail "RustDesk Service is not RUNNING."
    }

    Log "Service: RUNNING"

    # Strict option read-back again.
    $actualIdServer = Get-RustDeskOption `
        -Exe $Exe `
        -Option "custom-rendezvous-server"

    $actualRelayServer = Get-RustDeskOption `
        -Exe $Exe `
        -Option "relay-server"

    $actualKey = Get-RustDeskOption `
        -Exe $Exe `
        -Option "key"

    if ($actualIdServer -ne $RustDeskIdServer) {

        Fail (
            "Final ID Server verification failed. " +
            "Expected [$RustDeskIdServer], got [$actualIdServer]."
        )
    }

    if ($actualRelayServer -ne $RustDeskRelayServer) {

        Fail (
            "Final Relay verification failed. " +
            "Expected [$RustDeskRelayServer], got [$actualRelayServer]."
        )
    }

    if ($actualKey -ne $RustDeskKey) {

        Fail "Final server key verification failed."
    }

    Log "ID Server: [$actualIdServer]"
    Log "Relay:     [$actualRelayServer]"
    Log "Key:       [verified]"

    # ID retry
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

    Log "RustDesk ID: [$rustDeskId]"

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

    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "RustDesk Service stopped unexpectedly " +
            "after closing GUI."
        )
    }

    Log "RustDesk Service remains RUNNING."

    # 5. Server options
    Set-RustDeskOption `
        -Exe $RustDeskExe `
        -Name "custom-rendezvous-server" `
        -Value $RustDeskIdServer

    Set-RustDeskOption `
        -Exe $RustDeskExe `
        -Name "relay-server" `
        -Value $RustDeskRelayServer

    Set-RustDeskOption `
        -Exe $RustDeskExe `
        -Name "key" `
        -Value $RustDeskKey

    # 6. Password
    Apply-RustDeskPassword `
        -Exe $RustDeskExe

    # 7. Final verification
    Verify-RustDesk `
        -Exe $RustDeskExe

    Log ""
    Log "============================================"
    Log "RustDesk deployment SUCCESS"
    Log "============================================"
    Log ""

    # GUI intentionally not started here.
    # NSIS should start it after script exit 0.

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