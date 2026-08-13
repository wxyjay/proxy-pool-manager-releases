#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/install-ppm-swift-backend.sh"
README="${ROOT_DIR}/README.md"

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "Expected ${file} to contain: ${needle}" >&2
    exit 1
  fi
}

bash -n "$SCRIPT"

assert_contains "$SCRIPT" "--install-vpngate-deps"
assert_contains "$SCRIPT" "--skip-vpngate-deps"
assert_contains "$SCRIPT" "--purge-vpngate-deps"
assert_contains "$SCRIPT" "ensure_vpngate_runtime_dependencies"
assert_contains "$SCRIPT" "ip) echo \"iproute2\""
assert_contains "$SCRIPT" "slirp4netns) echo \"slirp4netns\""
assert_contains "$SCRIPT" "openvpn) echo \"openvpn\""
assert_contains "$SCRIPT" "remove_vpngate_dependencies_if_requested"
assert_contains "$SCRIPT" "safe_vpngate_purge_package"
assert_contains "$SCRIPT" "Skipping package removal for iproute2"

assert_contains "$README" "--skip-vpngate-deps"
assert_contains "$README" "--purge-vpngate-deps"
