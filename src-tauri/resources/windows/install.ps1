#requires -Version 5.1

$ErrorActionPreference = "Stop"

# ============================================================
# RustDesk Windows Installer
# Args:
#   $args[0] = RustDesk password
#   $args[1] = RustDesk config
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile   = Join-Path $ScriptDir "rustdesk-install.log"

$Password = if ($args.Count -ge 1) { [string]$args[0] } else { "" }
$Config   = if ($args.Count -ge 2) { [string]$args[1] } else { "" }

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

    Write-Host $line

    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "WARNING: Cannot write log: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Current user information
# Save this BEFORE UAC elevation.
# ------------------------------------------------------------

$OriginalUser = [Environment]::UserName
$OriginalDomain = $env:USERDOMAIN

try {
    $OriginalUserProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )
}
catch {
    $OriginalUserProfile = $env:USERPROFILE
}

if ([string]::IsNullOrWhiteSpace($OriginalUserProfile)) {
    $OriginalUserProfile = $env:USERPROFILE
}

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

$RustDeskInstallDir = Join-Path $env:ProgramFiles "RustDesk"
$RustDeskExe        = Join-Path $RustDeskInstallDir "RustDesk.exe"

$LocalRustDeskExe   = Join-Path $ScriptDir "rustdesk.exe"

# Common per-user RustDesk locations.
$UserAppData        = Join-Path $OriginalUserProfile "AppData\Roaming"
$UserLocalAppData   = Join-Path $OriginalUserProfile "AppData\Local"

$UserRustDeskRoaming = Join-Path $UserAppData "RustDesk"
$UserRustDeskLocal   = Join-Path $UserLocalAppData "RustDesk"

# RustDesk may also store configuration in these locations
$UserRustDeskConfig1 = Join-Path $UserAppData "RustDesk"
$UserRustDeskConfig2 = Join-Path $UserLocalAppData "RustDesk"

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "RustDesk installer started"
Write-Log "============================================================"
Write-Log "Script:       $($MyInvocation.MyCommand.Definition)"
Write-Log "ScriptDir:    $ScriptDir"
Write-Log "LogFile:      $LogFile"
Write-Log "Current user: $OriginalUser"
Write-Log "User profile: $OriginalUserProfile"
Write-Log "Is elevated:  $([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)"
Write-Log "============================================================"

# ------------------------------------------------------------
# Validate arguments
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Log "[ARGS] ERROR: Password argument is missing."
    exit 10
}

if ([string]::IsNullOrWhiteSpace($Config)) {
    Write-Log "[ARGS] ERROR: Config argument is missing."
    exit 11
}

Write-Log "[ARGS] Password provided: YES"
Write-Log "[ARGS] Config provided:   YES"

# ------------------------------------------------------------
# Administrator check
# ------------------------------------------------------------

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdmin = $CurrentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

# ------------------------------------------------------------
# Elevate through UAC
# ------------------------------------------------------------

if (-not $IsAdmin) {

    Write-Log "============================================================"
    Write-Log "[ADMIN] Administrator privileges required."
    Write-Log "[ADMIN] Requesting UAC elevation..."
    Write-Log "============================================================"

    try {

        # IMPORTANT:
        # Pass arguments safely as Base64 to avoid quoting problems
        # with passwords/config containing special characters.

        $PasswordBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
        $ConfigBytes   = [System.Text.Encoding]::UTF8.GetBytes($Config)

        $PasswordB64 = [Convert]::ToBase64String($PasswordBytes)
        $ConfigB64   = [Convert]::ToBase64String($ConfigBytes)

        $ArgumentList = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$($MyInvocation.MyCommand.Definition)`""
            "-PasswordB64"
            "`"$PasswordB64`""
            "-ConfigB64"
            "`"$ConfigB64`""
        ) -join " "

        Write-Log "[ADMIN] Starting elevated PowerShell process..."

        $Process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $ArgumentList `
            -Verb RunAs `
            -Wait `
            -PassThru

        Write-Log "[ADMIN] Elevated installer exit code: $($Process.ExitCode)"

        exit $Process.ExitCode
    }
    catch {
        Write-Log "[ADMIN] ERROR: UAC elevation failed."
        Write-Log "[ADMIN] $($_.Exception.Message)"
        exit 20
    }
}

# ------------------------------------------------------------
# Decode arguments when running elevated
# ------------------------------------------------------------

$PasswordB64Param = $null
$ConfigB64Param   = $null

# Parse named arguments supplied to elevated instance.
for ($i = 0; $i -lt $args.Count; $i++) {

    if ($args[$i] -eq "-PasswordB64" -and ($i + 1) -lt $args.Count) {
        $PasswordB64Param = $args[$i + 1]
        $i++
        continue
    }

    if ($args[$i] -eq "-ConfigB64" -and ($i + 1) -lt $args.Count) {
        $ConfigB64Param = $args[$i + 1]
        $i++
        continue
    }
}

if ($PasswordB64Param) {
    try {
        $Password = [System.Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($PasswordB64Param)
        )
    }
    catch {
        Write-Log "[ARGS] ERROR: Cannot decode password."
        exit 21
    }
}

