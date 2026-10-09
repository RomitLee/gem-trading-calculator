#!/usr/bin/env bash
# 子霖宝石助手 —— 轻量更新（只更新页面文件，不动 Caddy 配置与数据接口）
#
#   curl -fsSL https://raw.githubusercontent.com/RomitLee/gem-trading-calculator/main/deploy/update.sh | sudo bash
#
# 适用：只改了 index.html / 图标这类静态文件的日常迭代。
# 若改了数据接口（server.py）或站点配置（Caddy），请改跑 docker-deploy.sh 全量部署。
#
# 原理：Caddy 的 file_server 是每次请求实时读磁盘的，所以新文件落盘即刻生效，
#       不需要 reload，也不会影响正在使用的人。

DOMAIN=gem.maipi.top
HOST_ROOT=/var/www/gem
REPO=RomitLee/gem-trading-calculator
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TS=$(date +%Y%m%d-%H%M%S)
WORK=/tmp/gem-update

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
      printf '    ✓ %s' "$path"; printf '（%s 字节）\n' "$(wc -c < "$out")"; return 0
    fi
  done
  rm -f "$out"
  if [ "$optional" = "optional" ]; then warn "跳过 $path（可选文件）"; return 0; fi
  die "下载失败：$path —— GitHub 全部镜像不通，请把本段输出发我"
}

mkdir -p "$WORK"
rm -rf "$WORK/new"; mkdir -p "$WORK/new/icons"

say "1/5 下载最新版本"
fetch index.html                        "$WORK/new/index.html"
fetch gem-calculator-sw.js              "$WORK/new/gem-calculator-sw.js"
fetch GemTradingCalculator.webmanifest  "$WORK/new/GemTradingCalculator.webmanifest" optional
for f in app-logo.png gem-calculator-icon-180.png gem-calculator-icon-192.png \
         gem-calculator-icon-512.png gem-dust.png gem-normal.png gem-star.png; do
  fetch "icons/$f" "$WORK/new/icons/$f" optional
done
RAW=$(grep -o 'id="appVersion">[^<]*' "$WORK/new/index.html" | head -1)
NEW_VER="${RAW##*>}"
[ -n "$NEW_VER" ] || die "下载的 index.html 里找不到版本徽章，可能拉到的不是本项目的文件"
ok "待更新版本: $NEW_VER"

say "2/5 定位 Caddy 容器"
CTR=$(docker ps --format '{{.Names}}	{{.Image}}' | awk -F'	' 'tolower($2) ~ /caddy/ {print $1; exit}')
[ -n "$CTR" ] || die "没找到运行中的 caddy 容器，请改用 docker-deploy.sh 做全量部署"
ok "目标容器: $CTR"
docker inspect "$CTR" > "$WORK/inspect.json" 2>/dev/null || die "docker inspect 失败"

# 算出静态文件的最终落点：优先已有挂载（持久化），否则 docker cp
python3 - <<'PY' > "$WORK/map.env"
import json
ins = json.load(open('/tmp/gem-update/inspect.json'))
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
PY
. "$WORK/map.env"
echo "    容器内站点目录: $CTR_STATIC"
echo "    宿主机路径    : ${STATIC_HOST:-无挂载}"

say "3/5 更新前备份"
mkdir -p "$HOST_ROOT"
if [ -f "$HOST_ROOT/index.html" ]; then
  RAW=$(grep -o 'id="appVersion">[^<]*' "$HOST_ROOT/index.html" | head -1)
  OLD_VER="${RAW##*>}"
else
  OLD_VER="未知"
fi
mkdir -p "$HOST_ROOT"
cp -a "$HOST_ROOT/index.html" "$HOST_ROOT/index.html.bak.$TS" 2>/dev/null && ok "已备份旧版 → $HOST_ROOT/index.html.bak.$TS（${OLD_VER:-未知}）" || warn "备份失败（可能首次部署）"

say "4/5 写入新文件"
cp -a "$WORK/new/." "$HOST_ROOT/" && ok "已更新 $HOST_ROOT"
if [ "$STATIC_MOUNTED" = "1" ]; then
  if [ "$STATIC_HOST" != "$HOST_ROOT" ]; then
    mkdir -p "$STATIC_HOST"
    cp -a "$WORK/new/." "$STATIC_HOST/" && ok "已同步到挂载目录 $STATIC_HOST"
  fi
  ok "持久化挂载，容器重建也不会丢"
else
  docker exec "$CTR" mkdir -p "$CTR_STATIC" 2>/dev/null || true
  if docker cp "$WORK/new/." "$CTR:$CTR_STATIC" 2>/dev/null; then
    ok "已 docker cp → 容器 $CTR_STATIC"
    warn "该容器没有挂载网站目录，重建会丢失文件；重跑本脚本即可恢复"
  else
    warn "docker cp 失败，请改用 docker-deploy.sh 全量部署"
  fi
fi

say "5/5 线上自检"
LIVE=""
for i in 1 2 3; do
  RAW=$(curl -s --max-time 12 "https://$DOMAIN/" | grep -o 'id="appVersion">v[0-9]*' | head -1)
  LIVE="${RAW##*>}"
  if [ -n "$LIVE" ]; then
    printf '    https://%s/  →  %s\n' "$DOMAIN" "$LIVE"
    break
  fi
  printf '    第 %d 次探测未取到版本，等待 5 秒…\n' "$i"
  sleep 5
done

printf '\n'
if [ "$LIVE" = "$NEW_VER" ]; then
  printf '\033[1m==> 结果：线上已是 %s，更新成功\033[0m\n' "$LIVE"
elif [ -n "$LIVE" ]; then
  printf '\033[1;33m!! 结果：线上是 %s，期望 %s —— 可能是 CDN/浏览器缓存，请强制刷新（Ctrl+F5）后再看\033[0m\n' "$LIVE" "$NEW_VER"
  echo "   若强制刷新后仍是旧版，请改跑 docker-deploy.sh 全量部署并把输出发我"
else
  printf '\033[1;31m!! 结果：取不到线上版本，页面可能不可访问\033[0m\n'
  docker exec "$CTR" sh -c "wget -q -T 5 -O - http://127.0.0.1/ --header 'Host: $DOMAIN' 2>/dev/null | grep -o 'id=\"appVersion\">[^<]*' | head -1" | sed 's/^/    容器内: /' || echo "    容器内也取不到"
  echo "   请把上面这段输出发我"
fi

cat <<EOF

============================================
 更新前  ${OLD_VER:-未知}
 更新后  $NEW_VER
 回滚    cp $HOST_ROOT/index.html.bak.$TS $HOST_ROOT/index.html
 容器日志 docker logs --tail 20 $CTR
============================================
EOF
