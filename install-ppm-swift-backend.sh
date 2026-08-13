#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="proxy-pool-manager-swift-backend"
DISPLAY_NAME="PPM Swift Backend"
RELEASE_REPO="${RELEASE_REPO:-wxyjay/proxy-pool-manager-releases}"
INSTALL_DIR="${INSTALL_DIR:-/opt/proxy-pool-manager-swift-backend}"
DATA_DIR="${DATA_DIR:-/var/lib/proxy-pool-manager-swift-backend}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_STATE_DIR="${DATA_DIR}/installer"
VPNGATE_DEPS_STATE_FILE="${INSTALL_STATE_DIR}/vpngate-installed-packages.txt"
LEGACY_SERVICE_NAME="LunchProxyPoolManager"
LEGACY_WORKING_DIR="/download/LunchProxyPoolManager"
LEGACY_UNIT_FILE="/etc/systemd/system/${LEGACY_SERVICE_NAME}.service"
BRANCH="main"
ACTION=""
MIGRATE_LEGACY="false"
VPNGATE_DEPS_MODE="auto"
PURGE_VPNGATE_DEPS="false"
TMP_DIR_TO_CLEAN=""

cleanup_tmp_dir() {
  if [[ -n "${TMP_DIR_TO_CLEAN:-}" ]]; then
    rm -rf "$TMP_DIR_TO_CLEAN"
  fi
}

trap cleanup_tmp_dir EXIT

usage() {
  cat <<'EOF'
Usage:
  install-ppm-swift-backend.sh [--branch main|debug] [--migrate-legacy] [--install|--uninstall|--purge|--status|--interactive]
  install-ppm-swift-backend.sh [--install-vpngate-deps|--skip-vpngate-deps] [--purge-vpngate-deps]

Environment:
  RELEASE_REPO  Public release repo, default wxyjay/proxy-pool-manager-releases.
  INSTALL_DIR   Program directory, default /opt/proxy-pool-manager-swift-backend.
  DATA_DIR      Runtime data directory, default /var/lib/proxy-pool-manager-swift-backend.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --install)
      ACTION="install"
      shift
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    --purge)
      ACTION="purge"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --interactive)
      ACTION="interactive"
      shift
      ;;
    --migrate-legacy|--migrate-legacy-data)
      MIGRATE_LEGACY="true"
      shift
      ;;
    --install-vpngate-deps)
      VPNGATE_DEPS_MODE="required"
      shift
      ;;
    --skip-vpngate-deps|--no-vpngate-deps)
      VPNGATE_DEPS_MODE="skip"
      shift
      ;;
    --purge-vpngate-deps)
      PURGE_VPNGATE_DEPS="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$BRANCH" != "main" && "$BRANCH" != "debug" ]]; then
  echo "--branch must be main or debug." >&2
  exit 1
fi

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

missing_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  printf '%s\n' "${missing[@]}"
}

have_sha256_tool() {
  command -v sha256sum >/dev/null 2>&1 ||
    command -v shasum >/dev/null 2>&1 ||
    command -v openssl >/dev/null 2>&1
}

install_missing_dependencies() {
  local missing=("$@")
  local packages=()
  local cmd

  if command -v apt-get >/dev/null 2>&1; then
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        curl) packages+=("curl") ;;
        tar) packages+=("tar") ;;
        systemctl) packages+=("systemd") ;;
        awk) packages+=("mawk") ;;
        sed) packages+=("sed") ;;
        grep) packages+=("grep") ;;
        find) packages+=("findutils") ;;
        shasum) packages+=("perl") ;;
        sha256-tool|sha256sum|openssl) packages+=("openssl") ;;
        mktemp|head|dirname|mv|cp|rm|chmod|mkdir|cat|id|uname) packages+=("coreutils") ;;
        *) packages+=("$cmd") ;;
      esac
    done
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
    return
  fi

  echo "No supported package manager found to install missing dependencies: ${missing[*]}" >&2
  exit 1
}

