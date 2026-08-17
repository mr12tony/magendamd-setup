param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter(Position = 1)]
    [string]$RustDeskConfig,

    [Parameter()]
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptPath = $PSCommandPath
$ScriptDir  = Split-Path -Parent $ScriptPath

$LogFile = Join-Path $ScriptDir "rustdesk-install.log"

$RustDeskX64 = Join-Path $ScriptDir "rustdesk-x86_64.exe"
$RustDeskArm = Join-Path $ScriptDir "rustdesk-aarch64.exe"

$RustDeskExe = Join-Path ${env:ProgramFiles} "RustDesk\rustdesk.exe"

$ServiceName = "Rustdesk"

# ============================================================
# LOG
# ============================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

    try {
        Add-Content `
            -LiteralPath $LogFile `
            -Value $line `
            -Encoding UTF8
    }
    catch {
    }

    Write-Output $line
}

function Write-Section {
    param(
        [string]$Name
    )

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
Write-Log "RustDesk target version: 1.4.9"
Write-Log "Script:       $ScriptPath"
Write-Log "ScriptDir:    $ScriptDir"
Write-Log "LogFile:      $LogFile"
Write-Log "Current user: $env:USERNAME"
Write-Log "User profile: $env:USERPROFILE"
Write-Log "Is elevated:  $(Test-Administrator)"
Write-Log "Elevated flag: $Elevated"

# ============================================================
# ARGUMENTS
# ============================================================

Write-Section "ARGS"

if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {
    Write-Log "Password provided: NO"
}
else {
    Write-Log "Password provided: YES"
}

if ([string]::IsNullOrWhiteSpace($RustDeskConfig)) {
    Write-Log "Config provided:   NO"
}
else {
    Write-Log "Config provided:   YES"
    Write-Log "Config length:     $($RustDeskConfig.Length)"
}

# ============================================================
# ELEVATION
# ============================================================

if (-not (Test-Administrator)) {

    Write-Section "ADMIN"

    Write-Log "PowerShell is not running as Administrator."
    Write-Log "Requesting Administrator privileges through UAC..."

    try {

        # ----------------------------------------------------
        # IMPORTANT:
        #
        # Формируем PowerShell-команду для elevated процесса.
        #
        # Json используется только для корректного quoting
        # строк password/config.
        # ----------------------------------------------------

        $passwordLiteral = ConvertTo-Json $RustDeskPassword -Compress
        $configLiteral   = ConvertTo-Json $RustDeskConfig -Compress
        $scriptLiteral   = ConvertTo-Json $ScriptPath -Compress

        $elevatedCommand = @"
`$ErrorActionPreference = 'Stop'

& $scriptLiteral `
    -RustDeskPassword $passwordLiteral `
    -RustDeskConfig $configLiteral `
    -Elevated

exit `$LASTEXITCODE
"@

        # PowerShell -EncodedCommand использует UTF-16LE
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($elevatedCommand)

        $encodedCommand = [Convert]::ToBase64String($bytes)

        Write-Log "Elevation command created."
        Write-Log "Encoded command length: $($encodedCommand.Length)"

        # ----------------------------------------------------
        # START ELEVATED POWERSHELL
        # ----------------------------------------------------

        Write-Log "Starting elevated PowerShell..."

        $elevatedProcess = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList @(
                "-NoProfile"
                "-ExecutionPolicy"
                "Bypass"
                "-EncodedCommand"
                $encodedCommand
            ) `
            -WorkingDirectory $ScriptDir `
            -PassThru

        if ($null -eq $elevatedProcess) {

            Write-Log "ERROR: Failed to start elevated PowerShell."

            exit 1
        }

        Write-Log "Elevated PowerShell started."
        Write-Log "Elevated PID: $($elevatedProcess.Id)"

        # ----------------------------------------------------
        # WAIT
        # ----------------------------------------------------

        Write-Log "Waiting for elevated PowerShell..."

        $elevatedProcess.WaitForExit()

        $elevatedExitCode = $elevatedProcess.ExitCode

        Write-Log "Elevated PowerShell finished."
        Write-Log "Elevated process exit code: $elevatedExitCode"

        if ($elevatedExitCode -eq 0) {

            Write-Log "Elevated installation completed successfully."

            exit 0
        }
        else {

            Write-Log "ERROR: Elevated installation failed."

            exit $elevatedExitCode
        }
    }
    catch {

        Write-Log "ERROR during UAC elevation:"
        Write-Log $_.Exception.Message

        exit 1
    }
}

# ============================================================
# ADMIN CONFIRMATION
# ============================================================

Write-Section "ADMIN"

