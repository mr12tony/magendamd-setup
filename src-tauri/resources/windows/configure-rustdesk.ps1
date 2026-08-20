# ============================================================
# configure-rustdesk.ps1
#
# RustDesk 1.4.9 deployment for Tauri / NSIS
#
# Flow:
#   1. Check admin
#   2. Find installed RustDesk
#   3. Check version
#   4. If missing / wrong version:
#        - close RustDesk GUI
#        - detect x64 / ARM64
#        - start bundled installer WITHOUT -Wait
#        - wait until installed rustdesk.exe == 1.4.9
#        - kill installer process if it remains hanging
#   5. Ensure RustDesk Service exists
#   6. Ensure Service = Running
#   7. Close GUI
#   8. Apply --config
#   9. Apply --password
#  10. Verify version / service / ID / options
#
# GUI should be started by NSIS AFTER this script returns exit 0,
# preferably using RunAsUser.
# ============================================================

$ErrorActionPreference = "Stop"


# ============================================================
# CONFIGURATION
# ============================================================

$TargetVersion = "1.4.9"

# Export Server Config from RustDesk.
$RustDeskConfig = "YOUR_EXPORTED_CONFIG"

# Test password.
# Later it is better to generate/obtain it dynamically.
$RustDeskPassword = "TestPassword123!"

$ServiceName = "Rustdesk"

$X64Installer = Join-Path `
    $PSScriptRoot `
    "rustdesk-1.4.9-x86_64.exe"

$Arm64Installer = Join-Path `
    $PSScriptRoot `
    "rustdesk-1.4.9-aarch64.exe"

# How long to wait for installation/update.
$InstallTimeoutSeconds = 90

# How long to wait for Service.
$ServiceTimeoutSeconds = 45


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


# ============================================================
# FIND INSTALLED RUSTDESK
# ============================================================

