param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter()]
    [string]$PasswordFile
)

$ErrorActionPreference = "Stop"

# ============================================================
# RUSTDESK WINDOWS LOCAL INSTALL + CONFIG + PASSWORD
#
# Files expected next to this script:
#
#   install.ps1
#   RustDesk2.toml
#   rustdesk-x86_64.exe
#   rustdesk-arm64.exe
#
# Usage:
#
#   .\install.ps1 MyPassword123
#
# If password is not provided:
#
#   .\install.ps1
#
# ============================================================


# ============================================================
# IMPORTANT:
# SAVE REAL USER BEFORE UAC ELEVATION
# ============================================================

$OriginalUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# Example:
# DESKTOP-XXXX\Alex

$RealUserName = $OriginalUser.Split('\')[-1]


# ============================================================
# REAL USER HOME
# ============================================================

$RealUserProfile = $env:USERPROFILE

# If launched elevated through UAC, try to recover original
# interactive user's profile from environment / registry.

if ($env:USERNAME -ne $RealUserName) {

    $profilePath = $null

    try {

        $profilePath = (
            Get-CimInstance Win32_UserProfile |
            Where-Object {
                $_.LocalPath -like "C:\Users\$RealUserName"
            } |
            Select-Object -First 1 -ExpandProperty LocalPath
        )

    }
    catch {
        $profilePath = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
        $RealUserProfile = $profilePath
    }
}


# ============================================================
# SETTINGS
# ============================================================

$ScriptDir = $PSScriptRoot

$ConfigSource = Join-Path `
    $ScriptDir `
    "RustDesk2.toml"

$ServiceName = "RustDesk"

$RustDeskInstallDir = Join-Path `
    $env:ProgramFiles `
    "RustDesk"

$RustDeskExe = Join-Path `
    $RustDeskInstallDir `
    "RustDesk.exe"

$UserConfigDir = Join-Path `
    $RealUserProfile `
    "AppData\Roaming\RustDesk\config"

$UserConfig = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

$UserPasswordConfig = Join-Path `
    $UserConfigDir `
    "RustDesk.toml"


$SystemConfigDir = `
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"

$SystemConfig = Join-Path `
    $SystemConfigDir `
    "RustDesk2.toml"

$SystemPasswordConfig = Join-Path `
    $SystemConfigDir `
    "RustDesk.toml"


# ============================================================
# ADMIN CHECK
# ============================================================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object `
    Security.Principal.WindowsPrincipal($identity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)


# ============================================================
# UAC ELEVATION
# ============================================================

if (-not $isAdmin) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "RustDesk installer requires Administrator privileges."
    Write-Host "Requesting UAC elevation..."
    Write-Host "============================================================"
    Write-Host ""

    $TempPasswordFile = ""

    # --------------------------------------------------------
    # Preserve password through UAC
    # --------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

        $TempPasswordFile = Join-Path `
            $env:TEMP `
            "rustdesk-password-$([Guid]::NewGuid().ToString('N')).txt"

        Set-Content `
            -LiteralPath $TempPasswordFile `
            -Value $RustDeskPassword `
            -Encoding UTF8
    }

    try {

        $argumentList = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-WindowStyle"
            "Hidden"
            "-File"
            "`"$PSCommandPath`""
        )

        if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile)) {

            $argumentList += @(
                "-PasswordFile"
                "`"$TempPasswordFile`""
            )
        }

        $elevatedProcess = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $argumentList `
            -WorkingDirectory $ScriptDir `
            -PassThru

        $elevatedProcess.WaitForExit()

        $exitCode = $elevatedProcess.ExitCode

    }
    catch {

        Write-Host ""
        Write-Host "ERROR: Failed to start elevated PowerShell." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""

        exit 1
    }
    finally {

        if (
            -not [string]::IsNullOrWhiteSpace($TempPasswordFile) -and
            (Test-Path -LiteralPath $TempPasswordFile)
        ) {

            Remove-Item `
                -LiteralPath $TempPasswordFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    exit $exitCode
}


# ============================================================
# PASSWORD FROM TEMP FILE
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($PasswordFile)) {

    if (-not (Test-Path -LiteralPath $PasswordFile)) {

        Write-Host ""
        Write-Host "ERROR: Password file not found." -ForegroundColor Red
        Write-Host ""

        exit 1
    }

    $RustDeskPassword = (
        Get-Content `
            -LiteralPath $PasswordFile `
            -Raw `
            -Encoding UTF8
    ).Trim()

    Remove-Item `
        -LiteralPath $PasswordFile `
        -Force `
        -ErrorAction SilentlyContinue
}


# ============================================================
# GENERATE PASSWORD
# ============================================================

if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    $bytes = New-Object byte[] 12

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $RustDeskPassword = (
        [Convert]::ToBase64String($bytes) `
            -replace '[^a-zA-Z0-9]', ''
    ).Substring(0, 16)

    $PasswordGenerated = $true

}
else {

    $PasswordGenerated = $false
}


# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "          RUSTDESK WINDOWS LOCAL INSTALL"
Write-Host "              CONFIG + PASSWORD"
Write-Host "============================================================"
Write-Host ""

Write-Host "Real user:"
Write-Host "  $RealUserName"

Write-Host ""
Write-Host "Real user profile:"
Write-Host "  $RealUserProfile"

Write-Host ""
Write-Host "Script directory:"
Write-Host "  $ScriptDir"

Write-Host ""
Write-Host "Config source:"
Write-Host "  $ConfigSource"

Write-Host ""
Write-Host "RustDesk executable:"
Write-Host "  $RustDeskExe"

Write-Host ""


# ============================================================
# CHECK CONFIG
# ============================================================

if (-not (Test-Path -LiteralPath $ConfigSource)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk2.toml not found:" -ForegroundColor Red
    Write-Host "  $ConfigSource"
    Write-Host ""

    exit 1
}


# ============================================================
# DETECT WINDOWS ARCHITECTURE
# ============================================================

Write-Host "Detecting Windows architecture..."

$Architecture = $env:PROCESSOR_ARCHITECTURE

if (
    $Architecture -eq "AMD64" -or
    $Architecture -eq "x86_64"
) {

    $InstallerName = "rustdesk-x86_64.exe"
    $ArchitectureDisplay = "x64"

}
elseif (
    $Architecture -eq "ARM64"
) {

    $InstallerName = "rustdesk-arm64.exe"
    $ArchitectureDisplay = "ARM64"

}
else {

    Write-Host ""
    Write-Host "ERROR: Unsupported Windows architecture:" -ForegroundColor Red
    Write-Host "  $Architecture"
    Write-Host ""

    exit 1
}


$InstallerPath = Join-Path `
    $ScriptDir `
    $InstallerName


Write-Host "Architecture: $ArchitectureDisplay"

Write-Host ""
Write-Host "RustDesk installer:"
Write-Host "  $InstallerPath"


# ============================================================
# CHECK INSTALLER
# ============================================================

if (-not (Test-Path -LiteralPath $InstallerPath)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk installer not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $InstallerPath"
    Write-Host ""

    exit 1
}


# ============================================================
# PASSWORD INFO
# ============================================================

Write-Host ""
Write-Host "Password:"
Write-Host "  $RustDeskPassword"

if ($PasswordGenerated) {
    Write-Host "  (randomly generated)"
}
else {
    Write-Host "  (provided by user)"
}

Write-Host ""


# ============================================================
# 1/8 STOP EXISTING RUSTDESK
# ============================================================

Write-Host "============================================================"
Write-Host "[1/8] STOPPING EXISTING RUSTDESK"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# STOP SERVICE IF EXISTS
# ------------------------------------------------------------

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Host "Current service status: $($service.Status)"

    if ($service.Status -ne "Stopped") {

        Write-Host "Stopping RustDesk service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue

        for ($i = 0; $i -lt 20; $i++) {

            Start-Sleep -Milliseconds 500

            $service = Get-Service `
                -Name $ServiceName `
                -ErrorAction SilentlyContinue

            if (
                $null -eq $service -or
                $service.Status -eq "Stopped"
            ) {
                break
            }
        }
    }

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (
        $null -ne $service -and
        $service.Status -ne "Stopped"
    ) {

        Write-Host ""
        Write-Host "ERROR: RustDesk service could not be stopped." -ForegroundColor Red

        exit 1
    }

    Write-Host "RustDesk service stopped."

}
else {

    Write-Host "RustDesk service not found."
}


# ------------------------------------------------------------
# STOP GUI
# ------------------------------------------------------------

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2


for ($i = 0; $i -lt 15; $i++) {

    $process = Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if ($null -eq $process) {
        break
    }

    Start-Sleep -Milliseconds 500
}


$process = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -ne $process) {

    Write-Host ""
    Write-Host "ERROR: RustDesk GUI is still running." -ForegroundColor Red

    exit 1
}

Write-Host "RustDesk GUI stopped."


# ============================================================
# 2/8 INSTALL RUSTDESK FROM LOCAL EXE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[2/8] INSTALLING RUSTDESK FROM LOCAL EXE"
Write-Host "============================================================"
Write-Host ""

Write-Host "Installer:"
Write-Host "  $InstallerPath"

Write-Host ""
Write-Host "Starting silent RustDesk installation..."


# ------------------------------------------------------------
# IMPORTANT:
# Do NOT use Start-Process -Wait here.
#
# Some RustDesk installer versions may keep the parent process
# alive while the actual installation is performed by a child
# process. Waiting forever here caused the previous script to
# appear frozen at:
#
#   Starting silent RustDesk installation...
#
# ------------------------------------------------------------

$installerProcess = Start-Process `
    -FilePath $InstallerPath `
    -ArgumentList "--silent-install" `
    -PassThru


$InstallerTimeoutSeconds = 60
$InstallerFinished = $false


for ($i = 0; $i -lt $InstallerTimeoutSeconds; $i++) {

    Start-Sleep -Seconds 1

    if ($installerProcess.HasExited) {

        $InstallerFinished = $true
        break
    }

    # --------------------------------------------------------
    # If RustDesk.exe already appeared, installation has
    # effectively completed even if the installer process
    # itself is still alive.
    # --------------------------------------------------------

    if (Test-Path -LiteralPath $RustDeskExe) {

        $InstallerFinished = $true
        break
    }

    Write-Progress `
        -Activity "Installing RustDesk" `
        -Status "Waiting for installer..." `
        -PercentComplete (
            [Math]::Min(
                99,
                (($i + 1) / $InstallerTimeoutSeconds) * 100
            )
        )
}


Write-Progress `
    -Activity "Installing RustDesk" `
    -Completed


# ------------------------------------------------------------
# If installer process is still alive but RustDesk exists,
# don't wait for it forever.
# ------------------------------------------------------------

if (
    -not $installerProcess.HasExited -and
    (Test-Path -LiteralPath $RustDeskExe)
) {

    Write-Host ""
    Write-Host "RustDesk executable detected."

    Write-Host "Installer process is still running."
    Write-Host "Continuing without waiting for installer process."

}
elseif (
    -not $InstallerFinished
) {

    Write-Host ""
    Write-Host "ERROR: RustDesk installer timed out after $InstallerTimeoutSeconds seconds." -ForegroundColor Red

    Write-Host ""
    Write-Host "Installer process:"
    Write-Host "  PID: $($installerProcess.Id)"

    try {

        Stop-Process `
            -Id $installerProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue

    }
    catch {}

    exit 1
}


# ------------------------------------------------------------
# Give installer a moment to finish file operations
# ------------------------------------------------------------

Start-Sleep -Seconds 3


# ============================================================
# VERIFY INSTALLATION
# ============================================================

Write-Host ""
Write-Host "Checking RustDesk installation..."

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe was not installed." -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $RustDeskExe"
    Write-Host ""

    exit 1
}


