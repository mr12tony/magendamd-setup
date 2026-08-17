param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter(Position = 1)]
    [string]$RustDeskConfig,

    [Parameter()]
    [string]$ArgsFile
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptPath = $PSCommandPath
$ScriptDir  = Split-Path -Parent $ScriptPath

$RustDeskX64 = Join-Path $ScriptDir "rustdesk-x86_64.exe"
$RustDeskArm = Join-Path $ScriptDir "rustdesk-aarch64.exe"

$RustDeskExe = Join-Path ${env:ProgramFiles} "RustDesk\rustdesk.exe"

$ServiceName = "Rustdesk"

# Лог в TEMP, чтобы не зависеть от прав на resources/
$LogFile = Join-Path $env:TEMP "rustdesk-install.log"

# ============================================================
# LOG
# ============================================================

function Write-Log {
    param(
        [string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

    try {
        Add-Content `
            -LiteralPath $LogFile `
            -Value $line `
            -Encoding UTF8 `
            -ErrorAction SilentlyContinue
    }
    catch {
    }

    Write-Output $line
}

function Write-Section {
    param(
        [string]$Name
    )

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "[$Name]"
    Write-Log "============================================================"
}

# ============================================================
# ADMIN
# ============================================================

function Test-Administrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ============================================================
# START
# ============================================================

Write-Section "START"

Write-Log "RustDesk installer started."
Write-Log "Script: $ScriptPath"
Write-Log "ScriptDir: $ScriptDir"
Write-Log "LogFile: $LogFile"
Write-Log "User: $env:USERNAME"
Write-Log "Is administrator: $(Test-Administrator)"

# ============================================================
# ELEVATION
# ============================================================

if (-not (Test-Administrator)) {

    Write-Section "ELEVATION"

    Write-Log "Current PowerShell is NOT elevated."

    # --------------------------------------------------------
    # Temporary argument file
    # --------------------------------------------------------

    $TempArgsFile = Join-Path `
        $env:TEMP `
        "rustdesk-install-$([Guid]::NewGuid().ToString('N')).json"

    try {

        $data = @{
            Password = $RustDeskPassword
            Config   = $RustDeskConfig
        }

        $data |
            ConvertTo-Json -Compress |
            Set-Content `
                -LiteralPath $TempArgsFile `
                -Encoding UTF8

        Write-Log "Temporary arguments file created:"
        Write-Log $TempArgsFile

        # ----------------------------------------------------
        # IMPORTANT:
        # Quote paths explicitly.
        # ----------------------------------------------------

        $psArguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$ScriptPath`""
            "-ArgsFile"
            "`"$TempArgsFile`""
        )

        Write-Log "Starting elevated PowerShell..."

        # ----------------------------------------------------
        # UAC
        # ----------------------------------------------------

        $process = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $psArguments `
            -PassThru `
            -WorkingDirectory $ScriptDir

        if ($null -eq $process) {

            Write-Log "ERROR: Start-Process returned null."

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue

            exit 1
        }

        Write-Log "Elevated PowerShell started."
        Write-Log "PID: $($process.Id)"

        # ----------------------------------------------------
        # WAIT FOR ELEVATED PROCESS
        # ----------------------------------------------------

        Write-Log "Waiting for elevated PowerShell..."

        $process.WaitForExit()

        $exitCode = $process.ExitCode

        Write-Log "Elevated PowerShell finished."
        Write-Log "Exit code: $exitCode"

        # ----------------------------------------------------
        # CLEANUP
        # ----------------------------------------------------

        if (Test-Path -LiteralPath $TempArgsFile) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        # ----------------------------------------------------
        # RETURN RESULT
        # ----------------------------------------------------

        if ($exitCode -eq 0) {

            Write-Log "Elevated installation completed successfully."

            exit 0
        }

        Write-Log "ERROR: Elevated installation failed."

        exit $exitCode
    }
    catch {

        Write-Log "ERROR during elevation:"
        Write-Log $_.Exception.Message

        if ($null -ne $TempArgsFile) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        exit 1
    }
}

# ============================================================
# ELEVATED INSTANCE
# ============================================================

Write-Section "ELEVATED INSTANCE"

Write-Log "Running as Administrator."

# ============================================================
# LOAD ARGUMENTS
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($ArgsFile)) {

    Write-Log "Loading arguments from temporary file:"
    Write-Log $ArgsFile

    if (-not (Test-Path -LiteralPath $ArgsFile)) {

        Write-Log "ERROR: Arguments file does not exist."

        exit 1
    }

    try {

        $json = Get-Content `
            -LiteralPath $ArgsFile `
            -Raw `
            -Encoding UTF8

        $data = $json | ConvertFrom-Json

        if ($null -eq $data) {

            Write-Log "ERROR: Arguments JSON is empty."

            exit 1
        }

        $RustDeskPassword = [string]$data.Password
        $RustDeskConfig   = [string]$data.Config

        Write-Log "Password loaded: YES"
        Write-Log "Config loaded: YES"
        Write-Log "Config length: $($RustDeskConfig.Length)"

        Remove-Item `
            -LiteralPath $ArgsFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {

        Write-Log "ERROR loading arguments:"
        Write-Log $_.Exception.Message

        exit 1
    }
}

# ============================================================
# VERIFY ADMIN
# ============================================================

if (-not (Test-Administrator)) {

    Write-Log "ERROR: Elevated instance is not Administrator."

    exit 1
}

# ============================================================
# ARCHITECTURE
# ============================================================

Write-Section "ARCHITECTURE"

$arch1 = $env:PROCESSOR_ARCHITECTURE
$arch2 = $env:PROCESSOR_ARCHITEW6432

Write-Log "PROCESSOR_ARCHITECTURE: $arch1"
Write-Log "PROCESSOR_ARCHITEW6432: $arch2"

$selectedInstaller = $null

if (
    $arch1 -eq "AMD64" -or
    $arch2 -eq "AMD64"
) {

    Write-Log "Detected AMD64."

    $selectedInstaller = $RustDeskX64
}
elseif (
    $arch1 -eq "ARM64" -or
    $arch2 -eq "ARM64"
) {

    Write-Log "Detected ARM64."

    $selectedInstaller = $RustDeskArm
}
else {

    Write-Log "ERROR: Unsupported architecture."

    exit 1
}

Write-Log "Selected installer:"
Write-Log $selectedInstaller

# ============================================================
# CHECK INSTALLER
# ============================================================

if (-not (Test-Path -LiteralPath $selectedInstaller)) {

    Write-Log "ERROR: RustDesk installer not found."

    exit 1
}

Write-Log "Installer exists."

# ============================================================
# STOP OLD RUSTDESK
# ============================================================

Write-Section "CLEANUP"

Write-Log "Stopping RustDesk processes..."

Get-Process `
    -Name "rustdesk" `
    -ErrorAction SilentlyContinue |
    Stop-Process `
        -Force `
        -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# ============================================================
# STOP OLD SERVICE
# ============================================================

Write-Log "Checking RustDesk service..."

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -ne $service) {

    Write-Log "RustDesk service exists."
    Write-Log "Status: $($service.Status)"

    if ($service.Status -eq "Running") {

        Write-Log "Stopping RustDesk service..."

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }

    Write-Log "Deleting RustDesk service..."

    & sc.exe delete $ServiceName 2>&1 |
        ForEach-Object {
            Write-Log $_
        }

    Start-Sleep -Seconds 3
}

