param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath
)

$ErrorActionPreference = "Stop"

try {
    Write-Host "[Token] Installer path: $InstallerPath"

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension(
        $InstallerPath
    )

    Write-Host "[Token] Installer filename: $fileName"

    # Supported:
    #
    # magendamd-setup-qwertyiop
    # magendamd-setup-qwertyiop (1)
    # magendamd-setup-qwertyiop (25)

    if (
        $fileName -notmatch
        '^magendamd-setup-([A-Za-z0-9_-]+)(?: \(\d+\))?$'
    ) {
        Write-Host "[Token] Token not found in filename."
        exit 2
    }

    $token = $Matches[1]

    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "[Token] Token is empty."
        exit 3
    }

    $programData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    )

    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw "Could not resolve ProgramData."
    }

    $directory = Join-Path $programData "Magendamd"
    $outputFile = Join-Path $directory "install.json"

    Write-Host "[Token] ProgramData: $programData"
    Write-Host "[Token] Output: $outputFile"

    New-Item `
        -ItemType Directory `
        -Path $directory `
        -Force |
        Out-Null

    $json = @{
        install_token = $token
    } | ConvertTo-Json -Compress

    $utf8 = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $outputFile,
        $json,
        $utf8
    )

    if (-not (Test-Path -LiteralPath $outputFile)) {
        throw "install.json was not created."
    }

    Write-Host "[Token] Token saved successfully."

    exit 0
}
catch {
    Write-Host "[Token] ERROR: $($_.Exception.Message)"
    exit 1
}