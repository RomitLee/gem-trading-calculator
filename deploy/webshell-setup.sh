#!/usr/bin/env bash
# 子霖宝石助手 —— 腾讯云一键部署（在控制台「登录 / WebShell」里执行）
#
#   curl -fsSL https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main/deploy/webshell-setup.sh | sudo bash
#
# 部署内容：页面静态文件 + 自建数据接口（Python/SQLite）+ Caddy 站点与 HTTPS
# 本地网络只放行 80/443，无法用 SSH 推送，故改为服务器自己拉取。

DOMAIN=gem.maipi.top
ROOT=/var/www/gem
API_DIR=/var/www/gem-api
DATA_DIR=/var/www/gem-data
NS='7ace42671474dd929f250fd4a627fd26934b3e26fbc06a50eb65d06648542e3f:v50'
REPO=RomitLee/gem-trading-calculator
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TS=$(date +%Y%m%d-%H%M%S)

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

say "0/8 诊断现有环境"
echo "    caddy: $($CADDY_BIN version 2>/dev/null | head -1 || echo '未找到')"
echo "    python3: $(command -v python3 >/dev/null && python3 -V || echo '未安装')"
echo "    systemd: $(command -v systemctl >/dev/null && echo 有 || echo 无)"
# 上次踩坑：/etc/caddy/Caddyfile 未必是 Caddy 真正在读的那个。
# 这里把所有可能的配置文件都找出来，后面逐个改写，避免改了个没人用的文件。
CF_LIST=""
add_cf() { case " $CF_LIST " in *" $1 "*) ;; *) [ -f "$1" ] && CF_LIST="$CF_LIST $1" ;; esac; }
for c in /etc/caddy/Caddyfile /usr/local/caddy/Caddyfile /www/server/caddy/Caddyfile \
         /opt/caddy/Caddyfile /www/server/panel/caddy/Caddyfile; do add_cf "$c"; done
for c in $(systemctl cat caddy 2>/dev/null | grep -o -- '--config[= ][^ "]*' | sed 's/--config[= ]//'); do add_cf "$c"; done
for c in $(ps -eo args 2>/dev/null | grep '[c]addy' | grep -o -- '--config[= ][^ ]*' | sed 's/--config[= ]//'); do add_cf "$c"; done
[ -z "$CF_LIST" ] && CF_LIST="/etc/caddy/Caddyfile"
CF=$(echo "$CF_LIST" | awk '{print $1}')
echo "    找到的配置文件: $CF_LIST"
echo "    （Caddy 启动方式）"; systemctl cat caddy 2>/dev/null | grep -E 'ExecStart|^# /' | head -4 | sed 's/^/      /'
echo "    进程: $(ps -eo args 2>/dev/null | grep -m1 '[c]addy' | head -c 160)"
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qi caddy; then
  warn "检测到 Caddy 跑在 Docker 里，配置可能在容器内部或挂载目录中"
  docker ps --format '      {{.Names}} {{.Image}}' 2>/dev/null | grep -i caddy
fi
for f in $CF_LIST; do
  echo "    --- $f ---"
  sed 's/^/    | /' "$f"
done
echo "    --- 结束 ---"
echo "    /var/www:"; ls -1 /var/www 2>/dev/null | sed 's/^/      /' || true

say "1/8 准备目录"
mkdir -p "$ROOT/icons" "$API_DIR" "$DATA_DIR" /var/log/caddy
chown -R ubuntu:ubuntu "$DATA_DIR" 2>/dev/null || true
if ! command -v python3 >/dev/null; then
  warn "未找到 python3，尝试安装"
  (apt-get update -qq && apt-get install -y -qq python3) || die "python3 安装失败，数据接口无法运行"
fi