if (-not (Test-Administrator)) {

    Write-Log "ERROR: PowerShell must run as Administrator."

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

Write-Log "Selected installer: $(Split-Path $selectedInstaller -Leaf)"
Write-Log "Installer path: $selectedInstaller"

# ============================================================
# CHECK INSTALLER
# ============================================================

if (-not (Test-Path -LiteralPath $selectedInstaller)) {

    Write-Log "ERROR: Installer not found:"
    Write-Log $selectedInstaller

    exit 1
}

$installerFile = Get-Item -LiteralPath $selectedInstaller

Write-Log "Installer found."
Write-Log "Size: $([math]::Round($installerFile.Length / 1MB, 2)) MB"

# ============================================================
# CLEANUP
# ============================================================

Write-Section "CLEANUP"

Write-Log "Stopping RustDesk processes..."

Get-Process `
    -Name "rustdesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

Write-Log "RustDesk processes stopped."

# ============================================================
# REMOVE OLD SERVICE
# ============================================================

Write-Log "Checking RustDesk service..."

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Log "RustDesk service found."
    Write-Log "Current status: $($service.Status)"

    if ($service.Status -eq "Running") {

        Write-Log "Stopping RustDesk service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }

    Write-Log "Removing RustDesk service..."

    & sc.exe delete $ServiceName 2>&1 |
        ForEach-Object {
            Write-Log "SC DELETE: $_"
        }

    Start-Sleep -Seconds 3
}
else {

    Write-Log "RustDesk service not found."
}

# ============================================================
# REMOVE OLD PROGRAM FILES
# ============================================================

$oldInstallDir = Join-Path ${env:ProgramFiles} "RustDesk"

Write-Log "Removing old RustDesk installation..."

if (Test-Path -LiteralPath $oldInstallDir) {

    try {

        Remove-Item `
            -LiteralPath $oldInstallDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Write-Log "Program Files RustDesk removed."
    }
    catch {

        Write-Log "WARNING: Could not completely remove old installation."
        Write-Log $_.Exception.Message
    }
}
else {

    Write-Log "Old RustDesk installation not found."
}

# ============================================================
# REMOVE USER DATA
# ============================================================

$userRoaming = Join-Path $env:APPDATA "RustDesk"
$userLocal   = Join-Path $env:LOCALAPPDATA "RustDesk"

if (Test-Path -LiteralPath $userRoaming) {

    Write-Log "Removing user APPDATA RustDesk..."

    Remove-Item `
        -LiteralPath $userRoaming `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $userLocal) {

    Write-Log "Removing user LOCALAPPDATA RustDesk..."

    Remove-Item `
        -LiteralPath $userLocal `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

$localServiceData = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"

if (Test-Path -LiteralPath $localServiceData) {

    Write-Log "Removing LocalService RustDesk data..."

    Remove-Item `
        -LiteralPath $localServiceData `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Log "Cleanup completed."

# ============================================================
# INSTALL
# ============================================================

Write-Section "INSTALL"

Write-Log "RustDesk installer: $selectedInstaller"
Write-Log "Running RustDesk silent installer..."

try {

    $installerProcess = Start-Process `
        -FilePath $selectedInstaller `
        -ArgumentList "--silent-install" `
        -PassThru

    Write-Log "Installer process started."
    Write-Log "PID: $($installerProcess.Id)"

    # --------------------------------------------------------
    # WAIT FOR INSTALLED EXE
    # --------------------------------------------------------

    $found = $false

    for ($i = 0; $i -lt 60; $i++) {

        if (Test-Path -LiteralPath $RustDeskExe) {

            $found = $true

            Write-Log "rustdesk.exe detected."
            Write-Log "Path: $RustDeskExe"

            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $found) {

        Write-Log "ERROR: RustDesk executable was not detected."

        if (-not $installerProcess.HasExited) {

            Stop-Process `
                -Id $installerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }

        exit 1
    }

    # --------------------------------------------------------
    # WAIT INSTALLER
    # --------------------------------------------------------

    if (-not $installerProcess.HasExited) {

        Write-Log "Waiting for installer process to finish..."

        $installerProcess.WaitForExit(30000)
    }

    if ($installerProcess.HasExited) {

        Write-Log "Installer process exited with code: $($installerProcess.ExitCode)"
    }
    else {

        Write-Log "WARNING: Installer process is still running."

        Stop-Process `
            -Id $installerProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Log "RustDesk installation completed."
}
catch {

    Write-Log "ERROR during RustDesk installation:"
    Write-Log $_.Exception.Message

    exit 1
}

# ============================================================
# VERIFY
# ============================================================

Write-Section "VERIFY"

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Log "ERROR: RustDesk executable not found."

    exit 1
}

$installedFile = Get-Item -LiteralPath $RustDeskExe

Write-Log "Executable: $RustDeskExe"
Write-Log "Size: $([math]::Round($installedFile.Length / 1MB, 2)) MB"

try {

    $version = $installedFile.VersionInfo

    Write-Log "Product version: $($version.ProductVersion)"
    Write-Log "File version:    $($version.FileVersion)"
}
catch {

    Write-Log "WARNING: Could not read version."
}

# ============================================================
# SERVICE INSTALL
# ============================================================

Write-Section "SERVICE"

Write-Log "Installing RustDesk service..."

try {

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -PassThru

    Write-Log "Service installation process started."
    Write-Log "PID: $($serviceProcess.Id)"

    $serviceFound = $false

    for ($i = 0; $i -lt 20; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($null -ne $service) {

            $serviceFound = $true

            Write-Log "RustDesk service found."
            Write-Log "Display name: $($service.DisplayName)"
            Write-Log "Status: $($service.Status)"

            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $serviceProcess.HasExited) {

        Write-Log "Service installation process is still running."

        Stop-Process `
            -Id $serviceProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Log "Service installation process stopped."
    }

    if (-not $serviceFound) {

        Write-Log "ERROR: RustDesk service was not created."

        exit 1
    }
}
catch {

    Write-Log "ERROR installing RustDesk service:"
    Write-Log $_.Exception.Message

    exit 1
}