vpngate_package_for_command() {
  case "$1" in
    ip) echo "iproute2" ;;
    slirp4netns) echo "slirp4netns" ;;
    openvpn) echo "openvpn" ;;
    *) echo "$1" ;;
  esac
}

apt_package_installed() {
  local package="$1"
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
}

record_vpngate_installed_packages() {
  local packages=("$@")
  local package
  [[ "${#packages[@]}" -gt 0 ]] || return 0

  mkdir -p "$INSTALL_STATE_DIR"
  touch "$VPNGATE_DEPS_STATE_FILE"
  for package in "${packages[@]}"; do
    if ! grep -Fxq "$package" "$VPNGATE_DEPS_STATE_FILE"; then
      printf '%s\n' "$package" >> "$VPNGATE_DEPS_STATE_FILE"
    fi
  done
}

install_vpngate_missing_dependencies() {
  local missing=("$@")
  local packages=()
  local newly_required=()
  local installed_by_script=()
  local cmd package

  if ! command -v apt-get >/dev/null 2>&1; then
    if [[ "$VPNGATE_DEPS_MODE" == "required" ]]; then
      echo "No supported package manager found for VPNGate dependencies: ${missing[*]}" >&2
      exit 1
    fi
    echo "Skipping VPNGate dependency installation: no supported package manager found (${missing[*]})." >&2
    return 0
  fi

  for cmd in "${missing[@]}"; do
    package="$(vpngate_package_for_command "$cmd")"
    packages+=("$package")
    if ! apt_package_installed "$package"; then
      newly_required+=("$package")
    fi
  done

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

  for package in "${newly_required[@]}"; do
    if apt_package_installed "$package"; then
      installed_by_script+=("$package")
    fi
  done
  record_vpngate_installed_packages "${installed_by_script[@]}"
}

ensure_vpngate_runtime_dependencies() {
  if [[ "$VPNGATE_DEPS_MODE" == "skip" ]]; then
    echo "Skipping VPNGate runtime dependency installation."
    return 0
  fi

  local required=(ip slirp4netns openvpn)
  local missing=()
  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] && missing+=("$item")
  done < <(missing_commands "${required[@]}")

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Missing VPNGate runtime dependencies: ${missing[*]}"
    install_vpngate_missing_dependencies "${missing[@]}"
  fi

  if [[ ! -e /dev/net/tun ]]; then
    echo "Warning: /dev/net/tun is missing. VPNGate workers require tun support on the host." >&2
  fi
}

safe_vpngate_purge_package() {
  local package="$1"
  case "$package" in
    slirp4netns|openvpn)
      ;;
    iproute2)
      echo "Skipping package removal for iproute2."
      return 0
      ;;
    *)
      echo "Skipping package removal for unrecognized VPNGate package: ${package}"
      return 0
      ;;
  esac

  if command -v apt-get >/dev/null 2>&1; then
    apt-get remove -y "$package" || true
    return 0
  fi

  echo "No supported package manager found to remove VPNGate package: ${package}" >&2
}

remove_vpngate_dependencies_if_requested() {
  [[ "$PURGE_VPNGATE_DEPS" == "true" ]] || return 0

  if [[ ! -f "$VPNGATE_DEPS_STATE_FILE" ]]; then
    echo "No VPNGate dependency state file found. Leaving system packages unchanged."
    return 0
  fi

  local package
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    safe_vpngate_purge_package "$package"
  done < "$VPNGATE_DEPS_STATE_FILE"
  rm -f "$VPNGATE_DEPS_STATE_FILE"
}

ensure_dependencies() {
  local profile="${1:-install}"
  local required=(mktemp sed awk grep head dirname find mv cp rm chmod mkdir cat id uname)
  local needs_sha="false"
  case "$profile" in
    install)
      required+=(curl tar systemctl)
      needs_sha="true"
      ;;
    systemd)
      required+=(systemctl)
      ;;
    *)
      echo "Unsupported dependency profile: ${profile}" >&2
      exit 1
      ;;
  esac

  local missing=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && missing+=("$item")
  done < <(missing_commands "${required[@]}")
  if [[ "$needs_sha" == "true" ]] && ! have_sha256_tool; then
    missing+=("sha256-tool")
  fi

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi

  echo "Missing required dependencies: ${missing[*]}" >&2
  if [[ -t 0 ]]; then
    read -r -p "Install missing dependencies now? [Y/n] " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
      echo "Dependency installation skipped. Exiting." >&2
      exit 1
    fi
    install_missing_dependencies "${missing[@]}"
  else
    echo "Non-interactive mode cannot install dependencies safely. Please install them first, then rerun." >&2
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
    return 0
  fi
  echo "Missing sha256sum, shasum, or openssl." >&2
  exit 1
}

