#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter(Position = 1)]
    [string]$RustDeskConfig,

    # Internal parameters used during UAC elevation.
    [Parameter(DontShow)]
    [string]$PasswordB64,

    [Parameter(DontShow)]
    [string]$ConfigB64,

    [Parameter(DontShow)]
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# PATHS
# ============================================================

$ScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$ScriptDir  = Split-Path -Parent $ScriptPath

# Keep the installer log next to install.ps1
$LogFile = Join-Path $ScriptDir 'rustdesk-install.log'

$ProgramFilesRustDesk = Join-Path $env:ProgramFiles 'RustDesk'
$RustDeskExe          = Join-Path $ProgramFilesRustDesk 'rustdesk.exe'

$ServiceName = 'Rustdesk'

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp - $Message"

    Write-Host $line

    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "LOG ERROR: $($_.Exception.Message)"
    }
}

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Log "============================================================"
    Write-Log "[$Title]"
    Write-Log "============================================================"
}

# ============================================================
# BASE64 HELPERS
# ============================================================

function ConvertTo-Base64String {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToBase64String($bytes)
}

function ConvertFrom-Base64String {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $bytes = [Convert]::FromBase64String($Value)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# ============================================================
# ADMIN CHECK
# ============================================================

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ============================================================
# RUN PROCESS
# ============================================================

function Invoke-ProcessChecked {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [int]$TimeoutSeconds = 120,

        [switch]$IgnoreExitCode
    )

    $displayArgs = ($Arguments -join ' ')

    Write-Log "[PROCESS] $FilePath $displayArgs"

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Build arguments safely.
    if ($Arguments.Count -gt 0) {
        $psi.Arguments = ($Arguments | ForEach-Object {
            $arg = [string]$_

            if ($arg -match '[\s"]') {
                '"' + ($arg -replace '"', '\"') + '"'
            }
            else {
                $arg
            }
        }) -join ' '
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        throw "Failed to start process: $FilePath"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill()
        }
        catch {}

        throw "Process timeout after $TimeoutSeconds seconds: $FilePath"
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode

    $stdoutClean = $stdout.Trim()
    $stderrClean = $stderr.Trim()

    if ($stdoutClean) {
        Write-Log "[PROCESS STDOUT] $stdoutClean"
    }

    if ($stderrClean) {
        Write-Log "[PROCESS STDERR] $stderrClean"
    }

    Write-Log "[PROCESS EXIT] $exitCode"

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "Process failed with exit code $exitCode: $FilePath"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        StdOut   = $stdoutClean
        StdErr   = $stderrClean
    }
}

# ============================================================
# STOP RUSTDESK
# ============================================================

function Stop-RustDesk {
    Write-Section "CLEANUP"

    Write-Log "[CLEANUP] Stopping RustDesk processes..."

    # Try normal process stop first.
    Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    # Also use taskkill because RustDesk may run under another account/service.
    & taskkill.exe /F /IM RustDesk.exe /T 2>$null | Out-Null
    & taskkill.exe /F /IM rustdesk.exe /T 2>$null | Out-Null

    Start-Sleep -Seconds 2

    $remaining = Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue

    if ($remaining) {
        Write-Log "[CLEANUP] WARNING: RustDesk processes are still running."
    }
    else {
        Write-Log "[CLEANUP] No RustDesk processes remain."
    }
}

# ============================================================
# REMOVE OLD DATA
# ============================================================

