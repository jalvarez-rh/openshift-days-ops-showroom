#!/usr/bin/env bash
# Install Zero Trust Workload Identity Manager (ZTWIM) on OpenShift via OLM.
# Upstream: https://github.com/openshift/zero-trust-workload-identity-manager
#
# Prerequisites:
#   - OpenShift 4.19+ with cluster-admin
#   - git, podman (preferred) or cluster image build (oc new-build)
#   - Egress to ghcr.io (SPIRE component images) unless mirrored
#
# Optional environment variables:
#   ZTWIM_REF              Git ref to clone (default: main)
#   ZTWIM_VERSION          Operator/bundle version label (default: 1.0.1)
#   ZTWIM_NAMESPACE        Operator namespace (default: zero-trust-workload-identity-manager)
#   ZTWIM_OPERATOR_IMAGE   Pre-built operator image (skip local build if set)
#   ZTWIM_BUNDLE_IMAGE     Pre-built bundle image (skip bundle build if set)
#   ZTWIM_WORKDIR          Clone directory (default: /tmp/zero-trust-workload-identity-manager)
#   ZTWIM_APPLY_SAMPLES    Apply upstream config/samples when true (default: true)
#   ZTWIM_SKIP_BUILD       If true, require ZTWIM_OPERATOR_IMAGE and ZTWIM_BUNDLE_IMAGE

set -euo pipefail

REPO_URL="${ZTWIM_REPO_URL:-https://github.com/openshift/zero-trust-workload-identity-manager.git}"
REF="${ZTWIM_REF:-main}"
VERSION="${ZTWIM_VERSION:-1.0.1}"
NAMESPACE="${ZTWIM_NAMESPACE:-zero-trust-workload-identity-manager}"
WORKDIR="${ZTWIM_WORKDIR:-/tmp/zero-trust-workload-identity-manager}"
APPLY_SAMPLES="${ZTWIM_APPLY_SAMPLES:-true}"
SKIP_BUILD="${ZTWIM_SKIP_BUILD:-false}"
BUILD_NS="${ZTWIM_BUILD_NAMESPACE:-ztwim-build}"
OPERATOR_SDK_VERSION="${OPERATOR_SDK_VERSION:-v1.39.0}"
BUNDLE_TIMEOUT="${ZTWIM_BUNDLE_TIMEOUT:-20m0s}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[ZTWIM]${NC} $*"; }
warn() { echo -e "${YELLOW}[ZTWIM]${NC} $*"; }
die() { echo -e "${RED}[ZTWIM] ERROR:${NC} $*" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

ztwim_csv_succeeded() {
  local csv
  csv="$(oc get csv -n "${NAMESPACE}" \
    -o jsonpath='{range .items[?(@.spec.displayName=="Zero Trust Workload Identity Manager")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1)"
  [[ -n "${csv}" ]] || return 1
  [[ "$(oc get csv "${csv}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]
}

check_prereqs() {
  log "Checking prerequisites..."
  command_exists oc || die "oc not found in PATH"
  oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift (run oc login)"
  oc auth can-i create subscriptions --all-namespaces >/dev/null 2>&1 \
    || die "Cluster admin required to install operators (current user: $(oc whoami))"
  command_exists git || die "git not found in PATH"

  local ver
  ver="$(oc version -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print((d.get('openshiftVersion') or d.get('serverVersion', {}).get('gitVersion', '')).lstrip('v')[:4])
" 2>/dev/null || true)"
  if [[ -n "${ver}" ]] && [[ "$(printf '%s\n' "4.19" "${ver}" | sort -V | head -1)" != "4.19" ]]; then
    warn "OpenShift ${ver} detected; upstream recommends 4.19+"
  fi

  if ! oc get namespace openshift-operators >/dev/null 2>&1; then
    die "OLM does not appear to be installed (missing openshift-operators namespace)"
  fi
  log "Connected as $(oc whoami) on $(oc config current-context 2>/dev/null || echo 'unknown context')"
}

clone_upstream() {
  if [[ -d "${WORKDIR}/.git" ]]; then
    log "Updating existing clone at ${WORKDIR}..."
    git -C "${WORKDIR}" fetch --depth 1 origin "${REF}" 2>/dev/null || git -C "${WORKDIR}" fetch origin
    git -C "${WORKDIR}" checkout "${REF}"
    git -C "${WORKDIR}" pull --ff-only origin "${REF}" 2>/dev/null || true
  else
    log "Cloning ${REPO_URL} (ref: ${REF})..."
    git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${WORKDIR}" 2>/dev/null \
      || git clone --depth 1 "${REPO_URL}" "${WORKDIR}"
    if [[ "${REF}" != "main" ]] && [[ "${REF}" != "master" ]]; then
      git -C "${WORKDIR}" checkout "${REF}" 2>/dev/null || true
    fi
  fi
}

ensure_operator_sdk() {
  if command_exists operator-sdk; then
    return 0
  fi
  local os arch dest
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  [[ "${arch}" == "x86_64" ]] && arch="amd64"
  [[ "${arch}" == "aarch64" ]] && arch="arm64"
  dest="${HOME}/.local/bin/operator-sdk"
  mkdir -p "$(dirname "${dest}")"
  log "Downloading operator-sdk ${OPERATOR_SDK_VERSION} to ${dest}..."
  curl -fsSL \
    "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk_${os}_${arch}" \
    -o "${dest}"
  chmod +x "${dest}"
  export PATH="${HOME}/.local/bin:${PATH}"
  command_exists operator-sdk || die "Failed to install operator-sdk"
}

cluster_registry_host() {
  local route_host
  route_host="$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${route_host}" ]]; then
    echo "${route_host}"
  else
    echo "image-registry.openshift-image-registry.svc:5000"
  fi
}

