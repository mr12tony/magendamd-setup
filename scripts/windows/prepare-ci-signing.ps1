$ErrorActionPreference = "Stop"

if ($env:GITHUB_ACTIONS -ne "true" -or -not $env:RUNNER_TEMP -or -not $env:GITHUB_ENV) {
    throw "This script prepares signing tools on a GitHub Actions Windows runner."
}

foreach ($Name in @("AZURE_SIGNING_ENDPOINT", "AZURE_SIGNING_ACCOUNT_NAME", "AZURE_CERTIFICATE_PROFILE_NAME")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
        throw "Set the $Name repository variable in GitHub Actions."
    }
}

$Endpoint = [Uri]$env:AZURE_SIGNING_ENDPOINT
if (-not $Endpoint.IsAbsoluteUri -or $Endpoint.Scheme -ne "https") {
    throw "AZURE_SIGNING_ENDPOINT must be the HTTPS Account URI from Azure."
}

# Hosted Windows runners include the SDK; choose the newest available x64 tool.
$SdkBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$SignTool = Get-ChildItem -Path "$SdkBin\*\x64\signtool.exe" -File |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1
if (-not $SignTool) {
    throw "The Windows SDK x64 signtool.exe is missing."
}

$ToolsDirectory = Join-Path $env:RUNNER_TEMP "magenda-signing"
New-Item -ItemType Directory -Force -Path $ToolsDirectory | Out-Null

# Use the same signing client as the existing local Windows signing script.
nuget install Microsoft.ArtifactSigning.Client `
    -OutputDirectory $ToolsDirectory `
    -ExcludeVersion `
    -NonInteractive `
    -Source "https://api.nuget.org/v3/index.json"
if ($LASTEXITCODE -ne 0) {
    throw "Cannot install the Azure Artifact Signing client (exit code $LASTEXITCODE)."
}

$Dlib = Join-Path $ToolsDirectory "Microsoft.ArtifactSigning.Client\bin\x64\Azure.CodeSigning.Dlib.dll"
if (-not (Test-Path -LiteralPath $Dlib -PathType Leaf)) {
    throw "Azure Artifact Signing x64 Dlib was not found in the installed package."
}

$MetadataPath = Join-Path $ToolsDirectory "metadata.json"
@{
    Endpoint = $Endpoint.AbsoluteUri
    CodeSigningAccountName = $env:AZURE_SIGNING_ACCOUNT_NAME
    CertificateProfileName = $env:AZURE_CERTIFICATE_PROFILE_NAME
    # azure/login exchanges the GitHub OIDC token for an Azure CLI session.
    # Keep AzureCliCredential enabled; no client secret or interactive login.
    ExcludeCredentials = @(
        "EnvironmentCredential",
        "WorkloadIdentityCredential",
        "ManagedIdentityCredential",
        "SharedTokenCacheCredential",
        "VisualStudioCredential",
        "VisualStudioCodeCredential",
        "AzurePowerShellCredential",
        "AzureDeveloperCliCredential",
        "InteractiveBrowserCredential"
    )
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $MetadataPath -Encoding utf8

"MAGENDA_SIGNTOOL_PATH=$($SignTool.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
"MAGENDA_SIGNING_DLIB_PATH=$Dlib" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
"MAGENDA_SIGNING_METADATA_PATH=$MetadataPath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
