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

$InstallLog = Join-Path $env:TEMP "rustdesk-install.log"

# ==========================================================
# LOGGING
# ==========================================================

function Log {
    param(
        [string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $line

    try {
        Add-Content -LiteralPath $InstallLog -Value $line -ErrorAction SilentlyContinue
    }
    catch {
    }
}

function Section {
    param(
        [string]$Name
    )

    Log ""
    Log "========"
    Log "[$Name]"
    Log "========"
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
# UAC
# ==========================================================

if (-not (Test-Administrator)) {

    Section "UAC"

    Log "Administrator privileges are required."
    Log "Requesting UAC..."

    try {

        $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

        $escapedScript = $PSCommandPath.Replace('"', '""')
        $escapedPassword = $Password.Replace('"', '""')

        $argumentString =
            "-NoProfile " +
            "-ExecutionPolicy Bypass " +
            "-File `"$escapedScript`" " +
            "-Password `"$escapedPassword`""

        Log "Starting elevated PowerShell..."

        $process = Start-Process `
            -FilePath $psExe `
            -ArgumentList $argumentString `
            -Verb RunAs `
            -Wait `
            -PassThru

        Log "Elevated PowerShell finished."
        Log "Exit code: $($process.ExitCode)"

        if ($process.ExitCode -ne 0) {
            Log "ERROR: elevated installation failed."
            exit $process.ExitCode
        }

        Log "Installation completed successfully."

        exit 0
    }
    catch {

        Log "ERROR: UAC elevation failed."
        Log $_.Exception.Message

        exit 1
    }
}

# ==========================================================
# START
# ==========================================================

Section "START"

Log "RustDesk Windows installer"
Log "Running as administrator: YES"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

Log "Windows identity: $($identity.Name)"
Log "Script directory: $ScriptDir"

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
        $BundledExe = Join-Path $ScriptDir "rustdesk-x86_64.exe"
    }

    "ARM64" {
        $BundledExe = Join-Path $ScriptDir "rustdesk-aarch64.exe"
    }

    default {
        Log "ERROR: unsupported architecture: $Architecture"
        exit 1
    }
}

Log "Architecture: $Architecture"
Log "RustDesk binary: $BundledExe"
Log "Install directory: $InstallDir"
Log "RustDesk executable: $RustDeskExe"

if (-not (Test-Path -LiteralPath $BundledExe -PathType Leaf)) {

    Log "ERROR: RustDesk binary not found:"
    Log $BundledExe

    exit 1
}

# ==========================================================
# STOP RUSTDESK
# ==========================================================

Section "STOP RUSTDESK"

Log "Stopping RustDesk processes..."

Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue |
    ForEach-Object {

        Log "Stopping PID $($_.Id)"

        Stop-Process `
            -Id $_.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

Start-Sleep -Seconds 2

# ==========================================================
# STOP OLD SERVICES
# ==========================================================

Log "Stopping RustDesk services..."

$ServiceNames = @(
    "RustDesk",
    "RustDeskService",
    "RustDesk Service"
)

foreach ($serviceName in $ServiceNames) {

    $service = Get-Service `
        -Name $serviceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        Log "Found service: $serviceName"
        Log "Current status: $($service.Status)"

        if ($service.Status -ne "Stopped") {

            try {
                Stop-Service `
                    -Name $serviceName `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
            catch {
                Log "WARNING: could not stop $serviceName"
            }
        }
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD SERVICES
# ==========================================================

Section "REMOVE OLD SERVICE"

foreach ($serviceName in $ServiceNames) {

    $service = Get-Service `
        -Name $serviceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        Log "Removing service: $serviceName"

        & sc.exe delete $serviceName 2>&1 |
            ForEach-Object {
                Log "$_"
            }
    }
}

Start-Sleep -Seconds 3

# ==========================================================
# REMOVE OLD INSTALLATION
# ==========================================================

Section "INSTALL APPLICATION"

if (Test-Path -LiteralPath $InstallDir) {

    Log "Removing old installation..."

    Remove-Item `
        -LiteralPath $InstallDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 1
}

Log "Creating installation directory..."

New-Item `
    -ItemType Directory `
    -Path $InstallDir `
    -Force |
    Out-Null

Log "Copying RustDesk..."

Copy-Item `
    -LiteralPath $BundledExe `
    -Destination $RustDeskExe `
    -Force

if (-not (Test-Path -LiteralPath $RustDeskExe -PathType Leaf)) {

    Log "ERROR: RustDesk executable was not installed."

    exit 1
}

Log "RustDesk executable installed."

# ==========================================================
# CONFIG
# ==========================================================

Section "CONFIG"

# IMPORTANT:
#
# Windows service uses LocalSystem/LocalService context.
#
# Therefore configuration for the service is placed in:
#
# C:\ProgramData\RustDesk\config
#
# ==========================================================

$ServiceConfigDir = Join-Path $env:ProgramData "RustDesk\config"

$ServiceConfigFile = Join-Path $ServiceConfigDir "RustDesk2.toml"

Log "Creating service configuration directory..."

New-Item `
    -ItemType Directory `
    -Path $ServiceConfigDir `
    -Force |
    Out-Null

Log "Writing RustDesk2.toml..."

$ConfigContent = @"
rendezvous_server = '$RendezvousServer`:21116'
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
    -LiteralPath $ServiceConfigFile `
    -Value $ConfigContent `
    -Encoding UTF8

if (-not (Test-Path -LiteralPath $ServiceConfigFile -PathType Leaf)) {

    Log "ERROR: failed to create RustDesk2.toml."

    exit 1
}

Log "Config created successfully."

Log "Configuration contents:"

Get-Content `
    -LiteralPath $ServiceConfigFile |
    ForEach-Object {
        Log $_
    }

# ==========================================================
# VERIFY CONFIG
# ==========================================================

Section "CONFIG VERIFY"

$config = Get-Content `
    -LiteralPath $ServiceConfigFile `
    -Raw

$expectedRendezvous =
    "rendezvous_server = '$RendezvousServer`:21116'"

$expectedRelay =
    "relay-server = '$RelayServer'"

$expectedCustom =
    "custom-rendezvous-server = '$RendezvousServer'"

$expectedKey =
    "key = '$RustDeskKey'"

if ($config -notlike "*$expectedRendezvous*") {

    Log "ERROR: rendezvous_server is incorrect."

    exit 1
}

if ($config -notlike "*$expectedRelay*") {

    Log "ERROR: relay-server is incorrect."

    exit 1
}

if ($config -notlike "*$expectedCustom*") {

    Log "ERROR: custom-rendezvous-server is incorrect."

    exit 1
}

if ($config -notlike "*$expectedKey*") {

    Log "ERROR: key is incorrect."

    exit 1
}

Log "Configuration verified."

# ==========================================================
# PASSWORD
# ==========================================================

Section "PASSWORD"

Log "Applying RustDesk permanent password..."

$passwordOutputFile = Join-Path $env:TEMP "rustdesk-password-output.txt"

Remove-Item `
    -LiteralPath $passwordOutputFile `
    -Force `
    -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--password"
        $Password
    ) `
    -Wait `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $passwordOutputFile `
    -RedirectStandardError $passwordOutputFile

Log "RustDesk --password exit code: $($process.ExitCode)"

if (Test-Path -LiteralPath $passwordOutputFile) {

    Get-Content `
        -LiteralPath $passwordOutputFile |
        ForEach-Object {
            if ($_ -ne "") {
                Log $_
            }
        }
}

if ($process.ExitCode -ne 0) {

    Log "ERROR: RustDesk password configuration failed."

    exit 1
}

Log "Password applied."

# ==========================================================
# SERVICE INSTALL
# ==========================================================

Section "SERVICE INSTALL"

Log "Installing RustDesk service..."

$serviceOutputFile = Join-Path $env:TEMP "rustdesk-service-output.txt"

Remove-Item `
    -LiteralPath $serviceOutputFile `
    -Force `
    -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--install-service"
    ) `
    -Wait `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $serviceOutputFile `
    -RedirectStandardError $serviceOutputFile

Log "RustDesk --install-service exit code: $($process.ExitCode)"

if (Test-Path -LiteralPath $serviceOutputFile) {

    Get-Content `
        -LiteralPath $serviceOutputFile |
        ForEach-Object {

            if ($_ -ne "") {
                Log $_
            }
        }
}

if ($process.ExitCode -ne 0) {

    Log "ERROR: RustDesk service installation failed."

    Log "Checking Windows services..."

    Get-Service |
        Where-Object {
            $_.Name -like "*RustDesk*" -or
            $_.DisplayName -like "*RustDesk*"
        } |
        ForEach-Object {

            Log "Service: $($_.Name)"
            Log "Display name: $($_.DisplayName)"
            Log "Status: $($_.Status)"
        }

    exit 1
}

# ==========================================================
# WAIT FOR SERVICE
# ==========================================================

Section "SERVICE START"

Log "Waiting for RustDesk service..."

$RustDeskService = $null

for ($i = 0; $i -lt 20; $i++) {

    $RustDeskService = Get-Service |
        Where-Object {
            $_.Name -like "*RustDesk*" -or
            $_.DisplayName -like "*RustDesk*"
        } |
        Select-Object -First 1

    if ($null -ne $RustDeskService) {
        break
    }

    Start-Sleep -Seconds 1
}

if ($null -eq $RustDeskService) {

    Log "ERROR: RustDesk service was not created."

    exit 1
}

Log "RustDesk service found."
Log "Service name: $($RustDeskService.Name)"
Log "Display name: $($RustDeskService.DisplayName)"

# ==========================================================
# SET AUTOMATIC
# ==========================================================

Log "Configuring service startup..."

Set-Service `
    -Name $RustDeskService.Name `
    -StartupType Automatic

Log "Service StartupType set to Automatic."

# ==========================================================
# START SERVICE
# ==========================================================

Log "Starting RustDesk service..."

if ($RustDeskService.Status -ne "Running") {

    Start-Service `
        -Name $RustDeskService.Name `
        -ErrorAction Stop
}

Start-Sleep -Seconds 2

$RustDeskService = Get-Service `
    -Name $RustDeskService.Name

Log "RustDesk service status: $($RustDeskService.Status)"

if ($RustDeskService.Status -ne "Running") {

    Log "ERROR: RustDesk service is not running."

    exit 1
}

# ==========================================================
# FINAL VERIFY
# ==========================================================

Section "FINAL"

if (Test-Path -LiteralPath $RustDeskExe -PathType Leaf) {

    Log "RustDesk executable: OK"
}
else {

    Log "ERROR: RustDesk executable missing."

    exit 1
}

if (Test-Path -LiteralPath $ServiceConfigFile -PathType Leaf) {

    Log "RustDesk configuration: OK"
}
else {

    Log "ERROR: RustDesk configuration missing."

    exit 1
}

$RustDeskService = Get-Service `
    -Name $RustDeskService.Name

Log "RustDesk service status: $($RustDeskService.Status)"

if ($RustDeskService.Status -ne "Running") {

    Log "ERROR: RustDesk service is not running."

    exit 1
}

# ==========================================================
# RESULT
# ==========================================================

Log ""
Log "========================================"
Log "RustDesk installation completed"
Log "========================================"
Log ""
Log "Architecture: $Architecture"
Log "RustDesk executable: $RustDeskExe"
Log "Service: $($RustDeskService.Name)"
Log "Service status: $($RustDeskService.Status)"
Log "Rendezvous: $RendezvousServer"
Log "Relay: $RelayServer"
Log "Config: $ServiceConfigFile"
Log "Password: configured"
Log "Installer log: $InstallLog"
Log ""
Log "========================================"

exit 0