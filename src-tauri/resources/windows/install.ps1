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

$LogFile = Join-Path $env:LOCALAPPDATA "Temp\rustdesk-install.log"

$RustDeskX64 = Join-Path $ScriptDir "rustdesk-x86_64.exe"
$RustDeskArm = Join-Path $ScriptDir "rustdesk-aarch64.exe"

$RustDeskExe = Join-Path ${env:ProgramFiles} "RustDesk\rustdesk.exe"

$ServiceName = "Rustdesk"

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        $logDir = Split-Path -Parent $LogFile

        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir |
                Out-Null
        }

        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

        Add-Content `
            -LiteralPath $LogFile `
            -Value $line `
            -Encoding UTF8
    }
    catch {
        # Logging must never break installation.
    }
}

function Fail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log "ERROR: $Message"

    Write-Output "RustDesk installation failed."
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
# START
# ============================================================

Write-Log "============================================================"
Write-Log "RustDesk installation started."
Write-Log "Script: $ScriptPath"
Write-Log "User: $env:USERNAME"
Write-Log "Administrator: $(Test-Administrator)"

# ============================================================
# LOAD ARGS FILE
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($ArgsFile)) {

    Write-Log "Loading arguments from temporary file."

    if (-not (Test-Path -LiteralPath $ArgsFile)) {
        Fail "Arguments file does not exist."
    }

    try {

        $json = Get-Content `
            -LiteralPath $ArgsFile `
            -Raw `
            -Encoding UTF8

        $data = $json | ConvertFrom-Json

        if ($null -eq $data) {
            Fail "Arguments file is empty."
        }

        if ($null -ne $data.Password) {
            $RustDeskPassword = [string]$data.Password
        }

        if ($null -ne $data.Config) {
            $RustDeskConfig = [string]$data.Config
        }

        Write-Log "Password loaded: $(-not [string]::IsNullOrWhiteSpace($RustDeskPassword))"
        Write-Log "Config loaded: $(-not [string]::IsNullOrWhiteSpace($RustDeskConfig))"

        Remove-Item `
            -LiteralPath $ArgsFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {

        Write-Log "Failed to read arguments file."
        Write-Log $_.Exception.ToString()

        Remove-Item `
            -LiteralPath $ArgsFile `
            -Force `
            -ErrorAction SilentlyContinue

        Fail "Could not load installation parameters."
    }
}

# ============================================================
# ELEVATION
# ============================================================

