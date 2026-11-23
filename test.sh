#!/usr/bin/env bash
set -euo pipefail

plugins_dir="$(cd "$(dirname "$0")" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local want="$2"
  if ! grep -qF -- "${want}" "${file}"; then
    echo "expected ${file} to contain: ${want}" >&2
    cat "${file}" >&2
    fail "missing expected content"
  fi
}

assert_not_contains() {
  local file="$1"
  local unwanted="$2"
  if grep -qF -- "${unwanted}" "${file}"; then
    echo "expected ${file} NOT to contain: ${unwanted}" >&2
    cat "${file}" >&2
    fail "found unexpected content"
  fi
}

# Runs a command expected to fail, captures stderr, and checks required (and optional forbidden) output.
assert_fails_with() {
  local workdir="$1"
  local want="$2"
  local forbid="$3"
  shift 3
  local err_file="${tmp}/stderr.log"
  if (cd "${workdir}" && "$@" >/dev/null 2>"${err_file}"); then
    fail "expected failure containing '${want}', but command succeeded"
  fi
  assert_contains "${err_file}" "${want}"
  if [[ -n "${forbid}" ]]; then
    assert_not_contains "${err_file}" "${forbid}"
  fi
}

setup_stub_bin() {
  local dir="$1"
  mkdir -p "${dir}/bin" "${dir}/store" "${dir}/work"
  : >"${dir}/calls.log"

  cat >"${dir}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "git $*" >>"${STUB_DIR}/calls.log"
case "${1:-}" in
  fetch) exit 0 ;;
  rev-parse) echo "deadbeef0123456789abcdef0123456789abcdef" ;;
  merge-base)
    if [[ "${STUB_GIT_ON_MAIN:-true}" == "true" ]]; then
      exit 0
    fi
    exit 1
    ;;
  *) exit 0 ;;
esac
EOF

  cat >"${dir}/bin/goreleaser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "goreleaser tag=${GORELEASER_CURRENT_TAG:-} $*" >>"${STUB_DIR}/calls.log"
EOF

  cat >"${dir}/bin/buildkite-agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "buildkite-agent $*" >>"${STUB_DIR}/calls.log"
case "${1:-}:${2:-}" in
  artifact:upload)
    echo "upload:$3" >>"${STUB_DIR}/uploads.log"
    ;;
  artifact:download)
    rm -rf dist
    cp -R "${STUB_DIR}/store/." .
    ;;
  secret:get)
    if [[ "${STUB_SECRET_FAIL:-false}" == "true" ]]; then
      echo "secret-ref-leak-sentinel: lookup failed" >&2
      exit 1
    fi
    echo "super-secret-token-value"
    ;;
  *) exit 1 ;;
esac
EOF

  cat >"${dir}/bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN leaked to cosign" >&2
  exit 1
fi
echo "cosign pwd=$(pwd) $*" >>"${STUB_DIR}/calls.log"
bundle=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--bundle" ]]; then
    bundle="$2"
    shift 2
  else
    shift
  fi
done
echo '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}' >"${bundle}"
EOF

  cat >"${dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "missing GH_TOKEN" >&2
  exit 1
fi
echo "gh $*" >>"${STUB_DIR}/calls.log"
case "${1:-}:${2:-}" in
  release:view)
    if [[ "${STUB_RELEASE_EXISTS:-false}" == "true" ]]; then
      exit 0
    fi
    exit 1
    ;;
  release:create)
    exit 0
    ;;
  api:*)
    if [[ "$*" == *"--method PUT"* ]]; then
      exit 0
    fi
    if [[ "${STUB_TAP_EXISTS:-true}" == "true" ]]; then
      echo "existing-blob-sha-123"
      exit 0
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF

  cat >"${dir}/bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "${STUB_UNAME:-Linux}"
EOF

  chmod +x "${dir}/bin/"*
}

seed_dist() {
  local store="$1"
  local tag="$2"
  rm -rf "${store}/dist"
  mkdir -p "${store}/dist/homebrew/Formula"
  for target in darwin_arm64 linux_amd64; do
    local archive="${store}/dist/quacktel_${target}.tar.gz"
    printf 'archive-%s-%s\n' "${target}" "${tag}" >"${archive}"
    sha256_of "${archive}" >"${archive}.sha256"
    printf '{"spdxVersion":"SPDX-2.3","target":"%s"}\n' "${target}" >"${archive}.sbom.json"
    sha256_of "${archive}.sbom.json" >"${archive}.sbom.json.sha256"
  done
  local darwin_sha
  darwin_sha="$(cat "${store}/dist/quacktel_darwin_arm64.tar.gz.sha256")"
  cat >"${store}/dist/homebrew/Formula/quacktel.rb" <<EOF
class Quacktel < Formula
  depends_on :macos
  url "https://github.com/quacktel/cli/releases/download/${tag}/quacktel_darwin_arm64.tar.gz"
  sha256 "${darwin_sha}"
end
EOF
}

