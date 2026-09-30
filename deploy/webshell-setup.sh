#!/usr/bin/env bash
# 备用方案：服务器 22 端口不通时，用腾讯云控制台的「登录 / WebShell」执行本脚本。
# 在 WebShell 里粘贴这一行即可：
#   curl -fsSL https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main/deploy/webshell-setup.sh | sudo bash
set -e

ROOT=/var/www/gem
DOMAIN=gem.maipi.top
BASE=https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main

# 国内服务器访问 GitHub 可能不通，逐个尝试镜像
MIRRORS=("$BASE" "https://ghfast.top/$BASE" "https://raw.fastgit.org/$BASE")
fetch() { # fetch <相对路径> <输出文件>
  local path="$1" out="$2" m
  for m in "${MIRRORS[@]}"; do
    if curl -fsSL --max-time 25 "$m/$path" -o "$out" && [ -s "$out" ]; then
      echo "  取到 $path"; return 0
    fi
  done
  echo "!! 无法下载 $path（服务器访问 GitHub 失败，请改用 SSH 部署）"; return 1
}

echo "==> 准备目录 $ROOT"
mkdir -p "$ROOT/icons"

echo "==> 下载站点文件"
fetch index.html "$ROOT/index.html"
fetch gem-calculator-sw.js "$ROOT/gem-calculator-sw.js"
fetch GemTradingCalculator.webmanifest "$ROOT/GemTradingCalculator.webmanifest"
for f in app-logo.png gem-calculator-icon-180.png gem-calculator-icon-192.png \
         gem-calculator-icon-512.png gem-dust.png gem-normal.png gem-star.png; do
  fetch "icons/$f" "$ROOT/icons/$f"
done

echo "==> 写入 Caddy 配置"
mkdir -p /etc/caddy/conf.d
fetch deploy/caddy-gem.caddyfile /tmp/gem.caddyfile
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__ROOT__|$ROOT|g" /tmp/gem.caddyfile > /etc/caddy/conf.d/gem.caddyfile
grep -q 'conf.d' /etc/caddy/Caddyfile || echo 'import /etc/caddy/conf.d/*.caddyfile' >> /etc/caddy/Caddyfile
caddy fmt --overwrite /etc/caddy/conf.d/gem.caddyfile || true
systemctl reload caddy || caddy reload --config /etc/caddy/Caddyfile

echo "==> 完成 → https://$DOMAIN/"