if (-not (Test-Administrator)) {

    # User-facing message.
    Write-Output "Installing RustDesk..."
    Write-Output "Administrator permission is required."

    Write-Log "Current PowerShell is not elevated."
    Write-Log "Requesting administrator privileges."

    $TempArgsFile = Join-Path `
        $env:TEMP `
        "rustdesk-install-$([Guid]::NewGuid().ToString('N')).json"

    try {

        # ----------------------------------------------------
        # SAVE ARGUMENTS
        # ----------------------------------------------------

        $argumentData = @{
            Password = $RustDeskPassword
            Config   = $RustDeskConfig
        }

        $argumentData |
            ConvertTo-Json -Compress |
            Set-Content `
                -LiteralPath $TempArgsFile `
                -Encoding UTF8

        Write-Log "Temporary arguments file created."

        # ----------------------------------------------------
        # ELEVATED POWERSHELL
        # ----------------------------------------------------

        $escapedScript = $ScriptPath.Replace('"', '\"')
        $escapedArgs   = $TempArgsFile.Replace('"', '\"')

        $elevatedArguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$escapedScript`""
            "-ArgsFile"
            "`"$escapedArgs`""
        )

        Write-Log "Starting elevated PowerShell."

        $elevatedProcess = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $elevatedArguments `
            -PassThru

        if ($null -eq $elevatedProcess) {
            Fail "Could not start elevated PowerShell."
        }

        Write-Log "Elevated process started. PID=$($elevatedProcess.Id)"

        # ----------------------------------------------------
        # WAIT FOR ELEVATED PROCESS
        # ----------------------------------------------------

        $elevatedProcess.WaitForExit()

        $exitCode = $elevatedProcess.ExitCode

        Write-Log "Elevated process finished. ExitCode=$exitCode"

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
        # RESULT
        # ----------------------------------------------------

        if ($exitCode -eq 0) {

            Write-Output "RustDesk installed successfully."
            exit 0
        }

        Write-Output "RustDesk installation failed."
        exit $exitCode
    }
    catch {

        Write-Log "Elevation error."
        Write-Log $_.Exception.ToString()

        if (Test-Path -LiteralPath $TempArgsFile) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Write-Output "RustDesk installation failed."

        exit 1
    }
}

# ============================================================
# ELEVATED INSTANCE
# ============================================================

Write-Log "Running elevated installation."

# ============================================================
# VALIDATE ARGUMENTS
# ============================================================

if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {
    Write-Log "Password was not provided."
}
else {
    Write-Log "Password provided."
}

if ([string]::IsNullOrWhiteSpace($RustDeskConfig)) {
    Write-Log "Config was not provided."
}
else {
    Write-Log "Config provided."
}

# ============================================================
# ARCHITECTURE
# ============================================================

$arch1 = $env:PROCESSOR_ARCHITECTURE
$arch2 = $env:PROCESSOR_ARCHITEW6432

Write-Log "PROCESSOR_ARCHITECTURE=$arch1"
Write-Log "PROCESSOR_ARCHITEW6432=$arch2"

$selectedInstaller = $null

if (
    $arch1 -eq "AMD64" -or
    $arch2 -eq "AMD64"
) {
    $selectedInstaller = $RustDeskX64
}
elseif (
    $arch1 -eq "ARM64" -or
    $arch2 -eq "ARM64"
) {
    $selectedInstaller = $RustDeskArm
}
else {
    Fail "Unsupported Windows architecture."
}

Write-Log "Selected installer: $selectedInstaller"

if (-not (Test-Path -LiteralPath $selectedInstaller)) {
    Fail "RustDesk installer was not found."
}

# ============================================================
# CLEANUP OLD INSTALLATION
# ============================================================

Write-Log "Stopping existing RustDesk processes."

Get-Process `
    -Name "rustdesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ------------------------------------------------------------
# SERVICE
# ------------------------------------------------------------

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Log "Existing RustDesk service found."

    if ($service.Status -ne "Stopped") {

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }

    Write-Log "Deleting existing RustDesk service."

    & sc.exe delete $ServiceName *> $null

    Start-Sleep -Seconds 3
}

# ------------------------------------------------------------
# PROGRAM FILES
# ------------------------------------------------------------

$oldInstallDir = Join-Path ${env:ProgramFiles} "RustDesk"