Write-Host "RustDesk.exe found:"
Write-Host "  $RustDeskExe"


# ============================================================
# 3/8 PREPARE CONFIG DIRECTORIES
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[3/8] PREPARING CONFIGURATION"
Write-Host "============================================================"
Write-Host ""


if (-not (Test-Path -LiteralPath $UserConfigDir)) {

    New-Item `
        -Path $UserConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


if (-not (Test-Path -LiteralPath $SystemConfigDir)) {

    New-Item `
        -Path $SystemConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


Write-Host "User config directory:"
Write-Host "  $UserConfigDir"

Write-Host ""
Write-Host "System config directory:"
Write-Host "  $SystemConfigDir"


# ============================================================
# 4/8 BACKUP + INSTALL RustDesk2.toml
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[4/8] INSTALLING RUSTDESK2.TOML"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# USER BACKUP
# ------------------------------------------------------------

if (Test-Path -LiteralPath $UserConfig) {

    $UserBackup = "$UserConfig.backup"

    Copy-Item `
        -LiteralPath $UserConfig `
        -Destination $UserBackup `
        -Force

    Write-Host "User backup:"
    Write-Host "  $UserBackup"
}


# ------------------------------------------------------------
# SYSTEM BACKUP
# ------------------------------------------------------------

if (Test-Path -LiteralPath $SystemConfig) {

    $SystemBackup = "$SystemConfig.backup"

    Copy-Item `
        -LiteralPath $SystemConfig `
        -Destination $SystemBackup `
        -Force

    Write-Host "System backup:"
    Write-Host "  $SystemBackup"
}


# ------------------------------------------------------------
# COPY USER CONFIG
# ------------------------------------------------------------

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $UserConfig `
    -Force


Write-Host ""
Write-Host "User RustDesk2.toml installed:"
Write-Host "  $UserConfig"


# ------------------------------------------------------------
# COPY SYSTEM CONFIG
# ------------------------------------------------------------

Copy-Item `
    -LiteralPath $ConfigSource `
    -Destination $SystemConfig `
    -Force


Write-Host ""
Write-Host "System RustDesk2.toml installed:"
Write-Host "  $SystemConfig"


# ------------------------------------------------------------
# VERIFY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $UserConfig)) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk2.toml was not installed." -ForegroundColor Red

    exit 1
}


