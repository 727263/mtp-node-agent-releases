#!/usr/bin/env bash
# MTP Node Agent one-click installer (Linux amd64). Run as root.
#
# Network install (recommended):
#   curl -fsSL https://raw.githubusercontent.com/727263/mtp-node-agent-releases/main/install.sh | bash
#   curl -fsSL .../install.sh | PANEL_ALLOW_IP=1.2.3.4,5.6.7.8 bash
#
# Local:
#   sudo bash install.sh
#   sudo FAKETLS_DOMAIN=cloudflare.com bash install.sh
#
# Env:
#   FAKETLS_DOMAIN PUBLIC_IP PANEL_ALLOW_IP LISTEN PREFIX
#   SKIP_TZ=1 SKIP_FIREWALL=1 REPO_BIN RELEASES_REPO
#   AGENT_NOFILE=65536 AGENT_MEM_PERCENT=70
#   PORT_MIN=20000 PORT_MAX=50000
set -euo pipefail

# Capture CLI overrides before defaults / detect
_EXPLICIT_PANEL_ALLOW_IP="${PANEL_ALLOW_IP-}"
_EXPLICIT_PUBLIC_IP="${PUBLIC_IP-}"

PREFIX="${PREFIX:-/opt/mtp-agent}"
SERVICE_NAME="${SERVICE_NAME:-mtp-agent}"
LISTEN="${LISTEN:-:9100}"
FAKETLS_DOMAIN="${FAKETLS_DOMAIN:-storage.googleapis.com}"
PUBLIC_IP="${PUBLIC_IP:-}"
PANEL_ALLOW_IP="${PANEL_ALLOW_IP:-}"
REPO_BIN="${REPO_BIN:-}"
RELEASES_REPO="${RELEASES_REPO:-727263/mtp-node-agent-releases}"
SKIP_TZ="${SKIP_TZ:-0}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
AGENT_NOFILE="${AGENT_NOFILE:-65536}"
AGENT_MEM_PERCENT="${AGENT_MEM_PERCENT:-70}"
PORT_MIN="${PORT_MIN:-20000}"
PORT_MAX="${PORT_MAX:-50000}"

info() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERR ] $*" >&2; exit 1; }

systemctl_ok() {
  local n=0
  while [[ "$n" -lt 3 ]]; do
    if systemctl "$@" 2>/dev/null; then
      return 0
    fi
    n=$((n + 1))
    if [[ "$n" -lt 3 ]]; then
      warn "systemctl $* failed; retry ${n}/3..."
      sleep 2
    fi
  done
  return 1
}

start_service() {
  if systemctl_ok daemon-reload && systemctl_ok enable --now "${SERVICE_NAME}"; then
    return 0
  fi
  warn "systemd/dbus issue on this host; restarting dbus..."
  systemctl restart dbus 2>/dev/null || true
  sleep 2
  if systemctl_ok daemon-reload && systemctl_ok enable --now "${SERVICE_NAME}"; then
    return 0
  fi
  warn "Could not start via systemd. Run manually:"
  warn "  systemctl daemon-reload && systemctl enable --now ${SERVICE_NAME}"
  warn "  or: ${PREFIX}/bin/mtp-agent -config ${CFG}"
  return 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  error "Please run as root"
fi

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

detect_public_ip() {
  curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null \
    || curl -4 -fsS --max-time 5 ip.sb 2>/dev/null \
    || curl -4 -fsS --max-time 5 api.ipify.org 2>/dev/null \
    || true
}

detect_ssh_client_ip() {
  local ip=""
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="${SSH_CLIENT%% *}"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="${SSH_CONNECTION%% *}"
  fi
  if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "${ip}" == *:* ]]; then
    echo "${ip}"
  fi
}

panel_port_from_listen() {
  local p="${LISTEN##*:}"
  if [[ "${p}" =~ ^[0-9]+$ ]]; then
    echo "${p}"
  else
    echo "9100"
  fi
}

