param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
)

$ErrorActionPreference = "Stop"

$SignTool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe"
$Dlib = "C:\MagendaSigning\Microsoft.ArtifactSigning.Client\bin\x64\Azure.CodeSigning.Dlib.dll"
$Metadata = "C:\MagendaSigning\metadata.json"

Write-Host ""
Write-Host "========================================"
Write-Host "Azure Artifact Signing"
Write-Host "File: $FilePath"
Write-Host "========================================"
Write-Host ""

if (-not (Test-Path $FilePath)) {
    throw "File to sign does not exist: $FilePath"
}

if (-not (Test-Path $SignTool)) {
    throw "signtool.exe not found: $SignTool"
}

if (-not (Test-Path $Dlib)) {
    throw "Azure.CodeSigning.Dlib.dll not found: $Dlib"
}

if (-not (Test-Path $Metadata)) {
    throw "Artifact Signing metadata not found: $Metadata"
}

& $SignTool sign `
    /v `
    /fd SHA256 `
    /tr "http://timestamp.acs.microsoft.com" `
    /td SHA256 `
    /dlib $Dlib `
    /dmdf $Metadata `
    $FilePath

if ($LASTEXITCODE -ne 0) {
    throw "Azure Artifact Signing failed with exit code $LASTEXITCODE for: $FilePath"
}

$sig = Get-AuthenticodeSignature $FilePath

if ($sig.Status -ne "Valid") {
    throw "Signature verification failed for $FilePath. Status: $($sig.Status)"
}

Write-Host ""
Write-Host "Successfully signed:"
Write-Host $FilePath
Write-Host "Signer: $($sig.SignerCertificate.Subject)"
Write-Host ""