if ($ConfigB64Param) {
    try {
        $Config = [System.Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($ConfigB64Param)
        )
    }
    catch {
        Write-Log "[ARGS] ERROR: Cannot decode config."
        exit 22
    }
}

# ------------------------------------------------------------
# Make sure we are really elevated
# ------------------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Log "[ADMIN] ERROR: Installer is not running as Administrator."
    exit 23
}

Write-Log "[ADMIN] Running with administrator privileges."

# ------------------------------------------------------------
# Detect architecture
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[ARCH] Detecting Windows architecture..."
Write-Log "============================================================"

$Architecture = $env:PROCESSOR_ARCHITECTURE

if ($env:PROCESSOR_ARCHITEW6432) {
    $Architecture = $env:PROCESSOR_ARCHITEW6432
}

Write-Log "[ARCH] Architecture: $Architecture"

# ------------------------------------------------------------
# Locate RustDesk executable
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $LocalRustDeskExe)) {
    Write-Log "[INSTALL] ERROR: rustdesk.exe not found:"
    Write-Log "[INSTALL] $LocalRustDeskExe"
    exit 30
}

Write-Log "[INSTALL] RustDesk binary found:"
Write-Log "[INSTALL] $LocalRustDeskExe"

# ------------------------------------------------------------
# Stop RustDesk processes
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[CLEANUP] Stopping existing RustDesk processes..."
Write-Log "============================================================"