podman_login_registry() {
  local registry="$1"
  local user token
  user="$(oc whoami)"
  token="$(oc whoami -t)"
  podman login "${registry}" -u "${user}" -p "${token}" --tls-verify=false
}

build_operator_image_oc() {
  log "Building operator image with OpenShift build (${BUILD_NS})..."
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${BUILD_NS}
EOF
  oc policy add-role-to-user system:image-builder "$(oc whoami)" -n "${BUILD_NS}" >/dev/null 2>&1 || true

  if ! oc get bc zero-trust-workload-identity-manager -n "${BUILD_NS}" >/dev/null 2>&1; then
    oc new-build --name=zero-trust-workload-identity-manager \
      --strategy=docker \
      "${REPO_URL}#${REF}" \
      -n "${BUILD_NS}" >/dev/null
  fi
  oc start-build zero-trust-workload-identity-manager -n "${BUILD_NS}" --wait
  oc get istag zero-trust-workload-identity-manager:latest -n "${BUILD_NS}" \
    -o jsonpath='{.image.dockerImageReference}'
}

build_operator_image_podman() {
  local registry img
  registry="$(cluster_registry_host)"
  oc create namespace "${BUILD_NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc policy add-role-to-user system:image-builder "$(oc whoami)" -n "${BUILD_NS}" >/dev/null 2>&1 || true
  img="${registry}/${BUILD_NS}/zero-trust-workload-identity-manager:${VERSION}"
  log "Building operator image with podman: ${img}"
  podman build -t "docker://${img}" "${WORKDIR}"
  podman_login_registry "${registry}"
  podman push "docker://${img}" --tls-verify=false
  echo "${img}"
}

resolve_operator_image() {
  if [[ -n "${ZTWIM_OPERATOR_IMAGE:-}" ]]; then
    echo "${ZTWIM_OPERATOR_IMAGE}"
    return
  fi
  if [[ "${SKIP_BUILD}" == "true" ]]; then
    die "ZTWIM_SKIP_BUILD=true but ZTWIM_OPERATOR_IMAGE is not set"
  fi
  if command_exists podman; then
    build_operator_image_podman
  else
    warn "podman not found; using oc new-build (slower)"
    build_operator_image_oc
  fi
}

