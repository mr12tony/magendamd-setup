#requires -Version 5.1

$ErrorActionPreference = "SilentlyContinue"

$OutFile = Join-Path $PSScriptRoot "rustdesk-diagnostics.txt"

function Section {
    param([string]$Name)

    Add-Content $OutFile ""
    Add-Content $OutFile "============================================================"
    Add-Content $OutFile $Name
    Add-Content $OutFile "============================================================"
}

function Run {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Section $Title

    try {
        $Result = & $Command 2>&1

        if ($null -ne $Result) {
            $Result | Out-String | Add-Content $OutFile
        }
    }
    catch {
        Add-Content $OutFile "ERROR: $($_.Exception.Message)"
    }
}

Remove-Item $OutFile -Force -ErrorAction SilentlyContinue

Add-Content $OutFile "RustDesk Windows diagnostics"
Add-Content $OutFile "Date: $(Get-Date)"
Add-Content $OutFile ""

# ==========================================================
# WINDOWS
# ==========================================================

Run "WINDOWS VERSION" {
    Get-ComputerInfo |
        Select-Object `
            WindowsProductName,
            WindowsVersion,
            OsBuildNumber,
            OsArchitecture,
            CsName
}

# ==========================================================
# CURRENT USER
# ==========================================================

Run "CURRENT POWERSHELL USER" {
    whoami
}

Run "WINDOWS IDENTITY" {
    [Security.Principal.WindowsIdentity]::GetCurrent() |
        Select-Object Name, User, AuthenticationType, IsSystem
}

Run "CURRENT USER ENVIRONMENT" {
    Get-ChildItem Env: |
        Sort-Object Name
}

# ==========================================================
# ARCHITECTURE
# ==========================================================

Run "ARCHITECTURE" {
    Write-Output "PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE"
    Write-Output "PROCESSOR_ARCHITEW6432=$env:PROCESSOR_ARCHITEW6432"
    Write-Output "OSArchitecture=$((Get-CimInstance Win32_OperatingSystem).OSArchitecture)"
}

# ==========================================================
# RUSTDESK PROCESSES
# ==========================================================

Run "RUSTDESK PROCESSES" {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "RustDesk"
        } |
        Select-Object `
            ProcessId,
            ParentProcessId,
            Name,
            ExecutablePath,
            CommandLine
}

# ==========================================================
# RUSTDESK SERVICES
# ==========================================================

Run "RUSTDESK SERVICES" {
    Get-CimInstance Win32_Service |
        Where-Object {
            $_.Name -match "RustDesk" -or
            $_.DisplayName -match "RustDesk" -or
            $_.PathName -match "RustDesk"
        } |
        Select-Object `
            Name,
            DisplayName,
            State,
            StartMode,
            StartName,
            PathName
}

# ==========================================================
# SC QUERY
# ==========================================================

Run "SC QUERY RUSTDESK" {
    sc.exe query type= service state= all
}

Run "SC QC RUSTDESK" {
    $Services = Get-CimInstance Win32_Service |
        Where-Object {
            $_.Name -match "RustDesk" -or
            $_.DisplayName -match "RustDesk"
        }

    foreach ($Service in $Services) {
        Write-Output ""
        Write-Output "SERVICE: $($Service.Name)"
        sc.exe qc $Service.Name
    }
}

# ==========================================================
# INSTALLED SOFTWARE
# ==========================================================

Run "INSTALLED SOFTWARE" {
    Get-ItemProperty `
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" |
        Where-Object {
            $_.DisplayName -match "RustDesk"
        } |
        Select-Object `
            DisplayName,
            DisplayVersion,
            Publisher,
            InstallLocation,
            UninstallString
}

# ==========================================================
# POSSIBLE RUSTDESK FILES
# ==========================================================

Run "PROGRAM FILES RUSTDESK" {

    $Paths = @(
        "$env:ProgramFiles\RustDesk",
        "${env:ProgramFiles(x86)}\RustDesk",
        "$env:ProgramData\RustDesk",
        "$env:LOCALAPPDATA\RustDesk",
        "$env:APPDATA\RustDesk"
    )

    foreach ($Path in $Paths) {

        Write-Output ""
        Write-Output "PATH: $Path"

        if (Test-Path $Path) {

            Get-ChildItem `
                -Path $Path `
                -Recurse `
                -Force |
                Select-Object FullName, Length, LastWriteTime

        }
        else {

            Write-Output "NOT FOUND"
        }
    }
}

# ==========================================================
# SEARCH FOR RUSTDESK.EXE
# ==========================================================

Run "RUSTDESK.EXE LOCATIONS" {

    $Roots = @(
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        "$env:ProgramData",
        "$env:LOCALAPPDATA",
        "$env:APPDATA"
    ) | Where-Object {
        $_ -and (Test-Path $_)
    }

    foreach ($Root in $Roots) {

        Write-Output ""
        Write-Output "SEARCH ROOT: $Root"

        Get-ChildItem `
            -Path $Root `
            -Filter "RustDesk.exe" `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LastWriteTime
    }
}

# ==========================================================
# CONFIG FILE SEARCH
# ==========================================================

Run "RUSTDESK2.TOML LOCATIONS" {

    $Roots = @(
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        "$env:ProgramData",
        "$env:LOCALAPPDATA",
        "$env:APPDATA",
        "$env:WINDIR"
    ) | Where-Object {
        $_ -and (Test-Path $_)
    }

    foreach ($Root in $Roots) {

        Write-Output ""
        Write-Output "SEARCH ROOT: $Root"

        Get-ChildItem `
            -Path $Root `
            -Filter "RustDesk2.toml" `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LastWriteTime
    }
}

