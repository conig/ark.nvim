#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/docker-readme-test.sh build
  scripts/docker-readme-test.sh run [<start-readme-test-nvim args...>]
  scripts/docker-readme-test.sh smoke
  scripts/docker-readme-test.sh shell

This builds and runs the Docker image for the repo's README-minimal config.

Environment:
  ARK_DOCKER_README_TEST_IMAGE   Override the image tag (default: ark-readme-test:local)
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile="${repo_root}/docker/readme-minimal/Dockerfile"
image_tag="${ARK_DOCKER_README_TEST_IMAGE:-ark-readme-test:local}"
command="${1:-run}"

case "${command}" in
  build)
    shift
    exec docker build -f "${dockerfile}" -t "${image_tag}" "$@" "${repo_root}"
    ;;
  run)
    shift
    exec docker run --rm -it "${image_tag}" "$@"
    ;;
  smoke)
    shift
    exec docker run --rm "${image_tag}" smoke "$@"
    ;;
  shell)
    shift
    exec docker run --rm -it "${image_tag}" shell "$@"
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
