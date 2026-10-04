# Keep annotation strings literal (including ISO timestamps) and reject ambiguous duplicate keys.
function ConvertFrom-OciJsonElement {
    param([System.Text.Json.JsonElement] $Element)

    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $result = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if ($result.Contains($property.Name)) { throw "OCI JSON contains duplicate property '$($property.Name)'." }
                $result.Add($property.Name, (ConvertFrom-OciJsonElement $property.Value))
            }
            return $result
        }
        'Array' {
            $result = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $result.Add((ConvertFrom-OciJsonElement $item)) }
            return ,$result.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            [long] $integer = 0
            if ($Element.TryGetInt64([ref] $integer)) { return $integer }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'Unsupported OCI JSON value.' }
    }
}

function Read-OciJson {
    param([string] $Path)

    $document = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($Path))
    try { return ConvertFrom-OciJsonElement $document.RootElement }
    finally { $document.Dispose() }
}

# Compare parsed JSON without ignoring descriptor, platform, annotation, or content changes.
function Assert-JsonIdentity {
    param($Source, $Destination, [string] $Path = 'index')

    if ($Source -is [System.Collections.IDictionary]) {
        if ($Destination -isnot [System.Collections.IDictionary] -or $Source.Count -ne $Destination.Count) {
            throw "Promoted OCI identity differs at '$Path'; only top-level index representation normalization is supported."
        }
        foreach ($key in $Source.Keys) {
            if (-not $Destination.Contains($key)) {
                throw "Promoted OCI identity is missing '$Path.$key'."
            }
            Assert-JsonIdentity $Source[$key] $Destination[$key] "$Path.$key"
        }
    } elseif ($Source -is [array]) {
        if ($Destination -isnot [array] -or $Source.Count -ne $Destination.Count) {
            throw "Promoted OCI identity differs at '$Path'; the manifest/platform list must remain complete."
        }
        for ($i = 0; $i -lt $Source.Count; $i++) {
            Assert-JsonIdentity $Source[$i] $Destination[$i] "$Path[$i]"
        }
    } elseif ($null -eq $Source) {
        if ($null -ne $Destination) { throw "Promoted OCI identity differs at '$Path'." }
    } elseif ($null -eq $Destination -or $Source.GetType() -ne $Destination.GetType() -or $Source -cne $Destination) {
        throw "Promoted OCI identity differs at '$Path'."
    }
}

function Assert-ContentDigest {
    param([string] $Path, [string] $Digest, $Size = $null)

    if ($Digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "Invalid SHA-256 content digest: $Digest"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Skopeo did not return required content: $Path"
    }
    $actualDigest = 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualDigest -cne $Digest) {
        throw "Content digest mismatch for '$Path': expected $Digest, received $actualDigest."
    }
    if ($null -ne $Size -and (Get-Item -LiteralPath $Path).Length -ne $Size) {
        throw "Content size mismatch for '$Path': expected $Size bytes."
    }
}

function Assert-PromotedIndex {
    param([string] $SourcePath, [string] $DestinationPath)

    $source = Read-OciJson $SourcePath
    $destination = Read-OciJson $DestinationPath
    $comparison = Read-OciJson $DestinationPath
    $indexTypes = @('application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json')
    if ($source.schemaVersion -ne 2 -or $source.mediaType -cne $indexTypes[0] -or
        $destination.schemaVersion -ne 2 -or $indexTypes -cnotcontains $destination.mediaType) {
        throw 'Promotion requires a source OCI index and a destination OCI index or Docker manifest list.'
    }
    # Skopeo can add a descriptor compression hint for existing zstd layers. Require child proof below.
    $hint = 'io.github.containers.compression.zstd'
    for ($i = 0; $i -lt [Math]::Min($source.manifests.Count, $comparison.manifests.Count); $i++) {
        $original = $source.manifests[$i]
        $promoted = $comparison.manifests[$i]
        if ($promoted.annotations -is [System.Collections.IDictionary] -and $promoted.annotations.Contains($hint) -and
            ($null -eq $original.annotations -or -not $original.annotations.Contains($hint))) {
            if ($promoted.annotations[$hint] -cne 'true') {
                throw "Invalid Skopeo zstd compression hint for '$($promoted.digest)'."
            }
            $promoted.annotations.Remove($hint)
            if ($promoted.annotations.Count -eq 0) {
                if (-not $original.Contains('annotations')) { $promoted.Remove('annotations') }
                elseif ($null -eq $original.annotations) { $promoted.annotations = $null }
            }
        }
    }
    # Apart from the proven compression hint, only recognized top-level media type/JSON formatting may change.
    $source.mediaType = $destination.mediaType
    Assert-JsonIdentity $source $comparison
    return $destination
}

function Assert-CompressionHint {
    param($Descriptor, $Child)

    $hint = 'io.github.containers.compression.zstd'
    if ($Descriptor.annotations -is [System.Collections.IDictionary] -and $Descriptor.annotations.Contains($hint)) {
        $zstdTypes = @('application/vnd.oci.image.layer.v1.tar+zstd', 'application/vnd.oci.image.layer.nondistributable.v1.tar+zstd')
        $zstdLayers = @($Child.layers | Where-Object { $zstdTypes -ccontains $_.mediaType })
        if ($Descriptor.annotations[$hint] -cne 'true' -or $zstdLayers.Count -eq 0) {
            throw "Skopeo zstd compression hint is not supported by the unchanged child manifest '$($Descriptor.digest)'."
        }
    }
}