# ============================================================
# REMOVE OLD INSTALLATION
# ============================================================

$oldInstallDir = Join-Path ${env:ProgramFiles} "RustDesk"

if (Test-Path -LiteralPath $oldInstallDir) {

    Write-Log "Removing old RustDesk installation..."

    Remove-Item `
        -LiteralPath $oldInstallDir `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
}

# ============================================================
# INSTALL RUSTDESK
# ============================================================

Write-Section "INSTALL"

Write-Log "Starting RustDesk installer."

try {

    $installerProcess = Start-Process `
        -FilePath $selectedInstaller `
        -ArgumentList "--silent-install" `
        -PassThru `
        -Wait

    Write-Log "RustDesk installer finished."
    Write-Log "Installer exit code: $($installerProcess.ExitCode)"

    if ($installerProcess.ExitCode -ne 0) {

        Write-Log "ERROR: RustDesk installer returned non-zero exit code."

        exit 1
    }
}
catch {

    Write-Log "ERROR starting RustDesk installer:"
    Write-Log $_.Exception.Message

    exit 1
}

# ============================================================
# WAIT FOR RUSTDESK EXE
# ============================================================

Write-Log "Waiting for rustdesk.exe..."

$found = $false

for ($i = 0; $i -lt 30; $i++) {

    if (Test-Path -LiteralPath $RustDeskExe) {

        $found = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $found) {

    Write-Log "ERROR: rustdesk.exe was not found."

    exit 1
}

Write-Log "RustDesk executable found:"
Write-Log $RustDeskExe

# ============================================================
# SERVICE
# ============================================================

Write-Section "SERVICE"

Write-Log "Installing RustDesk service..."

try {

    # Здесь намеренно НЕ используем -Wait.
    # Ждём появления службы отдельно.

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -PassThru

    Write-Log "Service installation process started."
    Write-Log "PID: $($serviceProcess.Id)"
}
catch {

    Write-Log "ERROR starting service installation:"
    Write-Log $_.Exception.Message

    exit 1
}

# ============================================================
# WAIT FOR SERVICE
# ============================================================

$serviceFound = $false

for ($i = 0; $i -lt 30; $i++) {

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        $serviceFound = $true

        Write-Log "RustDesk service found."
        Write-Log "Status: $($service.Status)"

        break
    }

    Start-Sleep -Seconds 1
}

