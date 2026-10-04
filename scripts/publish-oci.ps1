$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/verify-promotion.ps1"

$archivePath = [System.IO.Path]::GetFullPath($env:ARCHIVE_PATH)
$releaseVersion = $env:RELEASE_VERSION
$imageRepository = $env:IMAGE_REPOSITORY
$registryUsername = $env:REGISTRY_USERNAME
$registryPassword = $env:REGISTRY_PASSWORD
$sourceDigest = $env:SOURCE_DIGEST
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
if ($sourceDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
    throw "The validated source OCI image digest is invalid: $sourceDigest"
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
$runnerTemp = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
} else {
    [System.IO.Path]::GetTempPath()
}
$handoffDirectory = Join-Path $runnerTemp ("oci-publish-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $handoffDirectory | Out-Null
$authPath = Join-Path $handoffDirectory 'auth.json'
$digestPath = Join-Path $handoffDirectory 'published-digest.txt'
$sourceManifestPath = Join-Path $handoffDirectory 'source-manifest.json'
$registryManifestPath = Join-Path $handoffDirectory 'registry-manifest.json'

function Invoke-Skopeo {
    param([string[]] $Arguments, [string] $Operation, [string] $OutputName = '')

    # Redirect raw bytes inside the container; PowerShell text redirection can change manifest digests.
    $script = 'if [ -n "$SKOPEO_OUTPUT" ]; then exec skopeo "$@" > "$SKOPEO_OUTPUT"; else exec skopeo "$@"; fi'
    $outputPath = if ($OutputName) { "/handoff/$OutputName" } else { '' }
    $dockerArguments = @(
        'run', '--rm', '--env', "SKOPEO_OUTPUT=$outputPath",
        '--mount', "type=bind,source=$artifactMount,target=/artifact,readonly",
        '--mount', "type=bind,source=$handoffMount,target=/auth,readonly",
        '--mount', "type=bind,source=$handoffMount,target=/handoff",
        '--entrypoint', '/bin/sh', $skopeoImage, '-ec', $script, 'skopeo'
    ) + $Arguments
    $upstream = @(& docker @dockerArguments 2>&1)
    $exitCode = $LASTEXITCODE
    $context = ($upstream | ForEach-Object { "$_" }) -join [System.Environment]::NewLine
    # Keep upstream diagnostics without exposing auth material, including outside GitHub's secret masking.
    foreach ($secret in @($registryPassword, $registryUsername, $auth.auths[$registryHost].auth)) {
        if ($secret) { $context = $context.Replace($secret, '***') }
    }
    if ($context) { Write-Host $context }
    if ($exitCode -ne 0) {
        $hint = if ($context -match 'preserve digests|preserve-digests|[Mm]anifest list must be converted|[Mm]anifest.*[Mm][Ii][Mm][Ee]|[Mm]anifest.*[Mm]edia.?type') {
            'The registry rejected the manifest representation. Promotion permits top-level normalization; check registry media-type support and the selected Skopeo version.'
        } elseif ($context -match '(?i)unauthorized|authentication required|denied|forbidden|invalid.*credential') {
            'The registry rejected access; check the deployment credentials and repository permissions.'
        } else {
            'Review the upstream Docker/Skopeo error below and check registry compatibility or availability.'
        }
        throw "$Operation failed (Docker/Skopeo exit code $exitCode). $hint$([System.Environment]::NewLine)$context"
    }
}

try {
    $registryHost = ($imageRepository -split '/', 2)[0]
    $credentialText = '{0}:{1}' -f $registryUsername, $registryPassword
    $auth = @{
        auths = @{
            $registryHost = @{
                auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($credentialText))
            }
        }
    }
    [System.IO.File]::WriteAllText($authPath, ($auth | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))

    $artifactMount = [System.IO.Path]::GetFullPath($archiveDirectory).Replace('\', '/')
    $handoffMount = [System.IO.Path]::GetFullPath($handoffDirectory).Replace('\', '/')
    $taggedImage = '{0}:{1}' -f $imageRepository, $releaseVersion
    $sourceImage = 'oci-archive:/artifact/{0}:{1}' -f $archiveName, $releaseVersion

    # Anchor the source snapshot to the digest returned by oci-artifact-verify, before publishing.
    Invoke-Skopeo -Arguments @('inspect', '--raw', $sourceImage) -OutputName 'source-manifest.json' -Operation 'Reading the verified source index'
    Assert-ContentDigest $sourceManifestPath $sourceDigest

    # The immutable archive is mounted read-only. Allow the registry's index representation to normalize.
    Invoke-Skopeo -Arguments @('copy', '--all', '--authfile', '/auth/auth.json', '--digestfile', '/handoff/published-digest.txt', $sourceImage, "docker://$taggedImage") -Operation "Publishing '$taggedImage'"

    if (-not (Test-Path -LiteralPath $digestPath -PathType Leaf)) {
        throw 'Skopeo did not produce a registry manifest digest.'
    }
    $publishedDigest = (Get-Content -LiteralPath $digestPath -Raw).Trim()
    if ($publishedDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "Skopeo returned an invalid destination registry SHA-256 digest: $publishedDigest"
    }
    $registryImageByDigest = '{0}@{1}' -f $imageRepository, $publishedDigest
    Invoke-Skopeo -Arguments @('inspect', '--raw', '--authfile', '/auth/auth.json', "docker://$registryImageByDigest") -OutputName 'registry-manifest.json' -Operation "Reading immutable registry reference '$registryImageByDigest'"
    Assert-ContentDigest $registryManifestPath $publishedDigest
    $registryIndex = Assert-PromotedIndex $sourceManifestPath $registryManifestPath

    # Exact child bytes prove unchanged config/layer references, platform identity, and attestation relationships.
    foreach ($manifest in $registryIndex.manifests) {
        $childReference = 'docker://{0}@{1}' -f $imageRepository, $manifest.digest
        $childPath = Join-Path $handoffDirectory 'child-manifest.json'
        Invoke-Skopeo -Arguments @('inspect', '--raw', '--authfile', '/auth/auth.json', $childReference) -OutputName 'child-manifest.json' -Operation "Reading child manifest '$($manifest.digest)'"
        Assert-ContentDigest $childPath $manifest.digest $manifest.size
        $child = Read-OciJson $childPath
        Assert-CompressionHint $manifest $child

        if ($manifest.platform.os -ceq 'linux') {
            $configPath = Join-Path $handoffDirectory 'platform-config.json'
            Invoke-Skopeo -Arguments @('inspect', '--raw', '--config', '--authfile', '/auth/auth.json', $childReference) -OutputName 'platform-config.json' -Operation "Reading platform config for '$($manifest.digest)'"
            Assert-ContentDigest $configPath $child.config.digest $child.config.size
            $config = Read-OciJson $configPath
            if ($config.os -cne $manifest.platform.os -or $config.architecture -cne $manifest.platform.architecture) {
                throw "Registry config platform does not match the verified index for '$($manifest.digest)'."
            }
            $labels = $config.config.Labels
            foreach ($identity in @(@('org.opencontainers.image.version', $releaseVersion), @('org.opencontainers.image.revision', $env:RELEASE_REVISION))) {
                if ($null -ne $labels -and $labels.Contains($identity[0]) -and $labels[$identity[0]] -cne $identity[1]) {
                    throw "Registry config label '$($identity[0])' does not match the release identity."
                }
            }
        }
    }

    if (-not $env:GITHUB_OUTPUT) {
        throw 'GITHUB_OUTPUT is not available; registry publication must run from a GitHub Action.'
    }
    $outputEncoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "image=$taggedImage$([System.Environment]::NewLine)", $outputEncoding)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "digest=$publishedDigest$([System.Environment]::NewLine)", $outputEncoding)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "image-by-digest=$registryImageByDigest$([System.Environment]::NewLine)", $outputEncoding)

    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @"
### Publish OCI Artifact from Codebelt

- Registry tag: $taggedImage
- Verified source OCI index digest: $sourceDigest
- Immutable registry digest: $publishedDigest
- Immutable image reference: $registryImageByDigest
"@
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary + [System.Environment]::NewLine, $outputEncoding)
    }

    Write-Host "Published $taggedImage at verified immutable registry digest $publishedDigest (source index $sourceDigest)."
} finally {
    Remove-Item -LiteralPath $handoffDirectory -Recurse -Force
}
