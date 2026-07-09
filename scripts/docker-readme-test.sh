#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/docker-readme-test.sh
  scripts/docker-readme-test.sh auto [run|smoke|shell] [args...]
  scripts/docker-readme-test.sh update
  scripts/docker-readme-test.sh build
  scripts/docker-readme-test.sh run [<start-readme-test-nvim args...>]
  scripts/docker-readme-test.sh smoke
  scripts/docker-readme-test.sh shell

This builds and runs the Docker image for the repo's README-minimal config.
The auto command rebuilds only when the image is missing or older than the
current checked-in and untracked repo files, then starts interactive Neovim by
default. Pass "smoke" or "shell" after auto to launch those modes instead.

Environment:
  ARK_DOCKER_README_TEST_IMAGE   Override the image tag (default: ark-readme-test:local)
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile="${repo_root}/docker/readme-minimal/Dockerfile"
image_tag="${ARK_DOCKER_README_TEST_IMAGE:-ark-readme-test:local}"
context_label="dev.ark.nvim.readme-test.context-sha"
command="${1:-auto}"
if (($# > 0)); then
  shift
fi

prepare_release_artifact() {
  local dist_dir="${repo_root}/dist/readme"
  local asset
  asset=$(python3 - "${repo_root}/release-manifest.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["release_targets"][0]["asset"])
PY
)

  if [[ -x "${dist_dir}/${asset}" && -f "${dist_dir}/${asset}.sha256" ]]; then
    return 0
  fi
  "${repo_root}/scripts/package-release.sh" "${dist_dir}"
}

context_fingerprint() {
  (
    cd "${repo_root}"
    git ls-files -co --exclude-standard -z \
      | sort -z \
      | xargs -0 sha256sum \
      | sha256sum \
      | awk '{ print $1 }'
  )
}

image_fingerprint() {
  docker image inspect \
    --format "{{ index .Config.Labels \"${context_label}\" }}" \
    "${image_tag}" 2>/dev/null || true
}

build_image() {
  local fingerprint="$1"
  shift
  prepare_release_artifact
  docker build \
    -f "${dockerfile}" \
    -t "${image_tag}" \
    --label "${context_label}=${fingerprint}" \
    "$@" \
    "${repo_root}"
}

update_image() {
  local fingerprint
  local built_fingerprint

  prepare_release_artifact
  fingerprint="$(context_fingerprint)"
  built_fingerprint="$(image_fingerprint)"

  if [[ "${built_fingerprint}" == "${fingerprint}" ]]; then
    return 0
  fi

  if [[ -z "${built_fingerprint}" ]]; then
    echo "Building Docker README test image ${image_tag}." >&2
  else
    echo "Updating Docker README test image ${image_tag}." >&2
  fi
  build_image "${fingerprint}" "$@"
}

run_image() {
  exec docker run --rm -it "${image_tag}" "$@"
}

smoke_image() {
  exec docker run --rm "${image_tag}" smoke "$@"
}

shell_image() {
  exec docker run --rm -it "${image_tag}" shell "$@"
}

case "${command}" in
  auto)
    update_image
    mode="${1:-run}"
    case "${mode}" in
      run | interactive)
        shift || true
        run_image "$@"
        ;;
      smoke)
        shift
        smoke_image "$@"
        ;;
      shell | bash)
        shift
        shell_image "$@"
        ;;
      -*)
        run_image "$@"
        ;;
      *)
        echo "unknown auto mode: ${mode}" >&2
        usage >&2
        exit 1
        ;;
    esac
    ;;
  update)
    update_image "$@"
    ;;
  build)
    build_image "$(context_fingerprint)" "$@"
    ;;
  run)
    run_image "$@"
    ;;
  smoke)
    smoke_image "$@"
    ;;
  shell)
    shell_image "$@"
    ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    echo "unknown subcommand: ${command}" >&2
    usage >&2
    exit 1
    ;;
esac