function Remove-RustDeskData {
    Write-Section "REMOVE"

    # --------------------------------------------------------
    # Service
    # --------------------------------------------------------

    Write-Log "[REMOVE] Stopping RustDesk service..."

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service) {
        try {
            if ($service.Status -ne 'Stopped') {
                Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        catch {
            Write-Log "[REMOVE] Service stop warning: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # Remove service
    # --------------------------------------------------------

    Write-Log "[REMOVE] Removing RustDesk service..."

    try {
        & sc.exe stop $ServiceName 2>$null | Out-Null
    }
    catch {}

    Start-Sleep -Seconds 1

    try {
        & sc.exe delete $ServiceName 2>$null | Out-Null
    }
    catch {}

    Start-Sleep -Seconds 2

    # --------------------------------------------------------
    # Application
    # --------------------------------------------------------

    if (Test-Path -LiteralPath $ProgramFilesRustDesk) {
        Write-Log "[REMOVE] Removing old RustDesk installation..."

        try {
            Remove-Item `
                -LiteralPath $ProgramFilesRustDesk `
                -Recurse `
                -Force `
                -ErrorAction Stop

            Write-Log "[REMOVE] Program Files RustDesk removed."
        }
        catch {
            throw "Failed to remove $ProgramFilesRustDesk : $($_.Exception.Message)"
        }
    }
    else {
        Write-Log "[REMOVE] Old RustDesk installation not found."
    }

    # --------------------------------------------------------
    # Current user's RustDesk data
    # --------------------------------------------------------

    $userAppData = Join-Path $env:APPDATA 'RustDesk'
    $userLocalAppData = Join-Path $env:LOCALAPPDATA 'RustDesk'

    if (Test-Path -LiteralPath $userAppData) {
        Write-Log "[REMOVE] Removing user APPDATA RustDesk..."
        Remove-Item -LiteralPath $userAppData -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $userLocalAppData) {
        Write-Log "[REMOVE] Removing user LOCALAPPDATA RustDesk..."
        Remove-Item -LiteralPath $userLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------
    # Service account data
    # --------------------------------------------------------

    $serviceProfileRustDesk = Join-Path `
        $env:WinDir `
        'ServiceProfiles\LocalService\AppData\Roaming\RustDesk'

    if (Test-Path -LiteralPath $serviceProfileRustDesk) {
        Write-Log "[REMOVE] Removing LocalService RustDesk data..."

        Remove-Item `
            -LiteralPath $serviceProfileRustDesk `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------
    # ProgramData
    # --------------------------------------------------------

    $programDataRustDesk = Join-Path $env:ProgramData 'RustDesk'

    if (Test-Path -LiteralPath $programDataRustDesk) {
        Write-Log "[REMOVE] Removing ProgramData RustDesk..."

        Remove-Item `
            -LiteralPath $programDataRustDesk `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Log "[REMOVE] Cleanup completed."
}

# ============================================================
# FIND INSTALLER
# ============================================================

function Find-RustDeskInstaller {
    Write-Section "INSTALLER"

    Write-Log "[INSTALLER] Searching for RustDesk installer..."

    $candidates = @(
        'rustdesk*.exe',
        '*rustdesk*.exe',
        'RustDesk*.msi',
        '*RustDesk*.msi'
    )

    $files = @()

    foreach ($pattern in $candidates) {
        $found = Get-ChildItem `
            -LiteralPath $ScriptDir `
            -Filter $pattern `
            -File `
            -ErrorAction SilentlyContinue

        if ($found) {
            $files += $found
        }
    }

    $files = $files |
        Sort-Object `
            @{Expression = {
                if ($_.Extension -ieq '.exe') { 0 } else { 1 }
            }},
            Name

    if (-not $files -or $files.Count -eq 0) {
        throw "RustDesk installer was not found in: $ScriptDir"
    }

    $installer = $files[0].FullName

    Write-Log "[INSTALLER] Selected: $installer"

    return $installer
}

# ============================================================
# INSTALL RUSTDESK
# ============================================================

function Install-RustDesk {
    param(
        [Parameter(Mandatory)]
        [string]$InstallerPath
    )

    Write-Section "INSTALL"

    $extension = [System.IO.Path]::GetExtension($InstallerPath)

    if ($extension -ieq '.exe') {

        Write-Log "[INSTALL] Running RustDesk silent installer..."

        $result = Invoke-ProcessChecked `
            -FilePath $InstallerPath `
            -Arguments @('--silent-install') `
            -TimeoutSeconds 180 `
            -IgnoreExitCode

        if ($result.ExitCode -ne 0) {
            Write-Log "[INSTALL] Installer returned exit code $($result.ExitCode)."
            Write-Log "[INSTALL] Continuing to verify installation..."
        }
    }
    elseif ($extension -ieq '.msi') {

        Write-Log "[INSTALL] Installing RustDesk MSI..."

        $result = Invoke-ProcessChecked `
            -FilePath 'msiexec.exe' `
            -Arguments @(
                '/i',
                $InstallerPath,
                '/qn',
                '/norestart'
            ) `
            -TimeoutSeconds 180 `
            -IgnoreExitCode

        if ($result.ExitCode -notin @(0, 3010)) {
            throw "MSI installation failed with exit code $($result.ExitCode)"
        }

        if ($result.ExitCode -eq 3010) {
            Write-Log "[INSTALL] MSI requested reboot (3010), continuing."
        }
    }
    else {
        throw "Unsupported installer type: $extension"
    }

    Start-Sleep -Seconds 5

    if (-not (Test-Path -LiteralPath $RustDeskExe)) {

        # Some installers may need a little longer.
        Write-Log "[INSTALL] rustdesk.exe not found yet. Waiting..."

        $deadline = (Get-Date).AddSeconds(30)

        while ((Get-Date) -lt $deadline) {

            if (Test-Path -LiteralPath $RustDeskExe) {
                break
            }

            Start-Sleep -Seconds 2
        }
    }

    if (-not (Test-Path -LiteralPath $RustDeskExe)) {
        throw "RustDesk installation finished, but rustdesk.exe was not found at $RustDeskExe"
    }

    Write-Log "[INSTALL] RustDesk executable found."
    Write-Log "[INSTALL] Path: $RustDeskExe"
}

# ============================================================
# INSTALL SERVICE
# ============================================================

function Install-RustDeskService {
    Write-Section "SERVICE"

    Write-Log "[SERVICE] Installing RustDesk service..."

    Invoke-ProcessChecked `
        -FilePath $RustDeskExe `
        -Arguments @('--install-service') `
        -TimeoutSeconds 120 `
        -IgnoreExitCode

    Start-Sleep -Seconds 5

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {
        throw "RustDesk service was not created."
    }

    Write-Log "[SERVICE] Service exists: $ServiceName"

    # Start service.
    try {
        if ($service.Status -ne 'Running') {
            Start-Service -Name $ServiceName -ErrorAction Stop
        }
    }
    catch {
        Write-Log "[SERVICE] Start-Service failed: $($_.Exception.Message)"
    }

    # Wait for running.
    $deadline = (Get-Date).AddSeconds(60)

    do {
        Start-Sleep -Seconds 3

        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction SilentlyContinue

        if (-not $service) {
            break
        }

        Write-Log "[SERVICE] Current status: $($service.Status)"

        if ($service.Status -eq 'Running') {
            break
        }

    } while ((Get-Date) -lt $deadline)

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service -or $service.Status -ne 'Running') {
        throw "RustDesk service is not running."
    }

    Write-Log "[SERVICE] RustDesk service is running."
}

# ============================================================
# CONFIGURE RUSTDESK
# ============================================================

function Configure-RustDesk {
    param(
        [Parameter(Mandatory)]
        [string]$Password,

        [Parameter(Mandatory)]
        [string]$Config
    )

    Write-Section "CONFIG"

    if ([string]::IsNullOrWhiteSpace($Config)) {
        throw "RustDesk configuration string is empty."
    }

    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw "RustDesk password is empty."
    }

    # --------------------------------------------------------
    # Get ID BEFORE configuration
    # --------------------------------------------------------

    Write-Log "[ID] Getting RustDesk ID..."

    $idResult = Invoke-ProcessChecked `
        -FilePath $RustDeskExe `
        -Arguments @('--get-id') `
        -TimeoutSeconds 60

    $rustdeskId = $idResult.StdOut.Trim()

    if ([string]::IsNullOrWhiteSpace($rustdeskId)) {
        throw "RustDesk returned an empty ID."
    }

    Write-Log "[ID] RustDesk ID: $rustdeskId"

    # --------------------------------------------------------
    # Apply encrypted config
    # --------------------------------------------------------

    Write-Log "[CONFIG] Applying RustDesk encrypted configuration..."

    $configResult = Invoke-ProcessChecked `
        -FilePath $RustDeskExe `
        -Arguments @('--config', $Config) `
        -TimeoutSeconds 60 `
        -IgnoreExitCode

    if ($configResult.ExitCode -ne 0) {
        throw "RustDesk --config failed with exit code $($configResult.ExitCode)"
    }

    # --------------------------------------------------------
    # Apply permanent password
    # --------------------------------------------------------

    Write-Log "[PASSWORD] Applying RustDesk permanent password..."

    $passwordResult = Invoke-ProcessChecked `
        -FilePath $RustDeskExe `
        -Arguments @('--password', $Password) `
        -TimeoutSeconds 60 `
        -IgnoreExitCode

    if ($passwordResult.ExitCode -ne 0) {
        throw "RustDesk --password failed with exit code $($passwordResult.ExitCode)"
    }

    Write-Log "[CONFIG] RustDesk configuration commands completed."

    # --------------------------------------------------------
    # Restart service so configuration is picked up
    # --------------------------------------------------------

    Write-Log "[SERVICE] Restarting RustDesk service..."

    Restart-Service `
        -Name $ServiceName `
        -Force `
        -ErrorAction Stop

    Start-Sleep -Seconds 5

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction Stop

    if ($service.Status -ne 'Running') {
        throw "RustDesk service did not return to Running state."
    }

    Write-Log "[SERVICE] RustDesk service restarted successfully."

    return $rustdeskId
}

# ============================================================
# VERIFY
# ============================================================

function Verify-RustDesk {
    Write-Section "VERIFY"

    if (-not (Test-Path -LiteralPath $RustDeskExe)) {
        throw "Verification failed: RustDesk executable does not exist."
    }

    $service = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $service) {
        throw "Verification failed: RustDesk service does not exist."
    }

    if ($service.Status -ne 'Running') {
        throw "Verification failed: RustDesk service is not running."
    }

    # Current user config
    $userConfigDir = Join-Path $env:APPDATA 'RustDesk\config'

    # Service profile config
    $serviceConfigDir = Join-Path `
        $env:WinDir `
        'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'

    Write-Log "[VERIFY] User config directory: $userConfigDir"
    Write-Log "[VERIFY] Service config directory: $serviceConfigDir"

    $foundConfigs = @()

    if (Test-Path -LiteralPath $userConfigDir) {
        $foundConfigs += Get-ChildItem `
            -LiteralPath $userConfigDir `
            -Filter 'RustDesk*.toml' `
            -File `
            -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $serviceConfigDir) {
        $foundConfigs += Get-ChildItem `
            -LiteralPath $serviceConfigDir `
            -Filter 'RustDesk*.toml' `
            -File `
            -ErrorAction SilentlyContinue
    }

    if ($foundConfigs.Count -gt 0) {

        foreach ($file in $foundConfigs) {
            Write-Log "[VERIFY] Config found: $($file.FullName)"
        }

    }
    else {
        Write-Log "[VERIFY] WARNING: No RustDesk TOML files detected yet."
    }

    # Get final ID
    $idResult = Invoke-ProcessChecked `
        -FilePath $RustDeskExe `
        -Arguments @('--get-id') `
        -TimeoutSeconds 60

    $finalId = $idResult.StdOut.Trim()

    if ([string]::IsNullOrWhiteSpace($finalId)) {
        throw "Verification failed: RustDesk final ID is empty."
    }

    Write-Log "[VERIFY] Final RustDesk ID: $finalId"

    return $finalId
}

# ============================================================
# START GUI
# ============================================================

function Start-RustDeskGui {
    Write-Section "GUI"

    Write-Log "[GUI] Starting RustDesk GUI for interactive user..."

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    Write-Log "[GUI] Installer account: $currentUser"

    # We are elevated here, therefore starting directly would start
    # RustDesk elevated. We explicitly launch it through explorer.exe
    # so it runs in the interactive desktop session.
    try {

        Start-Process `
            -FilePath 'explorer.exe' `
            -ArgumentList $RustDeskExe `
            -WorkingDirectory $ProgramFilesRustDesk `
            -ErrorAction Stop

        Write-Log "[GUI] GUI launch requested."

    }
    catch {

        Write-Log "[GUI] Explorer launch failed: $($_.Exception.Message)"

        # Fallback.
        try {
            Start-Process `
                -FilePath $RustDeskExe `
                -WorkingDirectory $ProgramFilesRustDesk `
                -ErrorAction Stop

            Write-Log "[GUI] GUI fallback launch requested."
        }
        catch {
            Write-Log "[GUI] GUI could not be started: $($_.Exception.Message)"
        }
    }
}

# ============================================================
# MAIN
# ============================================================

$exitCode = 0

try {

    # --------------------------------------------------------
    # Initial log
    # --------------------------------------------------------

    Write-Section "START"

    Write-Log "RustDesk installer started."
    Write-Log "Script:      $ScriptPath"
    Write-Log "ScriptDir:   $ScriptDir"
    Write-Log "LogFile:     $LogFile"
    Write-Log "Current user: $env:USERNAME"
    Write-Log "User profile: $env:USERPROFILE"
    Write-Log "Is elevated: $(Test-IsAdministrator)"

    Write-Section "ARGS"

    # --------------------------------------------------------
    # Decode elevated arguments if present
    # --------------------------------------------------------

    if ($Elevated) {

        Write-Log "[ARGS] Elevated execution mode."

        if ([string]::IsNullOrWhiteSpace($PasswordB64)) {
            throw "Elevated execution: PasswordB64 is missing."
        }

        if ([string]::IsNullOrWhiteSpace($ConfigB64)) {
            throw "Elevated execution: ConfigB64 is missing."
        }

        $RustDeskPassword = ConvertFrom-Base64String $PasswordB64
        $RustDeskConfig   = ConvertFrom-Base64String $ConfigB64
    }

    if ([string]::IsNullOrWhiteSpace($RustDeskPassword)) {
        throw "RustDesk password was not provided."
    }

    if ([string]::IsNullOrWhiteSpace($RustDeskConfig)) {
        throw "RustDesk config was not provided."
    }

    Write-Log "[ARGS] Password provided: YES"
    Write-Log "[ARGS] Config provided:   YES"

    # --------------------------------------------------------
    # UAC elevation
    # --------------------------------------------------------

    if (-not (Test-IsAdministrator)) {

        Write-Section "ADMIN"

        Write-Log "[ADMIN] Administrator privileges required."
        Write-Log "[ADMIN] Requesting UAC elevation..."

        $passwordEncoded = ConvertTo-Base64String $RustDeskPassword
        $configEncoded   = ConvertTo-Base64String $RustDeskConfig

        $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

        $argumentList = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            "`"$ScriptPath`""
            '-Elevated'
            '-PasswordB64'
            $passwordEncoded
            '-ConfigB64'
            $configEncoded
        )

        Write-Log "[ADMIN] Starting elevated PowerShell process..."

        $elevatedProcess = Start-Process `
            -FilePath $psExe `
            -Verb RunAs `
            -ArgumentList $argumentList `
            -PassThru `
            -Wait `
            -ErrorAction Stop

        Write-Log "[ADMIN] Elevated installer exit code: $($elevatedProcess.ExitCode)"

        exit $elevatedProcess.ExitCode
    }

    # --------------------------------------------------------
    # We are elevated from here
    # --------------------------------------------------------

    Write-Section "ADMIN"

    Write-Log "[ADMIN] Running elevated."
    Write-Log "[ADMIN] Administrator privileges confirmed."

    # --------------------------------------------------------
    # Locate installer
    # --------------------------------------------------------

    $installer = Find-RustDeskInstaller

    # --------------------------------------------------------
    # Cleanup
    # --------------------------------------------------------

    Stop-RustDesk
    Remove-RustDeskData

    # --------------------------------------------------------
    # Install
    # --------------------------------------------------------

    Install-RustDesk `
        -InstallerPath $installer

    # --------------------------------------------------------
    # Service
    # --------------------------------------------------------

    Install-RustDeskService

    # --------------------------------------------------------
    # Configure
    # --------------------------------------------------------

    $rustdeskId = Configure-RustDesk `
        -Password $RustDeskPassword `
        -Config $RustDeskConfig

    # --------------------------------------------------------
    # Verify
    # --------------------------------------------------------

    $finalId = Verify-RustDesk

    # --------------------------------------------------------
    # GUI
    # --------------------------------------------------------

    Start-RustDeskGui

    # --------------------------------------------------------
    # Success
    # --------------------------------------------------------

    Write-Section "SUCCESS"

    Write-Log "RustDesk installation completed successfully."
    Write-Log "Architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    Write-Log "RustDesk ID:  $finalId"
    Write-Log "Password:     SUCCESS"
    Write-Log "Config:       SUCCESS"
    Write-Log "Service:      RUNNING"
    Write-Log "============================================================"

    # stdout for Tauri
    Write-Output "RustDesk ID: $finalId"
    Write-Output "Password: SUCCESS"
    Write-Output "Config: SUCCESS"
    Write-Output "Service: RUNNING"

    $exitCode = 0
}
catch {

    $exitCode = 1

    Write-Section "ERROR"

    Write-Log "INSTALL ERROR: $($_.Exception.Message)"

    if ($_.InvocationInfo) {
        Write-Log "ERROR LOCATION: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    }

    Write-Log "============================================================"

    Write-Error "RustDesk installation failed: $($_.Exception.Message)"
}

exit $exitCode