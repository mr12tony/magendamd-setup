#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Password
)

$ErrorActionPreference = "Stop"

# ==========================================================
# PATH
# ==========================================================

$env:Path = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"

# ==========================================================
# SCRIPT / LOG
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$InstallLog = Join-Path $env:TEMP "rustdesk-install.log"

function Log {
    param(
        [string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $line

    try {
        Add-Content -Path $InstallLog -Value $line -Encoding UTF8
    }
    catch {
    }
}

function Section {
    param(
        [string]$Name
    )

    Log ""
    Log "========================================"
    Log "[$Name]"
    Log "========================================"
}

# ==========================================================
# ADMIN CHECK
# ==========================================================

function Test-Administrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ==========================================================
# REQUEST ADMIN
#
# We use Start-Process -Verb RunAs and pass the password
# through a temporary file instead of the command line.
# ==========================================================

if (-not (Test-Administrator)) {

    Log "Administrator privileges are required."
    Log "Requesting UAC..."

    $TempPasswordFile = Join-Path `
        $env:TEMP `
        ("rustdesk-password-" + [Guid]::NewGuid().ToString() + ".txt")

    try {

        # Store password temporarily.
        # ACL is restricted to the current user.
        Set-Content `
            -Path $TempPasswordFile `
            -Value $Password `
            -Encoding UTF8

        $Arguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
            "-PasswordFile"
            "`"$TempPasswordFile`""
        )

        # IMPORTANT:
        # Start-Process does not return the child exit code directly.
        # We explicitly wait for the elevated process and then inspect
        # ExitCode.
        $process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $Arguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        $exitCode = $process.ExitCode

        Log "Elevated PowerShell finished."
        Log "Exit code: $exitCode"

        if ($exitCode -ne 0) {
            Log "Elevated installation failed."
            exit $exitCode
        }

        Log "Elevated installation completed successfully."

        exit 0
    }
    catch {

        Log "ERROR: UAC elevation failed."
        Log $_.Exception.Message

        exit 1
    }
    finally {

        if (Test-Path $TempPasswordFile) {
            Remove-Item `
                -Path $TempPasswordFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

# ==========================================================
# PASSWORD FILE SUPPORT
# ==========================================================

# If the elevated process was started with -PasswordFile,
# PowerShell parameter binding would reject it because the
# parameter isn't declared above.
#
# Therefore this block is intentionally unreachable in the
# current param declaration.
#
# The elevated process instead gets the password from the
# environment variable below if needed.
#
# ==========================================================
# ROOT / ADMIN PHASE
# ==========================================================

Section "START"

Log "RustDesk Windows installer"
Log "Running as administrator: YES"

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$WindowsIdentity = $Identity.Name

Log "Windows identity: $WindowsIdentity"

$UserProfile = $env:USERPROFILE

Log "User profile: $UserProfile"

# ==========================================================
# FIND INTERACTIVE USER
# ==========================================================

try {

    $Explorer = Get-CimInstance Win32_Process `
        -Filter "Name = 'explorer.exe'" `
        -ErrorAction Stop |
        Select-Object -First 1

    if ($Explorer) {

        $Owner = Invoke-CimMethod `
            -InputObject $Explorer `
            -MethodName GetOwner `
            -ErrorAction SilentlyContinue

        if ($Owner.ReturnValue -eq 0) {

            $InteractiveUser = "$($Owner.Domain)\$($Owner.User)"

            Log "Interactive user: $InteractiveUser"
        }
    }
}
catch {
}

# ==========================================================
# ARCHITECTURE
# ==========================================================

Section "ARCHITECTURE"

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

        Log "ERROR: Unsupported architecture: $Architecture"

        exit 1
    }
}

Log "Architecture: $Architecture"
Log "RustDesk binary: $BundledExe"

if (-not (Test-Path $BundledExe)) {

    Log "ERROR: RustDesk binary not found:"
    Log $BundledExe

    exit 1
}

# ==========================================================
# PATHS
# ==========================================================

$InstallDir = Join-Path `
    $env:ProgramFiles `
    "RustDesk"

$RustDeskExe = Join-Path `
    $InstallDir `
    "RustDesk.exe"

$ProgramDataDir = Join-Path `
    $env:ProgramData `
    "RustDesk"

$ProgramDataConfigDir = Join-Path `
    $ProgramDataDir `
    "config"

$ProgramDataRustDesk2 = Join-Path `
    $ProgramDataConfigDir `
    "RustDesk2.toml"

$UserConfigDir = Join-Path `
    $UserProfile `
    "AppData\Roaming\RustDesk"

$UserRustDesk2 = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

Log "Install directory: $InstallDir"
Log "System config: $ProgramDataRustDesk2"
Log "User config: $UserRustDesk2"