if (-not (Test-Path -LiteralPath $SystemConfig)) {

    Write-Host ""
    Write-Host "ERROR: System RustDesk2.toml was not installed." -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "RustDesk2.toml installed successfully."


# ============================================================
# 5/8 START RUSTDESK
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[5/8] STARTING RUSTDESK"
Write-Host "============================================================"
Write-Host ""


Write-Host "Starting RustDesk GUI..."


# ------------------------------------------------------------
# Start RustDesk WITHOUT -Wait
# ------------------------------------------------------------

Start-Process `
    -FilePath $RustDeskExe


Write-Host "Waiting for RustDesk to initialize..."


$RustDeskRunning = $false


for ($i = 0; $i -lt 20; $i++) {

    Start-Sleep -Seconds 1

    $rustDeskProcess = Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue

    if ($null -ne $rustDeskProcess) {

        $RustDeskRunning = $true

        break
    }
}


if (-not $RustDeskRunning) {

    Write-Host ""
    Write-Host "ERROR: RustDesk GUI did not start." -ForegroundColor Red

    exit 1
}


Write-Host "RustDesk process is running."


Write-Host ""
Write-Host "Waiting 5 seconds for RustDesk initialization..."

Start-Sleep -Seconds 5


# ============================================================
# 6/8 APPLY PASSWORD
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[6/8] APPLYING RUSTDESK PASSWORD"
Write-Host "============================================================"
Write-Host ""


Write-Host "Executing:"
Write-Host "  RustDesk.exe --password ********"
Write-Host ""


$passwordProcess = Start-Process `
    -FilePath $RustDeskExe `
    -ArgumentList @(
        "--password",
        $RustDeskPassword
    ) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden


Write-Host "RustDesk --password exit code:"
Write-Host "  $($passwordProcess.ExitCode)"


if ($passwordProcess.ExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: RustDesk --password failed." -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "Password applied successfully."


# ============================================================
# 7/8 VERIFY RustDesk.toml
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[7/8] VERIFYING RUSTDESK.TOML"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# USER PASSWORD CONFIG
# ------------------------------------------------------------

$UserPasswordConfigFound = $false


for ($i = 0; $i -lt 15; $i++) {

    if (Test-Path -LiteralPath $UserPasswordConfig) {

        $file = Get-Item `
            -LiteralPath $UserPasswordConfig

        if ($file.Length -gt 0) {

            $UserPasswordConfigFound = $true

            break
        }
    }

    Start-Sleep -Seconds 1
}