if (Test-Path -LiteralPath $oldInstallDir) {

    Write-Log "Removing old RustDesk installation."

    try {

        Remove-Item `
            -LiteralPath $oldInstallDir `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
    catch {

        Write-Log "Could not completely remove old installation."
        Write-Log $_.Exception.Message
    }
}

# ============================================================
# USER DATA
# ============================================================

$userRoaming = Join-Path $env:APPDATA "RustDesk"
$userLocal   = Join-Path $env:LOCALAPPDATA "RustDesk"

if (Test-Path -LiteralPath $userRoaming) {

    Remove-Item `
        -LiteralPath $userRoaming `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $userLocal) {

    Remove-Item `
        -LiteralPath $userLocal `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

$localServiceData =
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"

if (Test-Path -LiteralPath $localServiceData) {

    Remove-Item `
        -LiteralPath $localServiceData `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Log "Cleanup completed."

# ============================================================
# INSTALL RUSTDESK
# ============================================================

Write-Log "Starting RustDesk silent installer."

try {

    $installerProcess = Start-Process `
        -FilePath $selectedInstaller `
        -ArgumentList "--silent-install" `
        -PassThru

    Write-Log "Installer PID=$($installerProcess.Id)"

    $installed = $false

    # --------------------------------------------------------
    # WAIT UP TO 120 SECONDS
    # --------------------------------------------------------

    for ($i = 0; $i -lt 120; $i++) {

        if (Test-Path -LiteralPath $RustDeskExe) {

            $installed = $true
            Write-Log "RustDesk executable detected."

            break
        }

        if ($installerProcess.HasExited) {

            Write-Log "Installer process exited. Code=$($installerProcess.ExitCode)"

            # Give filesystem/service a little time.
            Start-Sleep -Seconds 2

            if (Test-Path -LiteralPath $RustDeskExe) {

                $installed = $true
                Write-Log "RustDesk executable detected after installer exit."
            }

            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $installed) {

        Write-Log "RustDesk executable was not detected after 120 seconds."

        if (-not $installerProcess.HasExited) {

            Stop-Process `
                -Id $installerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Fail "RustDesk installation timed out."
    }

    # --------------------------------------------------------
    # WAIT A LITTLE FOR INSTALLER TO FINISH
    # --------------------------------------------------------

    if (-not $installerProcess.HasExited) {

        Write-Log "Waiting for installer process."

        $installerProcess.WaitForExit(30000)
    }

    Write-Log "RustDesk installer stage completed."
}
catch {

    Write-Log "RustDesk installer exception."
    Write-Log $_.Exception.ToString()

    Fail "RustDesk installation failed."
}

# ============================================================
# VERIFY EXE
# ============================================================

if (-not (Test-Path -LiteralPath $RustDeskExe)) {
    Fail "RustDesk executable was not installed."
}

Write-Log "RustDesk executable verified."

# ============================================================
# INSTALL SERVICE
# ============================================================

Write-Log "Installing RustDesk service."

try {

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -PassThru

    Write-Log "Service installer PID=$($serviceProcess.Id)"

    $serviceFound = $false

    # --------------------------------------------------------
    # WAIT UP TO 30 SECONDS
    # --------------------------------------------------------

    for ($i = 0; $i -lt 30; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($null -ne $service) {

            $serviceFound = $true

            Write-Log "RustDesk service created."

            break
        }

        Start-Sleep -Seconds 1
    }

    # RustDesk may keep this process alive.
    if (-not $serviceProcess.HasExited) {

        Write-Log "Service installer process still running."

        Stop-Process `
            -Id $serviceProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

    if (-not $serviceFound) {
        Fail "RustDesk service was not created."
    }
}
catch {

    Write-Log "Service installation exception."
    Write-Log $_.Exception.ToString()

    Fail "RustDesk service installation failed."
}

# ============================================================
# SERVICE AUTOSTART
# ============================================================

Write-Log "Configuring RustDesk service autostart."

try {

    Set-Service `
        -Name $ServiceName `
        -StartupType Automatic `
        -ErrorAction Stop

}
catch {

    Write-Log "Set-Service failed. Trying sc.exe."

    $scOutput = & sc.exe config $ServiceName start= auto 2>&1

    foreach ($line in $scOutput) {
        Write-Log "SC: $line"
    }

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not configure RustDesk service autostart."
    }
}

# ============================================================
# START SERVICE
# ============================================================

Write-Log "Starting RustDesk service."

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Fail "RustDesk service does not exist."
}

if ($service.Status -ne "Running") {

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop
    }
    catch {

        Write-Log "Start-Service failed."
        Write-Log $_.Exception.Message
    }
}

$running = $false

for ($i = 0; $i -lt 30; $i++) {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        if ($service.Status -eq "Running") {

            $running = $true
            break
        }
    }

    Start-Sleep -Seconds 1
}

if (-not $running) {
    Fail "RustDesk service did not start."
}

Write-Log "RustDesk service is running."

# ============================================================
# CONFIG
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($RustDeskConfig)) {

    Write-Log "Applying RustDesk configuration."

    try {

        $configProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--config"
                $RustDeskConfig
            ) `
            -PassThru `
            -Wait

        Write-Log "Config exit code=$($configProcess.ExitCode)"

        if ($configProcess.ExitCode -ne 0) {
            Write-Log "WARNING: RustDesk config returned non-zero exit code."
        }
    }
    catch {

        Write-Log "Config exception."
        Write-Log $_.Exception.ToString()
    }
}

# ============================================================
# PASSWORD
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    Write-Log "Applying RustDesk password."

    try {

        $passwordProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--password"
                $RustDeskPassword
            ) `
            -PassThru `
            -Wait

        Write-Log "Password exit code=$($passwordProcess.ExitCode)"

        if ($passwordProcess.ExitCode -ne 0) {
            Write-Log "WARNING: RustDesk password returned non-zero exit code."
        }
    }
    catch {

        Write-Log "Password exception."
        Write-Log $_.Exception.ToString()
    }
}

# ============================================================
# FINAL VERIFICATION
# ============================================================

Write-Log "Performing final verification."

if (-not (Test-Path -LiteralPath $RustDeskExe)) {
    Fail "RustDesk executable is missing."
}

$finalService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $finalService) {
    Fail "RustDesk service is missing."
}

if ($finalService.Status -ne "Running") {
    Fail "RustDesk service is not running."
}

Write-Log "RustDesk installation completed successfully."
Write-Log "Final service status=$($finalService.Status)"

# ============================================================
# SUCCESS
# ============================================================

Write-Output "RustDesk installed successfully."

exit 0