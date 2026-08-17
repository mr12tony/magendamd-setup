param(
    [Parameter(Position = 0)]
    [string]$RustDeskPassword,

    [Parameter(Position = 1)]
    [string]$RustDeskConfig,

    [switch]$Elevated,

    [string]$ArgsFile
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptPath = $PSCommandPath
$ScriptDir  = Split-Path -Parent $ScriptPath

$LogFile = Join-Path $ScriptDir "rustdesk-install.log"

$RustDeskX64 = Join-Path $ScriptDir "rustdesk-x86_64.exe"
$RustDeskArm = Join-Path $ScriptDir "rustdesk-aarch64.exe"

$RustDeskExe = Join-Path ${env:ProgramFiles} "RustDesk\rustdesk.exe"

$ServiceName = "Rustdesk"


# ============================================================
# LOGGING
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
            -Encoding UTF8
    }
    catch {
        # Logging must never break installer
    }

    Write-Output $line
}


function Write-Section {
    param(
        [string]$Name
    )

    Write-Log "============================================================"
    Write-Log "[$Name]"
    Write-Log "============================================================"
}


# ============================================================
# ADMIN CHECK
# ============================================================

function Test-Administrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


# ============================================================
# START
# ============================================================

Write-Section "START"

Write-Log "RustDesk installer started."
Write-Log "Script:       $ScriptPath"
Write-Log "ScriptDir:    $ScriptDir"
Write-Log "Current user: $env:USERNAME"
Write-Log "User profile: $env:USERPROFILE"
Write-Log "Is elevated:  $(Test-Administrator)"
Write-Log "Elevated flag: $Elevated"


# ============================================================
# LOAD ARGUMENTS FROM TEMP FILE
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($ArgsFile)) {

    Write-Section "ARGS FILE"

    Write-Log "ArgsFile: $ArgsFile"

    if (-not (Test-Path -LiteralPath $ArgsFile)) {

        Write-Log "ERROR: ArgsFile does not exist."

        exit 10
    }

    try {

        $json = Get-Content `
            -LiteralPath $ArgsFile `
            -Raw `
            -Encoding UTF8

        $data = $json | ConvertFrom-Json

        if ($null -eq $data) {

            Write-Log "ERROR: ArgsFile is empty."

            exit 11
        }

        if ($null -ne $data.Password) {
            $RustDeskPassword = [string]$data.Password
        }

        if ($null -ne $data.Config) {
            $RustDeskConfig = [string]$data.Config
        }

        Write-Log "Password loaded: YES"
        Write-Log "Config loaded:   YES"
        Write-Log "Config length:   $($RustDeskConfig.Length)"

    }
    catch {

        Write-Log "ERROR reading ArgsFile:"
        Write-Log $_.Exception.Message

        exit 12
    }
}


# ============================================================
# ARGUMENTS
# ============================================================

Write-Section "ARGS"

Write-Log "Password provided: $(-not [string]::IsNullOrWhiteSpace($RustDeskPassword))"
Write-Log "Config provided:   $(-not [string]::IsNullOrWhiteSpace($RustDeskConfig))"

if (-not [string]::IsNullOrWhiteSpace($RustDeskConfig)) {
    Write-Log "Config length: $($RustDeskConfig.Length)"
}


# ============================================================
# ELEVATION
# ============================================================

if (-not (Test-Administrator)) {

    Write-Section "ELEVATION"

    Write-Log "Current PowerShell is NOT Administrator."
    Write-Log "Requesting Administrator privileges..."


    # --------------------------------------------------------
    # TEMP ARGS FILE
    # --------------------------------------------------------

    $TempArgsFile = Join-Path `
        $env:TEMP `
        "rustdesk-install-$([Guid]::NewGuid().ToString('N')).json"


    try {

        $argumentData = @{
            Password = $RustDeskPassword
            Config   = $RustDeskConfig
        }


        # ----------------------------------------------------
        # WRITE TEMP JSON
        # ----------------------------------------------------

        $argumentData |
            ConvertTo-Json -Compress |
            Set-Content `
                -LiteralPath $TempArgsFile `
                -Encoding UTF8


        Write-Log "Temporary arguments file created."
        Write-Log "ArgsFile: $TempArgsFile"


        # ----------------------------------------------------
        # CREATE POWERSHELL COMMAND
        #
        # We deliberately use EncodedCommand here.
        #
        # This avoids all quoting/escaping problems with:
        #
        # - paths containing spaces
        # - JSON
        # - password
        # - config
        # ----------------------------------------------------

        $command = @"
& '$ScriptPath' -Elevated -ArgsFile '$TempArgsFile'
exit `$LASTEXITCODE
"@


        $bytes = [
            System.Text.Encoding
        ]::Unicode.GetBytes($command)


        $encodedCommand = [
            Convert
        ]::ToBase64String($bytes)


        Write-Log "Elevated PowerShell command created."
        Write-Log "Encoded command length: $($encodedCommand.Length)"


        # ----------------------------------------------------
        # START ELEVATED POWERSHELL
        # ----------------------------------------------------

        Write-Log "Showing UAC prompt..."


        $process = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -WorkingDirectory $ScriptDir `
            -ArgumentList @(
                "-NoProfile"
                "-ExecutionPolicy"
                "Bypass"
                "-EncodedCommand"
                $encodedCommand
            ) `
            -PassThru `
            -ErrorAction Stop


        Write-Log "Elevated PowerShell started."
        Write-Log "Elevated PID: $($process.Id)"


        # ----------------------------------------------------
        # WAIT
        # ----------------------------------------------------

        Write-Log "Waiting for elevated installer..."


        $process.WaitForExit()


        $exitCode = $process.ExitCode


        Write-Log "Elevated PowerShell finished."
        Write-Log "Elevated exit code: $exitCode"


        # ----------------------------------------------------
        # CLEAN TEMP FILE
        # ----------------------------------------------------

        if (Test-Path -LiteralPath $TempArgsFile) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue

            Write-Log "Temporary arguments file removed."
        }


        # ----------------------------------------------------
        # RETURN CHILD EXIT CODE
        # ----------------------------------------------------

        if ($exitCode -eq 0) {

            Write-Log "Installation completed successfully."

            exit 0
        }
        else {

            Write-Log "Installation FAILED."

            exit $exitCode
        }
    }
    catch {

        Write-Log "ERROR during elevation:"
        Write-Log $_.Exception.Message


        if (
            -not [string]::IsNullOrWhiteSpace($TempArgsFile) -and
            (Test-Path -LiteralPath $TempArgsFile)
        ) {

            Remove-Item `
                -LiteralPath $TempArgsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }


        exit 20
    }
}