if (-not $UserPasswordConfigFound) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk.toml was not created or is empty." -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $UserPasswordConfig"

    exit 1
}


$userPasswordFile = Get-Item `
    -LiteralPath $UserPasswordConfig


Write-Host "User RustDesk.toml verified:"
Write-Host "  $UserPasswordConfig"

Write-Host "Size:"
Write-Host "  $($userPasswordFile.Length) bytes"


# ------------------------------------------------------------
# SYSTEM PASSWORD CONFIG
# ------------------------------------------------------------

if (Test-Path -LiteralPath $SystemPasswordConfig) {

    $systemPasswordFile = Get-Item `
        -LiteralPath $SystemPasswordConfig

    Write-Host ""
    Write-Host "System RustDesk.toml found:"
    Write-Host "  $SystemPasswordConfig"

    Write-Host "Size:"
    Write-Host "  $($systemPasswordFile.Length) bytes"

}
else {

    Write-Host ""
    Write-Host "WARNING: System RustDesk.toml was not found." -ForegroundColor Yellow
}


# ============================================================
# GET RUSTDESK ID
# ============================================================

Write-Host ""
Write-Host "Getting RustDesk ID..."


$RustDeskId = ""

try {

    $RustDeskId = (
        & $RustDeskExe --get-id 2>$null
    ).Trim()

}
catch {

    $RustDeskId = ""
}


