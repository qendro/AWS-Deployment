#!/bin/bash
# Thin OCI wrapper. All Python and dependency installation happen in Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE=aws-deployment:latest
command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo 'Start the Docker daemon first.' >&2; exit 1; }
if [[ "$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.dxnn.oci-sdk"}}' 2>/dev/null || true)" != 2.187.2 ]]; then
    docker buildx build --platform linux/arm64 --load -t "$IMAGE" "$ROOT"
fi
umask 077
mkdir -p "$ROOT/output/oci"
args=(run --rm -e "OCI_HOST_HOME=$HOME" -e "OCI_HOST_ROOT=$ROOT"
      -e "OCI_CONFIG_FILE=${OCI_CONFIG_FILE:-$HOME/.oci/config}"
      -e "OCI_PROFILE=${OCI_PROFILE:-DEFAULT}"
      -e "OCI_SIGNING_KEY_FILE=${OCI_SIGNING_KEY_FILE:-}"
      -v "$ROOT:$ROOT:ro" -v "$ROOT/output/oci:$ROOT/output/oci"
      -w "$ROOT" --entrypoint python3)
# The planning pass reads YAML/state/config in the container. It emits only file
# paths, never key contents. Mount external config and keys at identical paths.
auth="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
case "$auth" in
    '~/'*) auth="$HOME/${auth#\~/}" ;;
esac
[[ "$auth" = /* ]] || auth="$ROOT/$auth"
if [[ -f "$auth" ]]; then
    args+=(-v "$(dirname "$auth"):$(dirname "$auth"):ro")
fi
# Allow a launch YAML outside this repository, read-only at the host path.
previous=""
for value in "$@"; do
    if [[ "$previous" == -c || "$previous" == --config ]]; then
        yaml_path="$value"
        case "$yaml_path" in '~/'*) yaml_path="$HOME/${yaml_path#\~/}" ;; esac
        [[ "$yaml_path" = /* ]] || yaml_path="$ROOT/$yaml_path"
        [[ -f "$yaml_path" ]] || { echo "Configuration file is missing: $yaml_path" >&2; exit 1; }
        case "$yaml_path" in "$ROOT/"*) ;; *) args+=(-v "$(dirname "$yaml_path"):$(dirname "$yaml_path"):ro") ;; esac
    fi
    previous="$value"
done
mount_plan=$(mktemp)
trap 'rm -f "$mount_plan"' EXIT
docker "${args[@]}" "$IMAGE" "$ROOT/scripts/oci_manager.py" --mount-plan "$@" > "$mount_plan"
while IFS= read -r -d '' path; do
    [[ -f "$path" ]] || { echo "Required key/config file is missing: $path" >&2; exit 1; }
    # Files beneath the repo are already visible, with generated keys writable.
    case "$path" in "$ROOT/"*) ;; *) args+=(-v "$path:$path:ro") ;; esac
done < "$mount_plan"
if [[ -t 0 && -t 1 ]]; then args+=(-it); fi
docker "${args[@]}" "$IMAGE" "$ROOT/scripts/oci_manager.py" "$@"
