# Embedded in uninstall.exe, so removing MagendaSupport's resources does not
# disable this step. Use RustDesk's own uninstaller; never purge its profiles.
$ErrorActionPreference = "Stop"

function Get-RustDeskUninstallState {
    param([string[]]$InstallationDirectories = @())

    $directories = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in $InstallationDirectories) { $directories.Add($directory) }
    $registered = $false
    $keys = @(
        "SOFTWARE\RustDesk\InstallState\RustDesk",
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1"
    )
    # Explicit views also work when NSIS starts 32-bit Windows PowerShell.
    $views = @([Microsoft.Win32.RegistryView]::Registry32)
    if ([Environment]::Is64BitOperatingSystem) {
        $views = @([Microsoft.Win32.RegistryView]::Registry64) + $views
    }
    foreach ($view in $views) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, $view
        )
        try {
            foreach ($name in $keys) {
                $key = $hive.OpenSubKey($name)
                if ($null -eq $key) { continue }
                try {
                    $registered = $true
                    $location = [string]$key.GetValue("InstallLocation", "")
                    if (-not [string]::IsNullOrWhiteSpace($location)) {
                        $directories.Add($location.TrimEnd('\'))
                    }
                }
                finally { $key.Dispose() }
            }
        }
        finally { $hive.Dispose() }
    }
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $directories.Add((Join-Path $root "RustDesk"))
        }
    }

    $servicePresent = $false
    try {
        $service = Get-Service -Name "Rustdesk" -ErrorAction Stop
        try { $servicePresent = $true }
        # Do not retain a service handle: it can delay sc.exe delete completion.
        finally { $service.Dispose() }
    }
    catch {
        if ($_.FullyQualifiedErrorId -notmatch '^NoServiceFoundForGivenName(,|$)') {
            throw
        }
    }

    $existing = @($directories | Select-Object -Unique | Where-Object {
        Test-Path -LiteralPath $_ -ErrorAction Stop
    })
    $executable = $null
    foreach ($directory in $existing) {
        $candidate = Join-Path $directory "rustdesk.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop) {
            $executable = $candidate
            break
        }
    }

    [PSCustomObject]@{
        Present = $registered -or $servicePresent -or $existing.Count -gt 0
        ServicePresent = $servicePresent
        Registered = $registered
        Directories = $existing
        Executable = $executable
    }
}

function Assert-NoRustDeskSetup {
    $setup = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'rustdesk%.exe'" -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -match '(?i)(?:^|[\s"])--(?:silent-install|install-service|uninstall-service|remove-service|uninstall|update)(?=[\s"]|$)'
        })
    if ($setup.Count -gt 0) {
        throw "RustDesk installation/removal is already running. Let it finish, then retry."
    }
}

function Start-RustDeskUninstall {
    param([string]$Executable)

    # Do not execute an arbitrary UninstallString through cmd.exe. The installed
    # RustDesk command also handles its service, shortcuts and firewall rule.
    # Its removal script intentionally keeps user/service ID and config files.
    $process = Start-Process -FilePath $Executable -ArgumentList "--uninstall" `
        -WorkingDirectory $PSScriptRoot -PassThru
    $process.Dispose()
}

function Invoke-RustDeskUninstall {
    param([int]$TimeoutSeconds = 120)

    Assert-NoRustDeskSetup
    $state = Get-RustDeskUninstallState
    if (-not $state.Present) {
        Write-Host "[RustDesk uninstall] Already absent. ID and settings kept."
        return
    }
    if ([string]::IsNullOrWhiteSpace($state.Executable)) {
        throw "RustDesk is partially installed but rustdesk.exe is missing. Repair RustDesk, then retry uninstalling."
    }

    Write-Host "[RustDesk uninstall] Removing the program and service; keeping ID and settings..."
    # Registry removal can precede file removal, including a custom install path.
    $installationDirectories = @($state.Directories)
    Start-RustDeskUninstall -Executable $state.Executable

    # --uninstall can exit (or kill itself) before its removal script finishes.
    # Exit code alone is not evidence of removal. Wait for all postconditions.
    $absentChecks = 0
    for ($second = 1; $second -le $TimeoutSeconds; $second++) {
        Start-Sleep -Seconds 1
        $state = Get-RustDeskUninstallState -InstallationDirectories $installationDirectories
        if ($state.Present) { $absentChecks = 0 } else { $absentChecks++ }
        if ($absentChecks -ge 3) {
            Write-Host "[RustDesk uninstall] Program and service removed. ID and settings kept."
            return
        }
        if (($second % 10) -eq 0) {
            Write-Host "[RustDesk uninstall] Waiting: service=$($state.ServicePresent), registry=$($state.Registered), directories=$($state.Directories.Count)"
        }
    }
    throw "RustDesk removal did not complete within ${TimeoutSeconds}s. Let any removal process finish, then retry; a restart or RustDesk repair may be needed."
}

# Dot-sourcing exposes the orchestration for isolated tests without uninstalling.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Administrator privileges are required to remove RustDesk."
        }
        Invoke-RustDeskUninstall
        exit 0
    }
    catch {
        Write-Host "[RustDesk uninstall] ERROR: $($_.Exception.Message)"
        exit 1
    }
}
