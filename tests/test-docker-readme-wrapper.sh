#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d /tmp/ark-docker-readme-wrapper.XXXXXX)
bin_dir="$tmp_root/bin"
log_file="$tmp_root/docker.log"
image_fingerprint_file="$tmp_root/image-fingerprint"
dist_dir="$tmp_root/dist"
release_source="$tmp_root/ark-lsp-source"
package_script="$tmp_root/package-release.sh"
script="$repo_root/scripts/docker-readme-test.sh"

cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$bin_dir"

cat >"$release_source" <<'EOF'
artifact-v1
EOF
chmod 755 "$release_source"

cat >"$package_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

dist_dir=$1
asset="ark-lsp-v0.1.0-alpha.1-x86_64-unknown-linux-gnu"
mkdir -p "$dist_dir"
install -m 755 "$ARK_FAKE_RELEASE_SOURCE" "$dist_dir/$asset"
sha256sum "$dist_dir/$asset" >"$dist_dir/$asset.sha256"
EOF
chmod 755 "$package_script"

cat >"$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  image)
    if [[ "${2:-}" != "inspect" ]]; then
      echo "unexpected docker image command: $*" >&2
      exit 2
    fi
    if [[ -s "${ARK_FAKE_DOCKER_IMAGE_FINGERPRINT}" ]]; then
      cat "${ARK_FAKE_DOCKER_IMAGE_FINGERPRINT}"
      printf '\n'
      exit 0
    fi
    exit 1
    ;;
  build)
    label=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == "--label" ]]; then
        label="$arg"
        break
      fi
      previous="$arg"
    done
    fingerprint="${label#*=}"
    printf '%s\n' "$fingerprint" >"${ARK_FAKE_DOCKER_IMAGE_FINGERPRINT}"
    printf 'build %s\n' "$*" >>"${ARK_FAKE_DOCKER_LOG}"
    ;;
  run)
    printf 'run %s\n' "$*" >>"${ARK_FAKE_DOCKER_LOG}"
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "$bin_dir/docker"

run_wrapper() {
  PATH="$bin_dir:$PATH" \
    ARK_FAKE_DOCKER_LOG="$log_file" \
    ARK_FAKE_DOCKER_IMAGE_FINGERPRINT="$image_fingerprint_file" \
    ARK_FAKE_RELEASE_SOURCE="$release_source" \
    ARK_DOCKER_README_DIST_DIR="$dist_dir" \
    ARK_DOCKER_README_PACKAGE_SCRIPT="$package_script" \
    "$script" "$@" >/dev/null 2>&1
}

run_wrapper auto smoke
mapfile -t calls <"$log_file"
if [[ "${#calls[@]}" -ne 2 || "${calls[0]}" != build\ * || "${calls[1]}" != "run run --rm ark-readme-test:local smoke" ]]; then
  printf 'unexpected first auto smoke calls:\n' >&2
  cat "$log_file" >&2
  exit 1
fi

: >"$log_file"
run_wrapper auto shell
mapfile -t calls <"$log_file"
if [[ "${#calls[@]}" -ne 1 || "${calls[0]}" != "run run --rm -it ark-readme-test:local shell" ]]; then
  printf 'expected current image to skip build and run shell, got:\n' >&2
  cat "$log_file" >&2
  exit 1
fi

cat >"$release_source" <<'EOF'
artifact-v2
EOF
: >"$log_file"
run_wrapper update
mapfile -t calls <"$log_file"
if [[ "${#calls[@]}" -ne 1 || "${calls[0]}" != build\ * ]]; then
  printf 'expected update to rebuild after the release artifact changed, got:\n' >&2
  cat "$log_file" >&2
  exit 1
fi
