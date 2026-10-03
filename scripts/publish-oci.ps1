$ErrorActionPreference = 'Stop'

$archivePath = [System.IO.Path]::GetFullPath($env:ARCHIVE_PATH)
$releaseVersion = $env:RELEASE_VERSION
$imageRepository = $env:IMAGE_REPOSITORY
$registryUsername = $env:REGISTRY_USERNAME
$registryPassword = $env:REGISTRY_PASSWORD
$expectedDigest = $env:EXPECTED_DIGEST
$skopeoImage = $env:SKOPEO_IMAGE

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "OCI archive was not found: $archivePath"
}
if ($imageRepository -notmatch '^[A-Za-z0-9.-]+(?::[0-9]+)?(?:/[A-Za-z0-9._-]+)+$') {
    throw "Registry repository '$imageRepository' must be a registry/repository path without a scheme or tag."
}
if ([string]::IsNullOrWhiteSpace($registryUsername) -or [string]::IsNullOrWhiteSpace($registryPassword)) {
    throw 'Registry credentials are missing; configure the protected deployment secrets.'
}
if ($expectedDigest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
    throw "The validated OCI image digest is invalid: $expectedDigest"
}
if ([string]::IsNullOrWhiteSpace($skopeoImage)) {
    throw 'A Skopeo container image is required.'
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI is required to promote an OCI archive on Linux, Windows, or macOS.'
}

$dockerVersion = & docker version --format '{{.Server.Version}}'
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($dockerVersion -join '').Trim())) {
    throw 'Docker is not connected to a running container engine.'
}

$archiveDirectory = Split-Path -Parent $archivePath
$archiveName = Split-Path -Leaf $archivePath
$env:ARCHIVE_NAME = $archiveName
$runnerTemp = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
} else {
    [System.IO.Path]::GetTempPath()
}
$handoffDirectory = Join-Path $runnerTemp ("oci-publish-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $handoffDirectory | Out-Null
$authPath = Join-Path $handoffDirectory 'auth.json'
$digestPath = Join-Path $handoffDirectory 'published-digest.txt'
$registryManifestPath = Join-Path $handoffDirectory 'registry-manifest.json'

try {
    $registryHost = ($imageRepository -split '/', 2)[0]
    $credentialText = '{0}:{1}' -f $registryUsername, $registryPassword
    $auth = @{
        auths = @{
            $registryHost = @{
                auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($credentialText))
            }
        }
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($authPath, $auth, [System.Text.UTF8Encoding]::new($false))

    $artifactMount = [System.IO.Path]::GetFullPath($archiveDirectory).Replace('\', '/')
    $handoffMount = [System.IO.Path]::GetFullPath($handoffDirectory).Replace('\', '/')
    $authMount = [System.IO.Path]::GetFullPath($handoffDirectory).Replace('\', '/')
    $taggedImage = '{0}:{1}' -f $imageRepository, $releaseVersion
    $registryImageByDigest = '{0}@{1}' -f $imageRepository, $expectedDigest

    $copyScript = @'
set -eu
skopeo copy --all --preserve-digests --authfile /auth/auth.json --digestfile /handoff/published-digest.txt "oci-archive:/artifact/$ARCHIVE_NAME:$RELEASE_VERSION" "docker://$IMAGE_REPOSITORY:$RELEASE_VERSION"
'@
    $copyArguments = @(
        'run', '--rm',
        '--env', 'ARCHIVE_NAME',
        '--env', 'RELEASE_VERSION',
        '--env', 'IMAGE_REPOSITORY',
        '--mount', "type=bind,source=$artifactMount,target=/artifact,readonly",
        '--mount', "type=bind,source=$authMount,target=/auth,readonly",
        '--mount', "type=bind,source=$handoffMount,target=/handoff",
        '--entrypoint', '/bin/sh',
        $skopeoImage,
        '-ec', $copyScript
    )
    & docker @copyArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Skopeo failed to publish '$taggedImage'; check registry credentials, permissions, and registry availability."
    }

    if (-not (Test-Path -LiteralPath $digestPath -PathType Leaf)) {
        throw 'Skopeo did not produce a registry manifest digest.'
    }
    $publishedDigest = (Get-Content -LiteralPath $digestPath -Raw).Trim()
    if ($publishedDigest -ne $expectedDigest) {
        throw "Registry digest mismatch: expected $expectedDigest, published $publishedDigest."
    }

    $inspectScript = @'
set -eu
skopeo inspect --raw --authfile /auth/auth.json "docker://$IMAGE_REPOSITORY@$EXPECTED_DIGEST" > /handoff/registry-manifest.json
'@
    $inspectArguments = @(
        'run', '--rm',
        '--env', 'IMAGE_REPOSITORY',
        '--env', 'EXPECTED_DIGEST',
        '--mount', "type=bind,source=$authMount,target=/auth,readonly",
        '--mount', "type=bind,source=$handoffMount,target=/handoff",
        '--entrypoint', '/bin/sh',
        $skopeoImage,
        '-ec', $inspectScript
    )
    & docker @inspectArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Skopeo could not read back immutable registry reference '$registryImageByDigest'."
    }
    if (-not (Test-Path -LiteralPath $registryManifestPath -PathType Leaf)) {
        throw 'Skopeo did not return the published registry manifest.'
    }
    $remoteDigest = 'sha256:' + (Get-FileHash -LiteralPath $registryManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($remoteDigest -ne $expectedDigest) {
        throw "The registry returned manifest digest $remoteDigest, expected $expectedDigest."
    }

    if (-not $env:GITHUB_OUTPUT) {
        throw 'GITHUB_OUTPUT is not available; registry publication must run from a GitHub Action.'
    }
    $outputEncoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "image=$taggedImage$([System.Environment]::NewLine)", $outputEncoding)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "digest=$expectedDigest$([System.Environment]::NewLine)", $outputEncoding)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "image-by-digest=$registryImageByDigest$([System.Environment]::NewLine)", $outputEncoding)

    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @"
### Publish OCI Artifact from Codebelt

- Registry tag: $taggedImage
- Immutable registry digest: $expectedDigest
- Immutable image reference: $registryImageByDigest
"@
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary + [System.Environment]::NewLine, $outputEncoding)
    }

    Write-Host "Published $taggedImage at immutable digest $expectedDigest."
} finally {
    Remove-Item -LiteralPath $handoffDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
