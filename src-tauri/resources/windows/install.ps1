param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter()]
    [string]$PasswordFile,

    [Parameter()]
    [string]$OriginalUserName,

    [Parameter()]
    [string]$OriginalUserProfile
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
# ============================================================


# ============================================================
# IMPORTANT:
# DETERMINE REAL INTERACTIVE USER BEFORE UAC
# ============================================================

if ([string]::IsNullOrWhiteSpace($OriginalUserName)) {

    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $OriginalUserName = $CurrentIdentity.Name.Split('\')[-1]
}


# ============================================================
# REAL USER PROFILE
# ============================================================

if ([string]::IsNullOrWhiteSpace($OriginalUserProfile)) {

    $OriginalUserProfile = $env:USERPROFILE

    try {

        $profilePath = (
            Get-CimInstance Win32_UserProfile |
            Where-Object {
                $_.LocalPath -eq "C:\Users\$OriginalUserName" -and
                $_.Loaded -eq $true
            } |
            Select-Object -First 1 -ExpandProperty LocalPath
        )

        if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
            $OriginalUserProfile = $profilePath
        }

    }
    catch {
        # Keep current profile if lookup fails.
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


# ------------------------------------------------------------
# USER CONFIG
# ------------------------------------------------------------

$UserConfigDir = Join-Path `
    $OriginalUserProfile `
    "AppData\Roaming\RustDesk\config"

$UserConfig = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

$UserPasswordConfig = Join-Path `
    $UserConfigDir `
    "RustDesk.toml"


# ------------------------------------------------------------
# SERVICE / LOCAL SYSTEM CONFIG
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
            "-OriginalUserName"
            "`"$OriginalUserName`""
            "-OriginalUserProfile"
            "`"$OriginalUserProfile`""
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
Write-Host "  $OriginalUserName"

Write-Host ""
Write-Host "Real user profile:"
Write-Host "  $OriginalUserProfile"

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
# FUNCTION:
# STOP RUSTDESK COMPLETELY
# ============================================================

function Stop-RustDeskCompletely {

    Write-Host ""
    Write-Host "Stopping RustDesk service..."

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        if ($service.Status -ne "Stopped") {

            Stop-Service `
                -Name $ServiceName `
                -Force `
                -ErrorAction SilentlyContinue

        }

        for ($i = 0; $i -lt 30; $i++) {

            $service = Get-Service `
                -Name $ServiceName `
                -ErrorAction SilentlyContinue

            if (
                $null -eq $service -or
                $service.Status -eq "Stopped"
            ) {
                break
            }

            Start-Sleep -Milliseconds 500
        }
    }


    Write-Host "Stopping RustDesk GUI..."

    Get-Process `
        -Name "RustDesk" `
        -ErrorAction SilentlyContinue |
        Stop-Process `
            -Force `
            -ErrorAction SilentlyContinue


    for ($i = 0; $i -lt 30; $i++) {

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
        Write-Host "ERROR: RustDesk process is still running." -ForegroundColor Red

        return $false
    }


    Write-Host "RustDesk completely stopped."

    return $true
}


# ============================================================
# 1/8 STOP EXISTING RUSTDESK
# ============================================================

Write-Host "============================================================"
Write-Host "[1/8] STOPPING EXISTING RUSTDESK"
Write-Host "============================================================"
Write-Host ""

if (-not (Stop-RustDeskCompletely)) {
    exit 1
}


# ============================================================
# 2/8 INSTALL RUSTDESK
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
# REMOVE OLD EXE REFERENCE ONLY AFTER PROCESS IS STOPPED
# ------------------------------------------------------------

$OldExeExists = Test-Path -LiteralPath $RustDeskExe

if ($OldExeExists) {

    try {

        $oldFile = Get-Item `
            -LiteralPath $RustDeskExe `
            -ErrorAction Stop

        Write-Host "Existing RustDesk.exe detected."
        Write-Host "Existing version timestamp:"
        Write-Host "  $($oldFile.LastWriteTime)"

    }
    catch {}
}


# ------------------------------------------------------------
# START INSTALLER WITHOUT -WAIT
#
# IMPORTANT:
# Do not use -Wait because some RustDesk installers can keep
# the parent process alive while installation continues in
# another process.
# ------------------------------------------------------------

$installerProcess = Start-Process `
    -FilePath $InstallerPath `
    -ArgumentList "--silent-install" `
    -PassThru


$InstallerTimeoutSeconds = 120
$RustDeskDetected = $false


# ------------------------------------------------------------
# WAIT FOR RustDesk.exe
# ------------------------------------------------------------

for ($i = 0; $i -lt $InstallerTimeoutSeconds; $i++) {

    Start-Sleep -Seconds 1

    if (Test-Path -LiteralPath $RustDeskExe) {

        $RustDeskDetected = $true

        Write-Host ""
        Write-Host "RustDesk.exe detected."

        break
    }


    if ($installerProcess.HasExited) {

        Write-Host ""
        Write-Host "Installer process exited."

        Write-Host "Installer exit code:"
        Write-Host "  $($installerProcess.ExitCode)"

        if ($installerProcess.ExitCode -ne 0) {

            Write-Host ""
            Write-Host "WARNING: Installer returned non-zero exit code." -ForegroundColor Yellow
        }
    }


    Write-Progress `
        -Activity "Installing RustDesk" `
        -Status "Waiting for RustDesk.exe..." `
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


if (-not $RustDeskDetected) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe did not appear after $InstallerTimeoutSeconds seconds." -ForegroundColor Red

    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $RustDeskExe"

    exit 1
}


# ============================================================
# WAIT FOR RustDesk.exe TO STABILIZE
# ============================================================

Write-Host ""
Write-Host "Waiting for RustDesk.exe to finish writing..."


$StableChecksRequired = 3
$StableChecks = 0

$LastLength = -1
$LastWriteTime = [DateTime]::MinValue


for ($i = 0; $i -lt 60; $i++) {

    if (-not (Test-Path -LiteralPath $RustDeskExe)) {

        $StableChecks = 0

        Start-Sleep -Seconds 1

        continue
    }


    try {

        $file = Get-Item `
            -LiteralPath $RustDeskExe `
            -ErrorAction Stop

        $CurrentLength = $file.Length
        $CurrentWriteTime = $file.LastWriteTimeUtc


        if (
            $CurrentLength -eq $LastLength -and
            $CurrentWriteTime -eq $LastWriteTime -and
            $CurrentLength -gt 0
        ) {

            $StableChecks++

        }
        else {

            $StableChecks = 0
        }


        $LastLength = $CurrentLength
        $LastWriteTime = $CurrentWriteTime


        Write-Progress `
            -Activity "Waiting for RustDesk installation" `
            -Status "File size: $CurrentLength bytes; stable checks: $StableChecks/$StableChecksRequired" `
            -PercentComplete (
                [Math]::Min(
                    99,
                    (($i + 1) / 60) * 100
                )
            )


        if ($StableChecks -ge $StableChecksRequired) {

            break
        }

    }
    catch {

        $StableChecks = 0
    }


    Start-Sleep -Seconds 1
}


Write-Progress `
    -Activity "Waiting for RustDesk installation" `
    -Completed


if (
    -not (Test-Path -LiteralPath $RustDeskExe) -or
    $StableChecks -lt $StableChecksRequired
) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe did not stabilize." -ForegroundColor Red

    exit 1
}


$installedExe = Get-Item `
    -LiteralPath $RustDeskExe


Write-Host ""
Write-Host "RustDesk.exe is ready."

Write-Host "Size:"
Write-Host "  $($installedExe.Length) bytes"

Write-Host "Last write:"
Write-Host "  $($installedExe.LastWriteTime)"


# ------------------------------------------------------------
# Give installer additional time for service/files.
# ------------------------------------------------------------

Write-Host ""
Write-Host "Waiting additional 3 seconds for installer finalization..."

Start-Sleep -Seconds 3


# ============================================================
# STOP AGAIN AFTER INSTALLATION
# ============================================================

Write-Host ""
Write-Host "Stopping RustDesk again before configuration..."


if (-not (Stop-RustDeskCompletely)) {
    exit 1
}


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


# ============================================================
# SOURCE FILE INFORMATION
# ============================================================

$SourceFile = Get-Item `
    -LiteralPath $ConfigSource `
    -ErrorAction Stop


if ($SourceFile.Length -eq 0) {

    Write-Host ""
    Write-Host "ERROR: Source RustDesk2.toml is empty." -ForegroundColor Red

    exit 1
}


$SourceHash = (
    Get-FileHash `
        -LiteralPath $ConfigSource `
        -Algorithm SHA256
).Hash


Write-Host "Source RustDesk2.toml:"
Write-Host "  $ConfigSource"

Write-Host "Source size:"
Write-Host "  $($SourceFile.Length) bytes"

Write-Host "Source SHA256:"
Write-Host "  $SourceHash"


# ============================================================
# BACKUP USER CONFIG
# ============================================================

if (Test-Path -LiteralPath $UserConfig) {

    $UserBackup = "$UserConfig.backup"

    Copy-Item `
        -LiteralPath $UserConfig `
        -Destination $UserBackup `
        -Force

    Write-Host ""
    Write-Host "User backup created:"
    Write-Host "  $UserBackup"
}


# ============================================================
# BACKUP SYSTEM CONFIG
# ============================================================

if (Test-Path -LiteralPath $SystemConfig) {

    $SystemBackup = "$SystemConfig.backup"

    Copy-Item `
        -LiteralPath $SystemConfig `
        -Destination $SystemBackup `
        -Force

    Write-Host ""
    Write-Host "System backup created:"
    Write-Host "  $SystemBackup"
}


# ============================================================
# FUNCTION:
# INSTALL CONFIG SAFELY
# ============================================================

function Install-ConfigFile {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )


    $DestinationDir = Split-Path `
        -Parent `
        $Destination


    if (-not (Test-Path -LiteralPath $DestinationDir)) {

        New-Item `
            -Path $DestinationDir `
            -ItemType Directory `
            -Force |
            Out-Null
    }


    # --------------------------------------------------------
    # Create temporary file in the same directory.
    # This avoids cross-volume replacement issues.
    # --------------------------------------------------------

    $TempConfig = Join-Path `
        $DestinationDir `
        "RustDesk2.toml.installing.$([Guid]::NewGuid().ToString('N')).tmp"


    try {

        Copy-Item `
            -LiteralPath $Source `
            -Destination $TempConfig `
            -Force


        # ----------------------------------------------------
        # Verify temporary copy BEFORE replacing target.
        # ----------------------------------------------------

        if (-not (Test-Path -LiteralPath $TempConfig)) {

            throw "Temporary configuration file was not created."
        }


        $TempFile = Get-Item `
            -LiteralPath $TempConfig


        if ($TempFile.Length -ne (Get-Item $Source).Length) {

            throw "Temporary configuration size does not match source."
        }


        $TempHash = (
            Get-FileHash `
                -LiteralPath $TempConfig `
                -Algorithm SHA256
        ).Hash


        if ($TempHash -ne $SourceHash) {

            throw "Temporary configuration SHA256 does not match source."
        }


        # ----------------------------------------------------
        # Remove old destination.
        # ----------------------------------------------------

        if (Test-Path -LiteralPath $Destination) {

            Remove-Item `
                -LiteralPath $Destination `
                -Force
        }


        # ----------------------------------------------------
        # Move verified file into final location.
        # ----------------------------------------------------

        Move-Item `
            -LiteralPath $TempConfig `
            -Destination $Destination `
            -Force


        # ----------------------------------------------------
        # Verify final file.
        # ----------------------------------------------------

        if (-not (Test-Path -LiteralPath $Destination)) {

            throw "Final configuration file does not exist."
        }


        $FinalFile = Get-Item `
            -LiteralPath $Destination


        if ($FinalFile.Length -ne (Get-Item $Source).Length) {

            throw "Final configuration size does not match source."
        }


        $FinalHash = (
            Get-FileHash `
                -LiteralPath $Destination `
                -Algorithm SHA256
        ).Hash


        if ($FinalHash -ne $SourceHash) {

            throw "Final configuration SHA256 does not match source."
        }


        Write-Host ""
        Write-Host "Configuration installed:"
        Write-Host "  $Destination"

        Write-Host "Size:"
        Write-Host "  $($FinalFile.Length) bytes"

        Write-Host "Last write:"
        Write-Host "  $($FinalFile.LastWriteTime)"

        Write-Host "SHA256:"
        Write-Host "  $FinalHash"

    }
    finally {

        if (Test-Path -LiteralPath $TempConfig) {

            Remove-Item `
                -LiteralPath $TempConfig `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}


# ============================================================
# INSTALL USER CONFIG
# ============================================================

Install-ConfigFile `
    -Source $ConfigSource `
    -Destination $UserConfig


# ============================================================
# INSTALL SYSTEM CONFIG
# ============================================================

Install-ConfigFile `
    -Source $ConfigSource `
    -Destination $SystemConfig


# ============================================================
# VERIFY USER CONFIG CONTENT
# ============================================================

Write-Host ""
Write-Host "Verifying user RustDesk2.toml content..."


$UserConfigHash = (
    Get-FileHash `
        -LiteralPath $UserConfig `
        -Algorithm SHA256
).Hash


if ($UserConfigHash -ne $SourceHash) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk2.toml differs from source." -ForegroundColor Red

    exit 1
}


Write-Host "User RustDesk2.toml matches source."


# ============================================================
# VERIFY SYSTEM CONFIG CONTENT
# ============================================================

Write-Host ""
Write-Host "Verifying system RustDesk2.toml content..."


$SystemConfigHash = (
    Get-FileHash `
        -LiteralPath $SystemConfig `
        -Algorithm SHA256
).Hash


if ($SystemConfigHash -ne $SourceHash) {

    Write-Host ""
    Write-Host "ERROR: System RustDesk2.toml differs from source." -ForegroundColor Red

    exit 1
}


Write-Host "System RustDesk2.toml matches source."


# ============================================================
# IMPORTANT:
# DO NOT START RUSTDESK BEFORE CONFIG VERIFICATION
# ============================================================

Write-Host ""
Write-Host "RustDesk2.toml configuration is ready."
Write-Host "RustDesk has NOT been started yet."


# ============================================================
# 5/8 START RUSTDESK
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[5/8] STARTING RUSTDESK"
Write-Host "============================================================"
Write-Host ""

Write-Host "Starting RustDesk GUI..."


Start-Process `
    -FilePath $RustDeskExe


Write-Host "Waiting for RustDesk process..."


$RustDeskRunning = $false


for ($i = 0; $i -lt 30; $i++) {

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


# ------------------------------------------------------------
# IMPORTANT:
# Give RustDesk time to read RustDesk2.toml.
# ------------------------------------------------------------

Write-Host ""
Write-Host "Waiting 8 seconds for RustDesk initialization..."

Start-Sleep -Seconds 8


# ============================================================
# CHECK CONFIG HAS NOT BEEN REPLACED
# ============================================================

Write-Host ""
Write-Host "Checking RustDesk2.toml after startup..."


$UserConfigAfterStart = Get-FileHash `
    -LiteralPath $UserConfig `
    -Algorithm SHA256


if ($UserConfigAfterStart.Hash -ne $SourceHash) {

    Write-Host ""
    Write-Host "WARNING: RustDesk2.toml changed after RustDesk startup." -ForegroundColor Yellow

    Write-Host "Re-applying configuration..."


    # --------------------------------------------------------
    # Stop again.
    # --------------------------------------------------------

    if (-not (Stop-RustDeskCompletely)) {
        exit 1
    }


    # --------------------------------------------------------
    # Re-install config.
    # --------------------------------------------------------

    Install-ConfigFile `
        -Source $ConfigSource `
        -Destination $UserConfig

    Install-ConfigFile `
        -Source $ConfigSource `
        -Destination $SystemConfig


    Write-Host ""
    Write-Host "Configuration re-applied successfully."


    # --------------------------------------------------------
    # Start again.
    # --------------------------------------------------------

    Start-Process `
        -FilePath $RustDeskExe


    Write-Host "Waiting for RustDesk again..."

    $RustDeskRunning = $false


    for ($i = 0; $i -lt 30; $i++) {

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
        Write-Host "ERROR: RustDesk did not restart." -ForegroundColor Red

        exit 1
    }


    Write-Host ""
    Write-Host "Waiting 8 seconds for second initialization..."

    Start-Sleep -Seconds 8
}


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
Write-Host "Password command completed successfully."


