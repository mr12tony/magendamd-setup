param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter()]
    [string]$PasswordFile,

    [Parameter()]
    [string]$TargetUser,

    [Parameter()]
    [string]$TargetAppData
)

$ErrorActionPreference = "Stop"

# ============================================================
# RUSTDESK WINDOWS LOCAL INSTALL + CONFIG + PASSWORD
#
# Files expected next to this script:
#
#   install-rustdesk.ps1
#   RustDesk2.toml
#   RustDesk-*-x86_64.exe
#   RustDesk-*-aarch64.exe
#
# Usage:
#
#   .\install-rustdesk.ps1 MyPassword123
#
# Or:
#
#   .\install-rustdesk.ps1
#
# If password is not provided:
#   random password will be generated.
#
# ============================================================


# ============================================================
# SETTINGS
# ============================================================

$ScriptDir = $PSScriptRoot

$ConfigSource = Join-Path `
    $ScriptDir `
    "RustDesk2.toml"

$ProgramFilesRustDesk = Join-Path `
    $env:ProgramFiles `
    "RustDesk"

$RustDeskExe = Join-Path `
    $ProgramFilesRustDesk `
    "RustDesk.exe"

$ServiceName = "RustDesk"


# ============================================================
# DETERMINE REAL USER
# ============================================================

if ([string]::IsNullOrWhiteSpace($TargetUser)) {

    $OriginalUser = $env:USERNAME

}
else {

    $OriginalUser = $TargetUser

}


# ============================================================
# DETERMINE REAL APPDATA
# ============================================================

if ([string]::IsNullOrWhiteSpace($TargetAppData)) {

    $OriginalAppData = $env:APPDATA

}
else {

    $OriginalAppData = $TargetAppData

}


# ============================================================
# ADMIN CHECK
# ============================================================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object `
    Security.Principal.WindowsPrincipal(
        $identity
    )

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)


# ============================================================
# UAC ELEVATION
# ============================================================

if (-not $isAdmin) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "RustDesk installation requires Administrator privileges."
    Write-Host "Requesting UAC elevation..."
    Write-Host "============================================================"
    Write-Host ""

    $TempPasswordFile = ""

    # --------------------------------------------------------
    # Save password temporarily if supplied
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
            "-File"
            "`"$PSCommandPath`""
            "-TargetUser"
            "`"$OriginalUser`""
            "-TargetAppData"
            "`"$OriginalAppData`""
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
        Write-Host "ERROR: Failed to start elevated PowerShell." `
            -ForegroundColor Red

        Write-Host $_.Exception.Message `
            -ForegroundColor Red

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
        Write-Host "ERROR: Password file not found." `
            -ForegroundColor Red

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
# CONFIG PATHS
# ============================================================

$UserConfigDir = Join-Path `
    $OriginalAppData `
    "RustDesk\config"

$UserConfig = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

$UserPasswordConfig = Join-Path `
    $UserConfigDir `
    "RustDesk.toml"


# ------------------------------------------------------------
# RustDesk Windows service runs as LocalService
# ------------------------------------------------------------

$SystemConfigDir = `
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"

$SystemConfig = Join-Path `
    $SystemConfigDir `
    "RustDesk2.toml"

$SystemPasswordConfig = Join-Path `
    $SystemConfigDir `
    "RustDesk.toml"


# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "       RUSTDESK WINDOWS LOCAL INSTALL + CONFIG + PASSWORD"
Write-Host "============================================================"
Write-Host ""

Write-Host "Target user:"
Write-Host "  $OriginalUser"

Write-Host ""
Write-Host "Target APPDATA:"
Write-Host "  $OriginalAppData"

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
# DETECT ARCHITECTURE
# ============================================================

Write-Host "Detecting Windows architecture..."

$Architecture = $env:PROCESSOR_ARCHITECTURE

if (
    $Architecture -eq "ARM64" -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture `
        -eq [System.Runtime.InteropServices.Architecture]::Arm64
) {

    $ArchitectureName = "ARM64"

    $ExePatterns = @(
        "*aarch64*.exe",
        "*arm64*.exe"
    )

}
else {

    $ArchitectureName = "x86_64"

    $ExePatterns = @(
        "*x86_64*.exe",
        "*x64*.exe"
    )
}


