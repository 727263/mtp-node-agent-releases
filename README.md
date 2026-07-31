# MTP Node Agent Releases

本仓库**仅发布安装脚本与 Linux 二进制**，用于节点一键升级。

- 源码不公开
- 下载：右侧 Releases 中的 `mtp-agent-linux-amd64`
- 版本号见根目录 `VERSION`

安装示例（一键，自动设 Asia/Shanghai 时区并拉最新二进制）:

```bash
curl -fsSL https://github.com/727263/mtp-node-agent-releases/releases/latest/download/install.sh | bash
```

或分步下载后再装:

```bash
curl -fsSL -o install.sh https://github.com/727263/mtp-node-agent-releases/releases/latest/download/install.sh
curl -fsSL -o mtp-agent-linux-amd64 https://github.com/727263/mtp-node-agent-releases/releases/latest/download/mtp-agent-linux-amd64
chmod +x install.sh mtp-agent-linux-amd64
sudo bash install.sh
```

可选环境变量: `FAKETLS_DOMAIN`、`PUBLIC_IP`、`LISTEN`、`SKIP_TZ=1`（跳过时区）。
