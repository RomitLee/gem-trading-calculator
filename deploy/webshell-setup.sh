#!/usr/bin/env bash
# 子霖宝石助手 —— 服务器一键部署（腾讯云控制台「登录 / WebShell」里执行）
#
# 用法：在 WebShell 终端粘贴这一行回车即可
#   curl -fsSL https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main/deploy/webshell-setup.sh | sudo bash
#
# 说明：本机 22 端口出网被网络策略拦截，无法用 SSH 推送，故改为服务器自己拉取。

DOMAIN=gem.maipi.top
ROOT=/var/www/gem
REPO=RomitLee/gem-trading-calculator
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TS=$(date +%Y%m%d-%H%M%S)

# 国内服务器访问 GitHub 可能不通，逐个尝试镜像
MIRRORS=(
  "$RAW"
  "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH"
  "https://fastly.jsdelivr.net/gh/$REPO@$BRANCH"
  "https://ghfast.top/$RAW"
  "https://gh-proxy.com/$RAW"
  "https://ghproxy.net/$RAW"
)

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    ✓ %s\n' "$1"; }
warn(){ printf '    ! %s\n' "$1"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$1"; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 sudo 运行：curl ... | sudo bash"

fetch() { # fetch <相对路径> <输出文件> [可选]
  local path="$1" out="$2" optional="$3" m
  for m in "${MIRRORS[@]}"; do
    if curl -fsSL --max-time 30 --retry 1 "$m/$path" -o "$out" && [ -s "$out" ]; then
      ok "已下载 $path"
      return 0
    fi
  done
  rm -f "$out"
  if [ "$optional" = "optional" ]; then
    warn "跳过 $path（可选文件，下载失败）"
    return 0
  fi
  die "下载失败：$path —— 服务器访问 GitHub 全部镜像均不通，请把终端输出发给我改用离线包"
}

CADDY_BIN=$(command -v caddy || echo /usr/bin/caddy)

say "1/5 准备目录 $ROOT"
mkdir -p "$ROOT/icons"

say "2/5 下载站点文件"
fetch index.html                        "$ROOT/index.html"
fetch gem-calculator-sw.js              "$ROOT/gem-calculator-sw.js"
fetch GemTradingCalculator.webmanifest  "$ROOT/GemTradingCalculator.webmanifest" optional
for f in app-logo.png gem-calculator-icon-180.png gem-calculator-icon-192.png \
         gem-calculator-icon-512.png gem-dust.png gem-normal.png gem-star.png; do
  fetch "icons/$f" "$ROOT/icons/$f" optional
done
grep -q 'v5' "$ROOT/index.html" || warn "index.html 内容异常，请检查"

say "3/5 写入 Caddy 配置"
mkdir -p /etc/caddy/conf.d
fetch deploy/caddy-gem.caddyfile /tmp/gem.caddyfile
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__ROOT__|$ROOT|g" /tmp/gem.caddyfile > /etc/caddy/conf.d/gem.caddyfile
ok "站点配置 → /etc/caddy/conf.d/gem.caddyfile"

# 主配置：确保 import 了 conf.d
CF=/etc/caddy/Caddyfile
if [ ! -f "$CF" ]; then
  echo 'import /etc/caddy/conf.d/*.caddyfile' > "$CF"
  ok "新建 $CF"
elif ! grep -q 'conf.d' "$CF"; then
  cp -n "$CF" "$CF.bak.$TS"
  echo 'import /etc/caddy/conf.d/*.caddyfile' >> "$CF"
  ok "已在 $CF 末尾追加 import（原文件备份为 $CF.bak.$TS）"
fi

# 若主配置里已有同域名站点块，Caddy 会因「duplicate site address」拒绝加载，
# 此时整份接管主配置（先备份）
if grep -Rqs "^[[:space:]]*$DOMAIN" "$CF" /etc/caddy/conf.d/*.caddyfile 2>/dev/null \
   && grep -qs "^[[:space:]]*$DOMAIN" "$CF"; then
  warn "$CF 内已存在 $DOMAIN 站点块，为避免冲突将整份接管"
  cp "$CF" "$CF.bak.$TS"
  cat > "$CF" <<EOF
# 由 gem 部署脚本于 $TS 接管，原配置备份： $CF.bak.$TS
import /etc/caddy/conf.d/*.caddyfile
EOF
fi

say "4/5 校验并重载 Caddy"
if ! "$CADDY_BIN" validate --config "$CF" 2>&1 | sed 's/^/    /'; then
  warn "配置校验失败，回滚主配置"
  [ -f "$CF.bak.$TS" ] && cp "$CF.bak.$TS" "$CF"
  die "Caddy 配置不合法，请把上面报错发给我"
fi
ok "配置校验通过"
systemctl reload caddy 2>/dev/null || "$CADDY_BIN" reload --config "$CF" || service caddy reload || true
sleep 3

say "5/5 自检"
printf '    本地回环： '; curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 -H "Host: $DOMAIN" http://127.0.0.1/ || echo "失败"
printf '    版本号  ： '; curl -s --max-time 10 -H "Host: $DOMAIN" http://127.0.0.1/ | grep -o 'id="appVersion"[^<]*<[^>]*v[0-9]*' | grep -o 'v[0-9]*$' || echo "未取到"

cat <<EOF

============================================
 部署完成（如无报错）
 访问： https://$DOMAIN/
 右上角徽章应显示 v53
 首次签发 HTTPS 证书需 1~2 分钟，请耐心刷新
 云同步代理： /\.cloud/ -> 官方接口（已改写 Origin）
============================================
EOF
