$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================"
Write-Host " MagendaSupport Windows Release Signing"
Write-Host "============================================"
Write-Host ""

$ProjectRoot = Resolve-Path(
    Join-Path $PSScriptRoot "..\.."
)

$NsisDir = Join-Path `
    $ProjectRoot `
    "src-tauri\target\release\bundle\nsis"

$KeyPath = Join-Path `
    $HOME `
    ".tauri\magendasupport.key"

$SignTool = `
    "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe"

$Dlib = `
    "C:\MagendaSigning\Microsoft.ArtifactSigning.Client\bin\x64\Azure.CodeSigning.Dlib.dll"

$Metadata = `
    "C:\MagendaSigning\metadata.json"

$AzureCliDir = `
    "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"

$AzureCli = Join-Path `
    $AzureCliDir `
    "az.cmd"


# ------------------------------------------------------------
# Check files
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $NsisDir)) {
    throw "NSIS directory not found: $NsisDir"
}

if (-not (Test-Path -LiteralPath $SignTool)) {
    throw "SignTool not found: $SignTool"
}

if (-not (Test-Path -LiteralPath $Dlib)) {
    throw "Artifact Signing Dlib not found: $Dlib"
}

if (-not (Test-Path -LiteralPath $Metadata)) {
    throw "Artifact Signing metadata not found: $Metadata"
}

if (-not (Test-Path -LiteralPath $KeyPath)) {
    throw "Updater private key not found: $KeyPath"
}

if (-not (Test-Path -LiteralPath $AzureCli)) {
    throw "Azure CLI not found: $AzureCli"
}


# ------------------------------------------------------------
# Make Azure CLI available to Dlib
# ------------------------------------------------------------

if (($env:PATH -split ";") -notcontains $AzureCliDir) {
    $env:PATH = "$AzureCliDir;$env:PATH"
}

Write-Host "Azure CLI:"
Write-Host $AzureCli
Write-Host ""


# ------------------------------------------------------------
# Find newest NSIS installer
# ------------------------------------------------------------

$Installer = Get-ChildItem `
    -LiteralPath $NsisDir `
    -Filter "MagendaSupport_*_x64-setup.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $Installer) {
    throw "NSIS installer not found in: $NsisDir"
}

$InstallerPath = $Installer.FullName
$SigPath = "$InstallerPath.sig"

Write-Host "Installer:"
Write-Host $InstallerPath
Write-Host ""


# ------------------------------------------------------------
# Check Azure login
# ------------------------------------------------------------

Write-Host "Checking Azure CLI login..."
Write-Host ""

& $AzureCli account show *> $null

if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not logged in. Run: az login"
}

Write-Host "Azure login OK."
Write-Host ""


# ------------------------------------------------------------
# Azure Artifact Signing
# ------------------------------------------------------------

Write-Host "Signing NSIS installer with MagendaMD certificate..."
Write-Host ""

& $SignTool sign `
    /v `
    /fd SHA256 `
    /tr "http://timestamp.acs.microsoft.com" `
    /td SHA256 `
    /dlib $Dlib `
    /dmdf $Metadata `
    $InstallerPath

if ($LASTEXITCODE -ne 0) {
    throw "Azure Artifact Signing failed with exit code $LASTEXITCODE"
}


# ------------------------------------------------------------
# Verify Authenticode
# ------------------------------------------------------------

Write-Host ""
Write-Host "Verifying Authenticode signature..."
Write-Host ""

$Signature = Get-AuthenticodeSignature $InstallerPath

Write-Host "Status:"
Write-Host $Signature.Status

if ($Signature.SignerCertificate) {
    Write-Host ""
    Write-Host "Signer:"
    Write-Host $Signature.SignerCertificate.Subject
}

Write-Host ""

if ($Signature.Status -ne "Valid") {
    throw "Authenticode signature is not valid."
}

Write-Host "Authenticode signature OK."
Write-Host ""


# ------------------------------------------------------------
# Remove OLD Tauri updater signature
# ------------------------------------------------------------

if (Test-Path -LiteralPath $SigPath) {
    Write-Host "Removing old updater signature:"
    Write-Host $SigPath
    Write-Host ""

    Remove-Item `
        -LiteralPath $SigPath `
        -Force
}


# ------------------------------------------------------------
# Read Tauri updater password
# ------------------------------------------------------------

$Password = Read-Host `
    "Enter updater private key password" `
    -AsSecureString

$PasswordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
    $Password
)

try {

    $PlainPassword =
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $PasswordPtr
        )

    $PrivateKey = Get-Content `
        -LiteralPath $KeyPath `
        -Raw

    if ([string]::IsNullOrWhiteSpace($PrivateKey)) {
        throw "Updater private key is empty."
    }

    $env:TAURI_SIGNING_PRIVATE_KEY = $PrivateKey
    $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $PlainPassword


    # --------------------------------------------------------
    # Create NEW updater signature
    # --------------------------------------------------------

    Set-Location $ProjectRoot

    Write-Host ""
    Write-Host "Creating new Tauri updater signature..."
    Write-Host ""

    npm run tauri signer sign -- $InstallerPath

    if ($LASTEXITCODE -ne 0) {
        throw "Tauri updater signing failed with exit code $LASTEXITCODE"
    }


    # --------------------------------------------------------
    # Verify .sig
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $SigPath)) {
        throw "Updater signature was not created: $SigPath"
    }

    Write-Host ""
    Write-Host "Updater signature created:"
    Write-Host $SigPath
    Write-Host ""


    # --------------------------------------------------------
    # Final result
    # --------------------------------------------------------

    Write-Host "============================================"
    Write-Host " Windows release signing SUCCESS"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "Authenticode:"
    Write-Host $Signature.Status
    Write-Host $Signature.SignerCertificate.Subject
    Write-Host ""

    Write-Host "Release files:"
    Write-Host ""

    Get-Item `
        $InstallerPath, `
        $SigPath |
        Select-Object Name, Length, LastWriteTime
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