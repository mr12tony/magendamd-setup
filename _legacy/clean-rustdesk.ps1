# clean-rustdesk.ps1
# Run as Administrator
# Intended for test/VM cleanup before RustDesk deployment tests.

$ErrorActionPreference = "Continue"

$ServiceName = "Rustdesk"

function Log {
    param([string]$Message)
    Write-Host "[RustDesk cleanup] $Message"
}

function Warn {
    param([string]$Message)
    Write-Warning "[RustDesk cleanup] $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-IsAdministrator)) {
    Write-Host ""
    Write-Host "NOT CLEAN" -ForegroundColor Red
    Write-Host "Run this script from PowerShell as Administrator."
    exit 1
}

Log "Starting full RustDesk cleanup..."

# ============================================================
# 1. Find possible RustDesk executables before deleting anything
# ============================================================

$possibleExePaths = @(
    "$env:ProgramFiles\RustDesk\rustdesk.exe"
)

if (${env:ProgramFiles(x86)}) {
    $possibleExePaths += "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
}

$rustDeskExes = @(
    $possibleExePaths |
    Where-Object { $_ -and (Test-Path $_) }
)

# Try registry InstallLocation too
$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($root in $uninstallRoots) {
    try {
        $entries = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -like "RustDesk*"
            }

        foreach ($entry in $entries) {
            if ($entry.InstallLocation) {
                $candidate = Join-Path $entry.InstallLocation "rustdesk.exe"

                if (
                    (Test-Path $candidate) -and
                    ($rustDeskExes -notcontains $candidate)
                ) {
                    $rustDeskExes += $candidate
                }
            }
        }
    }
    catch {}
}

# ============================================================
# 2. Kill all RustDesk processes
# ============================================================

Log "Stopping RustDesk processes..."

try {
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Log "Stopping process PID=$($_.Id)"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}
catch {
    Warn "Could not stop one or more RustDesk processes."
}

Start-Sleep -Milliseconds 800

# ============================================================
# 3. Stop RustDesk service
# ============================================================

Log "Stopping RustDesk service..."

try {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service) {
        if ($service.Status -ne "Stopped") {
            Stop-Service `
                -Name $ServiceName `
                -Force `
                -ErrorAction SilentlyContinue
        }

        try {
            $service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(10)
            )
        }
        catch {}
    }
}
catch {
    Warn "Failed to stop RustDesk service."
}

# ============================================================
# 4. Try RustDesk's own uninstall command
# ============================================================

foreach ($exe in $rustDeskExes) {
    if (-not (Test-Path $exe)) {
        continue
    }

    Log "Trying RustDesk uninstall using:"
    Log $exe

    try {
        $process = Start-Process `
            -FilePath $exe `
            -ArgumentList "--uninstall" `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        Log "RustDesk uninstall exit code: $($process.ExitCode)"
    }
    catch {
        Warn "RustDesk --uninstall failed: $($_.Exception.Message)"
    }
}

Start-Sleep -Seconds 2

# ============================================================
# 5. Kill any processes spawned/left by uninstall
# ============================================================

Log "Checking for remaining RustDesk processes..."

Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 500

# ============================================================
# 6. Delete RustDesk service if still registered
# ============================================================

Log "Removing RustDesk service..."

try {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service) {
        & sc.exe stop $ServiceName | Out-Null
        Start-Sleep -Milliseconds 500

        & sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 1
    }
}
catch {
    Warn "Could not remove RustDesk service."
}

# ============================================================
# 7. Remove directories
# ============================================================

$pathsToDelete = @(
    "$env:ProgramFiles\RustDesk",
    "$env:APPDATA\RustDesk",
    "$env:LOCALAPPDATA\RustDesk",
    "$env:ProgramData\RustDesk",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Local\RustDesk"
)

if (${env:ProgramFiles(x86)}) {
    $pathsToDelete += "${env:ProgramFiles(x86)}\RustDesk"
}

# SYSTEM profile may also contain remnants on some installations.
$pathsToDelete += @(
    "C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk",
    "C:\Windows\System32\config\systemprofile\AppData\Local\RustDesk"
)

foreach ($path in ($pathsToDelete | Select-Object -Unique)) {
    if (-not $path) {
        continue
    }

    if (Test-Path $path) {
        Log "Removing: $path"

        try {
            Remove-Item `
                -LiteralPath $path `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        catch {
            Warn "Failed to remove '$path': $($_.Exception.Message)"
        }
    }
}

# ============================================================
# 8. Remove uninstall registry entries
# ============================================================

Log "Removing RustDesk uninstall registry entries..."

$registryRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

foreach ($root in $registryRoots) {
    if (-not (Test-Path $root)) {
        continue
    }

    try {
        Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue

                    if (
                        $_.PSChildName -like "*RustDesk*" -or
                        $props.DisplayName -like "RustDesk*"
                    ) {
                        Log "Removing registry key: $($_.Name)"

                        Remove-Item `
                            $_.PSPath `
                            -Recurse `
                            -Force `
                            -ErrorAction SilentlyContinue
                    }
                }
                catch {}
            }
    }
    catch {}
}

# ============================================================
# 9. Remove current-user RustDesk registry remnants
# ============================================================

$currentUserRegistryPaths = @(
    "HKCU:\Software\RustDesk"
)

foreach ($path in $currentUserRegistryPaths) {
    if (Test-Path $path) {
        Log "Removing registry key: $path"

        Remove-Item `
            $path `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ============================================================
# 10. Final cleanup of processes again
# ============================================================

Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 500

# ============================================================
# 11. Verification
# ============================================================

Log "Verifying cleanup..."

$problems = New-Object System.Collections.Generic.List[string]

# Process
$remainingProcesses = @(
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue
)

if ($remainingProcesses.Count -gt 0) {
    $problems.Add(
        "RustDesk process is still running: $(
            ($remainingProcesses.Id -join ', ')
        )"
    )
}

# Service
$remainingService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if ($remainingService) {
    $problems.Add(
        "RustDesk service still exists: status=$($remainingService.Status)"
    )
}

# Files/directories
foreach ($path in ($pathsToDelete | Select-Object -Unique)) {
    if ($path -and (Test-Path $path)) {
        $problems.Add("Directory still exists: $path")
    }
}

# Registry
foreach ($root in $registryRoots) {
    if (-not (Test-Path $root)) {
        continue
    }

    $remaining = @(
        Get-ChildItem $root -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue

                $_.PSChildName -like "*RustDesk*" -or
                $props.DisplayName -like "RustDesk*"
            }
            catch {
                $false
            }
        }
    )

    foreach ($item in $remaining) {
        $problems.Add("Registry entry remains: $($item.Name)")
    }
}

# ============================================================
# RESULT
# ============================================================

Write-Host ""
Write-Host "============================================"

if ($problems.Count -eq 0) {
    Write-Host "CLEAN" -ForegroundColor Green
    Write-Host "RustDesk was fully removed from checked locations."
    Write-Host "A Windows reboot is recommended before installer testing."
    Write-Host "============================================"
    exit 0
}

Write-Host "NOT CLEAN" -ForegroundColor Red
Write-Host ""
Write-Host "Remaining items:"

foreach ($problem in $problems) {
    Write-Host " - $problem" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "A reboot may be required if files/services are pending deletion."
Write-Host "============================================"

exit 1