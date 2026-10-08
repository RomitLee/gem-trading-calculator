#!/usr/bin/env python3
# 一次性迁移：把 WorkBuddy 云上那行现有数据搬到本机 SQLite。
# 服务器上执行：python3 /var/www/gem-api/seed.py
# 已存在同名行时默认跳过（加 --force 覆盖）。

import json
import os
import sqlite3
import sys
import urllib.parse
import urllib.request

DB_PATH = os.environ.get('GEM_DB', '/var/www/gem-data/zone_data.db')
WB_HOST = 'https://zilin-gem-helper.app.workbuddy.host'
WB_KEY = 'wbpk_zFJKokpBeUNzjAqOdXl4uI_QSwg7kq7en0gwIZCKq4NmX3LlN0xXiSP'
TOKEN_HASH = '7ace42671474dd929f250fd4a627fd26934b3e26fbc06a50eb65d06648542e3f'
NAMESPACES = [TOKEN_HASH + ':v50', TOKEN_HASH]  # 主行 + 9/28 遗留的僵尸行


def fetch_row(ns):
    url = WB_HOST + '/.cloud/database/rest/zone_data?' + urllib.parse.urlencode(
        {'namespace': 'eq.' + ns, 'select': 'namespace,payload,updated_at'})
    req = urllib.request.Request(url, headers={
        'x-wb-webapp-access-key': WB_KEY,
        'Origin': WB_HOST,
        'Referer': WB_HOST + '/',
        'Accept': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode('utf-8'))
    return data[0] if isinstance(data, list) and data else None


def main():
    force = '--force' in sys.argv
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    c = sqlite3.connect(DB_PATH, timeout=15)
    c.execute('CREATE TABLE IF NOT EXISTS zone_data ('
              'namespace TEXT PRIMARY KEY, payload TEXT, updated_at TEXT)')
    moved = 0
    for ns in NAMESPACES:
        try:
            row = fetch_row(ns)
        except Exception as e:
            print('  取 %s 失败: %s' % (ns[-8:], e))
            continue
        if not row or row.get('payload') is None:
            print('  %s 云端无数据，跳过' % ns[-8:])
            continue
        exists = c.execute('SELECT 1 FROM zone_data WHERE namespace = ?', (ns,)).fetchone()
        if exists and not force:
            print('  %s 本地已有，跳过（--force 可覆盖）' % ns[-8:])
            continue
        c.execute('INSERT INTO zone_data(namespace, payload, updated_at) VALUES(?, ?, ?) '
                  'ON CONFLICT(namespace) DO UPDATE SET payload = excluded.payload, '
                  'updated_at = excluded.updated_at',
                  (ns, json.dumps(row['payload'], ensure_ascii=False),
                   row.get('updated_at') or ''))
        moved += 1
        p = row['payload']
        print('  ✓ 导入 %s（rev %s，%s 个区服，updated_at %s）' % (
            ns[-8:], p.get('rev'), len(p.get('zones') or []), row.get('updated_at')))
    total = c.execute('SELECT COUNT(*) FROM zone_data').fetchone()[0]
    c.commit()
    c.close()
    print('共导入 %d 行 → %s（现有 %d 行）' % (moved, DB_PATH, total))
    return 0 if moved or total else 1


if __name__ == '__main__':
    sys.exit(main())
