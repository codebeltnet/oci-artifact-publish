# Publish OCI Artifact from Codebelt

Validates and promotes a previously built OCI archive to a container registry without rebuilding it. Promotion uses Skopeo's all-platform copy and digest-preservation options, then reads the registry manifest back by digest and confirms the bytes match.

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
  # Immutable SHA-256 digest confirmed at the registry.
  digest:
  # Immutable registry image reference suitable for Kubernetes deployment.
  image-by-digest:
```

This action invokes `codebeltnet/oci-artifact-verify@v1` before promotion, so the caller must make the .NET 10 SDK or newer available before invoking it. Verification runs before registry promotion and fails immediately with an explicit diagnostic when the SDK is missing. The action then uses the official Skopeo Linux container image to preserve multi-platform content and immutable digests. PowerShell 7 and a Docker Engine capable of running Linux containers must be available on the host; Windows hosts must use Linux container mode. The deployment caller supplies protected registry credentials and the durable OCI archive.

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

## License

This project is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.

> [!TIP]
> To learn more about the Codebelt experience and offerings, visit our [organization page](https://github.com/codebeltnet) on GitHub.
