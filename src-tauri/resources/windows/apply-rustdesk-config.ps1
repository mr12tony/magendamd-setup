param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter()]
    [string]$PasswordFile
)

$ErrorActionPreference = "Stop"

# ============================================================
# SETTINGS
# ============================================================

$ConfigSource = Join-Path $PSScriptRoot "RustDesk2.toml"

$ServiceName = "RustDesk"
$RustDeskExe = "C:\Program Files\RustDesk\RustDesk.exe"


# ============================================================
# ADMIN CHECK
# ============================================================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object Security.Principal.WindowsPrincipal($identity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)


# ============================================================
# UAC ELEVATION
# ============================================================

if (-not $isAdmin) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "RustDesk configuration requires Administrator privileges."
    Write-Host "Requesting UAC elevation..."
    Write-Host "============================================================"
    Write-Host ""

    $TempPasswordFile = ""

    # --------------------------------------------------------
    # Save supplied password for elevated process
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
            -WorkingDirectory $PSScriptRoot `
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
# GENERATE PASSWORD IF NOT PROVIDED
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

# Current user
$UserConfigDir = Join-Path `
    $env:APPDATA `
    "RustDesk\config"

$UserConfig = Join-Path `
    $UserConfigDir `
    "RustDesk2.toml"

$UserPasswordConfig = Join-Path `
    $UserConfigDir `
    "RustDesk.toml"


# RustDesk Windows Service runs as LocalService
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
Write-Host "             RUSTDESK CONFIG + PASSWORD"
Write-Host "============================================================"
Write-Host ""

Write-Host "RustDesk executable:"
Write-Host "  $RustDeskExe"

Write-Host ""
Write-Host "Config source:"
Write-Host "  $ConfigSource"

Write-Host ""
Write-Host "User RustDesk2.toml:"
Write-Host "  $UserConfig"

Write-Host ""
Write-Host "System RustDesk2.toml:"
Write-Host "  $SystemConfig"

Write-Host ""

# ============================================================
# CHECK RUSTDESK
# ============================================================

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk.exe not found:" -ForegroundColor Red
    Write-Host $RustDeskExe
    Write-Host ""

    exit 1
}


# ============================================================
# CHECK CONFIG
# ============================================================

if (-not (Test-Path -LiteralPath $ConfigSource)) {

    Write-Host ""
    Write-Host "ERROR: RustDesk2.toml not found:" -ForegroundColor Red
    Write-Host $ConfigSource
    Write-Host ""

    exit 1
}


# ============================================================
# PASSWORD INFO
# ============================================================

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
# 1. STOP SERVICE
# ============================================================

Write-Host "============================================================"
Write-Host "[1/6] STOPPING RUSTDESK SERVICE"
Write-Host "============================================================"
Write-Host ""

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Host "Current status: $($service.Status)"

    if ($service.Status -ne "Stopped") {

        Write-Host "Stopping service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------
    # Wait until service is stopped
    # --------------------------------------------------------

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
        Write-Host "ERROR: RustDesk service could not be stopped." -ForegroundColor Red
        Write-Host ""

        exit 1
    }

    Write-Host "Service stopped."

}
else {

    Write-Host "RustDesk service not found."
}


# ============================================================
# 2. STOP GUI
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[2/6] STOPPING RUSTDESK GUI"
Write-Host "============================================================"
Write-Host ""

Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2


# ------------------------------------------------------------
# Wait until GUI disappears
# ------------------------------------------------------------

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
    Write-Host "ERROR: RustDesk GUI process is still running." -ForegroundColor Red
    Write-Host ""

    exit 1
}

Write-Host "RustDesk GUI stopped."


# ============================================================
# 3. INSTALL RUSTDESK2.TOML
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[3/6] INSTALLING RUSTDESK2.TOML"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# USER CONFIG DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $UserConfigDir)) {

    New-Item `
        -Path $UserConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# SYSTEM CONFIG DIRECTORY
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SystemConfigDir)) {

    New-Item `
        -Path $SystemConfigDir `
        -ItemType Directory `
        -Force |
        Out-Null
}


# ------------------------------------------------------------
# BACKUP USER CONFIG
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
# BACKUP SYSTEM CONFIG
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
# 4. START RUSTDESK + APPLY PASSWORD
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[4/6] STARTING RUSTDESK + APPLYING PASSWORD"
Write-Host "============================================================"
Write-Host ""


# ------------------------------------------------------------
# START RUSTDESK
# ------------------------------------------------------------

Write-Host "Starting RustDesk..."

Start-Process `
    -FilePath $RustDeskExe

Write-Host "Waiting for RustDesk to initialize..."

Start-Sleep -Seconds 5


# ------------------------------------------------------------
# VERIFY RUSTDESK PROCESS
# ------------------------------------------------------------

$rustDeskProcess = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -eq $rustDeskProcess) {

    Write-Host ""
    Write-Host "ERROR: RustDesk process did not start." -ForegroundColor Red
    Write-Host ""

    exit 1
}

