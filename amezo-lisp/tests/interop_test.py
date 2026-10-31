# -*- coding: utf-8 -*-
"""Python版 <-> Lisp版 データ互換テスト: 同じ掲示板フォルダを両方で使う。"""
import os, re, shutil, subprocess, sys, tempfile, time, urllib.request, urllib.parse, urllib.error, socket

LISP = os.path.expanduser('~/workspace/amezo-lisp')
PYAPP = os.path.expanduser('~/workspace/amezo-python')
ng = ok = 0
def chk(name, cond, extra=''):
    global ng, ok
    if cond: ok += 1; print(f'OK {name}')
    else: ng += 1; print(f'NG {name} {extra}')

d = tempfile.mkdtemp(prefix='amezo_interop_')
shutil.copytree(LISP, d, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('.git', '__pycache__', 'tests', '*.patch', '*.fasl'))
for f in ('amezo.py', 'dai.py', 'jump.py', 'admin.py', 'archive.py'):
    shutil.copy(os.path.join(PYAPP, f), os.path.join(d, f))
with open(os.path.join(d, 'config.ini'), 'w', encoding='utf-8') as f:
    f.write('POST_INTERVAL = 0\nGLOBAL_WINDOW = 0\n')
for b in ('main', 'zatsu', 'test'):
    os.makedirs(os.path.join(d, b), exist_ok=True)

def py_post(fields):
    body = urllib.parse.urlencode(fields).encode()
    env = dict(os.environ, REQUEST_METHOD='POST', CONTENT_TYPE='application/x-www-form-urlencoded',
               CONTENT_LENGTH=str(len(body)), REMOTE_ADDR='127.0.0.1', QUERY_STRING='',
               HTTP_REFERER=f'http://x/main/index.html')
    r = subprocess.run([sys.executable, 'amezo.py'], input=body, cwd=d, env=env, capture_output=True)
    return r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace')

# 1) Python で delpass を作る (amezo.py の make_hash)
sys.path.insert(0, d)
os.chdir(d)
import importlib.util
spec = importlib.util.spec_from_file_location('pyamezo', os.path.join(d, 'amezo.py'))
pyamezo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pyamezo)
with open(os.path.join(d, 'delpass.txt'), 'w', encoding='utf-8') as f:
    f.write(pyamezo.make_hash('adminpw'))

# 2) Python で投稿 (トリップ付き)
out, err = py_post({'folder': 'main', 'name': '名無し#testpw', 'subj': '互換テスト', 'comm': 'Pythonで作ったスレ https://example.com/'})
files = [f for f in os.listdir(os.path.join(d, 'main')) if re.fullmatch(r'\d+\.html', f)]
chk('Python がスレッドを作成', len(files) == 1, str(files) + err[:200])
res = files[0][:-5] if files else ''
thread_path = os.path.join(d, 'main', files[0]) if files else ''
py_thread = open(thread_path, encoding='utf-8').read() if files else ''
trip_m = re.search(r'◆([A-Za-z0-9._]+)', py_thread)
chk('Python トリップが付いた', bool(trip_m), py_thread[:200])
py_trip = trip_m.group(1) if trip_m else ''

# 3) Lisp サーバーを同じフォルダで起動
with socket.socket() as s:
    s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
BASE = f'http://127.0.0.1:{port}'
srv = subprocess.Popen(['sbcl', '--script', 'amezo.lisp', '--no-tunnel', '--port', str(port)],
                       cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def req(path, data=None, headers=None, raw_headers=None):
    rq = urllib.request.Request(BASE + path, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(rq, timeout=15) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

try:
    for _ in range(120):
        try:
            if req('/style.css')[0] == 200: break
        except Exception: pass
        time.sleep(0.5)
    else:
        print('NG Lisp サーバーが起動しない'); sys.exit(1)

    st, hd, body = req(f'/main/{res}.html')
    chk('Lisp が Python 製スレッドを表示', st == 200 and '互換テスト'.encode() in body)

    # 4) Lisp で返信 (同じトリップPW) -> トリップが一致すること
    st, hd, body = req('/amezo.cgi', data=urllib.parse.urlencode(
        {'folder': 'main', 'name': '名無し#testpw', 'comm': 'Lispから返信', 'res': res}).encode())
    time.sleep(0.2)
    after = open(thread_path, encoding='utf-8').read()
    chk('Lisp が Python 製スレッドに返信できた', 'Lispから返信' in after, after[-300:])
    trips = re.findall(r'◆([A-Za-z0-9._]+)', after)
    chk('トリップが Python と Lisp で一致', len(trips) >= 2 and trips[0] == trips[1] == py_trip, str(trips))

    # 5) Python 管理画面のパスワード (Python make_hash) で Lisp 管理画面に入れる
    import http.cookiejar
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    rq = urllib.request.Request(BASE + '/admin.cgi', data=urllib.parse.urlencode({'pw': 'adminpw'}).encode())
    try:
        with opener.open(rq, timeout=15) as resp:
            admin_body = resp.read().decode('utf-8', 'replace'); admin_st = resp.status
    except urllib.error.HTTPError as e:
        admin_st, admin_body = e.code, e.read().decode('utf-8', 'replace')
    print('admin_st', admin_st); print('has pw field', 'name="pw"' in admin_body); print(admin_body[1000:1800]); chk('Python 製 delpass で Lisp 管理画面にログインできる', admin_st == 200 and 'name="pw"' not in admin_body, admin_body[:200])
finally:
    srv.terminate()

# 6) Python が Lisp の返信入りスレッドにさらに返信できる
out, err = py_post({'folder': 'main', 'name': '名無し', 'comm': 'Pythonから再度返信', 'res': res})
time.sleep(0.2)
final = open(thread_path, encoding='utf-8').read()
chk('Python が Lisp 返信入りスレッドに返信できた', 'Pythonから再度返信' in final, err[:200] + final[-200:])
n = len(re.findall(r'<dt>', final))
chk('レス数が 3 になっている', n == 3, f'n={n}')

print(f'== OK {ok} / NG {ng}')
sys.exit(1 if ng else 0)
