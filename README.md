# buildkite-release-plugins

Buildkite subdirectory plugins for shipping CLI releases with per-artifact checksums, SPDX SBOMs, keyless SLSA v1 provenance via Sigstore, immutable GitHub Releases, and validated Homebrew tap updates.

Requires Buildkite Agent `v3.108.0` or later for subdirectory plugin support. Always pin plugins by full 40-character commit SHA in consumer pipelines.

## Plugins

- `goreleaser-build`: fetches `BUILDKITE_TAG`, runs `goreleaser release --clean --skip=publish`, uploads configured `artifacts`, and uploads `darwin-artifacts` only on macOS agents.
- `slsa-attest`: validates semver and `main` ancestry, downloads and checksums archives and SBOMs, signs keyless SLSA v1 provenance bundles (`<archive>.sigstore.json`) via Cosign and Buildkite OIDC, and uploads the bundles as Buildkite artifacts. Does not fetch the GitHub token.
- `github-immutable-release`: re-verifies semver, `main` ancestry, existing-release guard, archive/SBOM checksums, and `.sigstore.json` bundles, then creates the GitHub release atomically in one `gh release create` call (`--prerelease` for `-` tags).
- `homebrew-tap`: validates a macOS Homebrew formula (`depends_on :macos`, tag URL, darwin SHA-256) against Buildkite artifacts. Supports `verify-only: true` (for pre-publish gating) and `skip-prerelease: true` (default, validates on `-rc.N` tags without pushing to the tap).

## Example pipeline

Run these from a dedicated tag-only Buildkite release pipeline (`.buildkite/pipeline.release.yml`) so the pipeline's OIDC identity and GitHub token cluster secret are never exposed to branch or pull request builds:

```yaml
steps:
  - label: ":goreleaser: release build {{matrix}}"
    key: release_build
    agents:
      queue: "{{matrix}}"
    matrix:
      - macos-medium
      - linux-small
      - linux-arm64-small
    plugins:
      - https://github.com/wolfeidau/buildkite-release-plugins.git/goreleaser-build#<commit-sha>:
          artifacts:
            - "dist/myapp_*.tar.gz*"
          darwin-artifacts:
            - dist/homebrew/Formula/myapp.rb

  - label: ":lock: attest provenance"
    key: slsa_attest
    depends_on: release_build
    agents:
      queue: linux-small
    plugins:
      - https://github.com/wolfeidau/buildkite-release-plugins.git/slsa-attest#<commit-sha>:
          repo: owner/myapp
          project: myapp
          targets:
            - darwin_arm64
            - linux_amd64
            - linux_arm64

  - label: ":beer: verify homebrew formula"
    key: verify_homebrew_formula
    depends_on: release_build
    agents:
      queue: linux-small
    plugins:
      - https://github.com/wolfeidau/buildkite-release-plugins.git/homebrew-tap#<commit-sha>:
          artifact-path: dist/homebrew/Formula/myapp.rb
          archive: myapp_darwin_arm64.tar.gz
          checksum-artifact: dist/myapp_darwin_arm64.tar.gz.sha256
          verify-only: true

  - label: ":github: publish release"
    key: publish_release
    depends_on:
      - slsa_attest
      - verify_homebrew_formula
    agents:
      queue: linux-small
    plugins:
      - https://github.com/wolfeidau/buildkite-release-plugins.git/github-immutable-release#<commit-sha>:
          repo: owner/myapp
          project: myapp
          targets:
            - darwin_arm64
            - linux_amd64
            - linux_arm64
          github-token-secret: MYAPP_GITHUB_TOKEN

  - label: ":beer: update homebrew tap"
    key: update_homebrew_tap
    depends_on: publish_release
    agents:
      queue: linux-small
    plugins:
      - https://github.com/wolfeidau/buildkite-release-plugins.git/homebrew-tap#<commit-sha>:
          tap: owner/homebrew-tap
          formula-path: Formula/myapp.rb
          artifact-path: dist/homebrew/Formula/myapp.rb
          archive: myapp_darwin_arm64.tar.gz
          checksum-artifact: dist/myapp_darwin_arm64.tar.gz.sha256
          github-token-secret: MYAPP_GITHUB_TOKEN
          skip-prerelease: true
```

## Development

```sh
mise install
lefthook install
mise run check:lint
mise run test
```

## Security

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