normalize_unit_path() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s\n' "$value"
}

legacy_unit_working_dir() {
  systemctl cat "${LEGACY_SERVICE_NAME}.service" 2>/dev/null \
    | awk -F= '/^[[:space:]]*WorkingDirectory[[:space:]]*=/ { value=$2 } END { print value }'
}

legacy_service_needs_migration() {
  local working_dir
  working_dir="$(legacy_unit_working_dir || true)"
  working_dir="$(normalize_unit_path "$working_dir")"
  [[ "$working_dir" == "$LEGACY_WORKING_DIR" ]]
}

remove_legacy_service() {
  echo "Stopping and removing legacy service: ${LEGACY_SERVICE_NAME}"
  systemctl stop "${LEGACY_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${LEGACY_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "$LEGACY_UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "${LEGACY_SERVICE_NAME}.service" >/dev/null 2>&1 || true
}

migrate_legacy_directory() {
  local name="$1"
  local source_dir="$2"
  local target_dir="$3"
  local target_parent
  target_parent="$(dirname "$target_dir")"
  mkdir -p "$target_parent"

  if [[ ! -d "$source_dir" ]]; then
    echo "Legacy ${name} directory not found: ${source_dir}. Skipping."
    return 0
  fi

  if [[ -e "$target_dir" ]]; then
    if find "$target_dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      echo "Migration failed: target ${name} directory already exists and is not empty: ${target_dir}" >&2
      exit 1
    fi
    rmdir "$target_dir" 2>/dev/null || {
      echo "Migration failed: target ${name} path exists but is not an empty directory: ${target_dir}" >&2
      exit 1
    }
  fi

  echo "Migrating legacy ${name}: ${source_dir} -> ${target_dir}"
  mv "$source_dir" "$target_dir"
}

migrate_legacy_data_if_requested() {
  [[ "$MIGRATE_LEGACY" == "true" ]] || return 0

  require_root
  need_cmd systemctl

  if ! systemctl cat "${LEGACY_SERVICE_NAME}.service" >/dev/null 2>&1; then
    echo "Legacy service ${LEGACY_SERVICE_NAME} not found. Skipping legacy migration."
    return 0
  fi

  if ! legacy_service_needs_migration; then
    local working_dir
    working_dir="$(normalize_unit_path "$(legacy_unit_working_dir || true)")"
    echo "Legacy service exists but WorkingDirectory is not ${LEGACY_WORKING_DIR} (${working_dir:-unknown}). Skipping legacy migration."
    return 0
  fi

  echo "Legacy service detected with WorkingDirectory=${LEGACY_WORKING_DIR}."
  remove_legacy_service

  mkdir -p "$DATA_DIR"
  migrate_legacy_directory "config" "${LEGACY_WORKING_DIR}/config" "${DATA_DIR}/config"
  migrate_legacy_directory "data" "${LEGACY_WORKING_DIR}/data" "${DATA_DIR}/data"
  echo "Legacy data migration completed."
}

manifest_url() {
  local channel="$1"
  printf 'https://raw.githubusercontent.com/%s/%s/manifests/swift-backend/%s.json' "$RELEASE_REPO" "$BRANCH" "$channel"
}

