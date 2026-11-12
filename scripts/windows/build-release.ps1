$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================"
Write-Host " MagendaSupport Windows Release Build"
Write-Host "============================================"
Write-Host ""

$ProjectRoot = Resolve-Path(
    Join-Path $PSScriptRoot "..\.."
)

$KeyPath = Join-Path $HOME ".tauri\magendasupport.key"
$IsCiBuild = $env:CI -eq "true" -or $env:GITHUB_ACTIONS -eq "true"
$PasswordPtr = [IntPtr]::Zero

try {
    if ([string]::IsNullOrWhiteSpace($env:TAURI_SIGNING_PRIVATE_KEY)) {
        if ($IsCiBuild) {
            throw "Set the TAURI_SIGNING_PRIVATE_KEY GitHub Actions secret."
        }
        if (-not (Test-Path -LiteralPath $KeyPath)) {
            throw "Updater private key not found: $KeyPath"
        }

        $PrivateKey = Get-Content -LiteralPath $KeyPath -Raw
        if ([string]::IsNullOrWhiteSpace($PrivateKey)) {
            throw "Updater private key is empty."
        }

        $Password = Read-Host "Enter updater private key password" -AsSecureString
        $PasswordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $PasswordPtr
        )
        $env:TAURI_SIGNING_PRIVATE_KEY = $PrivateKey
        $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $PlainPassword
    }

    Set-Location $ProjectRoot

    Write-Host "Project:"
    Write-Host $ProjectRoot
    Write-Host ""

    Write-Host "Building Tauri Windows release..."
    Write-Host ""

    $BuildArgs = @("run", "tauri", "--", "build", "--config", "src-tauri/tauri.windows.conf.json", "--bundles", "nsis")
    if ($IsCiBuild) {
        $BuildArgs += "--ci"
    }
    $BuildArgs += @("--", "--locked")
    npm @BuildArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Tauri build failed with exit code $LASTEXITCODE"
    }

    $NsisDir = Join-Path `
        $ProjectRoot `
        "src-tauri\target\release\bundle\nsis"

    Write-Host ""
    Write-Host "============================================"
    Write-Host " Windows release build SUCCESS"
    Write-Host "============================================"
    Write-Host ""

    if (Test-Path $NsisDir) {
        Get-ChildItem $NsisDir |
            Select-Object Name, Length, LastWriteTime
    }
}
finally {
    Write-Host ""
    Write-Host "Clearing updater signing secrets..."

    Remove-Item `
        Env:TAURI_SIGNING_PRIVATE_KEY `
        -ErrorAction SilentlyContinue

    Remove-Item `
        Env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD `
        -ErrorAction SilentlyContinue

    if ($PasswordPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
            $PasswordPtr
        )
    }

    $PrivateKey = $null
    $PlainPassword = $null

    Write-Host "Secrets cleared."
}
