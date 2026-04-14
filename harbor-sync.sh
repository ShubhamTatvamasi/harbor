#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="./sync-config.yaml"
DRY_RUN=false
SYNC_DOCKER=false
SYNC_OCI=false
SYNC_HELM=false
MODE_SELECTED=false
ALLOW_HTTP=false
CONTAINER_CMD=""

function fail() {
  echo "ERROR: $*" >&2
  exit 1
}

function info() {
  echo "[INFO] $*"
}

function ensure_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' is not installed."
}

function choose_container_cli() {
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    return
  fi
  if command -v nerdctl >/dev/null 2>&1; then
    CONTAINER_CMD="nerdctl"
    return
  fi
  fail "Neither docker nor nerdctl is installed. Install one of them to sync Docker images."
}

function is_yaml_file() {
  [[ "$1" == *.yaml || "$1" == *.yml ]]
}

function load_yaml_config() {
  info "Loading YAML config $CONFIG_FILE"
  ensure_command yq

  HARBOR_PROTOCOL="$(yq e '.harbor.protocol // "http"' "$CONFIG_FILE")"
  HARBOR_HOST="$(yq e '.harbor.host' "$CONFIG_FILE")"
  HARBOR_USERNAME="$(yq e '.harbor.username' "$CONFIG_FILE")"
  HARBOR_PASSWORD="$(yq e '.harbor.password' "$CONFIG_FILE")"
  HARBOR_PROJECT="$(yq e '.harbor.project // ""' "$CONFIG_FILE")"

  DOCKER_SOURCES=()
  HELM_SOURCES=()
  HELM_REPO_REPOS=()
  HELM_REPO_CHARTS=()
  HELM_REPO_VERSIONS=()
  mapfile -t DOCKER_SOURCES < <(yq e '.docker_images[]?' "$CONFIG_FILE")
  mapfile -t HELM_SOURCES < <(yq e '.oci_repos[]?' "$CONFIG_FILE")
  mapfile -t HELM_REPO_REPOS < <(yq e '.helm_repos[].repo? // ""' "$CONFIG_FILE")
  mapfile -t HELM_REPO_CHARTS < <(yq e '.helm_repos[].chart? // ""' "$CONFIG_FILE")
  mapfile -t HELM_REPO_VERSIONS < <(yq e '.helm_repos[].version? // ""' "$CONFIG_FILE")
}

function normalize_ref() {
  local ref="$1"
  ref="${ref#oci://}"
  ref="${ref#docker://}"
  echo "$ref"
}

function strip_registry() {
  local ref="$1"
  echo "${ref#*/}"
}

function derive_docker_target() {
  local source="$1"
  local repo_path target
  repo_path="$(strip_registry "$(normalize_ref "$source")")"
  repo_path="${repo_path##*/}"
  if [[ -n "${HARBOR_PROJECT:-}" ]]; then
    target="${HARBOR_HOST}/${HARBOR_PROJECT}/${repo_path}"
  else
    target="${HARBOR_HOST}/${repo_path}"
  fi
  echo "$target"
}

function derive_helm_target() {
  local target
  if [[ -n "${HARBOR_PROJECT:-}" ]]; then
    target="oci://${HARBOR_HOST}/${HARBOR_PROJECT}"
  else
    target="oci://${HARBOR_HOST}"
  fi
  echo "$target"
}

function docker_desktop() {
  [[ "$CONTAINER_CMD" != "docker" ]] && return 1
  docker info 2>/dev/null | grep -qiE 'Docker Desktop|docker desktop'
}

function docker_insecure_registry_exists() {
  local host="$1"
  [[ "$CONTAINER_CMD" != "docker" ]] && return 1
  docker info 2>/dev/null | awk '/Insecure Registries:/ {found=1; next} /^[^[:space:]]/ {found=0} found {print}' | grep -qE "(^|[[:space:]])${host}([[:space:]]|$)"
}

function ensure_docker_insecure_registry() {
  local config_path
  local host="$HARBOR_HOST"
  if docker_desktop; then
    cat <<EOF >&2
ERROR: Docker Desktop detected and '$host' is not configured as an insecure registry.

Open Docker Desktop > Settings > Docker Engine and add the following under "insecure-registries":

{
  "insecure-registries": ["$host"]
}

Then restart Docker Desktop and run the command again.
EOF
    fail "Docker Desktop insecure registry not configured."
  fi

  if [[ -f /etc/docker/daemon.json ]]; then
    config_path="/etc/docker/daemon.json"
  elif [[ -f "$HOME/.docker/daemon.json" ]]; then
    config_path="$HOME/.docker/daemon.json"
  else
    config_path="/etc/docker/daemon.json"
  fi

  if [[ ! -w "$config_path" ]] && [[ ! -w "$(dirname "$config_path")" ]]; then
    fail "Cannot write Docker daemon config at '$config_path'. Run as root or configure insecure registries manually."
  fi

  python3 - <<PY
import json
from pathlib import Path
path = Path(r"$config_path")
obj = {}
if path.exists():
    try:
        obj = json.loads(path.read_text())
    except Exception as e:
        raise SystemExit(f"Failed to parse {path}: {e}")
registries = obj.get("insecure-registries", [])
if r"$host" not in registries:
    registries.append(r"$host")
obj["insecure-registries"] = registries
path.write_text(json.dumps(obj, indent=2) + "\n")
PY

  info "Added '$host' to Docker insecure registries in $config_path. Restart Docker to apply."
}

