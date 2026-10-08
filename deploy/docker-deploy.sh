#!/usr/bin/env bash
# 子霖宝石助手 —— 腾讯云部署（Caddy 跑在 Docker 容器里时的专用脚本）
#
#   curl -fsSL https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main/deploy/docker-deploy.sh | sudo bash
#
# 上一版踩坑：宿主机的 /etc/caddy/Caddyfile 并不是 Caddy 真正在读的那个——
# Caddy 跑在容器里，配置和站点文件都在容器内部。本脚本改为全部在容器内操作：
#   · 用 docker inspect 定位容器真实配置路径 / 挂载 / 网桥网关
#   · 静态文件：优先用已有挂载（持久化），没有就 docker cp 进容器
#   · 数据接口：宿主机 Python 服务绑定 docker 网关地址，容器内 Caddy 反代过去
#   · 配置改动前容器内先备份，validate 不过就回滚

DOMAIN=gem.maipi.top
HOST_ROOT=/var/www/gem
API_DIR=/var/www/gem-api
DATA_DIR=/var/www/gem-data
NS='7ace42671474dd929f250fd4a627fd26934b3e26fbc06a50eb65d06648542e3f:v50'
REPO=RomitLee/gem-trading-calculator
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TS=$(date +%Y%m%d-%H%M%S)
WORK=/tmp/gem-docker-deploy

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
command -v docker >/dev/null 2>&1 || die "本机没有 docker 命令"

fetch() {
  local path="$1" out="$2" optional="$3" m
  for m in "${MIRRORS[@]}"; do
    if curl -fsSL --max-time 30 --retry 1 "$m/$path" -o "$out" && [ -s "$out" ]; then
      ok "已下载 $path"; return 0
    fi
  done
  rm -f "$out"
  if [ "$optional" = "optional" ]; then warn "跳过 $path（可选文件）"; return 0; fi
  die "下载失败：$path —— GitHub 全部镜像不通，请把本段输出发我，改用离线包部署"
}

mkdir -p "$WORK"

say "0/9 定位 Caddy 容器"
docker ps --format '      {{.Names}}  {{.Image}}  {{.Status}}' | sed 's/^/  /'
CTR=$(docker ps --format '{{.Names}}	{{.Image}}' | awk -F'	' 'tolower($2) ~ /caddy/ {print $1; exit}')
[ -n "$CTR" ] || die "没找到运行中的 caddy 容器（上面是 docker ps 的全部输出）"
ok "目标容器: $CTR"

docker inspect "$CTR" > "$WORK/inspect.json" 2>/dev/null || die "docker inspect 失败"
NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CTR" 2>/dev/null)
GW=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' "$CTR" 2>/dev/null | awk '{print $1}')
echo "    镜像     : $(docker inspect -f '{{.Config.Image}}' "$CTR")"
echo "    网络模式 : $NETMODE"
echo "    网桥网关 : ${GW:-无}"
echo "    启动命令 : $(docker inspect -f '{{.Config.Cmd}}' "$CTR" 2>/dev/null | head -c 160)"
echo "    挂载:"
docker inspect -f '{{range .Mounts}}      {{.Source}}  ->  {{.Destination}}  ({{.Mode}} rw={{.RW}}){{"\n"}}{{end}}' "$CTR" 2>/dev/null
echo "    compose 目录: $(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CTR" 2>/dev/null)"
echo "    compose 文件: $(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$CTR" 2>/dev/null)"

say "1/9 定位容器内真正的 Caddyfile"
CTR_CFG=""
for p in /etc/caddy/Caddyfile /etc/caddyfile /caddy/Caddyfile /config/Caddyfile /srv/Caddyfile; do
  if docker exec "$CTR" test -f "$p" 2>/dev/null; then CTR_CFG="$p"; break; fi
done
if [ -z "$CTR_CFG" ]; then
  CTR_CFG=$(docker exec "$CTR" sh -c 'tr "\0" "\n" < /proc/1/cmdline 2>/dev/null' 2>/dev/null \
    | awk '/^--config$/{getline;print;exit} /^--config=/{print substr($0,10);exit}')
fi
[ -n "$CTR_CFG" ] || CTR_CFG=/etc/caddy/Caddyfile
ok "容器内配置: $CTR_CFG"

# 判断该配置/静态目录是否被宿主机挂载覆盖（覆盖则直接改宿主机文件，天然持久化）
python3 - "$CTR_CFG" <<'PY' > "$WORK/map.env"
import json, os, sys
ins = json.load(open('/tmp/gem-docker-deploy/inspect.json'))
mounts = (ins[0] if isinstance(ins, list) else ins).get('Mounts') or []

