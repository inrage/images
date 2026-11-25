import base64
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import urllib.parse
import uuid


source = Path(__file__).resolve().parents[1] / 'update.sh'
token = 'fixture-' + uuid.uuid4().hex
repository = 'poller-auth-' + uuid.uuid4().hex
clone = Path('/tmp') / repository
assert not clone.exists()


with tempfile.TemporaryDirectory(prefix='poller-git-') as directory:
    root = Path(directory)
    config = root / 'gitconfig'
    env = dict(os.environ, GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0', GITHUB_TOKEN=token, DEBUG='1',
               GIT_USER_NAME='fixture-app[bot]',
               GIT_USER_EMAIL='12345+fixture-app[bot]@users.noreply.github.com')

    def run(*args, **kwargs):
        return subprocess.run(args, env=env, capture_output=True, text=True,
                              check=True, timeout=30, **kwargs)

    run('git', 'config', '--global', 'credential.helper',
        '!f() { printf "username=legacy-user\\npassword=legacy-password\\n"; }; f')
    run('bash', '-c', '. "$1"', 'bash', str(source))
    helper = run('git', 'config', '--global', '--get',
                 'credential.https://github.com.helper').stdout.strip()
    denied = subprocess.run(['git', 'credential', 'fill'], env=env,
                            input='protocol=https\nhost=unrelated.invalid\n\n',
                            capture_output=True, text=True, timeout=10)
    assert token not in denied.stdout + denied.stderr
    resolved = run('git', 'credential', 'fill',
                   input='protocol=https\nhost=github.com\n\n').stdout
    assert 'username=x-access-token' in resolved and 'password=' + token in resolved

    bare = root / 'inrage' / repository
    run('git', 'init', '--bare', '--initial-branch=main', str(bare))
    seed = root / 'seed'
    run('git', 'init', '--initial-branch=main', str(seed))
    (seed / 'version').write_text('before\n')
    run('git', '-C', str(seed), 'add', 'version')
    run('git', '-C', str(seed), 'commit', '-m', 'Initial fixture')
    run('git', '-C', str(seed), 'push', str(bare), 'main')
    backend = str(Path(run('git', '--exec-path').stdout.strip()) / 'git-http-backend')
    requests = []
    authorization = 'Basic ' + base64.b64encode(('x-access-token:' + token).encode()).decode()

    class GitServer(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def handle_git(self):
            if self.headers.get('Authorization') != authorization:
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
                self.end_headers()
                return
            requests.append(self.path)
            target = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get('Content-Length', '0'))
            cgi_env = dict(env, GIT_PROJECT_ROOT=str(root), GIT_HTTP_EXPORT_ALL='1',
                           REMOTE_USER='x-access-token', PATH_INFO=target.path,
                           QUERY_STRING=target.query, REQUEST_METHOD=self.command,
                           CONTENT_TYPE=self.headers.get('Content-Type', ''),
                           CONTENT_LENGTH=str(length))
            result = subprocess.run([backend], env=cgi_env, input=self.rfile.read(length),
                                    capture_output=True, check=True, timeout=20)
            headers, body = result.stdout.split(b'\r\n\r\n', 1)
            fields = [line.decode().split(': ', 1) for line in headers.split(b'\r\n')]
            status = next((int(value.split()[0]) for name, value in fields if name == 'Status'), 200)
            self.send_response(status)
            for name, value in fields:
                if name != 'Status':
                    self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        do_GET = handle_git
        do_POST = handle_git

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), GitServer)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    url = 'http://127.0.0.1:' + str(server.server_port)
    run('git', 'config', '--global', 'url.' + url + '/.insteadOf', 'https://github.com/')
    run('git', 'config', '--global', '--replace-all', 'credential.' + url + '.helper', '')
    run('git', 'config', '--global', '--add', 'credential.' + url + '.helper', helper)
    try:
        result = run('bash', '-c', '. "$1"; _git_clone "$2"; printf "after\\n" > version; '
                     '_git_commit . "Update fixture"; git push origin HEAD:main',
                     'bash', str(source), 'inrage/' + repository)
        assert token not in result.stdout + result.stderr
        assert token not in config.read_text() + (clone / '.git/config').read_text()
        assert run('git', '-C', str(clone), 'remote', 'get-url', '--push', 'origin').stdout.strip() == url + '/inrage/' + repository
        assert run('git', '--git-dir=' + str(bare), 'show', 'main:version').stdout == 'after\n'
        assert run('git', '--git-dir=' + str(bare), 'log', '-1', '--format=%ae').stdout.strip() == env['GIT_USER_EMAIL']
        assert any('git-upload-pack' in path for path in requests)
        assert any('git-receive-pack' in path for path in requests)
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join()
        if clone.exists():
            shutil.rmtree(clone)

print('Git clone/push, credential scope and secret handling checks passed')
