# ============================================================
# configure-rustdesk.ps1
#
# Tauri / NSIS RustDesk deployment
# Target: RustDesk 1.4.9
#
# Flow:
#   1. Detect/install/update RustDesk
#   2. Close user GUI
#   3. Ensure RustDesk Service exists
#   4. Stop Service
#   5. Backup + patch:
#        - LocalService RustDesk2.toml
#        - interactive user's RustDesk2.toml
#   6. Start Service
#   7. Apply permanent password
#   8. Verify configs
#   9. Verify Service
#  10. Get RustDesk ID
#
# RustDesk GUI is intentionally NOT started from this elevated
# PowerShell process. Start it from NSIS after exit code 0.
# ============================================================

$ErrorActionPreference = "Stop"


# ============================================================
# CONFIGURATION
# ============================================================

$TargetVersion = "1.4.9"

# Self-hosted configuration
$RustDeskIdServer = "rustdesk.magendamd.com"
$RustDeskRelayServer = "rustdesk.magendamd.com"
$RustDeskKey = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# RustDesk rendezvous port.
# If your server uses a non-standard port, change it.
$RustDeskRendezvousPort = 21116

# Test password.
# Later better generate/fetch dynamically.
$RustDeskPassword = "rihn7vw9"

$ServiceName = "Rustdesk"

$InstallTimeoutSeconds = 90
$ServiceTimeoutSeconds = 45

$X64Installer = Join-Path `
    $PSScriptRoot `
    "rustdesk-1.4.9-x86_64.exe"

$Arm64Installer = Join-Path `
    $PSScriptRoot `
    "rustdesk-1.4.9-aarch64.exe"


# ============================================================
# LOGGING
# ============================================================

function Log {
    param([string]$Message)

    Write-Host "[RustDesk deployment] $Message"
}


function Fail {
    param([string]$Message)

    Write-Host ""
    Write-Host "[RustDesk deployment] ERROR: $Message" -ForegroundColor Red
    Write-Host ""

    exit 1
}


# ============================================================
# ADMIN
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
# VERSION
#
# 1.4.9+67 -> 1.4.9
# ============================================================

