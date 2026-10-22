import importlib.util
import json
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from pathlib import Path

spec = importlib.util.spec_from_file_location('gem_api', 'deploy/gem-api/server.py')
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class ExpenseAuthorizationTest(unittest.TestCase):
    def test_permissions_validation_and_legacy_preservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            api.DB_PATH = str(Path(tmp) / 'test.db')
            server = api.ThreadingHTTPServer(('127.0.0.1', 0), api.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            base = 'http://127.0.0.1:%s' % server.server_port

            def post(path, body, token=''):
                req = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json', 'X-Gem-Admin-Session': token})
                try:
                    with urllib.request.urlopen(req) as res:
                        return res.status, json.load(res)
                except urllib.error.HTTPError as e:
                    return e.code, json.load(e)

            try:
                row = {'namespace': 'test', 'payload': {'expenses': [{'id': '1', 'type': 'card', 'date': '2026-10-22', 'zones': ['秦淮风光', '罗浮山'], 'price': 720}]}}
                self.assertEqual(post('/api/zone_data', row)[0], 403)
                self.assertEqual(post('/api/admin_session', {'password': 'incorrect'})[0], 403)
                # Use a test password; production credentials are never needed by tests.
                api.ADMIN_HASH = api.hashlib.sha256(b'test-password').hexdigest()
                code, session = post('/api/admin_session', {'password': 'test-password'})
                self.assertEqual(code, 200)
                token = session['token']
                self.assertEqual(post('/api/zone_data', row, token)[0], 200)
                legacy = post('/api/zone_data', {'namespace': 'test', 'payload': {'rev': 2}})
                self.assertEqual(legacy[1][0]['payload']['expenses'], row['payload']['expenses'])
                row['payload']['expenses'][0]['price'] = -1
                self.assertEqual(post('/api/zone_data', row, token)[0], 400)
                row['payload']['expenses'] = []
                self.assertEqual(post('/api/zone_data', row)[0], 403)
                self.assertEqual(post('/api/zone_data', row, token)[0], 200)
            finally:
                server.shutdown()
                server.server_close()


if __name__ == '__main__':
    unittest.main()
