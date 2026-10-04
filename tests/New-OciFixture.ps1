function New-OciFixture {
    param([string] $Directory, [bool] $UseZstd = $true)

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $version = '1.2.3'
    $revision = '0123456789abcdef0123456789abcdef01234567'
    $encoding = [Text.UTF8Encoding]::new($false)
    $blobs = @{}
    function Add-Blob([string] $Text, [string] $MediaType) {
        $bytes = $encoding.GetBytes($Text)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $blobs["blobs/sha256/$hash"] = $bytes
        return [ordered]@{ mediaType = $MediaType; digest = "sha256:$hash"; size = $bytes.Length }
    }

    # A real compressed empty tar layer, shared by two runnable platform manifests.
    $layerBytes = [byte[]]::new(1024)
    $diffId = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($layerBytes)).ToLowerInvariant()
    if ($UseZstd) {
        # Skopeo-generated zstd encoding of 1024 zero bytes (an empty tar); no zstd runtime dependency.
        $compressedBytes = [Convert]::FromBase64String('KLUv/UQIAAMDIAAAzayF8A==')
        $layerMediaType = 'application/vnd.oci.image.layer.v1.tar+zstd'
    } else {
        $compressed = [IO.MemoryStream]::new()
        $gzip = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionLevel]::Optimal, $true)
        $gzip.Write($layerBytes)
        $gzip.Dispose()
        $compressedBytes = $compressed.ToArray()
        $compressed.Dispose()
        $layerMediaType = 'application/vnd.oci.image.layer.v1.tar+gzip'
    }
    $layerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($compressedBytes)).ToLowerInvariant()
    $blobs["blobs/sha256/$layerHash"] = $compressedBytes
    $layer = [ordered]@{ mediaType = $layerMediaType; digest = "sha256:$layerHash"; size = $compressedBytes.Length }

    $manifests = @()
    $configs = @{}
    foreach ($architecture in @('amd64', 'arm64')) {
        $config = [ordered]@{
            architecture = $architecture; os = 'linux'
            config = @{ Labels = @{ 'org.opencontainers.image.version' = $version; 'org.opencontainers.image.revision' = $revision } }
            rootfs = @{ type = 'layers'; diff_ids = @($diffId) }
        }
        $configDescriptor = Add-Blob ($config | ConvertTo-Json -Depth 20 -Compress) 'application/vnd.oci.image.config.v1+json'
        $child = [ordered]@{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.manifest.v1+json'; config = $configDescriptor; layers = @($layer) }
        $descriptor = Add-Blob ($child | ConvertTo-Json -Depth 20 -Compress) $child.mediaType
        $configs[$descriptor.digest] = $configDescriptor.digest
        $descriptor.platform = @{ architecture = $architecture; os = 'linux' }
        $manifests += $descriptor
    }
    # Include non-runnable attestation manifests; --all and verification must retain them too.
    foreach ($platformManifest in @($manifests)) {
        $configDescriptor = Add-Blob '{}' 'application/vnd.oci.image.config.v1+json'
        $attestationLayer = Add-Blob ('{"subject":"' + $platformManifest.digest + '"}') 'application/vnd.in-toto+json'
        $child = [ordered]@{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.manifest.v1+json'; config = $configDescriptor; layers = @($attestationLayer) }
        $descriptor = Add-Blob ($child | ConvertTo-Json -Depth 20 -Compress) $child.mediaType
        $descriptor.platform = @{ architecture = 'unknown'; os = 'unknown' }
        $descriptor.annotations = @{ 'vnd.docker.reference.digest' = $platformManifest.digest; 'vnd.docker.reference.type' = 'attestation-manifest' }
        $manifests += $descriptor
    }
    $index = [ordered]@{
        schemaVersion = 2; mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = $manifests
        annotations = @{ 'org.opencontainers.image.version' = $version; 'org.opencontainers.image.revision' = $revision; 'org.opencontainers.image.created' = '2026-10-01T12:00:00Z' }
    }
    $sourceText = $index | ConvertTo-Json -Depth 30
    $sourceDescriptor = Add-Blob $sourceText $index.mediaType
    $sourceDescriptor.annotations = @{ 'org.opencontainers.image.ref.name' = $version }
    $root = @{ schemaVersion = 2; mediaType = $index.mediaType; manifests = @($sourceDescriptor) }
    $blobs['index.json'] = $encoding.GetBytes(($root | ConvertTo-Json -Depth 30 -Compress))
    $blobs['oci-layout'] = $encoding.GetBytes('{"imageLayoutVersion":"1.0.0"}')
    $archivePath = Join-Path $Directory 'release.oci.tar'
    $stream = [IO.File]::Create($archivePath)
    $writer = [System.Formats.Tar.TarWriter]::new($stream)
    try {
        foreach ($name in $blobs.Keys) {
            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $name)
            $entry.DataStream = [IO.MemoryStream]::new([byte[]] $blobs[$name])
            try { $writer.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    } finally { $writer.Dispose(); $stream.Dispose() }
    $checksumPath = "$archivePath.sha256"
    [IO.File]::WriteAllText($checksumPath, ((Get-FileHash $archivePath).Hash.ToLowerInvariant() + '  release.oci.tar'), $encoding)
    $sourcePath = Join-Path $Directory 'source.json'
    [IO.File]::WriteAllText($sourcePath, $sourceText, $encoding)
    return @{ Archive = $archivePath; Checksum = $checksumPath; SourcePath = $sourcePath; SourceDigest = $sourceDescriptor.digest; Index = $index; Blobs = $blobs; Configs = $configs; Version = $version; Revision = $revision }
}
