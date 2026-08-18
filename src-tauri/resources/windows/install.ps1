#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$Password
)

$ErrorActionPreference = "Stop"

# ==========================================================
# SCRIPT DIRECTORY
# ==========================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ==========================================================
# PATHS
# ==========================================================

$InstallRoot = Join-Path $env:ProgramData "RustDesk"

$InstallLog = Join-Path $InstallRoot "install.log"

$UserStdOutLog = Join-Path $InstallRoot "rustdesk-user.stdout.log"

$UserStdErrLog = Join-Path $InstallRoot "rustdesk-user.stderr.log"

$AppDir = Join-Path $env:ProgramFiles "RustDesk"

$RustDeskExe = Join-Path $AppDir "RustDesk.exe"

# ==========================================================
# CONFIG
# ==========================================================

$RendezvousServer = "rustdesk.magendamd.com"

$RelayServer = "rustdesk.magendamd.com"

$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# LOG DIRECTORY
# ==========================================================

New-Item `
    -ItemType Directory `
    -Path $InstallRoot `
    -Force `
    -ErrorAction SilentlyContinue |
    Out-Null

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
            -LiteralPath $InstallLog `
            -Value $Line `
            -Encoding UTF8
    }
    catch {
        # Logging must never break installer.
    }
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
# UAC
# ==========================================================