function docker_login_harbor() {
  info "Logging in to Harbor Docker registry $HARBOR_HOST"

  if [[ "$HARBOR_PROTOCOL" == "http" ]]; then
    if [[ "$CONTAINER_CMD" == "docker" ]]; then
      if docker_insecure_registry_exists "$HARBOR_HOST"; then
        info "Docker insecure registry '$HARBOR_HOST' already configured."
      elif [[ "$ALLOW_HTTP" == true ]]; then
        ensure_docker_insecure_registry
      else
        fail "Harbor is HTTP-only and Docker insecure registry is not configured. Use --allow-http or configure insecure registries manually."
      fi
    else
      info "Using nerdctl; HTTP access requires containerd/nerdctl to be configured for insecure registries or plain HTTP."
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "$CONTAINER_CMD login $HARBOR_HOST -u $HARBOR_USERNAME -p ********"
    return
  fi
  echo "$HARBOR_PASSWORD" | $CONTAINER_CMD login "$HARBOR_HOST" -u "$HARBOR_USERNAME" --password-stdin
}

function push_docker_image() {
  local source_ref target_ref source_pull target_push
  source_ref="$1"
  target_ref="$2"

  source_pull="$(normalize_ref "$source_ref")"
  target_push="$target_ref"

  info "Mirroring Docker image: $source_pull -> $target_push"

  if [[ "$DRY_RUN" == true ]]; then
    echo "$CONTAINER_CMD pull $source_pull"
    echo "$CONTAINER_CMD tag $source_pull $target_push"
    echo "$CONTAINER_CMD push $target_push"
    return
  fi

  $CONTAINER_CMD pull "$source_pull"
  $CONTAINER_CMD tag "$source_pull" "$target_push"
  $CONTAINER_CMD push "$target_push"
}

function ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Config file '$CONFIG_FILE' not found. Create it or pass the path as the first argument."
  fi

  if is_yaml_file "$CONFIG_FILE"; then
    load_yaml_config
  else
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  if [[ ${DOCKER_IMAGES+x} ]]; then
    DOCKER_SOURCES=("${DOCKER_IMAGES[@]}")
  fi
  if [[ ${HELM_CHARTS+x} ]]; then
    HELM_SOURCES=("${HELM_CHARTS[@]}")
  fi

  : "${HARBOR_HOST:?}"
  : "${HARBOR_USERNAME:?}"
  : "${HARBOR_PASSWORD:?}"
}

function helm_login_harbor() {
  local harbor_host
  local helm_flags=()
  harbor_host="$HARBOR_HOST"
  if [[ "$HARBOR_PROTOCOL" == "http" ]]; then
    helm_flags+=(--plain-http)
  fi

  info "Logging in to Harbor Helm/OCI registry $HARBOR_PROTOCOL://$HARBOR_HOST"
  if [[ "$DRY_RUN" == true ]]; then
    echo "HELM_EXPERIMENTAL_OCI=1 helm registry login $harbor_host -u $HARBOR_USERNAME --password-stdin ${helm_flags[*]}"
    return
  fi
  echo "$HARBOR_PASSWORD" | HELM_EXPERIMENTAL_OCI=1 helm registry login "$harbor_host" -u "$HARBOR_USERNAME" --password-stdin "${helm_flags[@]}"
}

function push_helm_chart() {
  local source_ref target_ref
  local helm_flags=()
  source_ref="$1"
  target_ref="$2"
  if [[ "$HARBOR_PROTOCOL" == "http" ]]; then
    helm_flags+=(--plain-http)
  fi

  info "Mirroring Helm chart: $source_ref -> $target_ref"
  if [[ "$DRY_RUN" == true ]]; then
    echo "workdir=\$(mktemp -d)"
    echo "pushd \"\$workdir\" >/dev/null"
    echo "HELM_EXPERIMENTAL_OCI=1 helm pull $source_ref --destination . ${helm_flags[*]}"
    echo "chart=\$(ls *.tgz 2>/dev/null | head -n1)"
    echo "HELM_EXPERIMENTAL_OCI=1 helm push \"\$chart\" $target_ref ${helm_flags[*]}"
    echo "popd >/dev/null"
    return
  fi

  local workdir
  workdir="$(mktemp -d)"
  pushd "$workdir" >/dev/null
  HELM_EXPERIMENTAL_OCI=1 helm pull "$source_ref" --destination . "${helm_flags[@]}"
  local chart_file
  chart_file=$(ls *.tgz 2>/dev/null | head -n1)
  if [[ -z "$chart_file" ]]; then
    fail "Failed to pull Helm chart from $source_ref"
  fi
  HELM_EXPERIMENTAL_OCI=1 helm push "$chart_file" "$target_ref" "${helm_flags[@]}"
  popd >/dev/null
  rm -rf "$workdir"
}

