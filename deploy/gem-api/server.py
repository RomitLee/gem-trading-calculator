#!/usr/bin/env python3
# 子霖宝石助手 —— 自建数据接口（只依赖 Python 标准库）
# 监听 127.0.0.1:8787，由 Caddy 把 /api/* 反代过来，不直接对外暴露。
#
# 接口（与页面里的 localCloud 适配层一一对应）：
#   GET  /api/zone_data?namespace=eq.<ns>   -> [{"namespace":..,"payload":{..},"updated_at":..}]
#   POST /api/zone_data  {"namespace":..,"payload":{..}}  -> 覆盖写入，updated_at 由服务器时间生成

import json
import hashlib
import hmac
import secrets
import time
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DB_PATH = os.environ.get('GEM_DB', '/var/www/gem-data/zone_data.db')
PORT = int(os.environ.get('GEM_API_PORT', '8787'))
# Caddy 若跑在 Docker 里，127.0.0.1 对它不可达，需绑定 docker 网桥在宿主机一侧的网关地址
HOST = os.environ.get('GEM_HOST', '127.0.0.1')
TZ = timezone(timedelta(hours=8))
ADMIN_HASH = os.environ.get('GEM_ADMIN_HASH', '7ace42671474dd929f250fd4a627fd26934b3e26fbc06a50eb65d06648542e3f')
SESSIONS = {}


def connect():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    c = sqlite3.connect(DB_PATH, timeout=15)
    c.execute('CREATE TABLE IF NOT EXISTS zone_data ('
              'namespace TEXT PRIMARY KEY, payload TEXT, updated_at TEXT)')
    return c


def now_iso():
    return datetime.now(TZ).isoformat(timespec='milliseconds')


class Handler(BaseHTTPRequestHandler):
    server_version = 'gem-api'

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        origin = self.headers.get('Origin')
        if origin:
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Access-Control-Allow-Credentials', 'true')
        self.send_header('Access-Control-Allow-Headers', 'content-type, prefer, x-wb-webapp-access-key, x-gem-admin-session')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        origin = self.headers.get('Origin')
        if origin:
            self.send_header('Access-Control-Allow-Origin', origin)
        self.send_header('Access-Control-Allow-Headers', 'content-type, prefer, x-wb-webapp-access-key, x-gem-admin-session')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        ns = (q.get('namespace') or [''])[0]
        if ns.startswith('eq.'):
            ns = ns[3:]
        if not ns:
            return self._send(400, {'error': 'namespace required'})
        c = connect()
        try:
            row = c.execute(
                'SELECT namespace, payload, updated_at FROM zone_data WHERE namespace = ?',
                (ns,)).fetchone()
        finally:
            c.close()
        if not row:
            return self._send(200, [])
        try:
            payload = json.loads(row[1])
        except Exception:
            payload = None
        self._send(200, [{'namespace': row[0], 'payload': payload, 'updated_at': row[2]}])

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b'{}'
        try:
            body = json.loads(raw.decode('utf-8'))
        except Exception:
            return self._send(400, {'error': 'bad json'})
        if urlparse(self.path).path == '/api/admin_session':
            if not isinstance(body, dict) or not isinstance(body.get('password'), str):
                return self._send(400, {'error': 'password required'})
            digest = hashlib.sha256(body['password'].encode('utf-8')).hexdigest()
            if not hmac.compare_digest(digest, ADMIN_HASH):
                return self._send(403, {'error': '管理员口令错误'})
            for key, expiry in list(SESSIONS.items()):
                if expiry <= time.time():
                    SESSIONS.pop(key, None)
            token = secrets.token_urlsafe(32)
            SESSIONS[token] = time.time() + 12 * 3600
            return self._send(200, {'token': token})
        if isinstance(body, list) and body:
            body = body[0]
        if not isinstance(body, dict):
            return self._send(400, {'error': 'object required'})
        ns = body.get('namespace')
        payload = body.get('payload')
        if not ns or payload is None:
            return self._send(400, {'error': 'namespace and payload required'})
        ts = now_iso()
        c = connect()
        try:
            c.execute('BEGIN IMMEDIATE')
            old = c.execute('SELECT payload FROM zone_data WHERE namespace = ?', (ns,)).fetchone()
            previous = json.loads(old[0]) if old else {}
            if not isinstance(payload, dict):
                return self._send(400, {'error': 'payload must be an object'})
            # Older clients omit expenses; preserve records rather than erase them.
            if 'expenses' not in payload and 'expenses' in previous:
                payload['expenses'] = previous['expenses']
                payload['expenseSeedVersion'] = previous.get('expenseSeedVersion', 1)
            if payload.get('expenses') != previous.get('expenses'):
                token = self.headers.get('X-Gem-Admin-Session', '')
                if SESSIONS.get(token, 0) <= time.time():
                    return self._send(403, {'error': '支出变更需要管理员重新授权'})
                if not valid_expenses(payload.get('expenses')):
                    return self._send(400, {'error': '支出数据不合法'})
            c.execute('INSERT INTO zone_data(namespace, payload, updated_at) VALUES(?, ?, ?) '
                      'ON CONFLICT(namespace) DO UPDATE SET payload = excluded.payload, '
                      'updated_at = excluded.updated_at',
                      (ns, json.dumps(payload, ensure_ascii=False), ts))
            c.commit()
            row = c.execute('SELECT payload, updated_at FROM zone_data WHERE namespace = ?',
                            (ns,)).fetchone()
        finally:
            c.close()
        self._send(200, [{'namespace': ns,
                          'payload': json.loads(row[0]) if row else payload,
                          'updated_at': row[1] if row else ts}])

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (self.log_date_time_string(), fmt % args))


def valid_expenses(rows):
    if not isinstance(rows, list):
        return False
    ids = set()
    for r in rows:
        try:
            if not isinstance(r, dict) or not isinstance(r.get('id'), str) or r['id'] in ids:
                return False
            ids.add(r['id'])
            kind = r['type']
            if kind not in ('hardware', 'account', 'coins', 'card'):
                return False
            datetime.strptime(r['date'], '%Y-%m-%d')
            price = r['price']
            if isinstance(price, bool) or not isinstance(price, (int, float)) or not 0 < price <= 1e10:
                return False
            zones = r['zones']
            if not isinstance(zones, list) or any(not isinstance(z, str) or not z.strip() for z in zones):
                return False
            if kind in ('account', 'coins') and len(zones) != 1:
                return False
            if kind == 'card' and not zones:
                return False
            if kind in ('hardware', 'account') and not str(r.get('description', '')).strip():
                return False
            if kind == 'coins' and (not isinstance(r.get('coins'), (int, float)) or not 0 < r['coins'] <= 1e12):
                return False
        except (KeyError, TypeError, ValueError):
            return False
    return True


if __name__ == '__main__':
    connect().close()
    sys.stderr.write('gem-api 监听 %s:%d  DB=%s\n' % (HOST, PORT, DB_PATH))
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
