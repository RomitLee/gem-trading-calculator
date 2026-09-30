import sys, socket, paramiko

HOST = '43.132.148.55'
USER = 'ubuntu'
PW = 'SBqukq269'
PORT = 22
# 本机代理软件接管了直连，必须通过本地 HTTP 代理建 CONNECT 隧道
PROXY = ('127.0.0.1', 64237)


def make_tunnel():
    s = socket.create_connection(PROXY, timeout=20)
    s.sendall(('CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n' % (HOST, PORT, HOST, PORT)).encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        chunk = s.recv(1024)
        if not chunk:
            raise RuntimeError('proxy closed')
        buf += chunk
    if b'200' not in buf.split(b'\r\n')[0]:
        raise RuntimeError('proxy refused: ' + buf[:120].decode('utf8', 'replace'))
    return s


cmd = ' '.join(sys.argv[1:]) if len(sys.argv) > 1 else 'echo ok'
sock = make_tunnel()
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, port=PORT, username=USER, password=PW, sock=sock,
          timeout=30, look_for_keys=False, allow_agent=False)
stdin, stdout, stderr = c.exec_command(cmd, timeout=180)
out = stdout.read().decode('utf8', 'replace')
err = stderr.read().decode('utf8', 'replace')
code = stdout.channel.recv_exit_status()
if out.strip():
    print(out, end='' if out.endswith('\n') else '\n')
if err.strip():
    print('[stderr] ' + err, end='' if err.endswith('\n') else '\n')
print('[exit %d]' % code)
c.close()