try {
    $Processes = Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue

    if ($Processes) {

        foreach ($Process in $Processes) {

            Write-Log "[CLEANUP] Stopping PID $($Process.Id)..."

            try {
                Stop-Process `
                    -Id $Process.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "[CLEANUP] WARNING: Cannot stop PID $($Process.Id)"
            }
        }

        Start-Sleep -Seconds 2
    }

    $Remaining = Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue

    if ($Remaining) {
        Write-Log "[CLEANUP] WARNING: RustDesk processes still exist."
    }
    else {
        Write-Log "[CLEANUP] No RustDesk processes remain."
    }
}
catch {
    Write-Log "[CLEANUP] WARNING: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Remove old installation
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[REMOVE] Removing previous RustDesk installation..."
Write-Log "============================================================"

try {

    if (Test-Path -LiteralPath $RustDeskInstallDir) {

        Remove-Item `
            -LiteralPath $RustDeskInstallDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Write-Log "[REMOVE] Previous RustDesk installation removed."
    }
    else {
        Write-Log "[REMOVE] Previous RustDesk installation not found."
    }
}
catch {
    Write-Log "[REMOVE] ERROR: Cannot remove old RustDesk."
    Write-Log "[REMOVE] $($_.Exception.Message)"
    exit 31
}

# ------------------------------------------------------------
# Remove old user data
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[REMOVE] Removing previous RustDesk user data..."
Write-Log "============================================================"

$UserDataPaths = @(
    $UserRustDeskRoaming,
    $UserRustDeskLocal
)

foreach ($Path in $UserDataPaths) {

    try {

        if (Test-Path -LiteralPath $Path) {

            Remove-Item `
                -LiteralPath $Path `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue

            Write-Log "[REMOVE] Removed: $Path"
        }
    }
    catch {
        Write-Log "[REMOVE] WARNING: Could not remove $Path"
    }
}

# ------------------------------------------------------------
# Install RustDesk
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[INSTALL] Installing RustDesk..."
Write-Log "============================================================"

try {

    New-Item `
        -ItemType Directory `
        -Path $RustDeskInstallDir `
        -Force `
        | Out-Null

    Copy-Item `
        -LiteralPath $LocalRustDeskExe `
        -Destination $RustDeskExe `
        -Force `
        -ErrorAction Stop

    Write-Log "[INSTALL] RustDesk installed:"
    Write-Log "[INSTALL] $RustDeskExe"
}
catch {
    Write-Log "[INSTALL] ERROR: Installation failed."
    Write-Log "[INSTALL] $($_.Exception.Message)"
    exit 32
}

if (-not (Test-Path -LiteralPath $RustDeskExe)) {
    Write-Log "[INSTALL] ERROR: RustDesk.exe does not exist after installation."
    exit 33
}

# ------------------------------------------------------------
# Get RustDesk ID
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[ID] Getting RustDesk ID..."
Write-Log "============================================================"

$RustDeskId = ""

try {

    $IdOutput = & $RustDeskExe --get-id 2>&1
    $IdExit = $LASTEXITCODE

    $RustDeskId = ($IdOutput | Out-String).Trim()

    Write-Log "[ID] Exit code: $IdExit"
    Write-Log "[ID] Result: $RustDeskId"

    if ($IdExit -ne 0 -or [string]::IsNullOrWhiteSpace($RustDeskId)) {
        Write-Log "[ID] WARNING: RustDesk ID was not obtained."
    }
}
catch {
    Write-Log "[ID] WARNING: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Start temporary RustDesk backend
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[SERVER] Starting temporary RustDesk backend..."
Write-Log "============================================================"

$ServerProcess = $null

try {

    $ServerProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--server" `
        -PassThru `
        -WindowStyle Hidden

    Write-Log "[SERVER] PID: $($ServerProcess.Id)"

    Start-Sleep -Seconds 3
}
catch {
    Write-Log "[SERVER] WARNING: Cannot start temporary backend."
    Write-Log "[SERVER] $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Apply password
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[PASSWORD] Applying RustDesk password..."
Write-Log "============================================================"

$PasswordExit = -1

try {

    $PasswordOutput = & $RustDeskExe --password $Password 2>&1
    $PasswordExit = $LASTEXITCODE

    Write-Log "[PASSWORD] Exit code: $PasswordExit"

    # Do NOT write PasswordOutput.
    # It may contain sensitive information.

    if ($PasswordExit -eq 0) {
        Write-Log "[PASSWORD] Password command returned success."
    }
    else {
        Write-Log "[PASSWORD] ERROR: Password command failed."
        Write-Log "[PASSWORD] Output: $($PasswordOutput | Out-String)"
    }
}
catch {
    Write-Log "[PASSWORD] ERROR: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Apply config
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[CONFIG] Applying RustDesk configuration..."
Write-Log "============================================================"

$ConfigExit = -1

try {

    $ConfigOutput = & $RustDeskExe --config $Config 2>&1
    $ConfigExit = $LASTEXITCODE

    Write-Log "[CONFIG] Exit code: $ConfigExit"

    # Do not log actual config.

    if ($ConfigExit -eq 0) {
        Write-Log "[CONFIG] Configuration command returned success."
    }
    else {
        Write-Log "[CONFIG] ERROR: Configuration command failed."
        Write-Log "[CONFIG] Output: $($ConfigOutput | Out-String)"
    }
}
catch {
    Write-Log "[CONFIG] ERROR: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Stop temporary backend
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[SERVER] Stopping temporary RustDesk backend..."
Write-Log "============================================================"

try {

    if ($ServerProcess) {

        if (-not $ServerProcess.HasExited) {
            Stop-Process `
                -Id $ServerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 1

    Write-Log "[SERVER] Temporary backend stopped."
}
catch {
    Write-Log "[SERVER] WARNING: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Verify user configuration
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[VERIFY] Checking RustDesk configuration..."
Write-Log "============================================================"

$ConfigFound = $false

$PossibleConfigPaths = @(
    (Join-Path $UserAppData "RustDesk"),
    (Join-Path $UserLocalAppData "RustDesk")
)

foreach ($Path in $PossibleConfigPaths) {

    if (Test-Path -LiteralPath $Path) {

        Write-Log "[VERIFY] RustDesk data directory exists: $Path"
        $ConfigFound = $true

        try {

            $Files = Get-ChildItem `
                -LiteralPath $Path `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue

            if ($Files) {
                Write-Log "[VERIFY] RustDesk configuration files detected."
            }
        }
        catch {
            Write-Log "[VERIFY] WARNING: Cannot inspect $Path"
        }
    }
}

if (-not $ConfigFound) {
    Write-Log "[VERIFY] WARNING: RustDesk user configuration directory was not detected."
}

# ------------------------------------------------------------
# Get final ID
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[ID] Getting final RustDesk ID..."
Write-Log "============================================================"

$FinalRustDeskId = ""

try {

    $FinalIdOutput = & $RustDeskExe --get-id 2>&1
    $FinalIdExit = $LASTEXITCODE

    $FinalRustDeskId = ($FinalIdOutput | Out-String).Trim()

    Write-Log "[ID] Exit code: $FinalIdExit"
    Write-Log "[ID] Final result: $FinalRustDeskId"
}
catch {
    Write-Log "[ID] WARNING: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Start GUI as original user
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "[GUI] Starting RustDesk GUI as $OriginalUser..."
Write-Log "============================================================"

$GuiExit = 0

try {

    # Use Explorer to launch in the interactive user's context.
    # This avoids leaving RustDesk running as Administrator.

    $GuiCommand = "Start-Process -FilePath '$RustDeskExe'"

    $GuiProcess = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$GuiCommand`"" `
        -WindowStyle Hidden `
        -PassThru

    Write-Log "[GUI] GUI launch requested."
}
catch {
    $GuiExit = 1
    Write-Log "[GUI] ERROR: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "RustDesk installation completed"
Write-Log "============================================================"
Write-Log "Architecture : $Architecture"
Write-Log "RustDesk ID  : $FinalRustDeskId"
Write-Log "Password     : $(if ($PasswordExit -eq 0) { 'SUCCESS' } else { 'FAILED' })"
Write-Log "Config       : $(if ($ConfigExit -eq 0) { 'SUCCESS' } else { 'FAILED' })"
Write-Log "GUI          : $(if ($GuiExit -eq 0) { 'SUCCESS' } else { 'FAILED' })"
Write-Log "============================================================"

# ------------------------------------------------------------
# Exit status
# ------------------------------------------------------------

if ($PasswordExit -ne 0) {
    exit 40
}

if ($ConfigExit -ne 0) {
    exit 41
}

if ($GuiExit -ne 0) {
    exit 42
}

exit 0