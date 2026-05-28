#!/usr/bin/env bash
# Build the openshift-days-ops-showroom static site with Antora (writes to ./www).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

if [[ ! -f "${SHOWROOM_SITE_YML}" ]]; then
  echo "ERROR: Antora playbook not found: ${SHOWROOM_SITE_YML}" >&2
  exit 1
fi

cd "${SHOWROOM_REPO_ROOT}"

echo "Removing previous site under www/..."
mkdir -p www
rm -rf www/*

echo "Building Antora site from ${SHOWROOM_SITE_YML}..."
if command -v antora >/dev/null 2>&1; then
  antora generate "${SHOWROOM_SITE_YML}" --stacktrace
else
  npx -y @antora/cli@3.1 @antora/site-generator@3.1
  npx -y @antora/cli@3.1 antora generate "${SHOWROOM_SITE_YML}" --stacktrace
fi

echo "Build complete: ${SHOWROOM_WWW}"
echo "Serve locally with: ${SCRIPT_DIR}/serve.sh"
