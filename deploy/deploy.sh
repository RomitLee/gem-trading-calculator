#!/usr/bin/env bash
# 子霖宝石助手 —— 部署到腾讯云服务器（服务器已装 Caddy，HTTPS 证书自动签发）
# 用法（本机 Git Bash 执行，需服务器 22 端口可达）：
#   SSH_HOST="ubuntu@43.132.148.55" DOMAIN="gem.maipi.top" REMOTE_ROOT="/var/www/gem" ./deploy.sh
set -euo pipefail

SSH_HOST="${SSH_HOST:-ubuntu@43.132.148.55}"
SSH_PORT="${SSH_PORT:-22}"
DOMAIN="${DOMAIN:-gem.maipi.top}"
REMOTE_ROOT="${REMOTE_ROOT:-/var/www/gem}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)

echo "==> 目标 ${SSH_HOST}  域名 ${DOMAIN}  目录 ${REMOTE_ROOT}"

# 1) 远端建目录
ssh "${SSH_OPTS[@]}" "$SSH_HOST" "sudo mkdir -p ${REMOTE_ROOT}/icons /etc/caddy/conf.d && sudo chown -R ubuntu:ubuntu ${REMOTE_ROOT}"

# 2) 上传站点文件
scp "${SSH_OPTS[@]}" \
  "${LOCAL_DIR}/index.html" \
  "${LOCAL_DIR}/gem-calculator-sw.js" \
  "${LOCAL_DIR}/GemTradingCalculator.webmanifest" \
  "${SSH_HOST}:${REMOTE_ROOT}/"
scp "${SSH_OPTS[@]}" "${LOCAL_DIR}/icons/"* "${SSH_HOST}:${REMOTE_ROOT}/icons/"

# 3) 渲染 Caddy 配置并上传
sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__ROOT__|${REMOTE_ROOT}|g" \
  "${LOCAL_DIR}/deploy/caddy-gem.caddyfile" > /tmp/gem.caddyfile
scp "${SSH_OPTS[@]}" /tmp/gem.caddyfile "${SSH_HOST}:/tmp/gem.caddyfile"
ssh "${SSH_OPTS[@]}" "$SSH_HOST" "sudo mv /tmp/gem.caddyfile /etc/caddy/conf.d/gem.caddyfile &&
  (grep -q 'conf.d' /etc/caddy/Caddyfile || echo 'import /etc/caddy/conf.d/*.caddyfile' | sudo tee -a /etc/caddy/Caddyfile) &&
  sudo caddy fmt --overwrite /etc/caddy/conf.d/gem.caddyfile &&
  sudo systemctl reload caddy"

echo "==> 部署完成 → https://${DOMAIN}/"