say "2/8 下载站点文件"
fetch index.html                        "$ROOT/index.html"
fetch gem-calculator-sw.js              "$ROOT/gem-calculator-sw.js"
fetch GemTradingCalculator.webmanifest  "$ROOT/GemTradingCalculator.webmanifest" optional
for f in app-logo.png gem-calculator-icon-180.png gem-calculator-icon-192.png \
         gem-calculator-icon-512.png gem-dust.png gem-normal.png gem-star.png; do
  fetch "icons/$f" "$ROOT/icons/$f" optional
done
grep -q 'appVersion' "$ROOT/index.html" || warn "index.html 内容异常"
printf '    版本徽章: '; grep -o 'id="appVersion">[^<]*' "$ROOT/index.html" | head -1

say "3/8 安装数据接口（Python + SQLite）"
fetch deploy/gem-api/server.py "$API_DIR/server.py"
fetch deploy/gem-api/seed.py   "$API_DIR/seed.py"
fetch deploy/gem-api/gem-api.service "$API_DIR/gem-api.service"
if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then
  cp "$API_DIR/gem-api.service" /etc/systemd/system/gem-api.service
  systemctl daemon-reload
  systemctl enable gem-api >/dev/null 2>&1 || true
  systemctl restart gem-api
  sleep 2
  echo "    服务状态: $(systemctl is-active gem-api 2>/dev/null)"
  if [ "$(systemctl is-active gem-api 2>/dev/null)" != "active" ]; then
    journalctl -u gem-api -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
    warn "服务未起来"
  fi
else
  warn "无 systemd，改用 nohup 常驻"
  pkill -f 'gem-api/server.py' 2>/dev/null || true
  sudo -u ubuntu nohup python3 "$API_DIR/server.py" >/var/log/gem-api.log 2>&1 &
  sleep 2
fi
printf '    本机自检: '; curl -s --max-time 8 "http://127.0.0.1:8787/api/zone_data?namespace=eq.__probe__" || echo "无响应"
echo

say "4/8 导入现有云端数据"
python3 "$API_DIR/seed.py" 2>&1 | sed 's/^/    /' || warn "导入未成功"
printf '    本地库现状:\n'
python3 - "$DATA_DIR/zone_data.db" <<'PY' 2>&1 | sed 's/^/      /'
import sqlite3, sys, json
try:
    c = sqlite3.connect(sys.argv[1])
    rows = list(c.execute('SELECT namespace, payload, updated_at FROM zone_data'))
    if not rows:
        print('空库')
    for ns, pl, ua in rows:
        try:
            p = json.loads(pl or '{}')
            print('%s  rev=%s  区服=%s  updated_at=%s' % (ns[-8:], p.get('rev'), len(p.get('zones') or []), ua))
        except Exception:
            print('%s  payload 解析失败' % ns[-8:])
except Exception as e:
    print('查询失败:', e)
PY

say "5/8 写入 Caddy 配置"
mkdir -p /etc/caddy/conf.d
fetch deploy/caddy-gem.caddyfile /tmp/gem.caddyfile
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__ROOT__|$ROOT|g" /tmp/gem.caddyfile > /etc/caddy/conf.d/gem.caddyfile
ok "站点配置 → /etc/caddy/conf.d/gem.caddyfile"

for CF in $CF_LIST; do
  echo "    · 处理 $CF"
  cp "$CF" "$CF.bak.$TS"
  ok "备份 → $CF.bak.$TS"
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
      ok "摘除该文件中旧的 $DOMAIN 站点块（其余站点保持不变）"
    else
      warn "无 python3，跳过摘除；若报 duplicate site address 请手动编辑 $CF"
    fi
  else
    ok "该文件中无 $DOMAIN 站点块"
  fi
  grep -q 'conf.d' "$CF" || printf '\n# [gem-deploy] 子霖宝石助手\nimport /etc/caddy/conf.d/*.caddyfile\n' >> "$CF"
  echo "      --- 改后 ---"
  sed 's/^/      | /' "$CF"
done

