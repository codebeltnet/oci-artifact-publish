$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/New-OciFixture.ps1"
. "$PSScriptRoot/../scripts/verify-promotion.ps1"
$publishPath = [IO.Path]::GetFullPath("$PSScriptRoot/../scripts/publish-oci.ps1")
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('oci-publish-tests-' + [guid]::NewGuid().ToString('N'))
$environmentNames = @('ARCHIVE_PATH', 'RELEASE_VERSION', 'RELEASE_REVISION', 'IMAGE_REPOSITORY', 'REGISTRY_USERNAME', 'REGISTRY_PASSWORD', 'SOURCE_DIGEST', 'SKOPEO_IMAGE', 'RUNNER_TEMP', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$script:passed = 0
$global:OciPublishTestState = @{}

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function docker {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'version') { return '29.0.0' }
    $global:OciPublishTestState.calls.Add($arguments)
    Assert-True (-not ($arguments -contains '--preserve-digests')) 'Publication must permit index conversion.'
    Assert-True (-not ($arguments -contains $env:REGISTRY_PASSWORD)) 'Credentials must not appear in Docker arguments.'
    $mount = $arguments | Where-Object { $_ -like 'type=bind,*target=/handoff' }
    $handoff = ($mount -replace '^type=bind,source=', '') -replace ',target=/handoff$', ''
    Assert-True (Test-Path (Join-Path $handoff 'auth.json')) 'Auth file must exist during promotion.'
    $outputArgument = $arguments | Where-Object { $_ -like 'SKOPEO_OUTPUT=*' }
    $outputName = $outputArgument -replace '^SKOPEO_OUTPUT=/handoff/', ''
    $commandIndex = [Array]::LastIndexOf($arguments, 'skopeo') + 1
    $command = $arguments[$commandIndex]
    $reference = $arguments[-1]
    if ($command -eq 'copy') {
        Assert-True ($arguments -contains '--all') 'Skopeo must publish all platforms.'
        Assert-True ($global:OciPublishTestState.calls.Count -eq 2) 'The verified source index must be read before publishing.'
        if ($global:OciPublishTestState.mode -eq 'access-failure') {
            $global:LASTEXITCODE = 1
            return 'unauthorized: authentication required'
        }
        if ($global:OciPublishTestState.mode -eq 'media-failure') {
            $global:LASTEXITCODE = 17
            return 'Manifest list must be converted to type "application/vnd.oci.image.index.v1+json": Instructed to preserve digests'
        }
        if ($global:OciPublishTestState.mode -eq 'missing-digest') { return }
        $digest = if ($global:OciPublishTestState.mode -eq 'invalid-digest') { 'sha256:invalid' } else { $global:OciPublishTestState.destinationDigest }
        [IO.File]::WriteAllText((Join-Path $handoff 'published-digest.txt'), $digest)
        return
    }
    $bytes = if ($reference.StartsWith('oci-archive:')) {
        $global:OciPublishTestState.fixture.Blobs['blobs/sha256/' + $global:OciPublishTestState.fixture.SourceDigest.Split(':')[1]]
    } elseif ($reference.EndsWith('@' + $global:OciPublishTestState.destinationDigest)) {
        Assert-True ($reference -eq "docker://$env:IMAGE_REPOSITORY@$($global:OciPublishTestState.destinationDigest)") 'Readback must use the destination digest.'
        if ($global:OciPublishTestState.mode -eq 'read-failure') { $global:LASTEXITCODE = 1; return 'manifest unknown' }
        $global:OciPublishTestState.destinationBytes
    } else {
        $digest = $reference.Split('@')[-1]
        if ($arguments -contains '--config') { $digest = $global:OciPublishTestState.fixture.Configs[$digest] }
        $global:OciPublishTestState.fixture.Blobs['blobs/sha256/' + $digest.Split(':')[1]]
    }
    if ($global:OciPublishTestState.mode -eq 'corrupt-child' -and $outputName -eq 'child-manifest.json') { $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    if ($global:OciPublishTestState.mode -eq 'corrupt-config' -and $outputName -eq 'platform-config.json') { $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    [IO.File]::WriteAllBytes((Join-Path $handoff $outputName), $bytes)
}

function Invoke-Case([string] $Name, [string] $Mode = 'normalized', [scriptblock] $Mutate = {}, [string] $ExpectedError = '') {
    $global:OciPublishTestState.mode = $Mode
    $global:OciPublishTestState.calls = [Collections.Generic.List[object]]::new()
    $destination = Read-OciJson $global:OciPublishTestState.fixture.SourcePath
    & $Mutate $destination
    $text = if ($Mode -eq 'unchanged') { Get-Content $global:OciPublishTestState.fixture.SourcePath -Raw } else { $destination | ConvertTo-Json -Depth 30 -Compress }
    if ($Mode -eq 'duplicate-json') { $text = '{"schemaVersion":1,' + $text.Substring(1) }
    $global:OciPublishTestState.destinationBytes = [Text.Encoding]::UTF8.GetBytes($text)
    $global:OciPublishTestState.destinationDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($global:OciPublishTestState.destinationBytes)).ToLowerInvariant()
    $env:REGISTRY_PASSWORD = if ($Mode -eq 'missing-credentials') { '' } else { 'unit-test-password' }
    $env:SOURCE_DIGEST = if ($Mode -eq 'wrong-source') { 'sha256:' + ('f' * 64) } else { $global:OciPublishTestState.fixture.SourceDigest }
    $env:GITHUB_OUTPUT = Join-Path $testDirectory 'publish-output.txt'
    [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
    $logPath = Join-Path $testDirectory 'case.log'
    $errorText = ''
    try { & $publishPath *> $logPath } catch { $errorText = $_.Exception.Message + [Environment]::NewLine + $_.ScriptStackTrace }
    $outputs = Get-Content $env:GITHUB_OUTPUT -Raw
    if ($ExpectedError) {
        Assert-True ($errorText.Contains($ExpectedError)) "$Name failed with unexpected error: $errorText"
        Assert-True ([string]::IsNullOrEmpty($outputs)) "$Name emitted success outputs on failure."
    } else {
        Assert-True (-not $errorText) "$Name failed: $errorText"
        Assert-True ($outputs.Contains("digest=$($global:OciPublishTestState.destinationDigest)")) 'Output digest must be the destination digest.'
        Assert-True ($outputs.Contains("image-by-digest=$env:IMAGE_REPOSITORY@$($global:OciPublishTestState.destinationDigest)")) 'Immutable reference must use the destination digest.'
        Assert-True ($outputs.Contains("image=$($env:IMAGE_REPOSITORY):$($env:RELEASE_VERSION)")) 'Tagged output must remain compatible.'
        Assert-True ($global:OciPublishTestState.calls.Count -eq 9) 'Both runnable configs and all four child manifests must be read.'
    }
    Assert-True (@(Get-ChildItem $testDirectory -Directory -Filter 'oci-publish-*').Count -eq 0) "$Name left temporary authentication material."
    $caseLog = [IO.File]::ReadAllText($logPath)
    Assert-True (-not $caseLog.Contains('unit-test-password')) "$Name printed credentials."
    $script:passed++
    Write-Host "PASS $Name"
}

try {
    $global:OciPublishTestState.fixture = New-OciFixture (Join-Path $testDirectory 'fixture with spaces')
    $archiveHash = (Get-FileHash $global:OciPublishTestState.fixture.Archive).Hash
    $env:ARCHIVE_PATH = $global:OciPublishTestState.fixture.Archive
    $env:RELEASE_VERSION = $global:OciPublishTestState.fixture.Version
    $env:RELEASE_REVISION = $global:OciPublishTestState.fixture.Revision
    $env:IMAGE_REPOSITORY = 'registry.example.test/geekle/docs'
    $env:REGISTRY_USERNAME = 'unit-test-user'
    $env:SKOPEO_IMAGE = 'quay.io/skopeo/stable:latest'
    $env:RUNNER_TEMP = $testDirectory
    $env:GITHUB_STEP_SUMMARY = Join-Path $testDirectory 'summary.md'

    Invoke-Case 'Top-level serialization normalization returns destination identity'
    Invoke-Case 'Unchanged digest remains compatible' -Mode unchanged
    Invoke-Case 'Recognized top-level media type conversion' -Mutate { param($index) $index.mediaType = 'application/vnd.docker.distribution.manifest.list.v2+json' }
    Invoke-Case 'Derived zstd descriptor hint preserves child identities' -Mutate { param($index) $index.manifests[0].annotations = @{ 'io.github.containers.compression.zstd' = 'true' } }
    Invoke-Case 'Invalid zstd hint fails' -Mutate { param($index) $index.manifests[0].annotations = @{ 'io.github.containers.compression.zstd' = 'false' } } -ExpectedError 'Invalid Skopeo zstd compression hint'
    Invoke-Case 'Unrelated descriptor annotation fails' -Mutate { param($index) $index.manifests[0].annotations = @{ 'unexpected.annotation' = 'true' } } -ExpectedError 'index.manifests[0]'
    Invoke-Case 'Attestation cannot claim zstd without a zstd layer' -Mutate { param($index) $index.manifests[2].annotations['io.github.containers.compression.zstd'] = 'true' } -ExpectedError 'not supported by the unchanged child manifest'
    Invoke-Case 'Missing platform fails' -Mutate { param($index) $index.manifests = @($index.manifests[0]) } -ExpectedError 'manifest/platform list must remain complete'
    Invoke-Case 'Changed platform fails' -Mutate { param($index) $index.manifests[0].platform.architecture = '386' } -ExpectedError 'platform.architecture'
    Invoke-Case 'Changed version fails' -Mutate { param($index) $index.annotations['org.opencontainers.image.version'] = '9.9.9' } -ExpectedError 'org.opencontainers.image.version'
    Invoke-Case 'Changed revision fails' -Mutate { param($index) $index.annotations['org.opencontainers.image.revision'] = 'f' * 40 } -ExpectedError 'org.opencontainers.image.revision'
    Invoke-Case 'Timestamp annotations remain literal strings' -Mutate { param($index) $index.annotations['org.opencontainers.image.created'] = '2026-10-01T14:00:00+02:00' } -ExpectedError 'org.opencontainers.image.created'
    Invoke-Case 'Duplicate JSON fields fail' -Mode duplicate-json -ExpectedError 'duplicate property'
    Invoke-Case 'Substituted child digest fails' -Mutate { param($index) $index.manifests[0].digest = 'sha256:' + ('f' * 64) } -ExpectedError 'manifests[0].digest'
    Invoke-Case 'Missing attestation fails' -Mutate { param($index) $index.manifests = @($index.manifests[0], $index.manifests[1]) } -ExpectedError 'manifest/platform list must remain complete'
    Invoke-Case 'Unknown media type fails' -Mutate { param($index) $index.mediaType = 'application/json' } -ExpectedError 'destination OCI index or Docker manifest list'
    Invoke-Case 'Source digest must match prior verification' -Mode wrong-source -ExpectedError 'Content digest mismatch'
    Assert-True ($global:OciPublishTestState.calls.Count -eq 1) 'Source mismatch must fail before publication.'
    Invoke-Case 'Missing credentials fail clearly' -Mode missing-credentials -ExpectedError 'Registry credentials are missing'
    Assert-True ($global:OciPublishTestState.calls.Count -eq 0) 'Missing credentials must fail before any Skopeo call.'
    Invoke-Case 'Invalid credentials preserve registry context' -Mode access-failure -ExpectedError 'unauthorized: authentication required'
    Invoke-Case 'Media failure preserves upstream context and exit status' -Mode media-failure -ExpectedError 'exit code 17'
    $log = Get-Content (Join-Path $testDirectory 'case.log') -Raw
    Assert-True ($log.Contains('Manifest list must be converted')) 'Skopeo error context was lost.'
    Assert-True (-not $log.Contains('check registry credentials')) 'Media conversion must not be diagnosed as authentication failure.'
    Invoke-Case 'Missing destination digest fails' -Mode missing-digest -ExpectedError 'did not produce a registry manifest digest'
    Invoke-Case 'Invalid destination digest fails' -Mode invalid-digest -ExpectedError 'invalid destination registry SHA-256 digest'
    Invoke-Case 'Unreadable registry image fails' -Mode read-failure -ExpectedError 'manifest unknown'
    Invoke-Case 'Corrupt child content fails' -Mode corrupt-child -ExpectedError 'Content digest mismatch'
    Invoke-Case 'Corrupt config content fails' -Mode corrupt-config -ExpectedError 'Content digest mismatch'
    Assert-True ((Get-FileHash $global:OciPublishTestState.fixture.Archive).Hash -eq $archiveHash) 'Promotion changed the persisted archive.'

    $global:OciPublishTestState.fixture = New-OciFixture (Join-Path $testDirectory 'gzip fixture') -UseZstd $false
    $env:ARCHIVE_PATH = $global:OciPublishTestState.fixture.Archive
    Invoke-Case 'Gzip content cannot claim zstd compression' -Mutate { param($index) $index.manifests[0].annotations = @{ 'io.github.containers.compression.zstd' = 'true' } } -ExpectedError 'not supported by the unchanged child manifest'

    $action = Get-Content "$PSScriptRoot/../action.yml" -Raw
    Assert-True ($action.IndexOf('uses: codebeltnet/oci-artifact-verify@v1') -lt $action.IndexOf('- id: publish')) 'Source verification must precede publication.'
    foreach ($inputName in @('archive-path', 'checksum-path', 'version', 'revision')) {
        Assert-True ($action.Contains("${inputName}: `${{ inputs.$inputName }}")) "Verifier must receive $inputName."
    }
    Assert-True ($action.Contains('SOURCE_DIGEST: ${{ steps.verify.outputs.digest }}')) 'Verifier digest must anchor source identity.'
    Assert-True (-not $action.Contains('EXPECTED_DIGEST')) 'Source digest must not be treated as destination identity.'
    Write-Host "$script:passed promotion regression cases and action contract checks passed."
} finally {
    Remove-Item Function:docker
    Remove-Variable OciPublishTestState -Scope Global
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