def host_of(cpath):
    best = None
    for m in mounts:
        d = (m.get('Destination') or '').rstrip('/')
        if not d:
            continue
        if cpath == d or cpath.startswith(d + '/'):
            if best is None or len(d) > len(best[0]):
                best = (d, m.get('Source') or '', bool(m.get('RW')))
    if not best:
        return None, False
    return best[1] + cpath[len(best[0]):], best[2]

cfg = sys.argv[1]
cfg_host, cfg_rw = host_of(cfg)
print('CFG_HOST=%s' % (cfg_host or ''))
print('CFG_MOUNTED=%s' % ('1' if cfg_host else '0'))

# 静态目录优先落在「已有挂载」里，这样容器重建也不会丢文件
st_host, st_rw = host_of('/var/www/gem')
CTR_STATIC = '/var/www/gem'
if st_host is None:
    PREF = ['/srv', '/var/www', '/usr/share/caddy', '/site', '/www', '/html', '/data/www']
    cand = [m for m in mounts if m.get('RW') and (m.get('Destination') or '').startswith('/')
            and not (m.get('Destination') or '').startswith(('/etc', '/var/log', '/proc', '/sys', '/dev'))]
    pick = None
    for p in PREF:
        for m in cand:
            if (m['Destination'] or '').rstrip('/') == p:
                pick = m
                break
        if pick:
            break
    if pick:
        CTR_STATIC = (pick['Destination'] or '').rstrip('/') + '/gem'
        st_host = (pick['Source'] or '').rstrip('/') + '/gem'
print('STATIC_HOST=%s' % (st_host or ''))
print('STATIC_MOUNTED=%s' % ('1' if st_host else '0'))
print('CTR_STATIC=%s' % CTR_STATIC)
# 找出所有可写的目录型挂载，供 docker cp 之外做持久化备选
for m in mounts:
    s, d, rw = m.get('Source') or '', m.get('Destination') or '', bool(m.get('RW'))
    print('# mount %s -> %s rw=%s' % (s, d, rw))
PY
sed 's/^/    /' "$WORK/map.env" | grep -E '^(    #|    [A-Z])' | head -20
. "$WORK/map.env"

say "2/9 容器内现有配置（关键诊断，如失败请把这段发我）"
if [ "$CFG_MOUNTED" = "1" ]; then
  cp "$CFG_HOST" "$WORK/caddy.conf"
  ok "$CTR_CFG 由宿主机 $CFG_HOST 挂载，直接改宿主机文件"
else
  if ! docker exec "$CTR" cat "$CTR_CFG" > "$WORK/caddy.conf" 2>/dev/null || [ ! -s "$WORK/caddy.conf" ]; then
    warn "读不到容器内 $CTR_CFG，列一下容器里的 /etc/caddy："
    docker exec "$CTR" sh -c 'ls -la /etc/caddy 2>/dev/null; ls -la /etc 2>/dev/null | head -20' | sed 's/^/    /'
    die "请把上面这段和 0/9 的输出一起发我，我按实际路径改脚本"
  fi
  ok "已从容器取出配置（$(wc -c < "$WORK/caddy.conf") 字节）"
  ok "已从容器取出配置（${#} 字节）"
fi
docker exec "$CTR" cp "$CTR_CFG" "$CTR_CFG.bak.$TS" 2>/dev/null && ok "容器内已备份 → $CTR_CFG.bak.$TS"
cp "$WORK/caddy.conf" "$WORK/caddy.conf.bak"
echo "    --- 容器内 $CTR_CFG 全文 ---"
sed 's/^/    | /' "$WORK/caddy.conf"
echo "    --- 结束 ---"

say "3/9 准备站点文件"
mkdir -p "$HOST_ROOT/icons" "$API_DIR" "$DATA_DIR"
chown -R ubuntu:ubuntu "$DATA_DIR" 2>/dev/null || true
fetch index.html                        "$HOST_ROOT/index.html"
fetch gem-calculator-sw.js              "$HOST_ROOT/gem-calculator-sw.js"
fetch GemTradingCalculator.webmanifest  "$HOST_ROOT/GemTradingCalculator.webmanifest" optional
for f in app-logo.png gem-calculator-icon-180.png gem-calculator-icon-192.png \
         gem-calculator-icon-512.png gem-dust.png gem-normal.png gem-star.png; do
  fetch "icons/$f" "$HOST_ROOT/icons/$f" optional
done
printf '    版本徽章: '; grep -o 'id="appVersion">[^<]*' "$HOST_ROOT/index.html" | head -1

say "4/9 安装/更新数据接口（Python + SQLite）"
fetch deploy/gem-api/server.py        "$API_DIR/server.py"
fetch deploy/gem-api/seed.py          "$API_DIR/seed.py"
fetch deploy/gem-api/gem-api.service  "$API_DIR/gem-api.service"
command -v python3 >/dev/null || (apt-get update -qq && apt-get install -y -qq python3) || die "python3 安装失败"