Write-Host "Architecture:"
Write-Host "  $ArchitectureName"


# ============================================================
# FIND LOCAL RUSTDESK INSTALLER
# ============================================================

$InstallerExe = $null

foreach ($pattern in $ExePatterns) {

    $candidate = Get-ChildItem `
        -LiteralPath $ScriptDir `
        -Filter $pattern `
        -File `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -ne $candidate) {

        $InstallerExe = $candidate.FullName

        break
    }
}


if ($null -eq $InstallerExe) {

    Write-Host ""
    Write-Host "ERROR: RustDesk installer for architecture '$ArchitectureName' was not found." `
        -ForegroundColor Red

    Write-Host ""

    Write-Host "Expected one of:"

    foreach ($pattern in $ExePatterns) {

        Write-Host "  $ScriptDir\$pattern"
    }

    Write-Host ""

    Write-Host "Available EXE files:"

    $availableExe = Get-ChildItem `
        -LiteralPath $ScriptDir `
        -Filter "*.exe" `
        -File `
        -ErrorAction SilentlyContinue

    if ($null -eq $availableExe) {

        Write-Host "  No EXE files found."

    }
    else {

        $availableExe |
            ForEach-Object {
                Write-Host "  $($_.Name)"
            }
    }

    exit 1
}


Write-Host ""
Write-Host "RustDesk installer:"
Write-Host "  $InstallerExe"


# ============================================================
# CHECK CONFIG
# ============================================================

if (-not (Test-Path -LiteralPath $ConfigSource)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk2.toml not found:" `
        -ForegroundColor Red

    Write-Host $ConfigSource

    Write-Host ""

    exit 1
}


# ============================================================
# PASSWORD INFO
# ============================================================

Write-Host ""
Write-Host "Password:"

if ($PasswordGenerated) {

    Write-Host "  $RustDeskPassword"
    Write-Host "  (randomly generated)"

}
else {

    Write-Host "  $RustDeskPassword"
    Write-Host "  (provided by user)"

}

Write-Host ""


# ============================================================
# 1. INSTALL / UPDATE RUSTDESK
# ============================================================

Write-Host "============================================================"
Write-Host "[1/8] INSTALLING RUSTDESK"
Write-Host "============================================================"
Write-Host ""

Write-Host "Running local RustDesk installer..."

$installerProcess = Start-Process `
    -FilePath $InstallerExe `
    -ArgumentList "--silent-install" `
    -Wait `
    -PassThru


Write-Host "Installer exit code:"
Write-Host "  $($installerProcess.ExitCode)"


if ($installerProcess.ExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: RustDesk installer failed." `
        -ForegroundColor Red

    exit $installerProcess.ExitCode
}


# ------------------------------------------------------------
# Wait for installation
# ------------------------------------------------------------

Write-Host ""
Write-Host "Waiting for RustDesk installation..."

$installed = $false

for ($i = 0; $i -lt 30; $i++) {

    if (Test-Path -LiteralPath $RustDeskExe) {

        $installed = $true

        break
    }

    Start-Sleep -Seconds 1
}


if (-not $installed) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe was not installed." `
        -ForegroundColor Red

    Write-Host $RustDeskExe

    exit 1
}


Write-Host "RustDesk installation verified."


# ============================================================
# 2. STOP RUSTDESK SERVICE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[2/8] STOPPING RUSTDESK SERVICE"
Write-Host "============================================================"
Write-Host ""

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


