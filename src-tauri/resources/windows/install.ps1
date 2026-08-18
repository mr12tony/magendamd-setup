#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Password,

    [string]$PasswordFile,

    [switch]$Elevated
)

$ErrorActionPreference = "Stop"

# ==========================================================
# PATH
# ==========================================================

$env:Path = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"

# ==========================================================
# SCRIPT
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$InstallLog = Join-Path `
    $env:TEMP `
    "rustdesk-install.log"

# ==========================================================
# CONFIG
# ==========================================================

$RendezvousServer = "rustdesk.magendamd.com"

$RelayServer = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# LOG
# ==========================================================

function Log {
    param(
        [string]$Message
    )

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    Write-Host $Line

    try {
        Add-Content `
            -Path $InstallLog `
            -Value $Line `
            -Encoding UTF8
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

function Test-IsAdministrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ==========================================================
# READ PASSWORD
# ==========================================================

if ([string]::IsNullOrWhiteSpace($Password)) {

    if (-not [string]::IsNullOrWhiteSpace($PasswordFile)) {

        if (-not (Test-Path $PasswordFile)) {

            Write-Host "ERROR: password file not found:"
            Write-Host $PasswordFile

            exit 1
        }

        $Password = (
            Get-Content `
                -Path $PasswordFile `
                -Raw
        ).Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($Password)) {

    Write-Host "ERROR: RustDesk password is required."

    exit 1
}

# ==========================================================
# UAC
# ==========================================================

if (-not (Test-IsAdministrator)) {

    Section "UAC"

    Log "Administrator privileges are required."
    Log "Requesting UAC..."

    $TempPasswordFile = Join-Path `
        $env:TEMP `
        ("rustdesk-password-" + [Guid]::NewGuid().ToString() + ".tmp")

    try {

        Set-Content `
            -Path $TempPasswordFile `
            -Value $Password `
            -Encoding UTF8 `
            -Force

        # Restrict temporary password file to current user.
        try {

            $Acl = Get-Acl $TempPasswordFile

            $Acl.SetAccessRuleProtection(
                $true,
                $false
            )

            $Rule = New-Object `
                System.Security.AccessControl.FileSystemAccessRule(
                    [Security.Principal.WindowsIdentity]::GetCurrent().Name,
                    "FullControl",
                    "Allow"
                )

            $Acl.AddAccessRule($Rule)

            Set-Acl `
                -Path $TempPasswordFile `
                -AclObject $Acl
        }
        catch {
        }

        $Arguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
            "-PasswordFile"
            "`"$TempPasswordFile`""
            "-Elevated"
        )

        Log "Starting elevated PowerShell..."

        $Process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $Arguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        $ExitCode = $Process.ExitCode

        Log "Elevated PowerShell finished."
        Log "Exit code: $ExitCode"

        if ($ExitCode -ne 0) {

            Log "ERROR: elevated installation failed."

            exit $ExitCode
        }

        Log "Installation completed successfully."

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
# ADMIN PHASE
# ==========================================================

Section "START"

Log "RustDesk Windows installer"

Log "Running as administrator: YES"

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

Log "Windows identity: $($Identity.Name)"

Log "Script directory: $ScriptDir"

# ==========================================================
# FIND REAL INTERACTIVE USER
# ==========================================================

$InteractiveUser = $null
$InteractiveDomain = $null
$InteractiveProfile = $null

try {

    $Explorer = Get-CimInstance `
        Win32_Process `
        -Filter "Name = 'explorer.exe'" |
        Select-Object -First 1

    if ($Explorer) {

        $Owner = Invoke-CimMethod `
            -InputObject $Explorer `
            -MethodName GetOwner

        if ($Owner.ReturnValue -eq 0) {

            $InteractiveUser = $Owner.User
            $InteractiveDomain = $Owner.Domain

            Log "Interactive user: $InteractiveDomain\$InteractiveUser"
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

        Log "ERROR: unsupported architecture: $Architecture"

        exit 1
    }
}

Log "Architecture: $Architecture"

Log "RustDesk binary: $BundledExe"

if (-not (Test-Path $BundledExe)) {

    Log "ERROR: RustDesk binary not found."

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

# IMPORTANT:
# This is where the Windows RustDesk SERVICE stores its
# configuration.
#
$ServiceRustDeskDir = Join-Path `
    $env:WINDIR `
    "ServiceProfiles\LocalService\AppData\Roaming\RustDesk"

$ServiceConfigDir = Join-Path `
    $ServiceRustDeskDir `
    "config"

$ServiceConfigFile = Join-Path `
    $ServiceConfigDir `
    "RustDesk2.toml"

Log "Install directory: $InstallDir"

Log "Service config directory: $ServiceConfigDir"

Log "Service config: $ServiceConfigFile"

# ==========================================================
# STOP RUSTDESK PROCESSES
# ==========================================================

Section "STOP RUSTDESK"

Log "Stopping RustDesk processes..."

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

$KnownServices = @(
    "RustDesk",
    "RustDeskService"
)

foreach ($Name in $KnownServices) {

    $Service = Get-Service `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if ($Service) {

        Log "Stopping service: $Name"

        Stop-Service `
            -Name $Name `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 2

# ==========================================================
# REMOVE OLD SERVICES
# ==========================================================

Section "REMOVE OLD SERVICE"

foreach ($Name in $KnownServices) {

    $Service = Get-Service `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if ($Service) {

        Log "Deleting service: $Name"

        & sc.exe delete $Name 2>&1 |
            ForEach-Object {
                Log "$_"
            }
    }
}

Start-Sleep -Seconds 3

# ==========================================================
# REMOVE OLD APPLICATION
# ==========================================================

Section "INSTALL APPLICATION"

if (Test-Path $InstallDir) {

    Log "Removing old installation..."

    Remove-Item `
        -Path $InstallDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

New-Item `
    -ItemType Directory `
    -Path $InstallDir `
    -Force |
    Out-Null

Log "Copying RustDesk..."

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
# SERVICE CONFIG
# ==========================================================

Section "CONFIG"

Log "Creating service configuration directory..."

New-Item `
    -ItemType Directory `
    -Path $ServiceConfigDir `
    -Force |
    Out-Null

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

Log "Writing RustDesk2.toml..."

Set-Content `
    -Path $ServiceConfigFile `
    -Value $ConfigContent `
    -Encoding UTF8 `
    -Force

if (-not (Test-Path $ServiceConfigFile)) {

    Log "ERROR: RustDesk2.toml was not created."

    exit 1
}

Log "Config created successfully."

# ==========================================================
# SHOW CONFIG
# ==========================================================

Log "Configuration contents:"

Get-Content $ServiceConfigFile |
    ForEach-Object {
        Log $_
    }

# ==========================================================
# INSTALL SERVICE
# ==========================================================

Section "SERVICE INSTALL"

Log "Installing RustDesk service..."

$ServiceOutput = & $RustDeskExe `
    --install-service `
    2>&1

$ServiceExitCode = $LASTEXITCODE

Log "RustDesk --install-service exit code: $ServiceExitCode"

$ServiceOutput |
    ForEach-Object {
        Log "$_"
    }

if ($ServiceExitCode -ne 0) {

    Log "ERROR: RustDesk service installation failed."

    exit 1
}

# ==========================================================
# FIND SERVICE
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

    Log "Searching installed services..."

    Get-Service |
        Where-Object {
            $_.Name -like "*RustDesk*" -or
            $_.DisplayName -like "*RustDesk*"
        } |
        ForEach-Object {
            Log "$($_.Name) | $($_.DisplayName) | $($_.Status)"
        }

    exit 1
}

Log "RustDesk service found."

Log "Service name: $($Service.Name)"

# ==========================================================
# SERVICE STARTUP
# ==========================================================

Section "SERVICE START"

Log "Setting service startup type to Automatic..."

Set-Service `
    -Name $Service.Name `
    -StartupType Automatic

Log "Starting RustDesk service..."

if ($Service.Status -ne "Running") {

    Start-Service `
        -Name $Service.Name
}

# ==========================================================
# WAIT SERVICE RUNNING
# ==========================================================

$Deadline = (Get-Date).AddSeconds(30)

while ((Get-Date) -lt $Deadline) {

    $Service = Get-Service `
        -Name $Service.Name

    if ($Service.Status -eq "Running") {
        break
    }

    Start-Sleep -Seconds 1
}

$Service = Get-Service `
    -Name $Service.Name

Log "Service status: $($Service.Status)"

if ($Service.Status -ne "Running") {

    Log "ERROR: RustDesk service failed to start."

    exit 1
}

# ==========================================================
# WAIT SERVICE CONFIG
# ==========================================================

Log "Waiting for RustDesk service configuration..."

$Deadline = (Get-Date).AddSeconds(20)

while ((Get-Date) -lt $Deadline) {

    if (Test-Path $ServiceConfigFile) {
        break
    }

    Start-Sleep -Milliseconds 500
}

if (-not (Test-Path $ServiceConfigFile)) {

    Log "ERROR: service configuration disappeared."

    exit 1
}

Log "Service configuration exists."

# ==========================================================
# PASSWORD
#
# IMPORTANT:
#
# Service must already be RUNNING.
#
# RustDesk's --password communicates with the running
# RustDesk instance/service. Calling it before the service
# exists/runs can affect the wrong profile.
# ==========================================================

Section "PASSWORD"

Log "Applying permanent password..."

$PasswordOutput = @()

try {

    $PasswordOutput = & $RustDeskExe `
        --password $Password `
        2>&1

    $PasswordExitCode = $LASTEXITCODE
}
catch {

    Log "ERROR executing RustDesk --password."

    Log $_.Exception.Message

    exit 1
}

Log "RustDesk --password exit code: $PasswordExitCode"

if ($PasswordOutput) {

    $PasswordOutput |
        ForEach-Object {
            Log "$_"
        }
}

if ($PasswordExitCode -ne 0) {

    Log "ERROR: RustDesk password command failed."

    exit 1
}

Log "Password command completed."

# ==========================================================
# RESTART SERVICE
#
# This makes sure the service reloads the resulting state.
# ==========================================================

Log "Restarting RustDesk service..."

Restart-Service `
    -Name $Service.Name `
    -Force

Start-Sleep -Seconds 3

$Service = Get-Service `
    -Name $Service.Name

Log "Service status after restart: $($Service.Status)"

if ($Service.Status -ne "Running") {

    Log "ERROR: RustDesk service is not running after restart."

    exit 1
}

# ==========================================================
# VERIFY CONFIG
# ==========================================================

Section "VERIFY"

Log "Verifying RustDesk2.toml..."

$Config = Get-Content `
    -Path $ServiceConfigFile `
    -Raw

if ($Config -notmatch [regex]::Escape(
    "rendezvous_server = '$RendezvousServer`:21116'"
)) {

    Log "ERROR: rendezvous_server is missing."

    exit 1
}

if ($Config -notmatch [regex]::Escape(
    "relay-server = '$RelayServer'"
)) {

    Log "ERROR: relay-server is missing."

    exit 1
}

if ($Config -notmatch [regex]::Escape(
    "custom-rendezvous-server = '$RendezvousServer'"
)) {

    Log "ERROR: custom-rendezvous-server is missing."

    exit 1
}

if ($Config -notmatch [regex]::Escape(
    "key = '$RustDeskKey'"
)) {

    Log "ERROR: RustDesk key is missing."

    exit 1
}

Log "Network configuration verified."

# ==========================================================
# GET ID
# ==========================================================

Section "RUSTDESK ID"

Log "Getting RustDesk ID..."

$RustDeskId = ""

for ($i = 0; $i -lt 30; $i++) {

    try {

        # PowerShell on Windows sometimes doesn't display
        # RustDesk stdout directly. Piping through Out-String
        # makes the output available.
        $Output = & $RustDeskExe `
            --get-id `
            2>$null |
            Out-String

        $RustDeskId = $Output.Trim()
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

    Log "WARNING: RustDesk ID could not be read."

    $RustDeskId = "unknown"
}
else {

    Log "RustDesk ID: $RustDeskId"
}

# ==========================================================
# FINAL
# ==========================================================

Section "FINAL"

$FinalService = Get-Service `
    -Name $Service.Name

Log "RustDesk executable: OK"

Log "RustDesk service: $($FinalService.Status)"

Log "RustDesk startup: $($FinalService.StartType)"

Log "RustDesk config: $ServiceConfigFile"

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
Write-Host "  $ServiceConfigFile"
Write-Host ""
Write-Host "Log:"
Write-Host "  $InstallLog"
Write-Host ""
Write-Host "========================================"

exit 0