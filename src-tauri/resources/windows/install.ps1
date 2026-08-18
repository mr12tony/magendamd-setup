#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$Password
)

$ErrorActionPreference = "Stop"

# ==========================================================
# CONFIG
# ==========================================================

$RendezvousServer = "rustdesk.magendamd.com"
$RelayServer      = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# PATHS
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$InstallDir = Join-Path $env:ProgramFiles "RustDesk"

$RustDeskExe = Join-Path $InstallDir "RustDesk.exe"

$ProgramDataRustDesk = Join-Path $env:ProgramData "RustDesk"

$ConfigDir = Join-Path $ProgramDataRustDesk "config"

$ConfigFile = Join-Path $ConfigDir "RustDesk2.toml"

$InstallLog = Join-Path $env:TEMP "rustdesk-install.log"

# ==========================================================
# LOGGING
# ==========================================================

function Log {
    param(
        [string]$Message
    )

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $Line

    try {
        Add-Content -Path $InstallLog -Value $Line -ErrorAction SilentlyContinue
    }
    catch {
    }
}

function Fail {
    param(
        [string]$Message
    )

    Log "ERROR: $Message"

    Write-Host ""
    Write-Host "========================================"
    Write-Host "INSTALLATION FAILED"
    Write-Host "========================================"
    Write-Host ""
    Write-Host $Message
    Write-Host ""
    Write-Host "Log:"
    Write-Host $InstallLog
    Write-Host ""

    exit 1
}

# ==========================================================
# TEST ADMIN
# ==========================================================

function Test-IsAdministrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ==========================================================
# UAC ELEVATION
# ==========================================================

