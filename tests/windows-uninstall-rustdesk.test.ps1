# No admin rights, live services, registry writes or real uninstall processes.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "../src-tauri/windows/uninstall-rustdesk.ps1")

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message (expected: $Expected, got: $Actual)" }
}

function New-State([bool]$Present, [string]$Executable = "") {
    [PSCustomObject]@{
        Present = $Present
        Executable = $Executable
        ServicePresent = $Present
        Registered = $Present
        Directories = @("D:\Tools\RustDesk")
    }
}

function Reset-Scenario($States) {
    $script:states = $States
    $script:stateCalls = 0
    $script:launches = 0
    $script:sleeps = 0
    $script:trackedDirectories = @()
    $script:busy = $false
}

# Every side-effect boundary is replaced before running any scenario.
function Assert-NoRustDeskSetup {
    if ($script:busy) { throw "setup busy" }
}
function Get-RustDeskUninstallState {
    param([string[]]$InstallationDirectories = @())
    $script:trackedDirectories = $InstallationDirectories
    $index = [Math]::Min($script:stateCalls, $script:states.Count - 1)
    $script:stateCalls++
    return $script:states[$index]
}
function Start-RustDeskUninstall {
    param([string]$Executable)
    Assert-Equal $Executable "D:\Tools\RustDesk\rustdesk.exe" "Wrong executable"
    $script:launches++
}
function Start-Sleep { param([int]$Seconds); $script:sleeps++ }

$present = New-State $true "D:\Tools\RustDesk\rustdesk.exe"
$absent = New-State $false

Reset-Scenario @($absent)
Invoke-RustDeskUninstall -TimeoutSeconds 5
Assert-Equal $script:launches 0 "An absent program must be a successful no-op"

Reset-Scenario @($present, $present, $absent, $present, $absent, $absent, $absent)
Invoke-RustDeskUninstall -TimeoutSeconds 10
Assert-Equal $script:launches 1 "Only one uninstall should be started"
Assert-Equal $script:sleeps 6 "Must wait for stable removal, not just launcher exit"
Assert-Equal ($script:trackedDirectories -join ',') "D:\Tools\RustDesk" "Custom path must stay tracked after registry removal"

Reset-Scenario @((New-State $true))
$failed = $false
try { Invoke-RustDeskUninstall -TimeoutSeconds 5 } catch { $failed = $true }
Assert-Equal $failed $true "Missing executable must not report successful removal"
Assert-Equal $script:launches 0 "Missing executable must not launch anything"

Reset-Scenario @($present)
$failed = $false
try { Invoke-RustDeskUninstall -TimeoutSeconds 4 } catch { $failed = $true }
Assert-Equal $failed $true "Incomplete removal must fail"
Assert-Equal $script:sleeps 4 "Waiting must be bounded"
Assert-Equal $script:launches 1 "Timeout must not start another uninstall"

Reset-Scenario @($present)
$script:busy = $true
$failed = $false
try { Invoke-RustDeskUninstall -TimeoutSeconds 5 } catch { $failed = $true }
Assert-Equal $failed $true "Concurrent setup must prevent removal"
Assert-Equal $script:launches 0 "Concurrent setup must not be interrupted"

Write-Host "Passed 5 isolated RustDesk uninstall scenarios."