# ============================================================
# 8/8 START SERVICE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[8/8] STARTING RUSTDESK SERVICE"
Write-Host "============================================================"
Write-Host ""


$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


# ------------------------------------------------------------
# Service may have been created by silent installer.
# If it doesn't exist, explicitly install it.
# ------------------------------------------------------------

if ($null -eq $service) {

    Write-Host "RustDesk service does not exist."
    Write-Host "Installing RustDesk service..."

    $installServiceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru `
        -WindowStyle Hidden


    Write-Host "Service installer exit code:"
    Write-Host "  $($installServiceProcess.ExitCode)"


    Start-Sleep -Seconds 3


    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue
}


if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service could not be created." -ForegroundColor Red

    exit 1
}


# ------------------------------------------------------------
# START SERVICE
# ------------------------------------------------------------

if ($service.Status -ne "Running") {

    Write-Host "Starting RustDesk service..."

    Start-Service `
        -Name $ServiceName `
        -ErrorAction Stop
}


# ------------------------------------------------------------
# WAIT FOR SERVICE
# ------------------------------------------------------------

$ServiceRunning = $false


for ($i = 0; $i -lt 30; $i++) {

    Start-Sleep -Seconds 1

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (
        $null -ne $service -and
        $service.Status -eq "Running"
    ) {

        $ServiceRunning = $true

        break
    }
}


if (-not $ServiceRunning) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service failed to start." -ForegroundColor Red
    Write-Host ""

    Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue |
        Format-List Name,Status,StartType

    exit 1
}


Write-Host "RustDesk service is RUNNING."


# ============================================================
# FINAL GUI CHECK
# ============================================================

Write-Host ""
Write-Host "Checking RustDesk GUI..."


$guiProcess = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue


if ($null -eq $guiProcess) {

    Write-Host ""
    Write-Host "WARNING: RustDesk GUI process is not detected." -ForegroundColor Yellow

}
else {

    Write-Host "RustDesk GUI is RUNNING."
}


# ============================================================
# FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                         DONE"
Write-Host "============================================================"
Write-Host ""


Write-Host "RustDesk:"
Write-Host "  $RustDeskExe"


Write-Host ""
Write-Host "Architecture:"
Write-Host "  $ArchitectureDisplay"


Write-Host ""
Write-Host "RustDesk ID:"

if (-not [string]::IsNullOrWhiteSpace($RustDeskId)) {

    Write-Host "  $RustDeskId"

}
else {

    Write-Host "  Failed to get RustDesk ID."
}


Write-Host ""
Write-Host "User:"
Write-Host "  $RealUserName"


Write-Host ""
Write-Host "User RustDesk2.toml:"
Write-Host "  $UserConfig"


Write-Host ""
Write-Host "System RustDesk2.toml:"
Write-Host "  $SystemConfig"


Write-Host ""
Write-Host "User RustDesk.toml:"
Write-Host "  $UserPasswordConfig"


Write-Host ""
Write-Host "System RustDesk.toml:"
Write-Host "  $SystemPasswordConfig"


Write-Host ""
Write-Host "Password:"
Write-Host "  $RustDeskPassword"


if ($PasswordGenerated) {
    Write-Host "  (randomly generated)"
}
else {
    Write-Host "  (provided by user)"
}


Write-Host ""
Write-Host "Service:"

Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue |
    Format-List Name,Status,StartType


Write-Host ""
Write-Host "GUI:"
Write-Host "  RUNNING"


Write-Host ""
Write-Host "============================================================"
Write-Host ""