# ============================================================
# SERVICE AUTOSTART
# ============================================================

Write-Section "SERVICE AUTOSTART"

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Log "ERROR: RustDesk service does not exist."

    exit 1
}

Write-Log "Configuring RustDesk service for automatic startup..."

try {

    Set-Service `
        -Name $ServiceName `
        -StartupType Automatic `
        -ErrorAction Stop

    Write-Log "RustDesk service StartupType set to Automatic."
}
catch {

    Write-Log "WARNING: Set-Service failed."
    Write-Log $_.Exception.Message

    try {

        & sc.exe config $ServiceName start= auto 2>&1 |
            ForEach-Object {
                Write-Log "SC CONFIG: $_"
            }

        Write-Log "RustDesk service configured using sc.exe."
    }
    catch {

        Write-Log "ERROR: Could not configure RustDesk service autostart."

        exit 1
    }
}

# ============================================================
# VERIFY SERVICE AUTOSTART
# ============================================================

Write-Log "Verifying RustDesk service configuration..."

$serviceInfo = & sc.exe qc $ServiceName 2>&1

$serviceInfo |
    ForEach-Object {
        Write-Log "SC QC: $_"
    }

$autoStartConfirmed = $false

foreach ($line in $serviceInfo) {

    if ($line -match "START_TYPE.*AUTO_START") {

        $autoStartConfirmed = $true
        break
    }
}

if ($autoStartConfirmed) {

    Write-Log "RustDesk service AUTOSTART: CONFIRMED."
}
else {

    Write-Log "ERROR: RustDesk service AUTOSTART was not confirmed."

    exit 1
}

# ============================================================
# START SERVICE
# ============================================================

Write-Section "SERVICE START"

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Log "ERROR: RustDesk service does not exist."

    exit 1
}

Write-Log "Current status: $($service.Status)"

if ($service.Status -ne "Running") {

    Write-Log "Starting RustDesk service..."

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop

        Write-Log "Start-Service command completed."
    }
    catch {

        Write-Log "WARNING: Start-Service failed."
        Write-Log $_.Exception.Message
    }
}

$running = $false

for ($i = 0; $i -lt 15; $i++) {

    Start-Sleep -Seconds 1

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        Write-Log "Service status: $($service.Status)"

        if ($service.Status -eq "Running") {

            $running = $true
            break
        }
    }
}

if ($running) {

    Write-Log "RustDesk service is running."
}
else {

    Write-Log "WARNING: RustDesk service is not running."
}

# ============================================================
# CONFIG
# ============================================================

Write-Section "CONFIG"

if (-not [string]::IsNullOrWhiteSpace($RustDeskConfig)) {

    Write-Log "Applying RustDesk configuration..."

    try {

        $configProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--config"
                $RustDeskConfig
            ) `
            -PassThru `
            -Wait

        Write-Log "RustDesk --config exit code: $($configProcess.ExitCode)"

        if ($configProcess.ExitCode -eq 0) {

            Write-Log "RustDesk configuration applied."
        }
        else {

            Write-Log "WARNING: Configuration returned non-zero exit code."
        }
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
# PASSWORD
# ============================================================

Write-Section "PASSWORD"

if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    Write-Log "Applying RustDesk permanent password..."

    try {

        $passwordProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--password"
                $RustDeskPassword
            ) `
            -PassThru `
            -Wait

        Write-Log "RustDesk --password exit code: $($passwordProcess.ExitCode)"

        if ($passwordProcess.ExitCode -eq 0) {

            Write-Log "RustDesk password applied."
        }
        else {

            Write-Log "WARNING: Password command returned non-zero exit code."
        }
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
# FINAL
# ============================================================

Write-Section "FINAL"

$finalService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $finalService) {

    Write-Log "Final service status: $($finalService.Status)"
}
else {

    Write-Log "WARNING: RustDesk service not found."
}

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Log "ERROR: RustDesk executable is missing."

    exit 1
}

Write-Log "RustDesk executable verified."
Write-Log "Installation completed successfully."

Write-Section "END"

exit 0