# ==========================================================
# CONFIG CONTENT
# ==========================================================

Run "CONFIG CONTENTS" {

    $Files = @(
        "$env:APPDATA\RustDesk\RustDesk2.toml",
        "$env:ProgramData\RustDesk\config\RustDesk2.toml",
        "$env:ProgramData\RustDesk\RustDesk2.toml"
    )

    foreach ($File in $Files) {

        if (Test-Path $File) {

            Write-Output ""
            Write-Output "FILE: $File"
            Write-Output "--------------------------------------------"

            Get-Content $File
        }
    }
}

# ==========================================================
# RUSTDESK EXE HELP
# ==========================================================

Run "RUSTDESK COMMAND HELP" {

    $Candidates = @(
        "$env:ProgramFiles\RustDesk\RustDesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\RustDesk.exe"
    )

    foreach ($Exe in $Candidates) {

        if (Test-Path $Exe) {

            Write-Output ""
            Write-Output "EXE: $Exe"

            Write-Output "--- VERSION ---"

            (Get-Item $Exe).VersionInfo |
                Select-Object `
                    FileVersion,
                    ProductVersion,
                    ProductName,
                    FileDescription

            Write-Output "--- HELP ---"

            & $Exe --help 2>&1

            Write-Output "--- VERSION COMMAND ---"

            & $Exe --version 2>&1
        }
    }
}

# ==========================================================
# RUSTDESK COMMANDS
# ==========================================================

Run "RUSTDESK GET-ID" {

    $Candidates = @(
        "$env:ProgramFiles\RustDesk\RustDesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\RustDesk.exe"
    )

    foreach ($Exe in $Candidates) {

        if (Test-Path $Exe) {

            Write-Output ""
            Write-Output "EXE: $Exe"

            & $Exe --get-id 2>&1
        }
    }
}

# ==========================================================
# RUSTDESK SERVICE INSTALL HELP
# ==========================================================

Run "RUSTDESK INSTALL-SERVICE TEST" {

    $Candidates = @(
        "$env:ProgramFiles\RustDesk\RustDesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\RustDesk.exe"
    )

    foreach ($Exe in $Candidates) {

        if (Test-Path $Exe) {

            Write-Output ""
            Write-Output "EXE: $Exe"

            & $Exe --install-service 2>&1

            Write-Output "EXIT CODE: $LASTEXITCODE"
        }
    }
}

# ==========================================================
# REGISTRY RUSTDESK
# ==========================================================

Run "REGISTRY RUSTDESK HKLM" {

    Get-ChildItem `
        "HKLM:\SOFTWARE" `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "RustDesk"
        } |
        Select-Object PSPath
}

Run "REGISTRY RUSTDESK HKCU" {

    Get-ChildItem `
        "HKCU:\Software" `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "RustDesk"
        } |
        Select-Object PSPath
}

# ==========================================================
# STARTUP
# ==========================================================

Run "STARTUP RUSTDESK" {

    Get-CimInstance Win32_StartupCommand |
        Where-Object {
            $_.Name -match "RustDesk" -or
            $_.Command -match "RustDesk"
        } |
        Select-Object `
            Name,
            Command,
            Location,
            User
}

# ==========================================================
# TASK SCHEDULER
# ==========================================================

Run "SCHEDULED TASKS RUSTDESK" {

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -match "RustDesk" -or
            $_.TaskPath -match "RustDesk"
        } |
        Select-Object `
            TaskName,
            TaskPath,
            State
}

# ==========================================================
# FIREWALL
# ==========================================================

Run "FIREWALL RUSTDESK" {

    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match "RustDesk"
        } |
        Select-Object `
            DisplayName,
            Enabled,
            Direction,
            Action
}

# ==========================================================
# USER PROFILES
# ==========================================================

Run "USER PROFILES" {

    Get-CimInstance Win32_UserProfile |
        Where-Object {
            $_.Special -eq $false
        } |
        Select-Object `
            LocalPath,
            SID,
            Loaded
}

# ==========================================================
# LOCAL SERVICE PROFILE
# ==========================================================

Run "LOCAL SERVICE RUSTDESK DATA" {

    $Path = "$env:WINDIR\ServiceProfiles\LocalService\AppData\Roaming"

    if (Test-Path $Path) {

        Get-ChildItem `
            -Path $Path `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match "RustDesk"
            } |
            Select-Object FullName, Length, LastWriteTime
    }
}

# ==========================================================
# NETWORK CONFIG
# ==========================================================

Run "NETWORK CONFIG FILES" {

    $Files = Get-ChildItem `
        -Path @(
            "$env:ProgramData",
            "$env:APPDATA",
            "$env:LOCALAPPDATA",
            "$env:WINDIR\ServiceProfiles"
        ) `
        -Filter "RustDesk*.toml" `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    foreach ($File in $Files) {

        Write-Output ""
        Write-Output "FILE: $($File.FullName)"

        Get-Content $File.FullName
    }
}

# ==========================================================
# FINAL
# ==========================================================

Section "END"

Add-Content $OutFile "Diagnostics completed."
Add-Content $OutFile "Output file:"
Add-Content $OutFile $OutFile

Write-Host ""
Write-Host "Diagnostics completed."
Write-Host ""
Write-Host "File:"
Write-Host $OutFile