Write-Host "RustDesk process is running."


# ------------------------------------------------------------
# APPLY PASSWORD
# ------------------------------------------------------------

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

Write-Host "RustDesk --password exit code: $($passwordProcess.ExitCode)"


if ($passwordProcess.ExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: RustDesk --password failed." -ForegroundColor Red
    Write-Host ""

    exit 1
}

Write-Host "Password applied successfully."


# ------------------------------------------------------------
# WAIT FOR RustDesk.toml
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking RustDesk.toml..."

$PasswordConfigFound = $false

for ($i = 0; $i -lt 10; $i++) {

    if (Test-Path -LiteralPath $UserPasswordConfig) {

        $passwordConfigFile = Get-Item `
            -LiteralPath $UserPasswordConfig

        if ($passwordConfigFile.Length -gt 0) {

            $PasswordConfigFound = $true

            break
        }
    }

    Start-Sleep -Seconds 1
}


# ------------------------------------------------------------
# VERIFY USER RustDesk.toml
# ------------------------------------------------------------

if (-not $PasswordConfigFound) {

    Write-Host ""
    Write-Host "ERROR: User RustDesk.toml was not created or is empty." -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  $UserPasswordConfig"
    Write-Host ""

    exit 1
}

Write-Host ""
Write-Host "User RustDesk.toml verified:"
Write-Host "  $UserPasswordConfig"

$passwordConfigFile = Get-Item `
    -LiteralPath $UserPasswordConfig

Write-Host "Size:"
Write-Host "  $($passwordConfigFile.Length) bytes"


# ------------------------------------------------------------
# VERIFY SYSTEM RustDesk.toml
# ------------------------------------------------------------

if (Test-Path -LiteralPath $SystemPasswordConfig) {

    $systemPasswordConfigFile = Get-Item `
        -LiteralPath $SystemPasswordConfig

    Write-Host ""
    Write-Host "System RustDesk.toml found:"
    Write-Host "  $SystemPasswordConfig"

    Write-Host "Size:"
    Write-Host "  $($systemPasswordConfigFile.Length) bytes"
}
else {

    Write-Host ""
    Write-Host "WARNING: System RustDesk.toml was not found." -ForegroundColor Yellow
}


# ============================================================
# 5. RESTART SERVICE
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[5/6] STARTING RUSTDESK SERVICE"
Write-Host "============================================================"
Write-Host ""

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Host ""
    Write-Host "ERROR: RustDesk service does not exist." -ForegroundColor Red
    Write-Host ""

    exit 1
}


Start-Service `
    -Name $ServiceName


# ------------------------------------------------------------
# Wait until service is running
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
    Write-Host "ERROR: RustDesk service failed to start." -ForegroundColor Red
    Write-Host ""

    Get-Service `
        -Name $ServiceName |
        Format-List Name,Status,StartType

    exit 1
}

Write-Host "RustDesk service is RUNNING."


# ============================================================
# 6. GUI
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "[6/6] GUI"
Write-Host "============================================================"
Write-Host ""

$guiProcess = Get-Process `
    -Name "RustDesk" `
    -ErrorAction SilentlyContinue

if ($null -ne $guiProcess) {

    Write-Host "RustDesk GUI is RUNNING."
}
else {

    Write-Host "WARNING: RustDesk GUI process was not detected." -ForegroundColor Yellow
}


# ============================================================
# FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "                         DONE"
Write-Host "============================================================"
Write-Host ""

Write-Host "Password:"
Write-Host "  $RustDeskPassword"

Write-Host ""
Write-Host "Service:"

Get-Service `
    -Name $ServiceName |
    Format-List Name,Status,StartType

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
Write-Host "RustDesk GUI remains running."

Write-Host ""
Write-Host "============================================================"