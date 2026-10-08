#!/usr/bin/env bash
# 子霖宝石助手 —— 服务器一键部署（腾讯云控制台「登录 / WebShell」里执行）
#
# 用法：在 WebShell 终端粘贴这一行回车即可
#   curl -fsSL https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main/deploy/webshell-setup.sh | sudo bash
#
# 背景：本地网络只放行 80/443，无法用 SSH 推送，故改为服务器自己拉取。

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

fetch() { # fetch <相对路径> <输出文件> [optional]
  local path="$1" out="$2" optional="$3" m
  for m in "${MIRRORS[@]}"; do
    if curl -fsSL --max-time 30 --retry 1 "$m/$path" -o "$out" && [ -s "$out" ]; then
      ok "已下载 $path"
      return 0
    fi
  done
  rm -f "$out"
  if [ "$optional" = "optional" ]; then
    warn "跳过 $path（可选文件）"
    return 0
  fi
  die "下载失败：$path —— GitHub 全部镜像不通，请把本段输出发我，改用离线包部署"
}

CADDY_BIN=$(command -v caddy || echo /usr/bin/caddy)

say "0/6 诊断现有环境"
echo "    caddy: $($CADDY_BIN version 2>/dev/null | head -1 || echo '未找到')"
# 定位真正加载的主配置文件
CF=""
for c in /etc/caddy/Caddyfile /usr/local/caddy/Caddyfile /www/server/caddy/Caddyfile /opt/caddy/Caddyfile; do
  [ -f "$c" ] && CF="$c" && break
done
if [ -z "$CF" ]; then
  CF=$(ps -eo args 2>/dev/null | grep -m1 '[c]addy' | grep -o -- '--config[= ][^ ]*' | sed 's/--config[= ]//' | head -1)
fi
[ -z "$CF" ] && CF=/etc/caddy/Caddyfile
echo "    主配置: $CF"
if [ -f "$CF" ]; then
  echo "    --- 现有主配置内容 ---"
  sed 's/^/    | /' "$CF"
  echo "    --- 结束 ---"
else
  warn "主配置文件不存在，将新建"
fi
echo "    /var/www:"; ls -1 /var/www 2>/dev/null | sed 's/^/      /' || true
echo "    caddy 服务: $(systemctl is-active caddy 2>/dev/null || echo '非 systemd / 未运行')"

say "1/6 准备目录 $ROOT"
mkdir -p "$ROOT/icons" /var/log/caddy
chown caddy:caddy /var/log/caddy 2>/dev/null || true

say "2/6 下载站点文件"
fetch index.html                        "$ROOT/index.html"
fetch gem-calculator-sw.js              "$ROOT/gem-calculator-sw.js"
fetch GemTradingCalculator.webmanifest  "$ROOT/GemTradingCalculator.webmanifest" optional
for f in app-logo.png gem-calculator-icon-180.png gem-calculator-icon-192.png \
         gem-calculator-icon-512.png gem-dust.png gem-normal.png gem-star.png; do
  fetch "icons/$f" "$ROOT/icons/$f" optional
done
grep -q 'appVersion' "$ROOT/index.html" || warn "index.html 内容异常，请检查"
ok "index.html $(wc -c < "$ROOT/index.html") 字节"

say "3/6 写入站点配置"
mkdir -p /etc/caddy/conf.d
fetch deploy/caddy-gem.caddyfile /tmp/gem.caddyfile
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__ROOT__|$ROOT|g" /tmp/gem.caddyfile > /etc/caddy/conf.d/gem.caddyfile
ok "站点配置 → /etc/caddy/conf.d/gem.caddyfile"

# 主配置：摘掉已存在的 gem.maipi.top 站点块（避免 duplicate site address），再确保 import conf.d
if [ -f "$CF" ]; then
  cp "$CF" "$CF.bak.$TS"
  ok "主配置已备份 → $CF.bak.$TS"
  if grep -qE "(^|[[:space:]])$DOMAIN([[:space:]]|\{|$)" "$CF"; then
    if command -v python3 >/dev/null 2>&1; then
      DOMAIN="$DOMAIN" python3 - "$CF" <<'PY'
import os, re, sys
path = sys.argv[1]; dom = os.environ['DOMAIN']
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
out, depth, skipping = [], 0, False
start = re.compile(r'^\s*(https?://)?' + dom.replace('.', r'\.') + r'(\s|\{|$)')
for ln in lines:
    if skipping:
        depth += ln.count('{') - ln.count('}')
        if depth <= 0:
            skipping = False
        continue
    if depth == 0 and start.match(ln):
        depth = ln.count('{') - ln.count('}')
        if depth > 0:
            skipping = True
        out.append('# [gem-deploy] 已移除旧的 %s 站点块' % dom)
        continue
    out.append(ln)
open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY
      ok "已从主配置摘除旧的 $DOMAIN 站点块（其余站点保持不变）"
    else
      warn "无 python3，跳过摘除；若报 duplicate site address 请手动编辑 $CF"
    fi
  else
    ok "主配置中没有 $DOMAIN 站点块，无需摘除"
  fi
  grep -q 'conf.d' "$CF" || printf '\n# [gem-deploy] 子霖宝石助手\nimport /etc/caddy/conf.d/*.caddyfile\n' >> "$CF"
else
  mkdir -p "$(dirname "$CF")"
  printf '# [gem-deploy] 子霖宝石助手\nimport /etc/caddy/conf.d/*.caddyfile\n' > "$CF"
  ok "新建主配置 $CF"
fi
echo "    --- 修改后的主配置 ---"
sed 's/^/    | /' "$CF"

say "4/6 校验并重载 Caddy"
if ! "$CADDY_BIN" validate --config "$CF" --adapter caddyfile 2>&1 | sed 's/^/    /'; then
  warn "校验失败，回滚主配置"
  [ -f "$CF.bak.$TS" ] && cp "$CF.bak.$TS" "$CF"
  die "Caddy 配置不合法，请把这段输出发我"
fi
ok "配置校验通过"
systemctl reload caddy 2>/dev/null || "$CADDY_BIN" reload --config "$CF" --adapter caddyfile || service caddy reload || true
sleep 3

say "5/6 自检"
printf '    本地回环 HTTP : '; curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 -H "Host: $DOMAIN" http://127.0.0.1/ || echo 失败
printf '    文件版本     : '; grep -o 'id="appVersion">[^<]*' "$ROOT/index.html" | head -1

say "6/6 证书状态（HTTPS 首次签发需 1~2 分钟）"
code=000
for i in 1 2 3 4 5 6; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$DOMAIN/" 2>/dev/null || echo 000)
  printf '    第 %d 次探测 https://%s/ → %s\n' "$i" "$DOMAIN" "$code"
  [ "$code" = "200" ] && break
  sleep 20
done
if [ "$code" != "200" ]; then
  warn "HTTPS 仍未就绪，下面是 Caddy 最近日志（请把这段发我）"
  journalctl -u caddy -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || tail -30 /var/log/caddy/gem.log 2>/dev/null | sed 's/^/    /'
fi

cat <<EOF

============================================
 部署流程结束
 访问： https://$DOMAIN/
 右上角徽章应为 v53
 云同步： /.cloud/ 已反代到官方接口并改写 Origin
 回滚：  cp $CF.bak.$TS $CF && systemctl reload caddy
============================================
EOF