# ============================================================
# ADMIN CONFIRMATION
# ============================================================

Write-Section "ADMIN"

if (-not (Test-Administrator)) {

    Write-Log "ERROR: Elevated PowerShell is NOT Administrator."

    exit 30
}

Write-Log "Administrator privileges confirmed."


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

    Write-Log "Detected architecture: AMD64"

    $selectedInstaller = $RustDeskX64

}
elseif (
    $arch1 -eq "ARM64" -or
    $arch2 -eq "ARM64"
) {

    Write-Log "Detected architecture: ARM64"

    $selectedInstaller = $RustDeskArm

}
else {

    Write-Log "ERROR: Unsupported architecture."

    exit 40
}


Write-Log "Selected installer: $selectedInstaller"


# ============================================================
# CHECK INSTALLER
# ============================================================

if (-not (Test-Path -LiteralPath $selectedInstaller)) {

    Write-Log "ERROR: RustDesk installer not found:"
    Write-Log $selectedInstaller

    exit 41
}


$installerFile = Get-Item -LiteralPath $selectedInstaller

Write-Log "Installer found."
Write-Log "Installer size: $([math]::Round($installerFile.Length / 1MB, 2)) MB"


# ============================================================
# CLEANUP
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
# REMOVE OLD SERVICE
# ============================================================

Write-Log "Checking RustDesk service..."


$service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


if ($null -ne $service) {

    Write-Log "RustDesk service found."
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
            Write-Log "SC DELETE: $_"
        }


    Start-Sleep -Seconds 3
}
else {

    Write-Log "RustDesk service not found."
}


# ============================================================
# REMOVE OLD INSTALLATION
# ============================================================

$oldInstallDir = Join-Path ${env:ProgramFiles} "RustDesk"


if (Test-Path -LiteralPath $oldInstallDir) {

    Write-Log "Removing old RustDesk installation..."


    try {

        Remove-Item `
            -LiteralPath $oldInstallDir `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Write-Log "Old installation removed."
    }
    catch {

        Write-Log "WARNING: Could not completely remove old installation."
        Write-Log $_.Exception.Message
    }
}
else {

    Write-Log "Old installation not found."
}


# ============================================================
# REMOVE USER DATA
# ============================================================

$userRoaming = Join-Path $env:APPDATA "RustDesk"
$userLocal   = Join-Path $env:LOCALAPPDATA "RustDesk"

if (Test-Path -LiteralPath $userRoaming) {

    Write-Log "Removing APPDATA RustDesk..."

    Remove-Item `
        -LiteralPath $userRoaming `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}


if (Test-Path -LiteralPath $userLocal) {

    Write-Log "Removing LOCALAPPDATA RustDesk..."

    Remove-Item `
        -LiteralPath $userLocal `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}


$localServiceData =
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"


if (Test-Path -LiteralPath $localServiceData) {

    Write-Log "Removing LocalService RustDesk data..."

    Remove-Item `
        -LiteralPath $localServiceData `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}


Write-Log "Cleanup completed."


# ============================================================
# INSTALL
# ============================================================

Write-Section "INSTALL"

Write-Log "Starting RustDesk silent installer..."