if (-not (Test-IsAdministrator)) {

    Log "Administrator privileges required."

    Log "Requesting UAC elevation..."

    try {

        $Arguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
            "-Password"
            "`"$Password`""
        )

        $Process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $Arguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        $ExitCode = $Process.ExitCode

        Log "Elevated process exit code: $ExitCode"

        exit $ExitCode
    }
    catch {

        Write-Host ""
        Write-Host "Administrator authorization failed:"
        Write-Host $_.Exception.Message

        exit 1
    }
}

# ==========================================================
# MAIN INSTALLATION
# ==========================================================

try {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "RustDesk Windows installer"
    Write-Host "========================================"
    Write-Host ""

    Log "Running as administrator: YES"

    Log "Script directory: $ScriptDir"

    # ======================================================
    # CURRENT USER
    # ======================================================

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $CurrentUserFull = $Identity.Name

    Log "Windows identity: $CurrentUserFull"

    # ======================================================
    # USER PROFILE
    #
    # IMPORTANT:
    # When elevated, USERPROFILE points to the admin
    # account, not necessarily the interactive user.
    #
    # For now use the original profile from environment
    # if available.
    # ======================================================

    $UserProfile = $env:USERPROFILE

    Log "User profile: $UserProfile"

    $UserConfigDir = Join-Path `
        $UserProfile `
        "AppData\Roaming\RustDesk"

    $UserRustDesk2 = Join-Path `
        $UserConfigDir `
        "RustDesk2.toml"

    Log "User config: $UserRustDesk2"

    # ======================================================
    # ARCHITECTURE
    # ======================================================

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

            throw "Unsupported Windows architecture: $Architecture"
        }
    }

    Log "Architecture: $Architecture"

    Log "RustDesk binary: $BundledExe"

    # ======================================================
    # CHECK BINARY
    # ======================================================

    if (-not (Test-Path -LiteralPath $BundledExe)) {

        throw "RustDesk executable not found: $BundledExe"
    }

    # ======================================================
    # STOP RUSTDESK
    # ======================================================

    Log "Stopping RustDesk..."

    Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue |
        Stop-Process `
            -Force `
            -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    # ======================================================
    # STOP SERVICES
    # ======================================================

    Log "Stopping RustDesk services..."

    $ServiceNames = @(
        "RustDesk"
        "RustDeskService"
        "RustDeskSvc"
    )

    foreach ($ServiceName in $ServiceNames) {

        $Service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($null -ne $Service) {

            Log "Stopping service: $ServiceName"

            Stop-Service `
                -Name $ServiceName `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 2

    # ======================================================
    # DELETE SERVICES
    # ======================================================

    Log "Removing old RustDesk services..."

    foreach ($ServiceName in $ServiceNames) {

        & sc.exe delete $ServiceName *> $null
    }

    Start-Sleep -Seconds 2

    # ======================================================
    # REMOVE OLD APP
    # ======================================================

    Log "Removing old RustDesk installation..."

    if (Test-Path -LiteralPath $AppDir) {

        Remove-Item `
            -LiteralPath $AppDir `
            -Recurse `
            -Force
    }

    # ======================================================
    # REMOVE USER CONFIG
    # ======================================================

    Log "Removing old user configuration..."

    if (Test-Path -LiteralPath $UserConfigDir) {

        Remove-Item `
            -LiteralPath $UserConfigDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # ======================================================
    # CREATE APP
    # ======================================================

    Log "Creating installation directory..."

    New-Item `
        -ItemType Directory `
        -Path $AppDir `
        -Force |
        Out-Null

    # ======================================================
    # COPY EXE
    # ======================================================

    Log "Installing RustDesk.exe..."

    Copy-Item `
        -LiteralPath $BundledExe `
        -Destination $RustDeskExe `
        -Force

    if (-not (Test-Path -LiteralPath $RustDeskExe)) {

        throw "RustDesk.exe was not installed."
    }

    Log "RustDesk executable installed."

    # ======================================================
    # CREATE USER CONFIG
    # ======================================================

    Log "Creating user configuration directory..."

    New-Item `
        -ItemType Directory `
        -Path $UserConfigDir `
        -Force |
        Out-Null

    # ======================================================
    # REMOVE OLD LOGS
    # ======================================================

    Remove-Item `
        -LiteralPath $UserStdOutLog `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $UserStdErrLog `
        -Force `
        -ErrorAction SilentlyContinue

    # ======================================================
    # START RUSTDESK
    # ======================================================

    Log "Starting RustDesk..."

    $RustDeskProcess = Start-Process `
        -FilePath $RustDeskExe `
        -WorkingDirectory $AppDir `
        -PassThru `
        -RedirectStandardOutput $UserStdOutLog `
        -RedirectStandardError $UserStdErrLog

    Log "RustDesk PID: $($RustDeskProcess.Id)"

    # ======================================================
    # WAIT FOR CONFIG
    # ======================================================

    Log "Waiting for RustDesk2.toml..."

    $Deadline = (Get-Date).AddSeconds(45)

    while (-not (Test-Path -LiteralPath $UserRustDesk2)) {

        if ((Get-Date) -gt $Deadline) {

            throw "RustDesk2.toml was not created within 45 seconds."
        }

        Start-Sleep -Milliseconds 500
    }

    Log "RustDesk2.toml created."

    # ======================================================
    # PASSWORD
    # ======================================================

    Log "Applying RustDesk password..."

    & $RustDeskExe `
        --password $Password

    $PasswordExitCode = $LASTEXITCODE

    Log "Password command exit code: $PasswordExitCode"

    if ($PasswordExitCode -ne 0) {

        throw "RustDesk password configuration failed."
    }

    Log "Password applied."

    # ======================================================
    # NETWORK CONFIG
    # ======================================================

    Log "Writing RustDesk2.toml..."

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
        -LiteralPath $UserRustDesk2 `
        -Value $ConfigContent `
        -Encoding UTF8 `
        -Force

    # ======================================================
    # VERIFY
    # ======================================================

    Log "Verifying configuration..."

    $Config = Get-Content `
        -LiteralPath $UserRustDesk2 `
        -Raw

    if ($Config -notlike "*rendezvous_server = '$RendezvousServer`:21116'*") {

        throw "rendezvous_server configuration is invalid."
    }

    if ($Config -notlike "*relay-server = '$RelayServer'*") {

        throw "relay-server configuration is invalid."
    }

    if ($Config -notlike "*custom-rendezvous-server = '$RendezvousServer'*") {

        throw "custom-rendezvous-server configuration is invalid."
    }

    if ($Config -notlike "*key = '$RustDeskKey'*") {

        throw "RustDesk key configuration is invalid."
    }

    Log "Network configuration verified."

    # ======================================================
    # STOP TEMPORARY PROCESS
    # ======================================================

    Log "Stopping temporary RustDesk..."

    Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue |
        Stop-Process `
            -Force `
            -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    # ======================================================
    # START FINAL PROCESS
    # ======================================================

    Log "Starting final RustDesk..."

    $FinalProcess = Start-Process `
        -FilePath $RustDeskExe `
        -WorkingDirectory $AppDir `
        -PassThru

    Log "Final RustDesk PID: $($FinalProcess.Id)"

    Start-Sleep -Seconds 3

    # ======================================================
    # GET ID
    # ======================================================

    Log "Getting RustDesk ID..."

    $RustDeskId = ""

    for ($i = 0; $i -lt 30; $i++) {

        try {

            $Output = & $RustDeskExe `
                --get-id `
                2>$null

            if ($Output) {

                $RustDeskId = (
                    $Output -join ""
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

        throw "RustDesk ID is empty."
    }

    Log "RustDesk ID: $RustDeskId"

    # ======================================================
    # RESULT
    # ======================================================

    Write-Host ""
    Write-Host "========================================"
    Write-Host "RustDesk installation completed"
    Write-Host "========================================"
    Write-Host ""

    Write-Host "User:"
    Write-Host "  $CurrentUserFull"

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

    Write-Host "Config:"
    Write-Host "  $UserRustDesk2"

    Write-Host ""

    Write-Host "Log:"
    Write-Host "  $InstallLog"

    Write-Host ""

    Write-Host "========================================"

    Log "Installation completed successfully."

    exit 0
}
catch {

    Log "========================================"

    Log "INSTALLATION FAILED"

    Log "Error: $($_.Exception.Message)"

    if ($_.InvocationInfo) {
        Log "Location: $($_.InvocationInfo.PositionMessage)"
    }

    if ($_.ScriptStackTrace) {
        Log "Stack: $($_.ScriptStackTrace)"
    }

    Log "========================================"

    Write-Host ""
    Write-Host "========================================"
    Write-Host "RUSTDESK INSTALLATION FAILED"
    Write-Host "========================================"
    Write-Host ""

    Write-Host "Error:"
    Write-Host $_.Exception.Message

    Write-Host ""

    Write-Host "Installer log:"
    Write-Host "  $InstallLog"

    Write-Host ""

    if (Test-Path -LiteralPath $UserStdErrLog) {

        Write-Host "RustDesk stderr:"
        Write-Host ""

        Get-Content `
            -LiteralPath $UserStdErrLog `
            -ErrorAction SilentlyContinue
    }

    Write-Host ""

    exit 1
}