function Normalize-RustDeskVersion {

    param(
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    if ($Version -match '(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }

    return $null
}


function Get-RustDeskVersion {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    if (-not (Test-Path -LiteralPath $Exe)) {
        return $null
    }

    try {

        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
            $Exe
        )

        Log "ProductVersion raw: [$($info.ProductVersion)]"
        Log "FileVersion raw:    [$($info.FileVersion)]"

        $version = Normalize-RustDeskVersion `
            $info.ProductVersion

        if ($version) {

            Log "Normalized ProductVersion: [$version]"

            return $version
        }

        $version = Normalize-RustDeskVersion `
            $info.FileVersion

        if ($version) {
            return $version
        }
    }
    catch {

        Log "Version check failed."
    }

    return $null
}


# ============================================================
# FIND INSTALLED RUSTDESK
# ============================================================

function Find-RustDeskExe {

    $paths = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) {

        $paths.Add(
            (Join-Path `
                $env:ProgramW6432 `
                "RustDesk\rustdesk.exe")
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {

        $paths.Add(
            (Join-Path `
                $env:ProgramFiles `
                "RustDesk\rustdesk.exe")
        )
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {

        $paths.Add(
            (Join-Path `
                ${env:ProgramFiles(x86)} `
                "RustDesk\rustdesk.exe")
        )
    }

    $paths.Add(
        "C:\Program Files\RustDesk\rustdesk.exe"
    )

    $paths.Add(
        "C:\Program Files (x86)\RustDesk\rustdesk.exe"
    )

    foreach ($path in ($paths | Select-Object -Unique)) {

        if (Test-Path -LiteralPath $path) {

            Log "Found RustDesk executable: $path"

            return $path
        }
    }

    return $null
}


# ============================================================
# ARCHITECTURE
# ============================================================

function Get-RustDeskInstaller {

    $arch = $env:PROCESSOR_ARCHITECTURE
    $wowArch = $env:PROCESSOR_ARCHITEW6432

    Log "PROCESSOR_ARCHITECTURE = $arch"
    Log "PROCESSOR_ARCHITEW6432 = $wowArch"

    if (
        $arch -eq "ARM64" -or
        $wowArch -eq "ARM64"
    ) {

        Log "Detected architecture: ARM64"

        if (-not (Test-Path -LiteralPath $Arm64Installer)) {

            Fail "ARM64 installer not found: $Arm64Installer"
        }

        return $Arm64Installer
    }

    if (
        $arch -eq "AMD64" -or
        $wowArch -eq "AMD64"
    ) {

        Log "Detected architecture: x86_64"

        if (-not (Test-Path -LiteralPath $X64Installer)) {

            Fail "x86_64 installer not found: $X64Installer"
        }

        return $X64Installer
    }

    Fail "Unsupported Windows architecture."
}


# ============================================================
# INTERACTIVE USER
#
# Important:
# installer is elevated, therefore $env:APPDATA may point to
# Administrator rather than the actual logged-in user.
# ============================================================

function Get-InteractiveUserProfile {

    Log "Detecting interactive Windows user..."

    try {

        $explorer = Get-CimInstance `
            Win32_Process `
            -Filter "Name='explorer.exe'" `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $explorer) {

            Log "explorer.exe not found."

            return $null
        }

        $owner = Invoke-CimMethod `
            -InputObject $explorer `
            -MethodName GetOwner `
            -ErrorAction Stop

        if ($owner.ReturnValue -ne 0) {

            return $null
        }

        $userName = $owner.User
        $domain = $owner.Domain

        Log "Interactive user: $domain\$userName"

        # ----------------------------------------------------
        # Resolve SID
        # ----------------------------------------------------

        $account = New-Object `
            System.Security.Principal.NTAccount(
                $domain,
                $userName
            )

        $sid = $account.Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value

        Log "Interactive user SID: $sid"


        # ----------------------------------------------------
        # Resolve actual profile path from ProfileList
        # ----------------------------------------------------

        $profileKey = `
            "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"

        $profile = Get-ItemProperty `
            -LiteralPath $profileKey `
            -ErrorAction Stop

        $profilePath = `
            [Environment]::ExpandEnvironmentVariables(
                $profile.ProfileImagePath
            )

        if (-not (Test-Path -LiteralPath $profilePath)) {

            Log "Interactive user profile path does not exist."

            return $null
        }

        Log "Interactive profile: $profilePath"

        return [PSCustomObject]@{
            UserName    = $userName
            Domain      = $domain
            SID         = $sid
            ProfilePath = $profilePath
        }
    }
    catch {

        Log "Could not detect interactive user profile."

        return $null
    }
}


# ============================================================
# SERVICE HELPERS
# ============================================================

function Get-RustDeskService {

    return Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue
}


function Test-RustDeskServiceRunning {

    $service = Get-RustDeskService

    return (
        $service -and
        $service.Status -eq "Running"
    )
}


function Get-RustDeskServicePid {

    try {

        $service = Get-CimInstance `
            Win32_Service `
            -Filter "Name='$ServiceName'" `
            -ErrorAction SilentlyContinue

        if (
            $service -and
            $service.ProcessId -and
            $service.ProcessId -ne 0
        ) {

            return [int]$service.ProcessId
        }
    }
    catch {}

    return $null
}


# ============================================================
# CLOSE GUI
#
# Service is NOT stopped here.
# ============================================================

function Stop-RustDeskGui {

    Log "Checking RustDesk GUI..."

    $servicePid = Get-RustDeskServicePid

    if ($servicePid) {
        Log "RustDesk Service PID: $servicePid"
    }

    $guiProcesses = @(
        Get-Process `
            -Name "rustdesk" `
            -ErrorAction SilentlyContinue |
        Where-Object {

            if (
                $servicePid -and
                $_.Id -eq $servicePid
            ) {
                return $false
            }

            return $_.SessionId -ne 0
        }
    )

    if ($guiProcesses.Count -eq 0) {

        Log "RustDesk GUI is not running."

        return
    }

    Log "Found $($guiProcesses.Count) RustDesk user process(es)."

    foreach ($process in $guiProcesses) {

        $processId = $process.Id

        Log (
            "Closing RustDesk user process: " +
            "PID=$processId, Session=$($process.SessionId)"
        )

        try {

            if ($process.MainWindowHandle -ne 0) {

                $closed = $process.CloseMainWindow()

                if ($closed) {

                    try {
                        $process.WaitForExit(3000)
                    }
                    catch {}
                }
            }
        }
        catch {}

        $remaining = Get-Process `
            -Id $processId `
            -ErrorAction SilentlyContinue

        if ($remaining) {

            Log "Force closing GUI PID=$processId..."

            Stop-Process `
                -Id $processId `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 1

    Log "RustDesk GUI close phase completed."
}


# ============================================================
# WAIT FOR INSTALLATION
# ============================================================

function Wait-ForRustDeskInstallation {

    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$InstallerProcess
    )

    Log (
        "Waiting for RustDesk $TargetVersion " +
        "(timeout ${InstallTimeoutSeconds}s)..."
    )

    for (
        $second = 1;
        $second -le $InstallTimeoutSeconds;
        $second++
    ) {

        $exe = Find-RustDeskExe

        if ($exe) {

            $version = Get-RustDeskVersion `
                -Exe $exe

            Log (
                "[$second/$InstallTimeoutSeconds] " +
                "version=[$version], expected=[$TargetVersion]"
            )

            if ($version -eq $TargetVersion) {

                Log "Required RustDesk version detected."

                return $exe
            }
        }

        Start-Sleep -Seconds 1
    }

    return $null
}


# ============================================================
# INSTALL / UPDATE / DOWNGRADE
# ============================================================

function Install-Or-Update-RustDesk {

    $existingExe = Find-RustDeskExe

    if ($existingExe) {

        $installedVersion = Get-RustDeskVersion `
            -Exe $existingExe

        Log "Installed RustDesk version: [$installedVersion]"
        Log "Required RustDesk version:  [$TargetVersion]"

        if ($installedVersion -eq $TargetVersion) {

            Log "Correct RustDesk version already installed."

            return $existingExe
        }

        Log (
            "RustDesk version mismatch: " +
            "$installedVersion -> $TargetVersion"
        )

        Stop-RustDeskGui
    }
    else {

        Log "RustDesk is not installed."
    }


    $installer = Get-RustDeskInstaller

    Log "Starting bundled RustDesk installer:"
    Log $installer

    try {

        $installerProcess = Start-Process `
            -FilePath $installer `
            -ArgumentList "--silent-install" `
            -PassThru
    }
    catch {

        Fail "Could not start RustDesk installer."
    }

    Log "RustDesk installer PID: $($installerProcess.Id)"

    $installedExe = Wait-ForRustDeskInstallation `
        -InstallerProcess $installerProcess

    if (-not $installedExe) {

        try {

            if (-not $installerProcess.HasExited) {

                Stop-Process `
                    -Id $installerProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {}

        Fail "RustDesk installation timeout."
    }


    # Installer sometimes remains alive even though installation
    # already finished.
    try {

        if (-not $installerProcess.HasExited) {

            Log "Stopping remaining installer process..."

            Stop-Process `
                -Id $installerProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch {}


    $actualVersion = Get-RustDeskVersion `
        -Exe $installedExe

    if ($actualVersion -ne $TargetVersion) {

        Fail (
            "RustDesk version verification failed. " +
            "Expected [$TargetVersion], got [$actualVersion]."
        )
    }

    Log "RustDesk installation/update successful."

    # Installer can finish service registration after EXE appears.
    Start-Sleep -Seconds 5

    return $installedExe
}


# ============================================================
# ENSURE SERVICE EXISTS
# ============================================================

function Ensure-RustDeskServiceExists {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    $service = Get-RustDeskService

    if ($service) {

        Log "RustDesk Service exists."

        return
    }

    Log "RustDesk Service does not exist."
    Log "Installing RustDesk Service..."

    try {

        & $Exe --install-service | Out-Null
    }
    catch {}

    for ($i = 1; $i -le 20; $i++) {

        Start-Sleep -Seconds 1

        $service = Get-RustDeskService

        if ($service) {

            Log "RustDesk Service registered."

            return
        }
    }

    Fail "RustDesk Service was not created."
}


# ============================================================
# STOP SERVICE
# ============================================================

function Stop-RustDeskService {

    $service = Get-RustDeskService

    if (-not $service) {

        Fail "RustDesk Service does not exist."
    }

    if ($service.Status -eq "Stopped") {

        Log "RustDesk Service already STOPPED."

        return
    }

    Log "Stopping RustDesk Service for config patch..."

    try {

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction Stop
    }
    catch {

        Log "Stop-Service returned an error."
    }

    for ($i = 1; $i -le 30; $i++) {

        Start-Sleep -Seconds 1

        $service = Get-RustDeskService

        if (
            $service -and
            $service.Status -eq "Stopped"
        ) {

            Log "RustDesk Service is STOPPED."

            return
        }
    }

    Fail "RustDesk Service could not be stopped."
}


# ============================================================
# START SERVICE
# ============================================================

function Start-RustDeskService {

    $service = Get-RustDeskService

    if (-not $service) {

        Fail "RustDesk Service does not exist."
    }

    if ($service.Status -eq "Running") {

        Log "RustDesk Service already RUNNING."

        return
    }

    Log "Starting RustDesk Service..."

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop
    }
    catch {

        Log "Start-Service returned an error; waiting anyway."
    }

    for (
        $i = 1;
        $i -le $ServiceTimeoutSeconds;
        $i++
    ) {

        Start-Sleep -Seconds 1

        $service = Get-RustDeskService

        if (
            $service -and
            $service.Status -eq "Running"
        ) {

            Log "RustDesk Service is RUNNING."

            Log "Waiting for RustDesk IPC initialization..."

            Start-Sleep -Seconds 3

            return
        }
    }

    Fail "RustDesk Service could not be started."
}


# ============================================================
# TOML STRING ESCAPE
# ============================================================

function ConvertTo-TomlString {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    # Use single-quoted TOML strings.
    # Single quote inside value must be escaped by doubling.
    return $Value.Replace("'", "''")
}


# ============================================================
# PATCH TOML
#
# Preserves unrelated RustDesk settings.
#
# Patches:
#   top-level rendezvous_server
#
#   [options]
#   custom-rendezvous-server
#   relay-server
#   key
# ============================================================

function Patch-RustDeskToml {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$IdServer,

        [Parameter(Mandatory = $true)]
        [string]$RelayServer,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    Log "Patching RustDesk config:"
    Log $Path

    $directory = Split-Path `
        $Path `
        -Parent

    if (-not (Test-Path -LiteralPath $directory)) {

        New-Item `
            -ItemType Directory `
            -Path $directory `
            -Force |
            Out-Null
    }


    # --------------------------------------------------------
    # Backup
    # --------------------------------------------------------

    if (Test-Path -LiteralPath $Path) {

        $backup = "$Path.bak"

        Copy-Item `
            -LiteralPath $Path `
            -Destination $backup `
            -Force

        Log "Backup created: $backup"
    }


    # --------------------------------------------------------
    # Read existing lines
    # --------------------------------------------------------

    $lines = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $Path) {

        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {

            $lines.Add($line)
        }
    }


    $escapedIdServer = ConvertTo-TomlString $IdServer
    $escapedRelay = ConvertTo-TomlString $RelayServer
    $escapedKey = ConvertTo-TomlString $Key

    $rendezvous = "$IdServer`:$RustDeskRendezvousPort"
    $escapedRendezvous = ConvertTo-TomlString $rendezvous


    # ========================================================
    # TOP LEVEL rendezvous_server
    # ========================================================

    $foundRendezvous = $false

    $inSection = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {

        $trimmed = $lines[$i].Trim()

        if ($trimmed -match '^$begin:math:display$\.\+$end:math:display$$') {

            $inSection = $true
        }

        if (
            -not $inSection -and
            $trimmed -match '^rendezvous_server\s*='
        ) {

            $lines[$i] = `
                "rendezvous_server = '$escapedRendezvous'"

            $foundRendezvous = $true

            break
        }
    }


    if (-not $foundRendezvous) {

        $lines.Insert(
            0,
            "rendezvous_server = '$escapedRendezvous'"
        )
    }


    # ========================================================
    # FIND OPTIONS SECTION
    # ========================================================

    $optionsStart = -1
    $optionsEnd = $lines.Count

    for ($i = 0; $i -lt $lines.Count; $i++) {

        if ($lines[$i].Trim() -eq "[options]") {

            $optionsStart = $i

            break
        }
    }


    if ($optionsStart -lt 0) {

        if (
            $lines.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace(
                $lines[$lines.Count - 1]
            )
        ) {

            $lines.Add("")
        }

        $lines.Add("[options]")

        $optionsStart = $lines.Count - 1
        $optionsEnd = $lines.Count
    }
    else {

        for (
            $i = $optionsStart + 1;
            $i -lt $lines.Count;
            $i++
        ) {

            if (
                $lines[$i].Trim() -match '^\[.+\]$'
            ) {

                $optionsEnd = $i

                break
            }
        }
    }


    # ========================================================
    # PATCH HELPER
    # ========================================================

    function Set-OptionLine {

        param(
            [string]$Name,
            [string]$Value
        )

        $found = $false

        # optionsEnd can change while inserting.
        for (
            $j = $optionsStart + 1;
            $j -lt $optionsEnd;
            $j++
        ) {

            $trimmed = $lines[$j].Trim()

            $pattern = '^' + `
                [Regex]::Escape($Name) + `
                '\s*='

            if ($trimmed -match $pattern) {

                $lines[$j] = "$Name = '$Value'"

                $found = $true

                break
            }
        }


        if (-not $found) {

            $lines.Insert(
                $optionsEnd,
                "$Name = '$Value'"
            )

            $optionsEnd++
        }
    }


    Set-OptionLine `
        -Name "custom-rendezvous-server" `
        -Value $escapedIdServer

    Set-OptionLine `
        -Name "relay-server" `
        -Value $escapedRelay

    Set-OptionLine `
        -Name "key" `
        -Value $escapedKey


    # ========================================================
    # WRITE UTF-8 WITHOUT BOM
    # ========================================================

    $encoding = New-Object `
        System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllLines(
        $Path,
        $lines.ToArray(),
        $encoding
    )

    Log "RustDesk config patched successfully."
}


# ============================================================
# VERIFY TOML
# ============================================================

function Verify-RustDeskToml {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {

        Fail "RustDesk config not found: $Path"
    }

    $content = [System.IO.File]::ReadAllText($Path)

    $expectedRendezvous = `
        "$RustDeskIdServer`:$RustDeskRendezvousPort"

    $checks = @(
        @{
            Name = "rendezvous_server"
            Value = $expectedRendezvous
        },
        @{
            Name = "custom-rendezvous-server"
            Value = $RustDeskIdServer
        },
        @{
            Name = "relay-server"
            Value = $RustDeskRelayServer
        },
        @{
            Name = "key"
            Value = $RustDeskKey
        }
    )

    foreach ($check in $checks) {

        $escaped = [Regex]::Escape(
            $check.Value
        )

        if ($content -notmatch $escaped) {

            Fail (
                "Config verification failed for " +
                "'$($check.Name)' in [$Path]"
            )
        }
    }

    Log "Config verification OK:"
    Log $Path
}


# ============================================================
# PASSWORD
#
# RustDesk 1.4.9 on tested machine prints:
#
# Done!
# ============================================================

function Apply-RustDeskPassword {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    if (-not (Test-RustDeskServiceRunning)) {

        Fail "Service must be RUNNING before --password."
    }

    Log "Applying RustDesk permanent password..."

    for ($attempt = 1; $attempt -le 3; $attempt++) {

        Log "Password attempt $attempt/3..."

        try {

            $result = (
                & $Exe `
                    --password `
                    $RustDeskPassword `
                    2>&1 |
                Out-String
            ).Trim()

            Log "Password CLI response: [$result]"

            if ($result -match 'Done!') {

                Log "Permanent password applied."

                return
            }
        }
        catch {}

        Start-Sleep -Seconds 2
    }

    Fail "RustDesk --password did not return Done!."
}


# ============================================================
# GET ID
# ============================================================

function Get-RustDeskId {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    try {

        return (
            & $Exe --get-id 2>&1 |
            Out-String
        ).Trim()
    }
    catch {

        return $null
    }
}


# ============================================================
# MAIN
# ============================================================

try {

    Log ""
    Log "============================================"
    Log "RustDesk deployment started"
    Log "Target version: $TargetVersion"
    Log "============================================"
    Log ""


    # ========================================================
    # 1. Administrator
    # ========================================================

    if (-not (Test-Administrator)) {

        Fail "Administrator privileges are required."
    }

    Log "Administrator privileges: OK"


    # ========================================================
    # 2. Detect interactive user BEFORE killing GUI
    # ========================================================

    $interactiveUser = Get-InteractiveUserProfile

    if (-not $interactiveUser) {

        Fail (
            "Could not determine interactive Windows user. " +
            "User-side RustDesk config cannot be configured."
        )
    }


    # ========================================================
    # 3. Install / update RustDesk
    # ========================================================

    $RustDeskExe = Install-Or-Update-RustDesk

    if (
        [string]::IsNullOrWhiteSpace($RustDeskExe) -or
        -not (Test-Path -LiteralPath $RustDeskExe)
    ) {

        Fail "rustdesk.exe could not be found."
    }


    # ========================================================
    # 4. Ensure Service exists
    # ========================================================

    Ensure-RustDeskServiceExists `
        -Exe $RustDeskExe


    # ========================================================
    # 5. Close GUI
    # ========================================================

    Stop-RustDeskGui


    # ========================================================
    # 6. Stop Service
    #
    # From this point RustDesk should not rewrite TOML.
    # ========================================================

    Stop-RustDeskService


    # ========================================================
    # 7. Build config paths
    # ========================================================

    $serviceConfig = Join-Path `
        $env:WINDIR `
        "ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml"


    $userConfig = Join-Path `
        $interactiveUser.ProfilePath `
        "AppData\Roaming\RustDesk\config\RustDesk2.toml"


    Log "Service config:"
    Log $serviceConfig

    Log "User config:"
    Log $userConfig


    # ========================================================
    # 8. Patch Service config
    # ========================================================

    Patch-RustDeskToml `
        -Path $serviceConfig `
        -IdServer $RustDeskIdServer `
        -RelayServer $RustDeskRelayServer `
        -Key $RustDeskKey


    # ========================================================
    # 9. Patch User config
    # ========================================================

    Patch-RustDeskToml `
        -Path $userConfig `
        -IdServer $RustDeskIdServer `
        -RelayServer $RustDeskRelayServer `
        -Key $RustDeskKey


    # ========================================================
    # 10. Verify files before RustDesk starts
    # ========================================================

    Verify-RustDeskToml `
        -Path $serviceConfig

    Verify-RustDeskToml `
        -Path $userConfig


    # ========================================================
    # 11. Start Service
    # ========================================================

    Start-RustDeskService


    # ========================================================
    # 12. Password
    # ========================================================

    Apply-RustDeskPassword `
        -Exe $RustDeskExe


    # ========================================================
    # 13. Wait a little, then verify configs again
    #
    # This detects if RustDesk rewrites our values.
    # ========================================================

    Start-Sleep -Seconds 3


    Verify-RustDeskToml `
        -Path $serviceConfig

    Verify-RustDeskToml `
        -Path $userConfig


    # ========================================================
    # 14. Service
    # ========================================================

    if (-not (Test-RustDeskServiceRunning)) {

        Fail "RustDesk Service is not RUNNING."
    }

    Log "RustDesk Service: RUNNING"


    # ========================================================
    # 15. Version
    # ========================================================

    $actualVersion = Get-RustDeskVersion `
        -Exe $RustDeskExe

    if ($actualVersion -ne $TargetVersion) {

        Fail (
            "Final version mismatch. " +
            "Expected [$TargetVersion], got [$actualVersion]."
        )
    }

    Log "RustDesk version: [$actualVersion]"


    # ========================================================
    # 16. RustDesk ID
    # ========================================================

    $rustDeskId = $null

    for ($i = 1; $i -le 10; $i++) {

        $rustDeskId = Get-RustDeskId `
            -Exe $RustDeskExe

        if (
            -not [string]::IsNullOrWhiteSpace(
                $rustDeskId
            )
        ) {

            break
        }

        Log "RustDesk ID not ready. Retry $i/10..."

        Start-Sleep -Seconds 2
    }

    if ([string]::IsNullOrWhiteSpace($rustDeskId)) {

        Fail "RustDesk ID is empty."
    }

    Log "RustDesk ID: [$rustDeskId]"


    # ========================================================
    # SUCCESS
    # ========================================================

    Log ""
    Log "============================================"
    Log "RustDesk deployment SUCCESS"
    Log "============================================"
    Log "Version : $actualVersion"
    Log "ID      : $rustDeskId"
    Log "Server  : $RustDeskIdServer"
    Log "Relay   : $RustDeskRelayServer"
    Log "Service : RUNNING"
    Log "User    : $($interactiveUser.Domain)\$($interactiveUser.UserName)"
    Log "============================================"
    Log ""


    # GUI intentionally not started here.
    # Start it from NSIS after script exit code 0.

    exit 0
}
catch {

    Log ""
    Log "============================================"
    Log "UNHANDLED ERROR"
    Log "============================================"

    Log $_.Exception.Message

    if ($_.ScriptStackTrace) {

        Log $_.ScriptStackTrace
    }

    exit 1
}