try {

    $installerProcess = Start-Process `
        -FilePath $selectedInstaller `
        -ArgumentList "--silent-install" `
        -PassThru


    Write-Log "RustDesk installer PID: $($installerProcess.Id)"


    # --------------------------------------------------------
    # WAIT FOR rustdesk.exe
    # --------------------------------------------------------

    $found = $false


    for ($i = 0; $i -lt 60; $i++) {

        if (Test-Path -LiteralPath $RustDeskExe) {

            $found = $true

            Write-Log "RustDesk executable detected."

            break
        }


        Start-Sleep -Seconds 1
    }


    if (-not $found) {

        Write-Log "ERROR: RustDesk executable was not detected."


        if (-not $installerProcess.HasExited) {

            Stop-Process `
                -Id $installerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }


        exit 50
    }


    # --------------------------------------------------------
    # WAIT INSTALLER
    # --------------------------------------------------------

    if (-not $installerProcess.HasExited) {

        Write-Log "Waiting for installer process..."

        $installerProcess.WaitForExit(30000)
    }


    if ($installerProcess.HasExited) {

        Write-Log "RustDesk installer exit code: $($installerProcess.ExitCode)"
    }


    Write-Log "RustDesk installation completed."
}
catch {

    Write-Log "ERROR during RustDesk installation:"
    Write-Log $_.Exception.Message

    exit 51
}


# ============================================================
# VERIFY
# ============================================================

Write-Section "VERIFY"


if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Log "ERROR: RustDesk executable not found."

    exit 60
}


$installedFile = Get-Item -LiteralPath $RustDeskExe


Write-Log "RustDesk executable: $RustDeskExe"
Write-Log "Size: $([math]::Round($installedFile.Length / 1MB, 2)) MB"


try {

    $version = $installedFile.VersionInfo

    Write-Log "Product version: $($version.ProductVersion)"
    Write-Log "File version:    $($version.FileVersion)"
}
catch {

    Write-Log "WARNING: Could not read RustDesk version."
}


# ============================================================
# SERVICE INSTALL
# ============================================================

Write-Section "SERVICE"


Write-Log "Installing RustDesk service..."


try {

    $serviceProcess = Start-Process `
        -FilePath $RustDeskExe `
        -ArgumentList "--install-service" `
        -PassThru


    Write-Log "Service installation PID: $($serviceProcess.Id)"


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

        exit 70
    }


    if (-not $serviceProcess.HasExited) {

        Write-Log "Service process still running."

        Stop-Process `
            -Id $serviceProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

}
catch {

    Write-Log "ERROR installing service:"
    Write-Log $_.Exception.Message

    exit 71
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
            Write-Log "SC CONFIG: $_"
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

    exit 80
}


Write-Log "Current service status: $($service.Status)"


if ($service.Status -ne "Running") {

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop

        Write-Log "Start-Service completed."

    }
    catch {

        Write-Log "WARNING: Start-Service failed."
        Write-Log $_.Exception.Message
    }
}


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


if ($running) {

    Write-Log "RustDesk service is RUNNING."

}
else {

    Write-Log "ERROR: RustDesk service failed to start."

    exit 81
}


# ============================================================
# CONFIG
# ============================================================

Write-Section "CONFIG"


if (-not [string]::IsNullOrWhiteSpace($RustDeskConfig)) {

    Write-Log "Applying RustDesk configuration..."


    try {

        $configProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--config"
                $RustDeskConfig
            ) `
            -PassThru `
            -Wait


        Write-Log "RustDesk --config exit code: $($configProcess.ExitCode)"


        if ($configProcess.ExitCode -ne 0) {

            Write-Log "WARNING: RustDesk config returned non-zero."
        }
        else {

            Write-Log "RustDesk configuration applied."
        }

    }
    catch {

        Write-Log "WARNING: Failed to apply RustDesk configuration."
        Write-Log $_.Exception.Message
    }

}
else {

    Write-Log "Config is empty. Skipping."
}


# ============================================================
# PASSWORD
# ============================================================

Write-Section "PASSWORD"


if (-not [string]::IsNullOrWhiteSpace($RustDeskPassword)) {

    Write-Log "Applying RustDesk password..."


    try {

        $passwordProcess = Start-Process `
            -FilePath $RustDeskExe `
            -ArgumentList @(
                "--password"
                $RustDeskPassword
            ) `
            -PassThru `
            -Wait


        Write-Log "RustDesk --password exit code: $($passwordProcess.ExitCode)"


        if ($passwordProcess.ExitCode -ne 0) {

            Write-Log "WARNING: RustDesk password returned non-zero."
        }
        else {

            Write-Log "RustDesk password applied."
        }

    }
    catch {

        Write-Log "WARNING: Failed to apply password."
        Write-Log $_.Exception.Message
    }

}
else {

    Write-Log "Password is empty. Skipping."
}


# ============================================================
# FINAL
# ============================================================

Write-Section "FINAL"


$finalService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue


if ($null -eq $finalService) {

    Write-Log "ERROR: RustDesk service not found."

    exit 90
}


Write-Log "Final service status: $($finalService.Status)"


if (-not (Test-Path -LiteralPath $RustDeskExe)) {

    Write-Log "ERROR: RustDesk executable is missing."

    exit 91
}


Write-Log "RustDesk executable verified."
Write-Log "Installation completed successfully."


Write-Section "END"


exit 0