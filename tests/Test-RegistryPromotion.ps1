param(
    [string] $VerifierPath = '',
    [string] $SkopeoImage = 'quay.io/skopeo/stable:latest',
    [string] $RegistryImage = 'registry:3',
    [string] $ArchivePath = '',
    [string] $ChecksumPath = '',
    [string] $Version = '',
    [string] $Revision = ''
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/New-OciFixture.ps1"
$publishPath = [IO.Path]::GetFullPath("$PSScriptRoot/../scripts/publish-oci.ps1")
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('oci-registry-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$environmentNames = @('ARCHIVE_PATH', 'RELEASE_VERSION', 'RELEASE_REVISION', 'IMAGE_REPOSITORY', 'REGISTRY_USERNAME', 'REGISTRY_PASSWORD', 'SOURCE_DIGEST', 'SKOPEO_IMAGE', 'RUNNER_TEMP', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$global:OciRegistryTestState = @{
    DockerPath = @(Get-Command docker -CommandType Application)[0].Source
    Network = 'oci-promotion-' + [guid]::NewGuid().ToString('N')
    Registry = 'oci-promotion-registry'
    ConfigPath = Join-Path $testDirectory 'registries.conf'
    Preserve = $false
}
$registryCreated = $false
$networkCreated = $false

function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

# This adapter selects the isolated test registry and can restore the old preservation flag.
# Every manifest, blob, config, authentication exchange, digest, and error comes from real tools.
function docker {
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]] $args)
    if ($arguments[0] -eq 'run') {
        $arguments.InsertRange(1, [string[]] @('--network', $global:OciRegistryTestState.Network,
            '--mount', ('type=bind,source=' + $global:OciRegistryTestState.ConfigPath.Replace('\', '/') + ',target=/etc/containers/registries.conf,readonly')))
        $commandIndex = $arguments.LastIndexOf('skopeo') + 1
        if ($arguments[$commandIndex] -eq 'copy') {
            if ($global:OciRegistryTestState.Preserve) { $arguments.Insert($commandIndex + 1, '--preserve-digests') }
        }
    }
    & $global:OciRegistryTestState.DockerPath @arguments
    $global:LASTEXITCODE = $LASTEXITCODE
}

function Assert-SourceFailure([string] $Expected, [string] $RequestedVersion, [string] $RequestedRevision) {
    $text = @(& dotnet run --file $VerifierPath -- $ArchivePath $ChecksumPath $RequestedVersion $RequestedRevision 2>&1) -join [Environment]::NewLine
    Assert-True ($LASTEXITCODE -ne 0 -and $text.Contains($Expected)) "Source verification should fail for $Expected. Received: $text"
    Assert-True ([string]::IsNullOrEmpty([IO.File]::ReadAllText($env:GITHUB_OUTPUT))) 'Failed source verification emitted a success digest.'
}

function Assert-Cleanup {
    Assert-True (@(Get-ChildItem $testDirectory -Directory -Filter 'oci-publish-*').Count -eq 0) 'Temporary registry authentication material was left behind.'
}

try {
    if (-not $ArchivePath) {
        $fixture = New-OciFixture (Join-Path $testDirectory 'fixture with spaces')
        $ArchivePath = $fixture.Archive; $ChecksumPath = $fixture.Checksum
        $Version = $fixture.Version; $Revision = $fixture.Revision
    }
    if (-not $VerifierPath) {
        $VerifierPath = Join-Path $testDirectory 'verify-oci-artifact.cs'
        Invoke-WebRequest 'https://raw.githubusercontent.com/codebeltnet/oci-artifact-verify/v1/verify-oci-artifact.cs' -OutFile $VerifierPath
    }
    $VerifierPath = [IO.Path]::GetFullPath($VerifierPath)
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    $ChecksumPath = [IO.Path]::GetFullPath($ChecksumPath)
    $archiveHash = (Get-FileHash $ArchivePath).Hash
    $checksumText = [IO.File]::ReadAllText($ChecksumPath)
    $env:ARCHIVE_PATH = $ArchivePath
    $env:RELEASE_VERSION = $Version
    $env:RELEASE_REVISION = $Revision
    $env:IMAGE_REPOSITORY = "$($global:OciRegistryTestState.Registry):5000/geekle/docs"
    $env:REGISTRY_USERNAME = 'promotion-test-user'
    $env:REGISTRY_PASSWORD = 'test-password-for-oci-promotion'
    $env:SKOPEO_IMAGE = $SkopeoImage
    $env:RUNNER_TEMP = $testDirectory
    $env:GITHUB_STEP_SUMMARY = Join-Path $testDirectory 'summary.md'
    $env:GITHUB_OUTPUT = Join-Path $testDirectory 'source-output.txt'
    [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')

    # Use the actual v1 source verifier, including its checksum, metadata, and platform validation.
    Assert-SourceFailure 'named for release version' '99.99.99' $Revision
    Assert-SourceFailure 'revision annotation does not match' $Version ('f' * 40)
    $invalidChecksum = Join-Path $testDirectory 'invalid.sha256'
    [IO.File]::WriteAllText($invalidChecksum, ('0' * 64) + '  ' + [IO.Path]::GetFileName($ArchivePath))
    $validChecksumPath = $ChecksumPath
    $ChecksumPath = $invalidChecksum
    Assert-SourceFailure 'checksum mismatch' $Version $Revision
    $ChecksumPath = $validChecksumPath
    & dotnet run --file $VerifierPath -- $ArchivePath $ChecksumPath $Version $Revision
    Assert-True ($LASTEXITCODE -eq 0) 'The persisted OCI archive must verify before publication.'
    $env:SOURCE_DIGEST = ([IO.File]::ReadAllText($env:GITHUB_OUTPUT).Trim() -replace '^digest=', '')
    if ($fixture) { Assert-True ($env:SOURCE_DIGEST -ceq $fixture.SourceDigest) 'Source verifier returned the wrong index digest.' }

    # Synthetic test credentials only. This bcrypt record is for test-password-for-oci-promotion.
    $authDirectory = Join-Path $testDirectory 'registry-auth'
    New-Item -ItemType Directory -Path $authDirectory | Out-Null
    [IO.File]::WriteAllText((Join-Path $authDirectory 'htpasswd'), 'promotion-test-user:$2y$05$OvrJhnS/PTlasd5uh/FW0uLHbMO3pnOPG1eEPAXDtKapZyrW/iclO')
    [IO.File]::WriteAllText($global:OciRegistryTestState.ConfigPath, "[[registry]]`nlocation = `"$($global:OciRegistryTestState.Registry):5000`"`ninsecure = true`n")
    & $global:OciRegistryTestState.DockerPath network create --internal $global:OciRegistryTestState.Network | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the isolated test network.'
    $networkCreated = $true
    & $global:OciRegistryTestState.DockerPath run -d --name $global:OciRegistryTestState.Network --network $global:OciRegistryTestState.Network --network-alias $global:OciRegistryTestState.Registry --mount "type=bind,source=$($authDirectory.Replace('\','/')),target=/auth,readonly" --env REGISTRY_AUTH=htpasswd --env REGISTRY_AUTH_HTPASSWD_REALM=promotion-test --env REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd $RegistryImage | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not start the authenticated test registry.'
    $registryCreated = $true

    $env:GITHUB_OUTPUT = Join-Path $testDirectory 'publish-output.txt'
    [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
    $global:OciRegistryTestState.Preserve = $true
    $errorText = ''
    try { & $publishPath *> (Join-Path $testDirectory 'original-failure.log') } catch { $errorText = $_.Exception.Message }
    Assert-True ($errorText.Contains('Manifest list must be converted') -and $errorText.Contains('Instructed to preserve digests')) "Did not reproduce the exact preservation/conversion regression: $errorText; log: $([IO.File]::ReadAllText((Join-Path $testDirectory 'original-failure.log')))"
    Assert-True ([IO.File]::ReadAllText($env:GITHUB_OUTPUT) -eq '') 'Failed publication emitted success outputs.'
    Assert-Cleanup
    Write-Host 'PASS real Skopeo preserve-digests/OCI conversion regression reproduced'

    $global:OciRegistryTestState.Preserve = $false
    & $publishPath
    $outputs = [IO.File]::ReadAllText($env:GITHUB_OUTPUT)
    $destinationDigest = ([regex]::Match($outputs, '(?m)^digest=(sha256:[0-9a-f]{64})\r?$')).Groups[1].Value
    Assert-True ($destinationDigest -and $destinationDigest -cne $env:SOURCE_DIGEST) 'The real OCI normalization must produce a different destination digest.'
    Assert-True ($outputs.Contains("image-by-digest=$env:IMAGE_REPOSITORY@$destinationDigest")) 'Immutable output must use the actual destination digest.'
    Assert-Cleanup
    Write-Host 'PASS real authenticated registry promotion, child/config readback, metadata, platforms, and destination outputs'

    $env:REGISTRY_PASSWORD = 'invalid-test-password'
    [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
    $errorText = ''
    try { & $publishPath *> (Join-Path $testDirectory 'invalid-auth.log') } catch { $errorText = $_.Exception.Message }
    Assert-True ($errorText.Contains('registry rejected access')) "Invalid registry credentials should fail clearly: $errorText"
    Assert-True ([IO.File]::ReadAllText($env:GITHUB_OUTPUT) -eq '') 'Invalid credentials emitted success outputs.'
    Assert-Cleanup
    Write-Host 'PASS invalid credentials against a real authenticated registry'
    Assert-True ((Get-FileHash $ArchivePath).Hash -eq $archiveHash) 'Promotion modified the immutable archive.'
    Assert-True ([IO.File]::ReadAllText($ChecksumPath) -ceq $checksumText) 'Promotion modified the immutable checksum.'
} finally {
    Remove-Item Function:docker
    if ($registryCreated) { & $global:OciRegistryTestState.DockerPath rm -f $global:OciRegistryTestState.Network | Out-Null }
    if ($networkCreated) { & $global:OciRegistryTestState.DockerPath network rm $global:OciRegistryTestState.Network | Out-Null }
    Remove-Variable OciRegistryTestState -Scope Global
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