test_goreleaser_build() {
  local case_dir="${tmp}/goreleaser_build"
  setup_stub_bin "${case_dir}"

  # Linux skips darwin-artifacts.
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_UNAME="Linux" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GORELEASER_BUILD_ARTIFACTS_0="dist/quacktel_*.tar.gz*" \
      BUILDKITE_PLUGIN_GORELEASER_BUILD_DARWIN_ARTIFACTS_0="dist/homebrew/Formula/quacktel.rb" \
      "${plugins_dir}/goreleaser-build/hooks/command"
  )
  assert_contains "${case_dir}/calls.log" "goreleaser tag=v0.2.1-rc.1 release --clean --skip=publish"
  assert_contains "${case_dir}/uploads.log" "upload:dist/quacktel_*.tar.gz*"
  assert_not_contains "${case_dir}/uploads.log" "upload:dist/homebrew/Formula/quacktel.rb"

  # Darwin uploads both artifacts and darwin-artifacts.
  : >"${case_dir}/uploads.log"
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_UNAME="Darwin" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GORELEASER_BUILD_ARTIFACTS_0="dist/quacktel_*.tar.gz*" \
      BUILDKITE_PLUGIN_GORELEASER_BUILD_DARWIN_ARTIFACTS_0="dist/homebrew/Formula/quacktel.rb" \
      "${plugins_dir}/goreleaser-build/hooks/command"
  )
  assert_contains "${case_dir}/uploads.log" "upload:dist/homebrew/Formula/quacktel.rb"

  # Rejects non-semver tag before fetching or running goreleaser.
  : >"${case_dir}/calls.log"
  assert_fails_with "${case_dir}/work" "is not a vX.Y.Z[-pre] tag" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v1.2" \
      BUILDKITE_PLUGIN_GORELEASER_BUILD_ARTIFACTS_0="dist/quacktel_*.tar.gz*" \
      "${plugins_dir}/goreleaser-build/hooks/command"
  assert_not_contains "${case_dir}/calls.log" "goreleaser"
}

test_slsa_attest() {
  local case_dir="${tmp}/slsa_attest"
  setup_stub_bin "${case_dir}"
  seed_dist "${case_dir}/store" "v0.2.1-rc.1"

  # Happy path writes provenance pointing at pipeline.release.yml and uploads bundles.
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_ORGANIZATION_SLUG="wolfeidauci" \
      BUILDKITE_PIPELINE_SLUG="quacktel-cli-release" \
      BUILDKITE_BUILD_URL="https://buildkite.com/wolfeidauci/quacktel-cli-release/builds/1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_1="linux_amd64" \
      "${plugins_dir}/slsa-attest/hooks/command"
  )
  assert_contains "${case_dir}/work/dist/provenance.json" "https://github.com/quacktel/cli/blob/deadbeef0123456789abcdef0123456789abcdef/.buildkite/pipeline.release.yml"
  assert_contains "${case_dir}/uploads.log" "upload:dist/quacktel_darwin_arm64.tar.gz.sigstore.json"
  assert_contains "${case_dir}/uploads.log" "upload:dist/quacktel_linux_amd64.tar.gz.sigstore.json"

  # Rejects non-semver tag before interpolating into provenance JSON.
  assert_fails_with "${case_dir}/work" "is not a vX.Y.Z[-pre] tag" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG='v0.2.1",evil' \
      BUILDKITE_ORGANIZATION_SLUG="wolfeidauci" \
      BUILDKITE_PIPELINE_SLUG="quacktel-cli-release" \
      BUILDKITE_BUILD_URL="https://buildkite.com/wolfeidauci/quacktel-cli-release/builds/1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="darwin_arm64" \
      "${plugins_dir}/slsa-attest/hooks/command"

  # Rejects non-main commit.
  assert_fails_with "${case_dir}/work" "is not on main" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_GIT_ON_MAIN="false" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_ORGANIZATION_SLUG="wolfeidauci" \
      BUILDKITE_PIPELINE_SLUG="quacktel-cli-release" \
      BUILDKITE_BUILD_URL="https://buildkite.com/wolfeidauci/quacktel-cli-release/builds/1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="darwin_arm64" \
      "${plugins_dir}/slsa-attest/hooks/command"

  # Rejects bad checksum.
  echo "0000000000000000000000000000000000000000000000000000000000000000" >"${case_dir}/store/dist/quacktel_darwin_arm64.tar.gz.sha256"
  assert_fails_with "${case_dir}/work" "checksum mismatch" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_ORGANIZATION_SLUG="wolfeidauci" \
      BUILDKITE_PIPELINE_SLUG="quacktel-cli-release" \
      BUILDKITE_BUILD_URL="https://buildkite.com/wolfeidauci/quacktel-cli-release/builds/1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="darwin_arm64" \
      "${plugins_dir}/slsa-attest/hooks/command"

  # Rejects repo values that would inject into the provenance JSON.
  : >"${case_dir}/calls.log"
  assert_fails_with "${case_dir}/work" "slsa-attest: invalid repo" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_ORGANIZATION_SLUG="wolfeidauci" \
      BUILDKITE_PIPELINE_SLUG="quacktel-cli-release" \
      BUILDKITE_BUILD_URL="https://buildkite.com/wolfeidauci/quacktel-cli-release/builds/1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO='a/b", "x": "y' \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="darwin_arm64" \
      "${plugins_dir}/slsa-attest/hooks/command"
  assert_not_contains "${case_dir}/calls.log" "cosign"

  # Rejects path traversal in project and targets.
  assert_fails_with "${case_dir}/work" "slsa-attest: invalid project" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="../evil" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="darwin_arm64" \
      "${plugins_dir}/slsa-attest/hooks/command"
  assert_fails_with "${case_dir}/work" "slsa-attest: invalid target" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_SLSA_ATTEST_TARGETS_0="../x" \
      "${plugins_dir}/slsa-attest/hooks/command"
  assert_not_contains "${case_dir}/calls.log" "cosign"
}