if ($null -ne $service) {

    Write-Host "Current status:"
    Write-Host "  $($service.Status)"


    if ($service.Status -ne "Stopped") {

        Write-Host ""
        Write-Host "Stopping service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue
    }


    for ($i = 0; $i -lt 20; $i++) {

        Start-Sleep -Seconds 1

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


    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue


    if (
        $null -ne $service -and
        $service.Status -ne "Stopped"
    ) {

        Write-Host ""
        Write-Host "ERROR: RustDesk service could not be stopped." `
            -ForegroundColor Red

        exit 1
    }


    Write-Host "RustDesk service stopped."

}
else {

    Write-Host "RustDesk service not found."
}


# ============================================================
# 3. STOP RUSTDESK GUI
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[3/8] STOPPING RUSTDESK GUI"
Write-Host "============================================================"
Write-Host ""


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

    Start-Sleep -Seconds 1
}


$process = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue


if ($null -ne $process) {

    Write-Host ""
    Write-Host "ERROR: RustDesk GUI process is still running." `
        -ForegroundColor Red

    exit 1
}


Write-Host "RustDesk GUI stopped."


# ============================================================
# 4. INSTALL RustDesk2.toml
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[4/8] INSTALLING RUSTDESK2.TOML"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# USER DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $UserConfigDir)) {

    New-Item `
        -Path $UserConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# SYSTEM DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SystemConfigDir)) {

    New-Item `
        -Path $SystemConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


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
    Write-Host "ERROR: User RustDesk2.toml was not installed." `
        -ForegroundColor Red

    exit 1
}


if (-not (Test-Path -LiteralPath $SystemConfig)) {

    Write-Host ""
    Write-Host "ERROR: System RustDesk2.toml was not installed." `
        -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "RustDesk2.toml installed successfully."


# ============================================================
# 5. START RUSTDESK GUI
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[5/8] STARTING RUSTDESK GUI"
Write-Host "============================================================"
Write-Host ""


Write-Host "Starting RustDesk..."

# ------------------------------------------------------------
# Important:
#
# Script is elevated, but RustDesk GUI should belong to the
# original interactive user.
#
# explorer.exe is used to launch the application through the
# user's normal desktop shell instead of directly creating an
# elevated child process.
# ------------------------------------------------------------

$explorer = Get-Process `
    -Name "explorer" `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1


if ($null -eq $explorer) {

    Write-Host ""
    Write-Host "ERROR: explorer.exe was not found." `
        -ForegroundColor Red

    exit 1
}


Start-Process `
    -FilePath "$env:WINDIR\explorer.exe" `
    -ArgumentList "`"$RustDeskExe`""


Write-Host "Waiting for RustDesk process..."

$rustDeskRunning = $false


for ($i = 0; $i -lt 20; $i++) {

    $rustDeskProcess = Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue


    if ($null -ne $rustDeskProcess) {

        $rustDeskRunning = $true

        break
    }


    Start-Sleep -Seconds 1
}


if (-not $rustDeskRunning) {

    Write-Host ""
    Write-Host "ERROR: RustDesk process did not start." `
        -ForegroundColor Red

    exit 1
}


Write-Host "RustDesk process is running."


# ------------------------------------------------------------
# REQUIRED INITIALIZATION DELAY
# ------------------------------------------------------------

Write-Host ""
Write-Host "Waiting 5 seconds for RustDesk initialization..."

Start-Sleep -Seconds 5


# ============================================================
# 6. APPLY PASSWORD
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
    Write-Host "ERROR: RustDesk --password failed." `
        -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "Password applied successfully."


# ============================================================
# 7. VERIFY RustDesk.toml
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[7/8] VERIFYING RUSTDESK.TOML"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# USER RustDesk.toml
# ------------------------------------------------------------

$UserPasswordConfigFound = $false


for ($i = 0; $i -lt 15; $i++) {

    if (Test-Path -LiteralPath $UserPasswordConfig) {

        $passwordConfigFile = Get-Item `
            -LiteralPath $UserPasswordConfig

        if ($passwordConfigFile.Length -gt 0) {

            $UserPasswordConfigFound = $true

            break
        }
    }

    Start-Sleep -Seconds 1
}


if (-not $UserPasswordConfigFound) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk.toml was not created or is empty." `
        -ForegroundColor Red

    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $UserPasswordConfig"

    exit 1
}


$passwordConfigFile = Get-Item `
    -LiteralPath $UserPasswordConfig


Write-Host "User RustDesk.toml verified:"
Write-Host "  $UserPasswordConfig"

Write-Host "Size:"
Write-Host "  $($passwordConfigFile.Length) bytes"


# ------------------------------------------------------------
# SYSTEM RustDesk.toml
# ------------------------------------------------------------

$SystemPasswordConfigFound = $false


for ($i = 0; $i -lt 15; $i++) {

    if (Test-Path -LiteralPath $SystemPasswordConfig) {

        $systemPasswordConfigFile = Get-Item `
            -LiteralPath $SystemPasswordConfig

        if ($systemPasswordConfigFile.Length -gt 0) {

            $SystemPasswordConfigFound = $true

            break
        }
    }

    Start-Sleep -Seconds 1
}


if (-not $SystemPasswordConfigFound) {

    Write-Host ""
    Write-Host "ERROR: System RustDesk.toml was not created or is empty." `
        -ForegroundColor Red

    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $SystemPasswordConfig"

    exit 1
}


$systemPasswordConfigFile = Get-Item `
    -LiteralPath $SystemPasswordConfig


Write-Host ""
Write-Host "System RustDesk.toml verified:"
Write-Host "  $SystemPasswordConfig"

Write-Host "Size:"
Write-Host "  $($systemPasswordConfigFile.Length) bytes"


Write-Host ""
Write-Host "RustDesk password configuration verified."


# ============================================================
# 8. START RUSTDESK SERVICE
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
# If silent installer did not create service, install it
# ------------------------------------------------------------

if ($null -eq $service) {

    Write-Host "RustDesk service does not exist."
    Write-Host "Installing RustDesk service..."

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -Wait `
        -PassThru `
        -WindowStyle Hidden


    Write-Host "Service installer exit code:"
    Write-Host "  $($serviceProcess.ExitCode)"


    Start-Sleep -Seconds 3


    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue
}


if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service does not exist." `
        -ForegroundColor Red

    exit 1
}


Write-Host "Service found."


# ------------------------------------------------------------
# START SERVICE
# ------------------------------------------------------------

if ($service.Status -ne "Running") {

    Write-Host ""
    Write-Host "Starting RustDesk service..."

    Start-Service `
        -Name $ServiceName
}


# ------------------------------------------------------------
# WAIT FOR SERVICE
# ------------------------------------------------------------

$running = $false


for ($i = 0; $i -lt 20; $i++) {

    Start-Sleep -Seconds 1


    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue


    if (
        $null -ne $service -and
        $service.Status -eq "Running"
    ) {

        $running = $true

        break
    }
}


if (-not $running) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service failed to start." `
        -ForegroundColor Red

    Get-Service `
        -Name $ServiceName |
        Format-List Name,Status,StartType

    exit 1
}


Write-Host ""
Write-Host "RustDesk service is RUNNING."


# ============================================================
# FINAL GUI CHECK
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                         FINAL CHECK"
Write-Host "============================================================"
Write-Host ""


$guiProcess = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue


if ($null -ne $guiProcess) {

    Write-Host "RustDesk GUI:"
    Write-Host "  RUNNING"

}
else {

    Write-Host "RustDesk GUI:"
    Write-Host "  WARNING: process was not detected" `
        -ForegroundColor Yellow
}


# ============================================================
# FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                         DONE"
Write-Host "============================================================"
Write-Host ""

Write-Host "Architecture:"
Write-Host "  $ArchitectureName"

Write-Host ""
Write-Host "Installer:"
Write-Host "  $InstallerExe"

Write-Host ""
Write-Host "RustDesk:"
Write-Host "  $RustDeskExe"

Write-Host ""
Write-Host "User:"
Write-Host "  $OriginalUser"

Write-Host ""
Write-Host "User APPDATA:"
Write-Host "  $OriginalAppData"

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
Write-Host "Service:"

Get-Service `
    -Name $ServiceName |
    Format-List Name,Status,StartType


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
Write-Host "GUI:"
Write-Host "  RUNNING"

Write-Host ""
Write-Host "============================================================"
Write-Host ""