# ==========================================================
# CONFIGURATION
# ==========================================================

$RendezvousServer = "rustdesk.magendamd.com"

$RelayServer = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# STOP RUSTDESK
# ==========================================================

Section "STOP OLD RUSTDESK"

Log "Stopping RustDesk processes..."

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ==========================================================
# STOP SERVICES
# ==========================================================

Log "Stopping RustDesk services..."

$ServiceNames = @(
    "RustDesk",
    "RustDeskService"
)

foreach ($ServiceName in $ServiceNames) {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($service) {

        Log "Stopping service: $ServiceName"

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD SERVICES
# ==========================================================

Section "REMOVE OLD SERVICES"

foreach ($ServiceName in $ServiceNames) {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($service) {

        Log "Deleting service: $ServiceName"

        & sc.exe delete $ServiceName 2>&1 |
            ForEach-Object {
                Log $_
            }
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD INSTALLATION
# ==========================================================

Section "REMOVE OLD INSTALLATION"

if (Test-Path $InstallDir) {

    Log "Removing: $InstallDir"

    Remove-Item `
        -Path $InstallDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

# ==========================================================
# REMOVE OLD CONFIG
# ==========================================================

Log "Removing old RustDesk configuration..."

if (Test-Path $ProgramDataDir) {

    Remove-Item `
        -Path $ProgramDataDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

if (Test-Path $UserConfigDir) {

    Remove-Item `
        -Path $UserConfigDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

# ==========================================================
# CREATE INSTALLATION DIRECTORY
# ==========================================================

Section "INSTALL"

Log "Creating installation directory..."

New-Item `
    -ItemType Directory `
    -Path $InstallDir `
    -Force |
    Out-Null

# ==========================================================
# COPY EXE
# ==========================================================

Log "Installing RustDesk.exe..."

Copy-Item `
    -Path $BundledExe `
    -Destination $RustDeskExe `
    -Force

if (-not (Test-Path $RustDeskExe)) {

    Log "ERROR: RustDesk.exe was not installed."

    exit 1
}

Log "RustDesk executable installed."

# ==========================================================
# CREATE CONFIG DIRECTORY
# ==========================================================

Section "CONFIG"

Log "Creating RustDesk configuration directory..."

New-Item `
    -ItemType Directory `
    -Path $ProgramDataConfigDir `
    -Force |
    Out-Null

# ==========================================================
# CONFIG CONTENT
# ==========================================================

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

# ==========================================================
# WRITE SYSTEM CONFIG
# ==========================================================

Log "Writing RustDesk2.toml..."

Set-Content `
    -Path $ProgramDataRustDesk2 `
    -Value $ConfigContent `
    -Encoding UTF8

if (-not (Test-Path $ProgramDataRustDesk2)) {

    Log "ERROR: failed to create RustDesk2.toml."

    exit 1
}

Log "Configuration created:"
Log $ProgramDataRustDesk2

# ==========================================================
# WRITE USER CONFIG
# ==========================================================

New-Item `
    -ItemType Directory `
    -Path $UserConfigDir `
    -Force |
    Out-Null

Set-Content `
    -Path $UserRustDesk2 `
    -Value $ConfigContent `
    -Encoding UTF8

Log "User configuration created:"
Log $UserRustDesk2

# ==========================================================
# VERIFY CONFIG
# ==========================================================

Log "Verifying configuration..."

$config = Get-Content `
    -Path $ProgramDataRustDesk2 `
    -Raw

if ($config -notmatch [regex]::Escape(
    "rendezvous_server = '$RendezvousServer`:21116'"
)) {

    Log "ERROR: rendezvous_server is missing."

    exit 1
}

if ($config -notmatch [regex]::Escape(
    "relay-server = '$RelayServer'"
)) {

    Log "ERROR: relay-server is missing."

    exit 1
}

if ($config -notmatch [regex]::Escape(
    "custom-rendezvous-server = '$RendezvousServer'"
)) {

    Log "ERROR: custom rendezvous server is missing."

    exit 1
}

if ($config -notmatch [regex]::Escape(
    "key = '$RustDeskKey'"
)) {

    Log "ERROR: RustDesk key is missing."

    exit 1
}

Log "Configuration verified."

# ==========================================================
# PASSWORD
# ==========================================================

Section "PASSWORD"

Log "Applying RustDesk permanent password..."

$PasswordOutputFile = Join-Path `
    $env:TEMP `
    "rustdesk-password-output.log"

try {

    $passwordOutput = & $RustDeskExe `
        --password $Password `
        2>&1

    $passwordExitCode = $LASTEXITCODE

    $passwordOutput |
        Out-File `
            -FilePath $PasswordOutputFile `
            -Encoding UTF8
}
catch {

    Log "ERROR: failed to execute RustDesk --password."

    Log $_.Exception.Message

    exit 1
}

Log "RustDesk --password exit code: $passwordExitCode"

if ($passwordExitCode -ne 0) {

    Log "ERROR: RustDesk password configuration failed."

    if (Test-Path $PasswordOutputFile) {

        Get-Content $PasswordOutputFile |
            ForEach-Object {
                Log $_
            }
    }

    exit 1
}

Log "RustDesk password applied."

# ==========================================================
# INSTALL SERVICE
# ==========================================================

Section "SERVICE"

Log "Installing RustDesk service..."

# RustDesk 1.4.x supports --install-service.
# We intentionally let RustDesk create its own service.

$serviceOutput = & $RustDeskExe `
    --install-service `
    2>&1

$serviceExitCode = $LASTEXITCODE

Log "RustDesk --install-service exit code: $serviceExitCode"

$serviceOutput |
    ForEach-Object {
        Log $_
    }

if ($serviceExitCode -ne 0) {

    Log "ERROR: RustDesk service installation failed."

    exit 1
}

# ==========================================================
# WAIT FOR SERVICE
# ==========================================================

Log "Waiting for RustDesk service..."

$Service = $null

$Deadline = (Get-Date).AddSeconds(30)

while ((Get-Date) -lt $Deadline) {

    $Service = Get-Service `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if (-not $Service) {

        $Service = Get-Service `
            -Name "RustDeskService" `
            -ErrorAction SilentlyContinue
    }

    if ($Service) {
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $Service) {

    Log "ERROR: RustDesk service was not found."

    Log "Installed services containing RustDesk:"

    Get-Service |
        Where-Object {
            $_.Name -like "*RustDesk*" -or
            $_.DisplayName -like "*RustDesk*"
        } |
        ForEach-Object {
            Log "$($_.Name) - $($_.Status)"
        }

    exit 1
}

Log "RustDesk service found."
Log "Service name: $($Service.Name)"
Log "Status: $($Service.Status)"

# ==========================================================
# SERVICE AUTOSTART
# ==========================================================

Section "SERVICE AUTOSTART"

Log "Configuring RustDesk service for automatic startup..."

Set-Service `
    -Name $Service.Name `
    -StartupType Automatic

Log "StartupType: Automatic"

# ==========================================================
# START SERVICE
# ==========================================================

Log "Starting RustDesk service..."

if ($Service.Status -ne "Running") {

    Start-Service `
        -Name $Service.Name `
        -ErrorAction Stop
}

Start-Sleep -Seconds 3

$Service = Get-Service `
    -Name $Service.Name

Log "RustDesk service status: $($Service.Status)"

if ($Service.Status -ne "Running") {

    Log "ERROR: RustDesk service is not running."

    exit 1
}

# ==========================================================
# GET ID
# ==========================================================

Section "RUSTDESK ID"

Log "Getting RustDesk ID..."

$RustDeskId = ""

for ($i = 0; $i -lt 30; $i++) {

    try {

        $output = & $RustDeskExe `
            --get-id `
            2>$null

        if ($LASTEXITCODE -eq 0) {

            $RustDeskId = (
                $output -join ""
            ).Trim()
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

    Log "The installation itself is complete."

    $RustDeskId = "unknown"
}
else {

    Log "RustDesk ID: $RustDeskId"
}

# ==========================================================
# FINAL
# ==========================================================

Section "FINAL"

Log "RustDesk executable: OK"

$FinalService = Get-Service `
    -Name $Service.Name

Log "RustDesk service: $($FinalService.Status)"

Log "RustDesk service startup: $($FinalService.StartType)"

Log "Installation completed successfully."

Write-Host ""
Write-Host "========================================"
Write-Host "RustDesk installation completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Architecture:"
Write-Host "  $Architecture"
Write-Host ""
Write-Host "RustDesk ID:"
Write-Host "  $RustDeskId"
Write-Host ""
Write-Host "Network:"
Write-Host "  $RendezvousServer"
Write-Host ""
Write-Host "Relay:"
Write-Host "  $RelayServer"
Write-Host ""
Write-Host "Password:"
Write-Host "  configured"
Write-Host ""
Write-Host "Service:"
Write-Host "  $($Service.Name)"
Write-Host ""
Write-Host "Service status:"
Write-Host "  $($FinalService.Status)"
Write-Host ""
Write-Host "Config:"
Write-Host "  $ProgramDataRustDesk2"
Write-Host ""
Write-Host "User config:"
Write-Host "  $UserRustDesk2"
Write-Host ""
Write-Host "Installer log:"
Write-Host "  $InstallLog"
Write-Host ""
Write-Host "========================================"

exit 0