test_github_immutable_release() {
  local case_dir="${tmp}/github_release"
  setup_stub_bin "${case_dir}"
  seed_dist "${case_dir}/store" "v0.2.1-rc.1"
  for target in darwin_arm64 linux_amd64; do
    echo '{}' >"${case_dir}/store/dist/quacktel_${target}.tar.gz.sigstore.json"
  done

  # Happy path passes --prerelease and all target assets in one gh release create call.
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_1="linux_amd64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"
  )
  assert_contains "${case_dir}/calls.log" "gh release create v0.2.1-rc.1 --repo quacktel/cli --verify-tag --title v0.2.1-rc.1 --notes  --prerelease"
  assert_contains "${case_dir}/calls.log" "dist/quacktel_darwin_arm64.tar.gz.sigstore.json"
  assert_not_contains "${case_dir}/calls.log" "super-secret-token-value"

  # Rejects bad tag.
  assert_fails_with "${case_dir}/work" "is not a vX.Y.Z[-pre] tag" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="not-a-tag" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"

  # Rejects non-main commit.
  assert_fails_with "${case_dir}/work" "is not on main" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_GIT_ON_MAIN="false" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"

  # Hides stderr from failed secret lookup.
  assert_fails_with "${case_dir}/work" "failed to read the QUACKTEL_GITHUB_TOKEN cluster secret" "secret-ref-leak-sentinel" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_SECRET_FAIL="true" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"

  # Refuses existing release.
  assert_fails_with "${case_dir}/work" "already exists" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_RELEASE_EXISTS="true" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"

  # Fails when a .sigstore.json provenance bundle is missing.
  rm -f "${case_dir}/store/dist/quacktel_darwin_arm64.tar.gz.sigstore.json"
  assert_fails_with "${case_dir}/work" "missing release asset dist/quacktel_darwin_arm64.tar.gz.sigstore.json" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"

  # Rejects checksum mismatch.
  echo '{}' >"${case_dir}/store/dist/quacktel_darwin_arm64.tar.gz.sigstore.json"
  echo "0000000000000000000000000000000000000000000000000000000000000000" >"${case_dir}/store/dist/quacktel_darwin_arm64.tar.gz.sha256"
  assert_fails_with "${case_dir}/work" "checksum mismatch" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"

  # Rejects bad repo, project and target values before any release call.
  : >"${case_dir}/calls.log"
  assert_fails_with "${case_dir}/work" "github-immutable-release: invalid repo" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO='a/b", "x": "y' \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"
  assert_fails_with "${case_dir}/work" "github-immutable-release: invalid project" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="../evil" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="darwin_arm64" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"
  assert_fails_with "${case_dir}/work" "github-immutable-release: invalid target" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_REPO="quacktel/cli" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_PROJECT="quacktel" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_TARGETS_0="../x" \
      BUILDKITE_PLUGIN_GITHUB_IMMUTABLE_RELEASE_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/github-immutable-release/hooks/command"
  assert_not_contains "${case_dir}/calls.log" "gh release create"
  assert_not_contains "${case_dir}/calls.log" "cosign"
}

