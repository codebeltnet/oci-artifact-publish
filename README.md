# Publish OCI Artifact from Codebelt

Validates and promotes a previously built OCI archive to a container registry without rebuilding it. Promotion uses Skopeo's all-platform copy, allows registry-compatible top-level index normalization, and verifies the resulting immutable registry identity against the source artifact.

> This action is part of the Codebelt umbrella and ensures a consistent way of:
>
> - Defining your CI/CD pipeline
> - Structuring your repository
> - Keeping your codebase small and feasible
> - Writing clean and maintainable code
> - Deploying your code to different environments
> - Automating as much as possible
>
> A paved path to excel as a DevSecOps Engineer.

## Usage

To use this action in your GitHub repository, you can follow these steps:

```yaml
uses: codebeltnet/oci-artifact-publish@v1
```

### Inputs

```yaml
with:
  # Path to the OCI image archive.
  archive-path:
  # Path to the detached SHA-256 checksum file.
  checksum-path:
  # Human-selected SemVer release version without the v prefix.
  version:
  # Full 40-character commit SHA represented by the image.
  revision:
  # Registry and repository name, without a scheme or tag.
  repository:
  # Registry username.
  username:
  # Registry password.
  password:
  # Skopeo container image used for OS-independent registry promotion.
  skopeo-image: quay.io/skopeo/stable:latest
```

### Outputs

```yaml
outputs:
  # Human-readable version-tagged image reference.
  image:
  # Actual immutable destination registry SHA-256 digest.
  digest:
  # Immutable registry image reference suitable for Kubernetes deployment.
  image-by-digest:
```

This action invokes `codebeltnet/oci-artifact-verify@v1` before promotion, so the caller must make the .NET 10 SDK or newer available before invoking it. Verification runs before registry promotion and fails immediately with an explicit diagnostic when the SDK is missing. The action then uses the official Skopeo Linux container image to preserve multi-platform content. PowerShell 7 and a Docker Engine capable of running Linux containers must be available on the host; Windows hosts must use Linux container mode. The deployment caller supplies protected registry credentials and the durable OCI archive.

### Artifact and deployment identity

The archive and its detached SHA-256 checksum remain the immutable release evidence. The verifier checks that checksum, the embedded OCI index digest, version/revision annotations, and required `linux/amd64` and `linux/arm64` platforms before any publication. The archive is mounted read-only during promotion.

`skopeo copy --all` promotes the existing archive without `--preserve-digests`. A registry such as JFrog/JCR can require index conversion or reserialization, even when the source and destination are both OCI indexes. Skopeo also adds a descriptor compression hint when it discovers existing zstd layers, which reproduces the Cuemon failure. These index changes can change the top-level digest without changing the images. Skopeo's `--digestfile` supplies the actual destination digest, which is used for readback and the `digest` and `image-by-digest` outputs. Existing inputs and output names are unchanged.

Verification reads the destination index by its immutable digest and hashes its raw bytes. Its parsed JSON must match the source index anchored to the verifier's digest, allowing a recognized top-level OCI-index/Docker-manifest-list media type change and JSON formatting/property-order changes. The only allowed descriptor annotation addition is Skopeo's `io.github.containers.compression.zstd=true`, and the unchanged child manifest must prove it contains a zstd layer. Every platform, existing annotation, child digest, size, and remaining descriptor field must remain identical, including attestation relationships. Each child manifest is read by digest and its bytes and size verified. Linux platform configs are also read and hashed against those unchanged manifests; their OS/architecture and version/revision labels, when present, must match the release identity. Identical child manifest bytes prove unchanged config and layer content references without rebuilding. Verification does not redownload all layer payloads; Skopeo performs the all-platform blob copy.

Registries that rewrite child manifests, recompress layers, remove annotations/attestations, or otherwise alter the verified content are rejected. The action currently supports top-level normalization only. Publication/readback failures retain upstream Docker/Skopeo context and return a non-zero exit status; outputs are written only after verification. Temporary auth material is removed on success and failure, and cleanup errors also fail the action.

## Examples

### Publish a verified OCI artifact to a registry

```yaml
- name: Publish OCI artifact
  uses: codebeltnet/oci-artifact-publish@v1
  with:
    archive-path: ${{ needs.build-docfx.outputs.archive-path }}
    checksum-path: ${{ needs.build-docfx.outputs.checksum-path }}
    version: ${{ needs.build.outputs.version }}
    revision: ${{ github.sha }}
    repository: ghcr.io/${{ github.repository_owner }}/docs
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

### Publish with a pinned Skopeo container image

```yaml
- name: Publish OCI artifact
  uses: codebeltnet/oci-artifact-publish@v1
  with:
    archive-path: ${{ needs.build-docfx.outputs.archive-path }}
    checksum-path: ${{ needs.build-docfx.outputs.checksum-path }}
    version: ${{ needs.build.outputs.version }}
    revision: ${{ github.sha }}
    repository: ghcr.io/${{ github.repository_owner }}/docs
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
    skopeo-image: quay.io/skopeo/stable:v1.16.1
```

## Contributing to Publish OCI Artifact from Codebelt

Contributions are welcome! Feel free to submit issues, feature requests, or pull requests to help improve this action.

Run the dependency-free PowerShell regression tests with:

```powershell
pwsh -NoProfile -File tests/Test-PublishOci.ps1
```

Run the integration test with PowerShell 7, .NET 10 or newer, and Docker in Linux container mode:

```powershell
pwsh -NoProfile -File tests/Test-RegistryPromotion.ps1
```

The integration test generates a four-manifest OCI archive with existing zstd layers, runs the actual `oci-artifact-verify@v1` verifier (downloaded from its public repository, or supplied with `-VerifierPath`), and promotes to an isolated authenticated local registry. Skopeo's real compression-hint normalization reproduces the original failure with digest preservation enabled; removing preservation allows promotion with a different destination digest and identical child/config contents. It also exercises real authentication rejection and checks archive/checksum immutability and auth cleanup. It does not simulate JFrog's server implementation. `-ArchivePath`, `-ChecksumPath`, `-Version`, and `-Revision` can instead select an existing release artifact for the same local test; the supplied files are read-only.

## License

This project is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.

> [!TIP]
> To learn more about the Codebelt experience and offerings, visit our [organization page](https://github.com/codebeltnet) on GitHub.
