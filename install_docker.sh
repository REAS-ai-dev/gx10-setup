#!/bin/bash
# Docker 安裝（通用，Ubuntu，amd64 / arm64 皆可）
# 用來在任何 Ubuntu 機器上裝 Docker（包含 GB10/ARM64 機器）。
#
# 依照 Docker 官方套件安裝（https://docs.docker.com/engine/install/ubuntu/），
# 不用 Snap 版 Docker（Snap 版限制較多，官方也建議一般情境用 apt 套件）。
#
# 用法: bash install_docker.sh
set -e

echo "=== Docker 安裝 ==="

# ── 0. 前置檢查 ────────────────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ 請不要用 root 執行，用一般帳號 + sudo 即可。"
  exit 1
fi

if ! command -v sudo &>/dev/null; then
  echo "❌ 找不到 sudo。"
  exit 1
fi

. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "ubuntu" ]; then
  echo "⚠️  偵測到非 Ubuntu 系統（ID=${ID:-未知}），此腳本走 Ubuntu 官方套件源，仍會嘗試繼續。"
fi

case "$(uname -m)" in
  x86_64|aarch64|arm64)
    ;;
  *)
    echo "⚠️  偵測到 $(uname -m)，Docker 官方 apt 來源沒有這個架構的套件，可能安裝失敗。"
    ;;
esac

if command -v docker &>/dev/null; then
  echo "✅ Docker 已安裝：$(docker --version)"
else
  # ── 1. 移除舊版／衝突套件 ────────────────────────────────────────────────
  echo "[1/5] 移除舊版或衝突的 Docker 套件（若有）..."
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    sudo apt-get remove -y "$pkg" 2>/dev/null || true
  done

  if snap list docker &>/dev/null; then
    echo "  偵測到 Snap 版 Docker，移除中..."
    sudo snap remove docker
  fi

  # ── 2. 設定官方 apt 來源 ─────────────────────────────────────────────────
  echo "[2/5] 設定 Docker 官方 apt 來源..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck source=/dev/null
  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  # ── 3. 安裝 Docker Engine + Compose plugin ─────────────────────────────
  echo "[3/5] 安裝 Docker Engine + Compose plugin..."
  sudo apt-get update
  sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "  ✅ 安裝完成：$(docker --version)"
fi

# ── 4. 讓目前使用者免 sudo 跑 docker ───────────────────────────────────────
echo "[4/5] 設定 docker 群組權限..."
sudo groupadd docker 2>/dev/null || true
NEWLY_ADDED=0
if id -nG "$USER" | grep -qw docker; then
  echo "  使用者 $USER 已在 docker 群組"
else
  sudo usermod -aG docker "$USER"
  NEWLY_ADDED=1
  echo "  已將 $USER 加入 docker 群組"
  echo "  ⚠️  需要登出重新登入（或執行 'newgrp docker'）才會生效"
fi

sudo systemctl enable --now docker

# ── 5. 驗證 ────────────────────────────────────────────────────────────────
echo "[5/5] 驗證安裝..."
echo ""
echo "Docker 版本："
docker --version
echo ""
echo "Compose plugin 版本："
docker compose version

echo ""
echo "=== 完成 ==="
echo "Docker 服務狀態：sudo systemctl status docker"
if [ "$NEWLY_ADDED" -eq 1 ]; then
  echo "提醒：重新登入 shell（或執行 'newgrp docker'）後，執行 'docker ps' 確認不需要 sudo 也能跑。"
fi