test_homebrew_tap() {
  local case_dir="${tmp}/homebrew_tap"
  setup_stub_bin "${case_dir}"
  seed_dist "${case_dir}/store" "v0.2.1-rc.1"

  # verify-only validates formula on stable or prerelease without needing tap config or secret.
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_SECRET_FAIL="true" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_VERIFY_ONLY="true" \
      "${plugins_dir}/homebrew-tap/hooks/command" >/dev/null
  )
  assert_not_contains "${case_dir}/calls.log" "gh api"

  # Prerelease with skip-prerelease=true validates formula and skips tap push without reading secret.
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_SECRET_FAIL="true" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="quacktel/homebrew-tap" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_SKIP_PRERELEASE="true" \
      "${plugins_dir}/homebrew-tap/hooks/command" >/dev/null
  )
  assert_not_contains "${case_dir}/calls.log" "gh api"

  # Rejects non-macOS formula in verify-only mode before publish.
  echo 'class Quacktel < Formula; end' >"${case_dir}/store/dist/homebrew/Formula/quacktel.rb"
  assert_fails_with "${case_dir}/work" "missing depends_on :macos" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1-rc.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_VERIFY_ONLY="true" \
      "${plugins_dir}/homebrew-tap/hooks/command"

  # Stable tag updates existing formula via GitHub Contents API with existing sha.
  seed_dist "${case_dir}/store" "v0.2.1"
  : >"${case_dir}/calls.log"
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="quacktel/homebrew-tap" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/homebrew-tap/hooks/command"
  )
  assert_contains "${case_dir}/calls.log" "gh api --method PUT repos/quacktel/homebrew-tap/contents/Formula/quacktel.rb"
  assert_contains "${case_dir}/calls.log" "-f sha=existing-blob-sha-123"

  # Stable tag creates formula when tap has no existing file (omits -f sha).
  : >"${case_dir}/calls.log"
  (
    cd "${case_dir}/work"
    PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_TAP_EXISTS="false" \
      BUILDKITE_TAG="v0.2.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="quacktel/homebrew-tap" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/homebrew-tap/hooks/command"
  )
  assert_contains "${case_dir}/calls.log" "gh api --method PUT repos/quacktel/homebrew-tap/contents/Formula/quacktel.rb"
  assert_not_contains "${case_dir}/calls.log" "-f sha="

  # Hides stderr from failed secret lookup on stable tag.
  assert_fails_with "${case_dir}/work" "failed to read the QUACKTEL_GITHUB_TOKEN cluster secret" "secret-ref-leak-sentinel" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      STUB_SECRET_FAIL="true" \
      BUILDKITE_TAG="v0.2.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="quacktel/homebrew-tap" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/homebrew-tap/hooks/command"

  # Rejects bad tap and formula-path before any API call.
  : >"${case_dir}/calls.log"
  assert_fails_with "${case_dir}/work" "homebrew-tap: invalid tap" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="../.." \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/homebrew-tap/hooks/command"
  assert_fails_with "${case_dir}/work" "homebrew-tap: invalid formula-path" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="quacktel/homebrew-tap" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="../Formula/x.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/homebrew-tap/hooks/command"
  assert_not_contains "${case_dir}/calls.log" "gh api"

  # Rejects a checksum artifact that is not a bare sha256 hex digest.
  echo 'not-hex" evil' >"${case_dir}/store/dist/quacktel_darwin_arm64.tar.gz.sha256"
  assert_fails_with "${case_dir}/work" "homebrew-tap: invalid checksum" "" \
    env PATH="${case_dir}/bin:${PATH}" \
      STUB_DIR="${case_dir}" \
      BUILDKITE_TAG="v0.2.1" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_TAP="quacktel/homebrew-tap" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_FORMULA_PATH="Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARTIFACT_PATH="dist/homebrew/Formula/quacktel.rb" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_ARCHIVE="quacktel_darwin_arm64.tar.gz" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_CHECKSUM_ARTIFACT="dist/quacktel_darwin_arm64.tar.gz.sha256" \
      BUILDKITE_PLUGIN_HOMEBREW_TAP_GITHUB_TOKEN_SECRET="QUACKTEL_GITHUB_TOKEN" \
      "${plugins_dir}/homebrew-tap/hooks/command"
  assert_not_contains "${case_dir}/calls.log" "gh api"
}

test_goreleaser_build
test_slsa_attest
test_github_immutable_release
test_homebrew_tap
echo "all release plugin tests passed"