extract_asset_sha() {
  local manifest="$1"
  local asset="$2"
  awk -v target="$asset" '
    index($0, "\"name\"") {
      line=$0
      sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      current=line
    }
    index($0, "\"sha256\"") && current == target {
      line=$0
      sub(/^.*"sha256"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$manifest"
}

download_asset() {
  local arch="$1"
  local channel="stable"
  [[ "$BRANCH" == "debug" ]] && channel="debug"
  local tmp_dir="$2"
  local manifest="${tmp_dir}/manifest.json"
  local tag asset expected_sha archive url actual_sha

  curl -fsSL "$(manifest_url "$channel")" -o "$manifest"
  tag="$(sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)"
  asset="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*linux-'"${arch}"'\.tar\.gz\)".*/\1/p' "$manifest" | head -n 1)"
  if [[ -z "$tag" || -z "$asset" ]]; then
    echo "No swift-backend asset found for arch=${arch} in ${channel} manifest." >&2
    exit 1
  fi
  expected_sha="$(extract_asset_sha "$manifest" "$asset" || true)"
  if [[ -z "$expected_sha" ]]; then
    echo "No SHA256 found for asset=${asset} in ${channel} manifest." >&2
    exit 1
  fi
  url="https://github.com/${RELEASE_REPO}/releases/download/${tag}/${asset}"
  archive="${tmp_dir}/${asset}"
  curl -fL "$url" -o "$archive"
  actual_sha="$(sha256_file "$archive")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "SHA256 mismatch for ${asset}: got ${actual_sha}, expected ${expected_sha}" >&2
    exit 1
  fi
  printf '%s\n' "$archive"
}

write_unit() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=${DISPLAY_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
Environment=PPM_ROOT=${DATA_DIR}
ExecStart=${INSTALL_DIR}/LunchProxyPoolManager --root ${DATA_DIR}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

install_or_update() {
  ensure_dependencies install
  mkdir -p "$DATA_DIR"
  ensure_vpngate_runtime_dependencies
  migrate_legacy_data_if_requested

  local arch tmp_dir archive
  arch="$(detect_arch)"
  TMP_DIR_TO_CLEAN="$(mktemp -d)"
  tmp_dir="$TMP_DIR_TO_CLEAN"

  echo "Installing ${DISPLAY_NAME} (${BRANCH}, ${arch})"
  archive="$(download_asset "$arch" "$tmp_dir")"

  mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  if [[ -x "${INSTALL_DIR}/LunchProxyPoolManager" ]]; then
    cp -f "${INSTALL_DIR}/LunchProxyPoolManager" "${INSTALL_DIR}/LunchProxyPoolManager.bak"
  fi
  tar -xzf "$archive" -C "$INSTALL_DIR"
  chmod +x "${INSTALL_DIR}/LunchProxyPoolManager"
  write_unit
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  systemctl --no-pager status "$SERVICE_NAME" || true
}

uninstall_keep_data() {
  ensure_dependencies systemd
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  remove_vpngate_dependencies_if_requested
  echo "Removed program files. Data preserved at ${DATA_DIR}."
}

purge_all() {
  uninstall_keep_data
  rm -rf "$DATA_DIR"
  echo "Removed data directory: ${DATA_DIR}"
}

show_status() {
  ensure_dependencies systemd
  systemctl --no-pager status "$SERVICE_NAME" || true
}

interactive_menu() {
  echo "${DISPLAY_NAME} installer"
  echo "1) Install or update"
  echo "2) Uninstall (keep data)"
  echo "3) Purge (remove data)"
  echo "4) Status"
  read -r -p "Choose: " choice
  case "$choice" in
    1)
      read -r -p "Branch main/debug (Enter keeps ${BRANCH}): " input_branch
      BRANCH="${input_branch:-$BRANCH}"
      install_or_update
      ;;
    2) uninstall_keep_data ;;
    3) purge_all ;;
    4) show_status ;;
    *) echo "Cancelled." ;;
  esac
}

if [[ -z "$ACTION" ]]; then
  if [ -t 0 ]; then
    ACTION="interactive"
  else
    ACTION="install"
  fi
fi

require_root

case "$ACTION" in
  install) install_or_update ;;
  uninstall) uninstall_keep_data ;;
  purge) purge_all ;;
  status) show_status ;;
  interactive) interactive_menu ;;
  *) usage; exit 1 ;;
esac