if (-not $serviceFound) {

    Write-Log "ERROR: RustDesk service was not created."

    if (-not $serviceProcess.HasExited) {

        Stop-Process `
            -Id $serviceProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

    exit 1
}

# ============================================================
# SERVICE AUTOSTART
# ============================================================

Write-Section "SERVICE AUTOSTART"

try {

    Set-Service `
        -Name $ServiceName `
        -StartupType Automatic `
        -ErrorAction Stop

    Write-Log "Service startup type set to Automatic."
}
catch {

    Write-Log "Set-Service failed. Trying sc.exe..."

    & sc.exe config $ServiceName start= auto 2>&1 |
        ForEach-Object {
            Write-Log $_
        }
}

# ============================================================
# START SERVICE
# ============================================================

Write-Section "SERVICE START"

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Log "ERROR: RustDesk service does not exist."

    exit 1
}

if ($service.Status -ne "Running") {

    Write-Log "Starting RustDesk service..."

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop
    }
    catch {

        Write-Log "WARNING: Start-Service failed:"
        Write-Log $_.Exception.Message
    }
}

# Wait for Running

$running = $false

for ($i = 0; $i -lt 20; $i++) {

    Start-Sleep -Seconds 1

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if ($null -ne $service) {

        Write-Log "Service status: $($service.Status)"

        if ($service.Status -eq "Running") {

            $running = $true
            break
        }
    }
}

if (-not $running) {

    Write-Log "WARNING: RustDesk service is not running."
}
else {

    Write-Log "RustDesk service is running."
}

# ============================================================
# CONFIG
# ============================================================

Write-Section "CONFIG"

if (-not [string]::IsNullOrWhiteSpace($RustDeskConfig)) {

    Write-Log "Applying RustDesk configuration..."

    try {

        $process = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--config",
                $RustDeskConfig
            ) `
            -PassThru `
            -Wait

        Write-Log "Config exit code: $($process.ExitCode)"

        if ($process.ExitCode -ne 0) {

            Write-Log "WARNING: Config returned non-zero exit code."
        }
    }
    catch {

        Write-Log "WARNING: Config failed:"
        Write-Log $_.Exception.Message
    }
}
else {

    Write-Log "Config is empty."
}

# ============================================================
# PASSWORD
# ============================================================

Write-Section "PASSWORD"

if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    Write-Log "Applying RustDesk password..."

    try {

        $process = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--password",
                $RustDeskPassword
            ) `
            -PassThru `
            -Wait

        Write-Log "Password exit code: $($process.ExitCode)"

        if ($process.ExitCode -ne 0) {

            Write-Log "WARNING: Password returned non-zero exit code."
        }
    }
    catch {

        Write-Log "WARNING: Password command failed:"
        Write-Log $_.Exception.Message
    }
}
else {

    Write-Log "Password is empty."
}

# ============================================================
# FINAL
# ============================================================

Write-Section "FINAL"

if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Log "ERROR: RustDesk executable does not exist."

    exit 1
}

$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($null -eq $service) {

    Write-Log "ERROR: RustDesk service does not exist."

    exit 1
}

Write-Log "RustDesk executable: OK"
Write-Log "RustDesk service: $($service.Status)"
Write-Log "Installation completed successfully."

Write-Section "END"

exit 0