# 容器访问宿主机：优先用网桥网关地址；host 网络模式则直接用 127.0.0.1
if [ "$NETMODE" = "host" ]; then
  CANDIDATES="127.0.0.1"
else
  CANDIDATES="$GW 172.17.0.1 172.18.0.1"
fi
API_UPSTREAM=""
probe_upstream() { # 容器内能否访问 <ip>:8787
  docker exec "$CTR" sh -c "wget -q -T 4 -O - 'http://$1:8787/api/zone_data?namespace=eq.__probe__' >/dev/null 2>&1 && echo OK" 2>/dev/null \
    || docker exec "$CTR" sh -c "nc -z -w 3 '$1' 8787 >/dev/null 2>&1 && echo OK" 2>/dev/null \
    || true
}
BIND_IP=""
for cand in $CANDIDATES; do
  [ -z "$cand" ] && continue
  echo "    试绑定 $cand ..."
  mkdir -p /etc/systemd/system/gem-api.service.d
  printf '[Service]\nEnvironment=GEM_HOST=%s\n' "$cand" > /etc/systemd/system/gem-api.service.d/host.conf
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart gem-api 2>/dev/null || {
    pkill -f 'gem-api/server.py' 2>/dev/null || true
    GEM_HOST="$cand" nohup python3 "$API_DIR/server.py" >/var/log/gem-api.log 2>&1 &
  }
  sleep 2
  if [ "$(probe_upstream "$cand")" = "OK" ]; then
    API_UPSTREAM="$cand:8787"; BIND_IP="$cand"
    ok "容器内可访问 $cand:8787"
    break
  fi
  warn "容器访问不到 $cand:8787"
done
if [ -z "$API_UPSTREAM" ]; then
  warn "容器访问不到宿主机任何候选地址，接口将暂时不可用（页面仍可打开，只是读不到数据）"
  API_UPSTREAM="127.0.0.1:8787"
fi
echo "    服务状态: $(systemctl is-active gem-api 2>/dev/null || echo 未知)  绑定: ${BIND_IP:-127.0.0.1}"

say "5/9 导入 / 检查本地数据"
python3 "$API_DIR/seed.py" 2>&1 | sed 's/^/    /' || warn "导入未成功"
python3 - "$DATA_DIR/zone_data.db" <<'PY' 2>&1 | sed 's/^/      /'
import sqlite3, sys, json
try:
    c = sqlite3.connect(sys.argv[1])
    rows = list(c.execute('SELECT namespace, payload, updated_at FROM zone_data'))
    if not rows: print('空库')
    for ns, pl, ua in rows:
        try:
            p = json.loads(pl or '{}')
            print('%s  rev=%s  区服=%s  updated_at=%s' % (ns[-8:], p.get('rev'), len(p.get('zones') or []), ua))
        except Exception: print('%s  payload 解析失败' % ns[-8:])
except Exception as e: print('查询失败:', e)
PY

say "6/9 静态文件送进容器"
if [ "$STATIC_MOUNTED" = "1" ]; then
  if [ "$STATIC_HOST" != "$HOST_ROOT" ]; then
    mkdir -p "$STATIC_HOST"
    cp -a "$HOST_ROOT/." "$STATIC_HOST/" && ok "站点文件已复制到挂载目录 $STATIC_HOST"
  fi
  ok "持久化：宿主机 $STATIC_HOST  ↔  容器 $CTR_STATIC"
else
  docker exec "$CTR" mkdir -p "$CTR_STATIC" 2>/dev/null || true
  if docker cp "$HOST_ROOT/." "$CTR:$CTR_STATIC" 2>/dev/null; then
    ok "已 docker cp 站点文件 → 容器 $CTR_STATIC"
    warn "注意：容器重建（如 docker compose up -d）会丢失这些文件，重跑本脚本即可恢复"
  else
    warn "docker cp 失败，静态文件可能读不到"
  fi
fi
docker exec "$CTR" mkdir -p /var/log/caddy 2>/dev/null || true
docker exec "$CTR" sh -c "ls -1 $CTR_STATIC 2>/dev/null | head -5" | sed 's/^/      容器内: /'

say "7/9 写入站点配置"
fetch deploy/caddy-gem.caddyfile "$WORK/gem.tpl"
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__ROOT__|$CTR_STATIC|g" -e "s|127\.0\.0\.1:8787|$API_UPSTREAM|g" \
    "$WORK/gem.tpl" > "$WORK/gem.block"

