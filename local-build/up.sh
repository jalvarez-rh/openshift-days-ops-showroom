#!/usr/bin/env bash
# Build openshift-days-ops-showroom and serve it with Podman (one-shot local preview).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/build.sh"
"${SCRIPT_DIR}/serve.sh"