build_bundle_image() {
  local operator_img="$1"
  local registry bundle_img csv_file
  registry="$(cluster_registry_host)"
  bundle_img="${registry}/${BUILD_NS}/zero-trust-workload-identity-manager-bundle:v${VERSION}"

  if [[ -n "${ZTWIM_BUNDLE_IMAGE:-}" ]]; then
    echo "${ZTWIM_BUNDLE_IMAGE}"
    return
  fi
  if [[ "${SKIP_BUILD}" == "true" ]]; then
    die "ZTWIM_SKIP_BUILD=true but ZTWIM_BUNDLE_IMAGE is not set"
  fi
  command_exists podman || die "podman required to build the OLM bundle image"

  csv_file="${WORKDIR}/bundle/manifests/zero-trust-workload-identity-manager.clusterserviceversion.yaml"
  [[ -f "${csv_file}" ]] || die "Bundle CSV not found at ${csv_file}"

  log "Patching bundle CSV with operator image ${operator_img}..."
  sed -i.bak -E "s|(image: )openshift.io/zero-trust-workload-identity-manager:.*|\1${operator_img}|" "${csv_file}"

  log "Building and pushing bundle image ${bundle_img}..."
  podman build -f "${WORKDIR}/bundle.Dockerfile" -t "docker://${bundle_img}" "${WORKDIR}"
  podman_login_registry "${registry}"
  podman push "docker://${bundle_img}" --tls-verify=false
  echo "${bundle_img}"
}

install_operator_olm() {
  local bundle_img="$1"
  log "Installing operator bundle via OLM (namespace: ${NAMESPACE})..."
  oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  operator-sdk run bundle "${bundle_img}" \
    --namespace "${NAMESPACE}" \
    --install-mode AllNamespaces \
    --timeout "${BUNDLE_TIMEOUT}" \
    --security-config-map operator-sdk-operator-cache
}

wait_for_csv() {
  log "Waiting for Zero Trust Workload Identity Manager CSV to reach Succeeded..."
  local elapsed=0 timeout=900
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    if ztwim_csv_succeeded; then
      log "Operator CSV is Succeeded"
      return 0
    fi
    sleep 15
    elapsed=$((elapsed + 15))
    warn "  still waiting (${elapsed}s)..."
  done
  die "Timed out waiting for operator CSV. Check: oc get csv,subscription,pods -n ${NAMESPACE}"
}

apply_samples() {
  [[ "${APPLY_SAMPLES}" == "true" ]] || { log "Skipping sample CRs (ZTWIM_APPLY_SAMPLES=${APPLY_SAMPLES})"; return; }
  log "Applying upstream sample SPIFFE/SPIRE CRs..."
  oc apply -k "${WORKDIR}/config/samples/"
  log "Sample CRs applied from config/samples/"
}

print_status() {
  log ""
  log "========================================================="
  log "ZTWIM installation summary"
  log "========================================================="
  oc get csv -n "${NAMESPACE}" 2>/dev/null || true
  oc get pods -n "${NAMESPACE}" 2>/dev/null || true
  log ""
  log "Console: Operators → Installed Operators → filter namespace ${NAMESPACE}"
  log "Docs:    https://github.com/openshift/zero-trust-workload-identity-manager"
}

main() {
  check_prereqs

  if ztwim_csv_succeeded; then
    log "Zero Trust Workload Identity Manager is already installed (CSV Succeeded)"
    apply_samples
    print_status
    exit 0
  fi

  clone_upstream
  ensure_operator_sdk

  local operator_img bundle_img
  operator_img="$(resolve_operator_image)"
  log "Operator image: ${operator_img}"

  bundle_img="$(build_bundle_image "${operator_img}")"
  log "Bundle image: ${bundle_img}"

  install_operator_olm "${bundle_img}"
  wait_for_csv
  apply_samples
  print_status
  log "Done."
}

main "$@"