# 摘掉旧的 gem.maipi.top 站点块（其余站点原样保留），再追加新块
DOMAIN="$DOMAIN" python3 - "$WORK/caddy.conf" <<'PY'
import os, re, sys
path = sys.argv[1]; dom = os.environ['DOMAIN']
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
out, depth, skipping = [], 0, False
start = re.compile(r'^\s*(https?://)?' + dom.replace('.', r'\.') + r'(\s|\{|$)')
for ln in lines:
    if skipping:
        depth += ln.count('{') - ln.count('}')
        if depth <= 0: skipping = False
        continue
    if depth == 0 and start.match(ln):
        depth = ln.count('{') - ln.count('}')
        if depth > 0: skipping = True
        out.append('# [gem-deploy] 已移除旧的 %s 站点块' % dom)
        continue
    out.append(ln)
open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY
printf '\n# [gem-deploy] 子霖宝石助手 %s\n' "$TS" >> "$WORK/caddy.conf"
cat "$WORK/gem.block" >> "$WORK/caddy.conf"
echo "    --- 追加的站点块 ---"
sed 's/^/    | /' "$WORK/gem.block"

write_cfg_back() {
  if [ "$CFG_MOUNTED" = "1" ]; then
    cp "$WORK/caddy.conf" "$CFG_HOST"
  else
    docker cp "$WORK/caddy.conf" "$CTR:$CTR_CFG"
  fi
}
write_cfg_back
ok "配置已写回容器"

say "8/9 容器内校验并重载"
if docker exec "$CTR" caddy validate --config "$CTR_CFG" --adapter caddyfile 2>&1 | sed 's/^/    /'; then
  ok "校验通过"
else
  warn "校验失败，回滚容器内配置"
  docker exec "$CTR" cp "$CTR_CFG.bak.$TS" "$CTR_CFG" 2>/dev/null
  docker exec "$CTR" caddy reload --config "$CTR_CFG" --adapter caddyfile >/dev/null 2>&1
  die "Caddy 配置不合法（已回滚）。请把上面 2/9 的现有配置和这段报错一起发我"
fi
docker exec "$CTR" caddy reload --config "$CTR_CFG" --adapter caddyfile 2>&1 | sed 's/^/    /' || {
  warn "reload 失败，尝试重启容器（配置已校验通过，重启即生效）"
  docker restart "$CTR" >/dev/null 2>&1 && ok "容器已重启" || warn "重启失败，请手动 docker restart $CTR"
}
sleep 5

say "9/9 自检"
printf '    容器内首页 : '; docker exec "$CTR" sh -c "wget -q -T 5 -O - http://127.0.0.1/ --header 'Host: $DOMAIN' 2>/dev/null | grep -o 'id=\"appVersion\">[^<]*' | head -1" 2>/dev/null || echo "取不到（仅诊断，不影响结果）"
code=000
for i in 1 2 3 4 5 6; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$DOMAIN/" 2>/dev/null || echo 000)
  printf '    第 %d 次 https://%s/ → %s\n' "$i" "$DOMAIN" "$code"
  [ "$code" = "200" ] && break
  sleep 15
done
ONLINE_VER=""
if [ "$code" = "200" ]; then
  printf '    线上页面版本: '; ONLINE_VER=$(curl -s --max-time 12 "https://$DOMAIN/" | grep -o 'id="appVersion">v[0-9]*' | head -1); echo "${ONLINE_VER:-取不到}"
  printf '    线上接口    : '; curl -s --max-time 12 "https://$DOMAIN/api/zone_data?namespace=eq.$NS" | head -c 200; echo
else
  warn "HTTPS 未就绪，容器最近日志（请把这段发我）："
  docker logs --tail 30 "$CTR" 2>/dev/null | sed 's/^/    /'
fi

printf '\n'
if [ -n "$ONLINE_VER" ]; then
  printf '\033[1m==> 结果：线上已是 %s，部署成功\033[0m\n' "$ONLINE_VER"
else
  printf '\033[1;31m!! 结果：线上还不是本站页面，配置没生效\033[0m\n'
  echo "   请把 0/9、1/9、2/9 三段输出发我"
fi

cat <<EOF

============================================
 页面     https://$DOMAIN/
 容器内站 $CTR_STATIC
 容器内配置 $CTR_CFG   （备份 $CTR_CFG.bak.$TS）
 数据     $DATA_DIR/zone_data.db（宿主机 SQLite）
 接口     宿主机 $BIND_IP:8787，容器内 Caddy 经 /api/ 反代
 回滚     docker exec $CTR cp $CTR_CFG.bak.$TS $CTR_CFG && docker exec $CTR caddy reload --config $CTR_CFG --adapter caddyfile
 日志     journalctl -u gem-api -f     容器: docker logs -f $CTR
============================================
EOF