yaml_set() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^${key}:" "${file}"; then
    sed -i.bak -E "s|^${key}:.*|${key}: \"${val}\"|" "${file}"
    rm -f "${file}.bak"
  else
    echo "${key}: \"${val}\"" >>"${file}"
  fi
}

yaml_get() {
  local file="$1" key="$2"
  grep -E "^${key}:" "${file}" 2>/dev/null | head -1 \
    | sed -E "s/^${key}:[[:space:]]*//; s/^\"//; s/\"$//; s/^'//; s/'$//" || true
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
  echo "${VER:-0.2.6}" >"$PREFIX/VERSION"
fi

PANEL_PORT="$(panel_port_from_listen)"

# Resolve public IP: explicit CLI > auto-detect (panel_allow_ip is NOT set at install; use panel Settings)
if [[ -z "${_EXPLICIT_PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(detect_public_ip)"
else
  PUBLIC_IP="${_EXPLICIT_PUBLIC_IP}"
fi

if [[ -n "${_EXPLICIT_PANEL_ALLOW_IP}" ]]; then
  PANEL_ALLOW_IP="${_EXPLICIT_PANEL_ALLOW_IP}"
else
  PANEL_ALLOW_IP=""
fi

CFG="$PREFIX/config.yaml"
FRESH_INSTALL=0
API_TOKEN=""
PANEL_PASS=""

if [[ ! -f "$CFG" ]]; then
  FRESH_INSTALL=1
  API_TOKEN="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)"
  PANEL_PASS="$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p)"
  cat >"$CFG" <<EOF
listen: "${LISTEN}"
api_token: "${API_TOKEN}"
panel_user: "admin"
panel_pass: "${PANEL_PASS}"
public_ip: "${PUBLIC_IP}"
panel_allow_ip: "${PANEL_ALLOW_IP}"
faketls_domain: "${FAKETLS_DOMAIN}"
data_dir: "${PREFIX}/data"
port_min: ${PORT_MIN}
port_max: ${PORT_MAX}
concurrency: 4096
tolerate_skew_sec: 30
EOF
  chmod 600 "$CFG"
else
  info "Keep existing config: $CFG"
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

  # public_ip: CLI overrides; else fill if empty
  if [[ -n "${_EXPLICIT_PUBLIC_IP}" ]]; then
    yaml_set "$CFG" "public_ip" "${_EXPLICIT_PUBLIC_IP}"
    PUBLIC_IP="${_EXPLICIT_PUBLIC_IP}"
  else
    cur="$(yaml_get "$CFG" "public_ip")"
    if [[ -z "${cur}" && -n "${PUBLIC_IP}" ]]; then
      yaml_set "$CFG" "public_ip" "${PUBLIC_IP}"
    elif [[ -n "${cur}" ]]; then
      PUBLIC_IP="${cur}"
    fi
  fi

  # panel_allow_ip: only explicit CLI overrides; otherwise keep existing or leave empty
  if [[ -n "${_EXPLICIT_PANEL_ALLOW_IP}" ]]; then
    yaml_set "$CFG" "panel_allow_ip" "${_EXPLICIT_PANEL_ALLOW_IP}"
    PANEL_ALLOW_IP="${_EXPLICIT_PANEL_ALLOW_IP}"
  else
    cur="$(yaml_get "$CFG" "panel_allow_ip")"
    PANEL_ALLOW_IP="${cur}"
    if ! grep -qE '^panel_allow_ip:' "$CFG"; then
      echo "panel_allow_ip: \"\"" >>"$CFG"
    fi
  fi

  cur_min="$(yaml_get "$CFG" "port_min")"
  cur_max="$(yaml_get "$CFG" "port_max")"
  [[ -n "${cur_min}" ]] && PORT_MIN="${cur_min}"
  [[ -n "${cur_max}" ]] && PORT_MAX="${cur_max}"
fi

if [[ -n "${PUBLIC_IP}" ]]; then
  info "Public IP: ${PUBLIC_IP}"
else
  warn "Could not detect public IP; set PUBLIC_IP=... or in panel"
fi
if [[ -n "${PANEL_ALLOW_IP}" ]]; then
  info "Panel/API allow IPs: ${PANEL_ALLOW_IP}"
else
  info "Panel/API IP filter: off (set panel_allow_ip in panel Settings after login)"
fi

# systemd + resource limits
MEM_BYTES=""
if [[ "${AGENT_MEM_PERCENT}" =~ ^[0-9]+$ ]] && [[ "${AGENT_MEM_PERCENT}" -gt 0 ]]; then
  MEM_BYTES="$(awk -v p="${AGENT_MEM_PERCENT}" \
    '/^MemTotal:/ {printf "%d", $2 * 1024 / 100 * p}' /proc/meminfo 2>/dev/null || true)"
fi

{
  cat <<EOF
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
LimitNOFILE=${AGENT_NOFILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF
  if [[ -n "${MEM_BYTES}" && "${MEM_BYTES}" -gt 0 ]]; then
    echo "MemoryAccounting=yes"
    echo "MemoryMax=${MEM_BYTES}"
    info "Resource limits: NOFILE=${AGENT_NOFILE} MemoryMax=$((MEM_BYTES / 1024 / 1024)) MiB (${AGENT_MEM_PERCENT}%)"
  else
    info "Resource limits: NOFILE=${AGENT_NOFILE} (no MemoryMax)"
  fi
  cat <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
} >/etc/systemd/system/${SERVICE_NAME}.service

# ---------- firewall ----------
iptables_rebuild_panel_allow() {
  local port="$1"
  local ip
  while iptables -D INPUT -p tcp --dport "${port}" -j DROP -m comment --comment "mtp-agent-api-deny" 2>/dev/null; do :; done
  while iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT -m comment --comment "mtp-agent-api" 2>/dev/null; do :; done
  while iptables -D INPUT -p tcp -s 127.0.0.1 --dport "${port}" -j ACCEPT -m comment --comment "mtp-agent-api-local" 2>/dev/null; do :; done
  if [[ -n "${PANEL_ALLOW_IP}" ]]; then
    IFS=',' read -ra _ips <<< "${PANEL_ALLOW_IP}"
    for ip in "${_ips[@]}"; do
      ip="$(echo "${ip}" | xargs)"
      [[ -n "${ip}" ]] || continue
      while iptables -D INPUT -p tcp -s "${ip}" --dport "${port}" -j ACCEPT -m comment --comment "mtp-agent-api" 2>/dev/null; do :; done
    done
    iptables -I INPUT -p tcp --dport "${port}" -j DROP -m comment --comment "mtp-agent-api-deny" || true
    iptables -I INPUT -p tcp -s 127.0.0.1 --dport "${port}" -j ACCEPT -m comment --comment "mtp-agent-api-local" || true
    for ip in "${_ips[@]}"; do
      ip="$(echo "${ip}" | xargs)"
      [[ -n "${ip}" ]] || continue
      iptables -I INPUT -p tcp -s "${ip}" --dport "${port}" -j ACCEPT -m comment --comment "mtp-agent-api" || true
    done
  else
    iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT -m comment --comment "mtp-agent-api" || true
  fi
}

persist_iptables() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1 && [[ -f /etc/init.d/iptables ]]; then
    service iptables save >/dev/null 2>&1 || true
  else
    mkdir -p /etc/iptables
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
  fi
}

open_firewall() {
  if [[ "${SKIP_FIREWALL}" == "1" ]]; then
    warn "SKIP_FIREWALL=1, skip firewall"
    return 0
  fi
  if [[ "${PORT_MIN}" -gt "${PORT_MAX}" ]]; then
    warn "invalid port range ${PORT_MIN}-${PORT_MAX}, skip firewall"
    return 0
  fi

  local opened=0
  local allow_note="any"
  local ip
  [[ -n "${PANEL_ALLOW_IP}" ]] && allow_note="${PANEL_ALLOW_IP}"

  if command -v ufw >/dev/null 2>&1; then
    info "UFW: panel ${PANEL_PORT}←${allow_note}; MTP ${PORT_MIN}:${PORT_MAX}"
    ufw delete allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    if [[ -n "${PANEL_ALLOW_IP}" ]]; then
      IFS=',' read -ra _ips <<< "${PANEL_ALLOW_IP}"
      for ip in "${_ips[@]}"; do
        ip="$(echo "${ip}" | xargs)"
        [[ -n "${ip}" ]] || continue
        ufw allow from "${ip}" to any port "${PANEL_PORT}" proto tcp comment 'mtp-agent-api' >/dev/null 2>&1 || true
      done
    else
      ufw allow "${PANEL_PORT}/tcp" comment 'mtp-agent-api' >/dev/null 2>&1 || true
    fi
    ufw allow "${PORT_MIN}:${PORT_MAX}/tcp" comment 'mtp-accounts' >/dev/null 2>&1 || true
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      info "UFW active"
    else
      warn "UFW inactive; rules written. Enable carefully after allowing SSH: ufw enable"
    fi
    opened=1
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld: panel←${allow_note}; MTP ${PORT_MIN}-${PORT_MAX}"
    firewall-cmd --permanent --remove-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    if [[ -n "${PANEL_ALLOW_IP}" ]]; then
      IFS=',' read -ra _ips <<< "${PANEL_ALLOW_IP}"
      for ip in "${_ips[@]}"; do
        ip="$(echo "${ip}" | xargs)"
        [[ -n "${ip}" ]] || continue
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${ip}\" port port=\"${PANEL_PORT}\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      done
    else
      firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    firewall-cmd --permanent --add-port="${PORT_MIN}-${PORT_MAX}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    opened=1
  fi

  if command -v iptables >/dev/null 2>&1; then
    info "iptables: panel←${allow_note}; MTP ${PORT_MIN}:${PORT_MAX}"
    iptables_rebuild_panel_allow "${PANEL_PORT}"
    if ! iptables -C INPUT -p tcp --dport "${PORT_MIN}:${PORT_MAX}" -j ACCEPT -m comment --comment "mtp-accounts" 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${PORT_MIN}:${PORT_MAX}" -j ACCEPT -m comment --comment "mtp-accounts" || true
    fi
    persist_iptables
    opened=1
  fi

  if [[ "${opened}" -eq 0 ]]; then
    warn "No UFW/firewalld/iptables; configure cloud security group:"
    warn "  panel ${PANEL_PORT}/tcp only from: ${allow_note}"
    warn "  MTP ${PORT_MIN}-${PORT_MAX}/tcp"
  else
    warn "Also mirror rules in cloud security group if any"
  fi
}

open_firewall

start_service || true
systemctl --no-pager --full status "${SERVICE_NAME}" 2>/dev/null || true

SHOW_IP="${PUBLIC_IP:-YOUR_IP}"
echo
if [[ "${FRESH_INSTALL}" -eq 1 ]]; then
  echo "==== MTP Node Agent installed ===="
  echo "Panel: http://${SHOW_IP}:${PANEL_PORT}/panel/"
  echo "User: admin"
  echo "Pass: ${PANEL_PASS}"
  echo "API Token: ${API_TOKEN}"
else
  echo "==== MTP Node Agent updated ===="
  echo "Panel: http://${SHOW_IP}:${PANEL_PORT}/panel/"
fi
echo "Public IP: ${SHOW_IP}"
echo "Panel allow IP: ${PANEL_ALLOW_IP:-'(none — configure in panel Settings)'}"
echo "FakeTLS: ${FAKETLS_DOMAIN}"
echo "MTP ports: ${PORT_MIN}-${PORT_MAX}"
echo "Limits: NOFILE=${AGENT_NOFILE} MEM%=${AGENT_MEM_PERCENT}"
echo "Config: ${CFG}"
echo "Optional CLI: PANEL_ALLOW_IP=1.2.3.4 bash install.sh"
echo "Locked out? SSH in, set panel_allow_ip: \"\" in ${CFG}, restart ${SERVICE_NAME}"
echo "Done."