function derive_helm_repo_target() {
  local target
  if [[ -n "${HARBOR_PROJECT:-}" ]]; then
    target="oci://${HARBOR_HOST}/${HARBOR_PROJECT}"
  else
    target="oci://${HARBOR_HOST}"
  fi
  echo "$target"
}

function push_helm_repo_chart() {
  local repo="$1"
  local chart="$2"
  local version="$3"
  local target_dir
  local repo_name
  local target

  target="$(derive_helm_repo_target "$chart" "$version")"
  repo_name="harbor-sync-$(date +%s%N)"
  target_dir="$(mktemp -d)"

  local helm_flags=()
  if [[ "$HARBOR_PROTOCOL" == "http" ]]; then
    helm_flags+=(--plain-http)
  fi

  info "Mirroring Helm repo chart: $repo/$chart@$version -> $target"
  if [[ "$DRY_RUN" == true ]]; then
    echo "helm repo add $repo_name $repo"
    echo "helm repo update"
    echo "pushd $target_dir >/dev/null"
    echo "helm pull $repo_name/$chart --version $version --destination . ${helm_flags[*]}"
    echo "chart=\$(ls *.tgz 2>/dev/null | head -n1)"
    echo "HELM_EXPERIMENTAL_OCI=1 helm push \"\$chart\" $target ${helm_flags[*]}"
    echo "popd >/dev/null"
    echo "helm repo remove $repo_name"
    return
  fi

  helm repo add "$repo_name" "$repo"
  helm repo update
  pushd "$target_dir" >/dev/null
  helm pull "$repo_name/$chart" --version "$version" --destination . "${helm_flags[@]}"
  local chart_file
  chart_file=$(ls *.tgz 2>/dev/null | head -n1)
  if [[ -z "$chart_file" ]]; then
    fail "Failed to pull Helm chart from $chart from repo $repo"
  fi
  HELM_EXPERIMENTAL_OCI=1 helm push "$chart_file" "$target" "${helm_flags[@]}"
  popd >/dev/null
  helm repo remove "$repo_name"
  rm -rf "$target_dir"
}

function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config|-c)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --allow-http)
        ALLOW_HTTP=true
        shift
        ;;
      --docker)
        SYNC_DOCKER=true
        MODE_SELECTED=true
        shift
        ;;
      --oci)
        SYNC_OCI=true
        MODE_SELECTED=true
        shift
        ;;
      --helm)
        SYNC_HELM=true
        MODE_SELECTED=true
        shift
        ;;
      --help|-h)
        cat <<'EOF'
Usage: ./harbor-sync.sh [--config path/to/config.yaml] [--dry-run] [--docker] [--oci] [--helm] [--allow-http]

Options:
  --config, -c   Path to the config file (default: ./sync-config.yaml)
  --dry-run      Print commands without executing them
  --allow-http    Attempt to add Harbor to Docker insecure registries for HTTP access
  --docker       Sync only Docker images from docker_images
  --oci          Sync only OCI Helm charts from oci_repos
  --helm         Sync only standard Helm repo charts from helm_repos
  --help, -h     Show this help message
EOF
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

function main() {
  parse_args "$@"
  ensure_command helm
  if [[ "$SYNC_DOCKER" == true ]]; then
    choose_container_cli
    ensure_command "$CONTAINER_CMD"
  fi
  ensure_config

  if [[ "$MODE_SELECTED" == false ]]; then
    SYNC_DOCKER=true
    SYNC_OCI=true
    SYNC_HELM=true
  fi

  if [[ "$SYNC_DOCKER" == true && ${DOCKER_SOURCES+x} ]] && (( ${#DOCKER_SOURCES[@]} )); then
    docker_login_harbor
    for source in "${DOCKER_SOURCES[@]}"; do
      target="$(derive_docker_target "$source")"
      push_docker_image "$source" "$target"
    done
  fi

  if [[ "$SYNC_OCI" == true && ${HELM_SOURCES+x} ]] && (( ${#HELM_SOURCES[@]} )); then
    helm_login_harbor
    for source in "${HELM_SOURCES[@]}"; do
      target="$(derive_helm_target "$source")"
      push_helm_chart "$source" "$target"
    done
  fi

  if [[ "$SYNC_HELM" == true && ${HELM_REPO_CHARTS+x} ]] && (( ${#HELM_REPO_CHARTS[@]} )); then
    helm_login_harbor
    for i in "${!HELM_REPO_CHARTS[@]}"; do
      repo="${HELM_REPO_REPOS[i]}"
      chart="${HELM_REPO_CHARTS[i]}"
      version="${HELM_REPO_VERSIONS[i]}"
      if [[ -z "$repo" || -z "$chart" || -z "$version" ]]; then
        fail "helm_repos entries must include repo, chart, and version."
      fi
      push_helm_repo_chart "$repo" "$chart" "$version"
    done
  fi

  info "Sync complete."
}

main "$@"
