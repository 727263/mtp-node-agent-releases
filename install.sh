#!/usr/bin/env bash
# MTP Node Agent installer (Linux). Run as root.
set -euo pipefail

PREFIX="${PREFIX:-/opt/mtp-agent}"
SERVICE_NAME="${SERVICE_NAME:-mtp-agent}"
LISTEN="${LISTEN:-:9100}"
FAKETLS_DOMAIN="${FAKETLS_DOMAIN:-storage.googleapis.com}"
PUBLIC_IP="${PUBLIC_IP:-}"
REPO_BIN="${REPO_BIN:-}"  # optional path to prebuilt binary

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 运行" >&2
  exit 1
fi

mkdir -p "$PREFIX/bin" "$PREFIX/data"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

SRC_BIN="$(pick_bin || true)"
if [[ -z "${SRC_BIN}" ]]; then
  echo "未找到二进制。请把 mtp-agent-linux-amd64 和 install.sh 放同一目录，或:" >&2
  echo "  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o mtp-agent ./cmd/agent" >&2
  echo "  REPO_BIN=/path/to/mtp-agent-linux-amd64 bash install.sh" >&2
  exit 1
fi
echo "使用二进制: ${SRC_BIN}"
install -m 755 "${SRC_BIN}" "$PREFIX/bin/mtp-agent"

# Ship VERSION next to install root (for /api/agent/info)
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  install -m 644 "${SCRIPT_DIR}/VERSION" "$PREFIX/VERSION"
elif [[ ! -f "$PREFIX/VERSION" ]]; then
  echo "0.2.0" >"$PREFIX/VERSION"
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
  echo "==== MTP Node Agent 已安装 ===="
  echo "面板: http://<IP>${LISTEN}/panel/  (若 listen 为 :9100 则端口 9100)"
  echo "用户: admin"
  echo "密码: ${PANEL_PASS}"
  echo "API Token: ${API_TOKEN}"
  echo "FakeTLS: ${FAKETLS_DOMAIN}"
  echo "配置: ${CFG}"
  echo "可用 FAKETLS_DOMAIN=cloudflare.com 重新安装前改域名（仅新装写入；已有配置请编辑 config.yaml）"
else
  echo "保留已有配置: $CFG"
fi

cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MTP Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
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
echo "完成。"