# ============================================================
# WAIT FOR PASSWORD CONFIG
# ============================================================

Write-Host ""
Write-Host "Waiting for RustDesk.toml..."


$UserPasswordConfigFound = $false


for ($i = 0; $i -lt 30; $i++) {

    if (Test-Path -LiteralPath $UserPasswordConfig) {

        try {

            $file = Get-Item `
                -LiteralPath $UserPasswordConfig `
                -ErrorAction Stop

            if ($file.Length -gt 0) {

                $UserPasswordConfigFound = $true

                break
            }

        }
        catch {}
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


Write-Host ""
Write-Host "User RustDesk.toml detected."


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

$userPasswordFile = Get-Item `
    -LiteralPath $UserPasswordConfig


Write-Host "User RustDesk.toml:"
Write-Host "  $UserPasswordConfig"

Write-Host "Size:"
Write-Host "  $($userPasswordFile.Length) bytes"

Write-Host "Last write:"
Write-Host "  $($userPasswordFile.LastWriteTime)"


$userPasswordContent = Get-Content `
    -LiteralPath $UserPasswordConfig `
    -Raw `
    -ErrorAction Stop


if ([string]::IsNullOrWhiteSpace($userPasswordContent)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.toml is empty." -ForegroundColor Red

    exit 1
}


# ------------------------------------------------------------
# PASSWORD FIELD
# ------------------------------------------------------------

$HasPasswordField = $false
$HasSaltField = $false


if ($userPasswordContent -match "(?m)^\s*password\s*=") {
    $HasPasswordField = $true
}


if ($userPasswordContent -match "(?m)^\s*salt\s*=") {
    $HasSaltField = $true
}


Write-Host ""
Write-Host "Password field:"
Write-Host "  $HasPasswordField"

Write-Host "Salt field:"
Write-Host "  $HasSaltField"


if (-not $HasPasswordField) {

    Write-Host ""
    Write-Host "ERROR: password field not found in RustDesk.toml." -ForegroundColor Red

    exit 1
}


if (-not $HasSaltField) {

    Write-Host ""
    Write-Host "ERROR: salt field not found in RustDesk.toml." -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "Password configuration verified."


# ============================================================
# SYSTEM PASSWORD CONFIG
# ============================================================

Write-Host ""
Write-Host "Copying RustDesk.toml to System config for permanent unattended access..."

# Копируем файл с паролем и солью в системную директорию службы
Copy-Item `
    -LiteralPath $UserPasswordConfig `
    -Destination $SystemPasswordConfig `
    -Force

if (Test-Path -LiteralPath $SystemPasswordConfig) {

    $systemPasswordFile = Get-Item `
        -LiteralPath $SystemPasswordConfig

    Write-Host ""
    Write-Host "System RustDesk.toml found (copied successfully):"
    Write-Host "  $SystemPasswordConfig"

    Write-Host "Size:"
    Write-Host "  $($systemPasswordFile.Length) bytes"

}
else {

    Write-Host ""
    Write-Host "ERROR: Failed to copy System RustDesk.toml." -ForegroundColor Red
    exit 1
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
# 8/8 START RUSTDESK SERVICE
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
# SERVICE DOES NOT EXIST
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


    Write-Host ""
    Write-Host "Service installer exit code:"
    Write-Host "  $($installServiceProcess.ExitCode)"


    if ($installServiceProcess.ExitCode -ne 0) {

        Write-Host ""
        Write-Host "WARNING: Service installer returned non-zero exit code." -ForegroundColor Yellow
    }


    # --------------------------------------------------------
    # Wait for service registration.
    # --------------------------------------------------------

    for ($i = 0; $i -lt 30; $i++) {

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if ($null -ne $service) {
            break
        }

        Start-Sleep -Seconds 1
    }
}


# ============================================================
# VERIFY SERVICE EXISTS
# ============================================================

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service could not be created." -ForegroundColor Red

    exit 1
}


Write-Host ""
Write-Host "RustDesk service found."


# ============================================================
# START SERVICE
# ============================================================

if ($service.Status -ne "Running") {

    Write-Host "Starting RustDesk service..."

    Start-Service `
        -Name $ServiceName `
        -ErrorAction Stop
}


# ============================================================
# WAIT FOR SERVICE
# ============================================================

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


Write-Host ""
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
# FINAL CONFIG VERIFICATION
# ============================================================

Write-Host ""
Write-Host "Final RustDesk2.toml verification..."


if (-not (Test-Path -LiteralPath $UserConfig)) {

    Write-Host ""
    Write-Host "ERROR: Final user RustDesk2.toml is missing." -ForegroundColor Red

    exit 1
}


$FinalConfigFile = Get-Item `
    -LiteralPath $UserConfig


$FinalConfigHash = (
    Get-FileHash `
        -LiteralPath $UserConfig `
        -Algorithm SHA256
).Hash


Write-Host "Final user RustDesk2.toml:"
Write-Host "  $UserConfig"

Write-Host "Size:"
Write-Host "  $($FinalConfigFile.Length) bytes"

Write-Host "Last write:"
Write-Host "  $($FinalConfigFile.LastWriteTime)"

Write-Host "SHA256:"
Write-Host "  $FinalConfigHash"


if ($FinalConfigHash -ne $SourceHash) {

    Write-Host ""
    Write-Host "WARNING: RustDesk2.toml differs from installation source." -ForegroundColor Yellow

}
else {

    Write-Host ""
    Write-Host "RustDesk2.toml still matches source."
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
Write-Host "  $OriginalUserName"


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

if ($null -ne $guiProcess) {

    Write-Host "  RUNNING"

}
else {

    Write-Host "  NOT DETECTED"

}


Write-Host ""
Write-Host "============================================================"
Write-Host ""