say "6/8 校验并重载 Caddy"
for CF in $CF_LIST; do
  if ! "$CADDY_BIN" validate --config "$CF" --adapter caddyfile 2>&1 | sed 's/^/    /'; then
    warn "$CF 校验失败，回滚该文件"
    [ -f "$CF.bak.$TS" ] && cp "$CF.bak.$TS" "$CF"
  else
    ok "$CF 校验通过"
  fi
done
systemctl reload caddy 2>/dev/null || "$CADDY_BIN" reload --config "$(echo $CF_LIST | awk '{print $1}')" --adapter caddyfile || service caddy reload || true
systemctl restart caddy 2>/dev/null || warn "restart 未执行（reload 可能已生效）"
sleep 4

say "7/8 自检"
printf '    本地 HTTP   : '; curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 -H "Host: $DOMAIN" http://127.0.0.1/ || echo 失败
printf '    本地页面版本: '; curl -s --max-time 10 -H "Host: $DOMAIN" http://127.0.0.1/ | grep -o 'id="appVersion">[^<]*' | head -1 || echo "不是本站内容！"
printf '    本地接口   : '; curl -s --max-time 10 -H "Host: $DOMAIN" "http://127.0.0.1/api/zone_data?namespace=eq.$NS" | head -c 150; echo
LOCAL_VER=$(curl -s --max-time 10 -H "Host: $DOMAIN" http://127.0.0.1/ | grep -o 'id="appVersion">v[0-9]*' | head -1)
if [ -z "$LOCAL_VER" ]; then
  warn "本地回环拿到的不是本站页面 —— Caddy 实际加载的配置文件不在本次改写的列表里"
  warn "请把上面 0/8 诊断里的「配置文件 / 启动方式 / 进程」整段发我"
fi

say "8/8 证书状态（首次签发需 1~2 分钟）"
code=000
for i in 1 2 3 4 5 6; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$DOMAIN/" 2>/dev/null || echo 000)
  printf '    第 %d 次 https://%s/ → %s\n' "$i" "$DOMAIN" "$code"
  [ "$code" = "200" ] && break
  sleep 20
done
if [ "$code" = "200" ]; then
  printf '    线上页面版本: '; curl -s --max-time 12 "https://$DOMAIN/" | grep -o 'id="appVersion">[^<]*' | head -1 || echo "不是本站内容！"
  printf '    线上接口    : '; curl -s --max-time 12 "https://$DOMAIN/api/zone_data?namespace=eq.$NS" | head -c 200; echo
else
  warn "HTTPS 未就绪，Caddy 最近日志（请把这段发我）："
  journalctl -u caddy -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || tail -30 /var/log/caddy/gem.log 2>/dev/null | sed 's/^/    /'
fi

ONLINE_VER=$(curl -s --max-time 12 "https://$DOMAIN/" | grep -o 'id="appVersion">v[0-9]*' | head -1)
ROLLBACK_HINT=""
for CF in $CF_LIST; do ROLLBACK_HINT="$ROLLBACK_HINT  cp $CF.bak.$TS $CF\n"; done

if [ -n "$ONLINE_VER" ]; then
  printf '\n\033[1m==> 结果：线上已是 %s，部署成功\033[0m\n' "$ONLINE_VER"
else
  printf '\n\033[1;31m!! 结果：线上还不是本站页面，配置没生效\033[0m\n'
  echo "   请把 0/8 诊断整段（配置文件列表 / Caddy 启动方式 / 进程参数）发我"
fi

cat <<EOF

============================================
 页面   https://$DOMAIN/        （徽章应为 v55）
 数据   $DATA_DIR/zone_data.db  （自建 SQLite，不再走 WorkBuddy 云）
 接口   127.0.0.1:8787，经 Caddy 以 /api/ 暴露
 日志   journalctl -u gem-api -f
 回滚：
$(printf "$ROLLBACK_HINT")  systemctl reload caddy
============================================
EOF