function Find-RustDeskExe {

    # --------------------------------------------------------
    # Standard locations
    # --------------------------------------------------------

    $paths = @(
        "$env:ProgramFiles\RustDesk\rustdesk.exe"
    )

    if (${env:ProgramFiles(x86)}) {
        $paths += "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
    }

    foreach ($path in $paths) {

        if (
            -not [string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path)
        ) {
            return $path
        }
    }


    # --------------------------------------------------------
    # Registry fallback
    # --------------------------------------------------------

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($registryPath in $registryPaths) {

        try {

            $entries = @(
                Get-ItemProperty `
                    $registryPath `
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
                        return $candidate
                    }
                }
            }
        }
        catch {
            # Registry fallback is optional.
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

    if (-not (Test-Path -LiteralPath $Exe)) {
        return $null
    }


    # --------------------------------------------------------
    # First try RustDesk CLI
    # --------------------------------------------------------

    try {

        $result = & $Exe --version 2>&1

        $text = ($result -join " ").Trim()

        if ($text -match '(\d+\.\d+\.\d+)') {
            return $Matches[1]
        }
    }
    catch {}


    # --------------------------------------------------------
    # Fallback: Windows file version
    # --------------------------------------------------------

    try {

        $fileVersion = (
            [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)
        ).FileVersion

        if ($fileVersion -match '(\d+\.\d+\.\d+)') {
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

    $arch = $env:PROCESSOR_ARCHITECTURE
    $wowArch = $env:PROCESSOR_ARCHITEW6432

    Log "PROCESSOR_ARCHITECTURE = $arch"
    Log "PROCESSOR_ARCHITEW6432 = $wowArch"


    # --------------------------------------------------------
    # ARM64
    # --------------------------------------------------------

    if (
        $arch -eq "ARM64" -or
        $wowArch -eq "ARM64"
    ) {

        Log "Windows architecture: ARM64"

        if (-not (Test-Path -LiteralPath $Arm64Installer)) {
            Fail "ARM64 installer not found: $Arm64Installer"
        }

        return $Arm64Installer
    }


    # --------------------------------------------------------
    # x86_64
    # --------------------------------------------------------

    if (
        $arch -eq "AMD64" -or
        $wowArch -eq "AMD64"
    ) {

        Log "Windows architecture: x86_64"

        if (-not (Test-Path -LiteralPath $X64Installer)) {
            Fail "x86_64 installer not found: $X64Installer"
        }

        return $X64Installer
    }

    Fail "Unsupported Windows architecture: $arch / $wowArch"
}


# ============================================================
# GET RUSTDESK SERVICE PID
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
# CLOSE RUSTDESK GUI
#
# Service process PID is explicitly excluded.
# ============================================================

function Stop-RustDeskGui {

    Log "Checking RustDesk GUI..."

    $servicePid = Get-RustDeskServicePid

    if ($servicePid) {
        Log "RustDesk Service PID: $servicePid"
    }


    $allProcesses = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue
    )


    $guiProcesses = @(
        $allProcesses |
        Where-Object {

            if ($servicePid -and $_.Id -eq $servicePid) {
                return $false
            }

            # Interactive/user processes should have
            # a session other than Session 0.
            return $_.SessionId -ne 0
        }
    )


    if ($guiProcesses.Count -eq 0) {

        Log "RustDesk GUI is not running."

        return
    }


    foreach ($process in $guiProcesses) {

        Log (
            "RustDesk GUI found: PID=$($process.Id), " +
            "Session=$($process.SessionId)"
        )


        # ----------------------------------------------------
        # Graceful close first
        # ----------------------------------------------------

        try {

            if ($process.MainWindowHandle -ne 0) {

                Log "Requesting graceful close for PID $($process.Id)..."

                $null = $process.CloseMainWindow()

                try {
                    $process.WaitForExit(5000)
                }
                catch {}
            }
        }
        catch {}


        # ----------------------------------------------------
        # Refresh process state
        # ----------------------------------------------------

        $stillRunning = Get-Process `
            -Id $process.Id `
            -ErrorAction SilentlyContinue


        # ----------------------------------------------------
        # Force close only GUI process
        # ----------------------------------------------------

        if ($stillRunning) {

            Log "GUI PID $($process.Id) did not exit. Forcing close..."

            Stop-Process `
                -Id $process.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }


    Start-Sleep -Milliseconds 750


    # --------------------------------------------------------
    # Verify no user-side RustDesk processes remain
    # --------------------------------------------------------

    $servicePid = Get-RustDeskServicePid

    $remaining = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue |
        Where-Object {

            if ($servicePid -and $_.Id -eq $servicePid) {
                return $false
            }

            return $_.SessionId -ne 0
        }
    )


    if ($remaining.Count -gt 0) {

        foreach ($process in $remaining) {
            Log (
                "Remaining RustDesk GUI/helper: " +
                "PID=$($process.Id), Session=$($process.SessionId)"
            )
        }

        Fail "RustDesk GUI could not be completely stopped."
    }

    Log "RustDesk GUI stopped."
}


# ============================================================
# WAIT FOR INSTALLED VERSION
#
# IMPORTANT:
# We do NOT wait for installer process termination.
#
# We wait for:
#
#   rustdesk.exe exists
#   AND
#   version == TargetVersion
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


    $lastReportedVersion = $null


    for (
        $second = 1;
        $second -le $InstallTimeoutSeconds;
        $second++
    ) {

        $exe = Find-RustDeskExe


        if ($exe) {

            $version = Get-RustDeskVersion -Exe $exe


            if ($version -ne $lastReportedVersion) {

                Log "Detected rustdesk.exe: $exe"
                Log "Detected version: $version"

                $lastReportedVersion = $version
            }


            if ($version -eq $TargetVersion) {

                Log "Required RustDesk version detected."

                return $exe
            }
        }


        # ----------------------------------------------------
        # Diagnostic installer status
        # ----------------------------------------------------

        if (($second % 5) -eq 0) {

            try {

                if ($InstallerProcess.HasExited) {

                    Log (
                        "Installer process already exited. " +
                        "Exit code: $($InstallerProcess.ExitCode)"
                    )
                }
                else {

                    Log (
                        "Installer PID $($InstallerProcess.Id) " +
                        "still running. Install check: " +
                        "$second/$InstallTimeoutSeconds"
                    )
                }
            }
            catch {

                Log "Install check: $second/$InstallTimeoutSeconds"
            }
        }


        Start-Sleep -Seconds 1
    }


    return $null
}


# ============================================================
# STOP ONLY THE ORIGINAL INSTALLER PROCESS IF IT HANGS
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
                "RustDesk is already installed, but installer " +
                "PID $($InstallerProcess.Id) is still running."
            )

            Log "Stopping hanging installer process..."

            Stop-Process `
                -Id $InstallerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue

            Start-Sleep -Milliseconds 500

            Log "Installer process stopped."
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
            "Could not inspect/stop installer process: " +
            $_.Exception.Message
        )
    }
}


# ============================================================
# INSTALL OR UPDATE RUSTDESK
# ============================================================

function Install-Or-Update-RustDesk {

    $exe = Find-RustDeskExe


    # --------------------------------------------------------
    # Existing RustDesk
    # --------------------------------------------------------

    if ($exe) {

        $installedVersion = Get-RustDeskVersion -Exe $exe

        Log "Installed RustDesk found:"
        Log $exe

        Log "Installed version: $installedVersion"
        Log "Required version:  $TargetVersion"


        if ($installedVersion -eq $TargetVersion) {

            Log "RustDesk $TargetVersion already installed."
            Log "Skipping installation/update."

            return $exe
        }


        Log (
            "RustDesk version mismatch: " +
            "$installedVersion -> $TargetVersion"
        )

        Log "Preparing RustDesk update/downgrade..."

        Stop-RustDeskGui
    }
    else {

        Log "RustDesk is not installed."
    }


    # --------------------------------------------------------
    # Choose installer
    # --------------------------------------------------------

    $installer = Get-RustDeskInstaller

    Log "Using installer:"
    Log $installer


    # --------------------------------------------------------
    # IMPORTANT:
    #
    # NO -Wait here.
    # --------------------------------------------------------

    Log "Starting RustDesk installer..."

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
    # Wait for actual installed version instead of installer
    # termination.
    # --------------------------------------------------------

    $installedExe = Wait-ForRustDeskInstallation `
        -InstallerProcess $installerProcess


    if (-not $installedExe) {

        Log "RustDesk installation timeout."


        # Kill only the installer PID started by this script.
        try {

            $installerProcess.Refresh()

            if (-not $installerProcess.HasExited) {

                Log (
                    "Stopping installer PID " +
                    "$($installerProcess.Id)..."
                )

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


    # --------------------------------------------------------
    # Installed version is correct.
    #
    # Installer may nevertheless remain hanging.
    # --------------------------------------------------------

    Stop-HangingInstaller `
        -InstallerProcess $installerProcess


    # --------------------------------------------------------
    # Final version confirmation
    # --------------------------------------------------------

    $actualVersion = Get-RustDeskVersion `
        -Exe $installedExe


    if ($actualVersion -ne $TargetVersion) {

        Fail (
            "RustDesk version verification failed. " +
            "Expected: $TargetVersion, actual: $actualVersion"
        )
    }


    Log "RustDesk installation/update successful."
    Log "Installed executable: $installedExe"
    Log "Installed version:    $actualVersion"

    return $installedExe
}


# ============================================================
# ENSURE SERVICE EXISTS
# ============================================================

function Ensure-RustDeskService {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )


    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue


    # --------------------------------------------------------
    # Install service if missing
    # --------------------------------------------------------

    if (-not $service) {

        Log "RustDesk Service does not exist."
        Log "Installing RustDesk Service..."


        & $Exe --install-service


        if ($LASTEXITCODE -ne 0) {

            Fail (
                "RustDesk --install-service failed. " +
                "Exit code: $LASTEXITCODE"
            )
        }


        # Wait until Service registration appears.
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
    # Start if needed
    # --------------------------------------------------------

    $service.Refresh()


    if ($service.Status -ne "Running") {

        Log (
            "RustDesk Service status: " +
            "$($service.Status)"
        )

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
    # Wait for Running
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


            # Important:
            # allow RustDesk IPC/config side to initialize.
            Start-Sleep -Seconds 3

            return
        }


        Start-Sleep -Seconds 1
    }


    Fail (
        "RustDesk Service did not reach RUNNING " +
        "within $ServiceTimeoutSeconds seconds."
    )
}


# ============================================================
# CHECK SERVICE
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

        Fail (
            "RustDeskConfig is not configured. " +
            "Set YOUR_EXPORTED_CONFIG before building."
        )
    }


    if (-not (Test-RustDeskServiceRunning)) {
        Fail "RustDesk Service is not running before --config."
    }


    Log "Applying RustDesk self-hosted configuration..."


    & $Exe --config $RustDeskConfig


    if ($LASTEXITCODE -ne 0) {

        Fail (
            "RustDesk --config failed. " +
            "Exit code: $LASTEXITCODE"
        )
    }


    Log "RustDesk --config command completed."

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


    if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {
        Fail "RustDeskPassword is empty."
    }


    if (-not (Test-RustDeskServiceRunning)) {
        Fail "RustDesk Service is not running before --password."
    }


    Log "Applying RustDesk permanent password..."


    & $Exe --password $RustDeskPassword


    if ($LASTEXITCODE -ne 0) {

        Log (
            "First --password attempt failed. " +
            "Exit code: $LASTEXITCODE"
        )

        Log "Waiting 3 seconds and retrying..."

        Start-Sleep -Seconds 3


        & $Exe --password $RustDeskPassword


        if ($LASTEXITCODE -ne 0) {

            Fail (
                "RustDesk --password failed twice. " +
                "Exit code: $LASTEXITCODE"
            )
        }
    }


    Log "RustDesk --password command completed."

    Start-Sleep -Seconds 2
}


# ============================================================
# GET OPTION
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


    Log "============================================"
    Log "Final RustDesk verification"
    Log "============================================"


    # --------------------------------------------------------
    # EXE
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $Exe)) {
        Fail "rustdesk.exe disappeared."
    }

    Log "Executable: $Exe"


    # --------------------------------------------------------
    # VERSION
    # --------------------------------------------------------

    $version = Get-RustDeskVersion -Exe $Exe

    Log "Version: $version"


    if ($version -ne $TargetVersion) {

        Fail (
            "Version verification failed. " +
            "Expected $TargetVersion, got $version."
        )
    }


    # --------------------------------------------------------
    # SERVICE
    # --------------------------------------------------------

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue


    if (-not $service) {
        Fail "RustDesk Service does not exist."
    }


    Log "Service status: $($service.Status)"


    if ($service.Status -ne "Running") {
        Fail "RustDesk Service is not RUNNING."
    }


    # --------------------------------------------------------
    # ID
    #
    # Sometimes ID does not become available instantly after
    # a fresh install/configuration, therefore retry.
    # --------------------------------------------------------

    $rustDeskId = $null


    for ($i = 0; $i -lt 10; $i++) {

        $rustDeskId = Get-RustDeskId -Exe $Exe


        if (
            -not [string]::IsNullOrWhiteSpace(
                $rustDeskId
            )
        ) {
            break
        }


        Log "RustDesk ID not ready yet. Waiting..."

        Start-Sleep -Seconds 2
    }


    if ([string]::IsNullOrWhiteSpace($rustDeskId)) {
        Fail "RustDesk returned an empty ID."
    }


    Log "RustDesk ID: $rustDeskId"


    # --------------------------------------------------------
    # CONFIG READ-BACK
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


    # --------------------------------------------------------
    # Service must STILL be running after config/password.
    # --------------------------------------------------------

    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "RustDesk Service stopped during " +
            "configuration."
        )
    }


    Log "RustDesk verification SUCCESS."
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
    # 1. Administrator
    # --------------------------------------------------------

    if (-not (Test-Administrator)) {
        Fail "Administrator privileges are required."
    }

    Log "Administrator privileges: OK"


    # --------------------------------------------------------
    # 2. Install / update / downgrade if required
    # --------------------------------------------------------

    $RustDeskExe = Install-Or-Update-RustDesk


    if (
        [string]::IsNullOrWhiteSpace($RustDeskExe) -or
        -not (Test-Path -LiteralPath $RustDeskExe)
    ) {

        Fail "Installed rustdesk.exe could not be found."
    }


    # --------------------------------------------------------
    # 3. Ensure Service
    # --------------------------------------------------------

    Ensure-RustDeskService `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # 4. Close GUI
    #
    # IMPORTANT:
    # RustDesk Service remains RUNNING.
    # --------------------------------------------------------

    Stop-RustDeskGui


    # --------------------------------------------------------
    # 5. Verify Service after GUI close
    # --------------------------------------------------------

    if (-not (Test-RustDeskServiceRunning)) {

        Fail (
            "RustDesk Service stopped unexpectedly " +
            "after closing GUI."
        )
    }


    Log "RustDesk Service remains RUNNING."


    # --------------------------------------------------------
    # 6. Config
    # --------------------------------------------------------

    Apply-RustDeskConfig `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # 7. Password
    # --------------------------------------------------------

    Apply-RustDeskPassword `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # 8. Final verification
    # --------------------------------------------------------

    Verify-RustDesk `
        -Exe $RustDeskExe


    # --------------------------------------------------------
    # DONE
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