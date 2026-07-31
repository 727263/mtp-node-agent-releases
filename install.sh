#!/usr/bin/env bash
# MTP Node Agent 涓€閿畨瑁咃紙Linux amd64锛夈€傝鐢?root 杩愯銆?#
# 缃戠粶涓€閿紙鎺ㄨ崘锛?
#   curl -fsSL https://github.com/727263/mtp-node-agent-releases/releases/latest/download/install.sh | bash
#
# 鏈湴锛堜簩杩涘埗涓庤剼鏈悓鐩綍锛?
#   sudo bash install.sh
#   sudo FAKETLS_DOMAIN=cloudflare.com bash install.sh
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
  error "璇蜂娇鐢?root 杩愯"
fi

# 瀹夎鍓嶇粺涓€涓婃捣鏃跺尯锛岄伩鍏嶆棩蹇?鍒版湡涓庡寳浜椂闂撮敊浣?set_timezone_shanghai() {
  local target="Asia/Shanghai"
  local current=""
  if [[ "${SKIP_TZ}" == "1" ]]; then
    warn "宸茶缃?SKIP_TZ=1锛岃烦杩囨椂鍖?
    return 0
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "${current}" == "${target}" ]]; then
      info "鏃跺尯宸叉槸 ${target}锛岃烦杩?
      return 0
    fi
    if timedatectl set-timezone "${target}" 2>/dev/null; then
      info "鏃跺尯宸茶涓?${target}"
      return 0
    fi
    warn "timedatectl 璁剧疆鏃跺尯澶辫触锛屽皾璇曟墜鍔ㄥ啓鍏?.."
  fi
  if [[ -f "/usr/share/zoneinfo/${target}" ]]; then
    ln -sf "/usr/share/zoneinfo/${target}" /etc/localtime
    echo "${target}" >/etc/timezone 2>/dev/null || true
    info "鏃跺尯宸茶涓?${target}"
  else
    warn "鏈壘鍒?zoneinfo/${target}锛岃烦杩囨椂鍖鸿缃?
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
  info "鏈満鏈壘鍒颁簩杩涘埗锛屾鍦ㄤ笅杞? ${url}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "${TMP_BIN}" "${url}" || error "涓嬭浇澶辫触"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMP_BIN}" "${url}" || error "涓嬭浇澶辫触"
  else
    error "闇€瑕?curl 鎴?wget"
  fi
  chmod +x "${TMP_BIN}"
  echo "${TMP_BIN}"
}

SRC_BIN="$(pick_bin || true)"
if [[ -z "${SRC_BIN}" ]]; then
  SRC_BIN="$(download_bin)"
fi
info "浣跨敤浜岃繘鍒? ${SRC_BIN}"
install -m 755 "${SRC_BIN}" "$PREFIX/bin/mtp-agent"

# Ship VERSION next to install root (for /api/agent/info)
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  install -m 644 "${SCRIPT_DIR}/VERSION" "$PREFIX/VERSION"
elif [[ ! -f "$PREFIX/VERSION" ]]; then
  VER="$(curl -fsSL "https://raw.githubusercontent.com/${RELEASES_REPO}/main/VERSION" 2>/dev/null || true)"
  echo "${VER:-0.2.4}" >"$PREFIX/VERSION"
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
concurrency: 128
EOF
  chmod 600 "$CFG"
  echo "==== MTP Node Agent 宸插畨瑁?===="
  echo "闈㈡澘: http://<IP>${LISTEN}/panel/  (鑻?listen 涓?:9100 鍒欑鍙?9100)"
  echo "鐢ㄦ埛: admin"
  echo "瀵嗙爜: ${PANEL_PASS}"
  echo "API Token: ${API_TOKEN}"
  echo "FakeTLS: ${FAKETLS_DOMAIN}"
  echo "鏃跺尯: Asia/Shanghai"
  echo "閰嶇疆: ${CFG}"
  echo "鍙敤 FAKETLS_DOMAIN=cloudflare.com 閲嶆柊瀹夎鍓嶆敼鍩熷悕锛堜粎鏂拌鍐欏叆锛涘凡鏈夐厤缃缂栬緫 config.yaml锛?
else
  info "淇濈暀宸叉湁閰嶇疆: $CFG"
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
echo "瀹屾垚銆?
