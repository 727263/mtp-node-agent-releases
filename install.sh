#!/usr/bin/env bash
# MTP Node Agent one-click installer (Linux amd64). Run as root.
#
# Network install (recommended):
#   curl -fsSL https://raw.githubusercontent.com/727263/mtp-node-agent-releases/main/install.sh | bash
#
# Local (binary next to this script):
#   sudo bash install.sh
#   sudo FAKETLS_DOMAIN=cloudflare.com bash install.sh
#
# Env: FAKETLS_DOMAIN PUBLIC_IP LISTEN PREFIX SKIP_TZ=1 REPO_BIN RELEASES_REPO
set -euo pipefail

PREFIX="${PREFIX:-/opt/mtp-agent}"
SERVICE_NAME="${SERVICE_NAME:-mtp-agent}"
LISTEN="${LISTEN:-:9100}"
FAKETLS_DOMAIN="${FAKETLS_DOMAIN:-storage.googleapis.com}"
PUBLIC_IP="${PUBLIC_IP:-}"
REPO_BIN="${REPO_BIN:-}"
RELEASES_REPO="${RELEASES_REPO:-727263/mtp-node-agent-releases}"
SKIP_TZ="${SKIP_TZ:-0}"

info() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERR ] $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  error "Please run as root"
fi

# Set Asia/Shanghai so logs/expiry align with Beijing time
set_timezone_shanghai() {
  local target="Asia/Shanghai"
  local current=""
  if [[ "${SKIP_TZ}" == "1" ]]; then
    warn "SKIP_TZ=1, skip timezone"
    return 0
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "${current}" == "${target}" ]]; then
      info "Timezone already ${target}"
      return 0
    fi
    if timedatectl set-timezone "${target}" 2>/dev/null; then
      info "Timezone set to ${target}"
      return 0
    fi
    warn "timedatectl failed, trying /etc/localtime..."
  fi
  if [[ -f "/usr/share/zoneinfo/${target}" ]]; then
    ln -sf "/usr/share/zoneinfo/${target}" /etc/localtime
    echo "${target}" >/etc/timezone 2>/dev/null || true
    info "Timezone set to ${target}"
  else
    warn "zoneinfo/${target} not found, skip timezone"
  fi
}

set_timezone_shanghai

mkdir -p "$PREFIX/bin" "$PREFIX/data"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
TMP_BIN=""
cleanup() {
  if [[ -n "${TMP_BIN}" && -f "${TMP_BIN}" ]]; then
    rm -f "${TMP_BIN}"
  fi
}
trap cleanup EXIT

pick_bin() {
  local c
  for c in \
    "${REPO_BIN}" \
    "${SCRIPT_DIR}/mtp-agent-linux-amd64" \
    "${SCRIPT_DIR}/mtp-agent" \
    "${SCRIPT_DIR}/bin/mtp-agent-linux-amd64" \
    "./mtp-agent-linux-amd64" \
    "./mtp-agent" \
    "./bin/mtp-agent-linux-amd64"
  do
    if [[ -n "$c" && -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

download_bin() {
  local url="https://github.com/${RELEASES_REPO}/releases/latest/download/mtp-agent-linux-amd64"
  TMP_BIN="$(mktemp /tmp/mtp-agent-XXXXXX)"
  info "Binary not found locally, downloading: ${url}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "${TMP_BIN}" "${url}" || error "download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMP_BIN}" "${url}" || error "download failed"
  else
    error "curl or wget required"
  fi
  chmod +x "${TMP_BIN}"
  echo "${TMP_BIN}"
}

SRC_BIN="$(pick_bin || true)"
if [[ -z "${SRC_BIN}" ]]; then
  SRC_BIN="$(download_bin)"
fi
info "Using binary: ${SRC_BIN}"
install -m 755 "${SRC_BIN}" "$PREFIX/bin/mtp-agent"

if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  install -m 644 "${SCRIPT_DIR}/VERSION" "$PREFIX/VERSION"
else
  VER="$(curl -fsSL "https://raw.githubusercontent.com/${RELEASES_REPO}/main/VERSION" 2>/dev/null || true)"
  echo "${VER:-0.2.5}" >"$PREFIX/VERSION"
fi

CFG="$PREFIX/config.yaml"
if [[ ! -f "$CFG" ]]; then
  API_TOKEN="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)"
  PANEL_PASS="$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p)"
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  fi
  cat >"$CFG" <<EOF
listen: "${LISTEN}"
api_token: "${API_TOKEN}"
panel_user: "admin"
panel_pass: "${PANEL_PASS}"
public_ip: "${PUBLIC_IP}"
faketls_domain: "${FAKETLS_DOMAIN}"
data_dir: "${PREFIX}/data"
port_min: 20000
port_max: 50000
concurrency: 4096
tolerate_skew_sec: 30
EOF
  chmod 600 "$CFG"
  echo "==== MTP Node Agent installed ===="
  echo "Panel: http://<IP>${LISTEN}/panel/  (port 9100 if listen is :9100)"
  echo "User: admin"
  echo "Pass: ${PANEL_PASS}"
  echo "API Token: ${API_TOKEN}"
  echo "FakeTLS: ${FAKETLS_DOMAIN}"
  echo "Timezone: Asia/Shanghai"
  echo "Config: ${CFG}"
  echo "Override FakeTLS before first install: FAKETLS_DOMAIN=cloudflare.com bash install.sh"
else
  info "Keep existing config: $CFG"
  # Soft-upgrade reconnect-related defaults without clobbering other settings.
  if ! grep -qE '^tolerate_skew_sec:' "$CFG"; then
    echo "tolerate_skew_sec: 30" >>"$CFG"
    info "Added tolerate_skew_sec: 30"
  fi
  if grep -qE '^concurrency:[[:space:]]*(0|128)[[:space:]]*$' "$CFG"; then
    sed -i.bak -E 's/^concurrency:[[:space:]]*(0|128)[[:space:]]*$/concurrency: 4096/' "$CFG"
    rm -f "${CFG}.bak"
    info "Updated concurrency 128/0 → 4096"
  elif ! grep -qE '^concurrency:' "$CFG"; then
    echo "concurrency: 4096" >>"$CFG"
    info "Added concurrency: 4096"
  fi
fi

cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MTP Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
Environment=TZ=Asia/Shanghai
ExecStart=${PREFIX}/bin/mtp-agent -config ${CFG}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
systemctl --no-pager --full status "${SERVICE_NAME}" || true
echo "Done."