if (-not (Test-IsAdministrator)) {

    Write-Host "Administrator privileges are required."
    Write-Host "Requesting UAC..."

    try {

        # Pass the password as a Base64 UTF8 string.
        # This avoids quoting problems with passwords containing
        # spaces, $, !, &, quotes, etc.

        $PasswordBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)

        $EncodedPassword = [Convert]::ToBase64String(
            $PasswordBytes
        )

        $Arguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
            "-PasswordBase64"
            "`"$EncodedPassword`""
        )

        # Re-launch ourselves elevated.

        $Process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $Arguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        Write-Host "Elevated PowerShell finished."
        Write-Host "Exit code: $($Process.ExitCode)"

        exit $Process.ExitCode
    }
    catch {

        Write-Host ""
        Write-Host "ERROR: UAC elevation failed."
        Write-Host $_.Exception.Message

        exit 1
    }
}

# ==========================================================
# PASSWORD BASE64 SUPPORT
# ==========================================================

# The elevated process may receive -PasswordBase64.
#
# Because param() above requires Password, we handle the
# command line manually if the Base64 form was supplied.

$RawCommandLine = [Environment]::CommandLine

if ($RawCommandLine -match '-PasswordBase64\s+"([^"]+)"') {

    try {

        $EncodedPassword = $Matches[1]

        $PasswordBytes = [Convert]::FromBase64String(
            $EncodedPassword
        )

        $Password = [System.Text.Encoding]::UTF8.GetString(
            $PasswordBytes
        )
    }
    catch {

        Fail "Unable to decode elevated password."
    }
}

if ([string]::IsNullOrWhiteSpace($Password)) {

    Fail "RustDesk password is empty."
}

# ==========================================================
# ADMIN PHASE
# ==========================================================

Log "========================================"
Log "RustDesk Windows installer"
Log "========================================"

Log "Running as administrator: YES"

# ==========================================================
# USER
# ==========================================================

$WindowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$WindowsUser = $WindowsIdentity.Name

$UserProfile = $env:USERPROFILE

Log "Windows identity: $WindowsUser"
Log "User profile: $UserProfile"

# ==========================================================
# ARCHITECTURE
# ==========================================================

$Architecture = $env:PROCESSOR_ARCHITECTURE

if ($env:PROCESSOR_ARCHITEW6432) {
    $Architecture = $env:PROCESSOR_ARCHITEW6432
}

switch ($Architecture.ToUpperInvariant()) {

    "AMD64" {

        $BundledExe = Join-Path `
            $ScriptDir `
            "rustdesk-x86_64.exe"
    }

    "ARM64" {

        $BundledExe = Join-Path `
            $ScriptDir `
            "rustdesk-aarch64.exe"
    }

    default {

        Fail "Unsupported Windows architecture: $Architecture"
    }
}

Log "Architecture: $Architecture"

Log "RustDesk binary: $BundledExe"

if (-not (Test-Path $BundledExe)) {

    Fail "RustDesk binary not found: $BundledExe"
}

# ==========================================================
# CONFIG PATH
# ==========================================================

Log "Config directory: $ConfigDir"
Log "Config file: $ConfigFile"

# ==========================================================
# STOP RUSTDESK PROCESS
# ==========================================================

Log "Stopping RustDesk..."

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ==========================================================
# STOP EXISTING SERVICES
# ==========================================================

Log "Stopping RustDesk services..."

$ServiceNames = @(
    "RustDesk",
    "RustDeskService"
)

foreach ($ServiceName in $ServiceNames) {

    $Service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $Service) {

        Log "Stopping service: $ServiceName"

        try {

            Stop-Service `
                -Name $ServiceName `
                -Force `
                -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD SERVICES
# ==========================================================

Log "Removing old RustDesk services..."

foreach ($ServiceName in $ServiceNames) {

    try {

        & sc.exe delete $ServiceName *> $null

    }
    catch {
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD INSTALLATION
# ==========================================================

Log "Removing old RustDesk installation..."

if (Test-Path $InstallDir) {

    try {

        Remove-Item `
            -Path $InstallDir `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
    catch {

        Fail "Unable to remove old RustDesk installation: $($_.Exception.Message)"
    }
}

# ==========================================================
# REMOVE OLD PROGRAMDATA CONFIG
# ==========================================================

Log "Removing old RustDesk configuration..."

if (Test-Path $ProgramDataRustDesk) {

    Remove-Item `
        -Path $ProgramDataRustDesk `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

# ==========================================================
# CREATE INSTALL DIRECTORY
# ==========================================================

Log "Creating RustDesk installation directory..."

New-Item `
    -ItemType Directory `
    -Path $InstallDir `
    -Force |
    Out-Null

# ==========================================================
# INSTALL EXE
# ==========================================================

Log "Installing RustDesk.exe..."

Copy-Item `
    -Path $BundledExe `
    -Destination $RustDeskExe `
    -Force

if (-not (Test-Path $RustDeskExe)) {

    Fail "RustDesk.exe was not installed."
}

Log "RustDesk executable installed."

# ==========================================================
# CREATE CONFIG DIRECTORY
# ==========================================================

Log "Creating RustDesk configuration directory..."

New-Item `
    -ItemType Directory `
    -Path $ConfigDir `
    -Force |
    Out-Null

# ==========================================================
# CONFIGURATION
# ==========================================================

Log "========================================"
Log "[CONFIG]"
Log "========================================"

Log "Applying RustDesk configuration..."

$ConfigContent = @"
rendezvous_server = '$RendezvousServer:21116'
nat_type = 1
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
relay-server = '$RelayServer'
custom-rendezvous-server = '$RendezvousServer'
key = '$RustDeskKey'
"@

Set-Content `
    -Path $ConfigFile `
    -Value $ConfigContent `
    -Encoding UTF8

if (-not (Test-Path $ConfigFile)) {

    Fail "RustDesk2.toml was not created."
}

Log "RustDesk2.toml created."

# ==========================================================
# VERIFY CONFIG
# ==========================================================

$Config = Get-Content `
    -Path $ConfigFile `
    -Raw

if ($Config -notmatch "rendezvous_server = '$RendezvousServer`:21116'") {

    Fail "rendezvous_server is missing from RustDesk2.toml."
}

if ($Config -notmatch "relay-server = '$RelayServer'") {

    Fail "relay-server is missing from RustDesk2.toml."
}

if ($Config -notmatch "custom-rendezvous-server = '$RendezvousServer'") {

    Fail "custom-rendezvous-server is missing from RustDesk2.toml."
}

if ($Config -notmatch "key = '$RustDeskKey'") {

    Fail "RustDesk key is missing from RustDesk2.toml."
}

Log "RustDesk configuration verified."

# ==========================================================
# PASSWORD
# ==========================================================

Log "========================================"
Log "[PASSWORD]"
Log "========================================"

Log "Applying RustDesk permanent password..."

$PasswordOutputFile = Join-Path `
    $env:TEMP `
    "rustdesk-password-output.log"

try {

    $PasswordProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList @(
            "--password"
            $Password
        ) `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $PasswordOutputFile `
        -RedirectStandardError $PasswordOutputFile

    $PasswordExitCode = $PasswordProcess.ExitCode

}
catch {

    Fail "Unable to execute RustDesk --password: $($_.Exception.Message)"
}

Log "RustDesk --password exit code: $PasswordExitCode"

if ($PasswordExitCode -ne 0) {

    if (Test-Path $PasswordOutputFile) {

        Log "RustDesk password output:"

        Get-Content $PasswordOutputFile |
            ForEach-Object {
                Log $_
            }
    }

    Fail "RustDesk password configuration failed."
}

Log "Password applied."

# ==========================================================
# SERVICE INSTALL
# ==========================================================

Log "========================================"
Log "[SERVICE]"
Log "========================================"

Log "Installing RustDesk service..."

# RustDesk's Windows executable installs its own service.

$ServiceInstallOutput = Join-Path `
    $env:TEMP `
    "rustdesk-service-install.log"

try {

    $ServiceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $ServiceInstallOutput `
        -RedirectStandardError $ServiceInstallOutput

    Log "RustDesk service command exit code: $($ServiceProcess.ExitCode)"

}
catch {

    Fail "Unable to install RustDesk service: $($_.Exception.Message)"
}

Start-Sleep -Seconds 3

# ==========================================================
# FIND SERVICE
# ==========================================================

Log "Waiting for RustDesk service..."

$RustDeskService = $null

for ($i = 0; $i -lt 20; $i++) {

    foreach ($ServiceName in $ServiceNames) {

        $RustDeskService = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($null -ne $RustDeskService) {
            break
        }
    }

    if ($null -ne $RustDeskService) {
        break
    }

    Start-Sleep -Seconds 1
}

if ($null -eq $RustDeskService) {

    Log "Service installation output:"

    if (Test-Path $ServiceInstallOutput) {

        Get-Content $ServiceInstallOutput |
            ForEach-Object {
                Log $_
            }
    }

    Fail "RustDesk service was not found after installation."
}

Log "RustDesk service found: $($RustDeskService.Name)"

# ==========================================================
# SERVICE AUTOSTART
# ==========================================================

Log "Configuring RustDesk service for automatic startup..."

try {

    Set-Service `
        -Name $RustDeskService.Name `
        -StartupType Automatic

}
catch {

    Fail "Unable to configure RustDesk service startup: $($_.Exception.Message)"
}

Log "Service StartupType set to Automatic."

# ==========================================================
# START SERVICE
# ==========================================================

Log "Starting RustDesk service..."

try {

    Start-Service `
        -Name $RustDeskService.Name `
        -ErrorAction Stop

}
catch {

    # It may already be running.

    Log "Start-Service returned: $($_.Exception.Message)"
}

Start-Sleep -Seconds 3

$RustDeskService = Get-Service `
    -Name $RustDeskService.Name `
    -ErrorAction SilentlyContinue

if ($null -eq $RustDeskService) {

    Fail "RustDesk service disappeared."
}

Log "RustDesk service status: $($RustDeskService.Status)"

if ($RustDeskService.Status -ne "Running") {

    Log "Attempting service restart..."

    try {

        Restart-Service `
            -Name $RustDeskService.Name `
            -Force `
            -ErrorAction Stop

    }
    catch {
    }

    Start-Sleep -Seconds 3

    $RustDeskService = Get-Service `
        -Name $RustDeskService.Name `
        -ErrorAction SilentlyContinue
}

if ($RustDeskService.Status -ne "Running") {

    Fail "RustDesk service is not running."
}

Log "RustDesk service is active and running."

# ==========================================================
# START GUI
# ==========================================================

Log "========================================"
Log "[GUI]"
Log "========================================"

Log "Starting RustDesk GUI..."

try {

    Start-Process `
        -FilePath $RustDeskExe `
        -WorkingDirectory $InstallDir

    Log "RustDesk GUI started."

}
catch {

    Log "WARNING: RustDesk GUI could not be started."
    Log $_.Exception.Message
}

# ==========================================================
# GET ID
# ==========================================================

Log "========================================"
Log "[ID]"
Log "========================================"

Log "Getting RustDesk ID..."

$RustDeskId = ""

for ($i = 0; $i -lt 30; $i++) {

    try {

        $Output = & $RustDeskExe --get-id 2>$null

        if ($null -ne $Output) {

            $RustDeskId = (
                ($Output | Out-String).Trim()
            )
        }
    }
    catch {

        $RustDeskId = ""
    }

    if (-not [string]::IsNullOrWhiteSpace($RustDeskId)) {
        break
    }

    Start-Sleep -Seconds 1
}

if ([string]::IsNullOrWhiteSpace($RustDeskId)) {

    Log "WARNING: RustDesk ID could not be obtained."
    Log "Installation itself was successful."
}
else {

    Log "RustDesk ID: $RustDeskId"
}

# ==========================================================
# FINAL
# ==========================================================

Log "========================================"
Log "[FINAL]"
Log "========================================"

if (Test-Path $RustDeskExe) {

    Log "RustDesk executable: OK"
}
else {

    Fail "RustDesk executable is missing."
}

$FinalService = Get-Service `
    -Name $RustDeskService.Name `
    -ErrorAction SilentlyContinue

if ($null -ne $FinalService) {

    Log "RustDesk service: $($FinalService.Status)"
}
else {

    Fail "RustDesk service is missing."
}

Log "Configuration: $ConfigFile"

Log "Installation completed successfully."

Write-Host ""
Write-Host "========================================"
Write-Host "RustDesk installation completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Architecture:"
Write-Host "  $Architecture"
Write-Host ""
Write-Host "RustDesk:"
Write-Host "  $RustDeskExe"
Write-Host ""
Write-Host "Service:"
Write-Host "  $($FinalService.Name)"
Write-Host ""
Write-Host "Service status:"
Write-Host "  $($FinalService.Status)"
Write-Host ""
Write-Host "Config:"
Write-Host "  $ConfigFile"
Write-Host ""

if (-not [string]::IsNullOrWhiteSpace($RustDeskId)) {

    Write-Host "RustDesk ID:"
    Write-Host "  $RustDeskId"
    Write-Host ""
}

Write-Host "Log:"
Write-Host "  $InstallLog"
Write-Host ""
Write-Host "========================================"

exit 0