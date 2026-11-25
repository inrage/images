import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
real_git = shutil.which('git')
base_digests = {version: 'sha256:' + letter * 64 for version, letter in
                [('8.1', 'a'), ('8.2', 'b'), ('8.3', 'c'), ('8.4', 'd')]}
frankenphp_digest = 'sha256:' + 'e' * 64
timestamp = '2026-11-25T00:00:00Z'


def metadata(digest):
    return {'last_updated': timestamp, 'images': [
        {'os': 'linux', 'architecture': 'amd64', 'digest': digest},
        {'os': 'linux', 'architecture': 'arm64', 'digest': 'sha256:' + '9' * 64},
        {'os': 'unknown', 'architecture': 'unknown', 'digest': 'sha256:' + '8' * 64},
    ]}


def scenario(name, mutate, expected_pushes, succeeds=True, legacy=False):
    with tempfile.TemporaryDirectory(prefix='poller-base-') as directory:
        directory = Path(directory)
        worktree = directory / 'worktree'
        remote = directory / 'remote.git'
        binaries = directory / 'bin'
        binaries.mkdir()
        env = dict(os.environ, GIT_CONFIG_GLOBAL=str(directory / 'gitconfig'),
                   GIT_CONFIG_NOSYSTEM='1', GIT_USER_NAME='fixture',
                   GIT_USER_EMAIL='fixture@example.test', DEBUG='',
                   GITHUB_TOKEN='fixture-token', REAL_GIT=real_git,
                   FIXTURE_WORKTREE=str(worktree), FIXTURE_PUSHES=str(directory / 'pushes'),
                   FIXTURE_METADATA=str(directory / 'metadata.json'),
                   PATH=str(binaries) + os.pathsep + os.environ['PATH'])

        def run(*args):
            return subprocess.run(args, env=env, text=True, capture_output=True,
                                  check=True, timeout=20)

        (binaries / 'git').write_text('''#!/usr/bin/env python3
import os,sys
if sys.argv[1] == 'push':
    with open(os.environ['FIXTURE_PUSHES'], 'a') as stream:
        stream.write('push\\n')
os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT'], *sys.argv[1:]])
''')
        (binaries / 'curl').write_text('''#!/usr/bin/env python3
import json,os,sys
parts=sys.argv[-1].rstrip('/').split('/')
key='/'.join(parts[-4:-2])+':'+parts[-1]
with open(os.environ['FIXTURE_METADATA']) as stream:
    response=json.load(stream)[key]
if response == 'error':
    sys.exit(22)
if response == 'malformed':
    print('{')
else:
    print(json.dumps(response))
''')
        for executable in binaries.iterdir():
            executable.chmod(0o755)
        run(real_git, 'config', '--global', 'user.name', 'fixture')
        run(real_git, 'config', '--global', 'user.email', 'fixture@example.test')
        run(real_git, 'config', '--global', 'commit.gpgSign', 'false')
        run(real_git, 'init', '--bare', '--initial-branch=main', str(remote))
        run(real_git, 'init', '--initial-branch=main', str(worktree))
        (worktree / '.php').write_text(''.join(version + '#' + digest + '\n'
                                             for version, digest in base_digests.items()))
        (worktree / '.frankenphp').write_text(('1-php8.4#' + timestamp if legacy else
                                              '8.4#' + frankenphp_digest) + '\n')
        run(real_git, '-C', str(worktree), 'add', '.')
        run(real_git, '-C', str(worktree), 'commit', '-m', 'Initial fixture')
        run(real_git, '-C', str(worktree), 'remote', 'add', 'origin', str(remote))
        run(real_git, '-C', str(worktree), 'push', '-u', 'origin', 'main')
        before = run(real_git, '--git-dir=' + str(remote), 'rev-parse', 'main').stdout
        values = {'inrage/docker-php:' + version: metadata(digest)
                  for version, digest in base_digests.items()}
        values['inrage/frankenphp:8.4'] = metadata(frankenphp_digest)
        values['dunglas/frankenphp:1-php8.4'] = metadata(frankenphp_digest)
        mutate(values, worktree)
        Path(env['FIXTURE_METADATA']).write_text(json.dumps(values))
        script_name = 'frankenphp.sh' if legacy else 'docker-wordpress.sh'
        script = (root / 'stability-tags' / script_name).read_text()
        script = script.replace('. ../update.sh', '')
        result = subprocess.run(['bash', '-e', '-c',
                                 '. "$1"; _git_clone() { cd "$FIXTURE_WORKTREE"; }; ' + script,
                                 'bash', str(root / 'update.sh')], env=env, text=True,
                                capture_output=True, timeout=30)
        assert (result.returncode == 0) == succeeds, (name, result.stdout, result.stderr)
        pushes_file = Path(env['FIXTURE_PUSHES'])
        pushes = pushes_file.read_text().splitlines() if pushes_file.exists() else []
        assert len(pushes) == expected_pushes, (name, pushes, result.stderr)
        after = run(real_git, '--git-dir=' + str(remote), 'rev-parse', 'main').stdout
        assert (before != after) == (expected_pushes > 0), name
        if expected_pushes:
            assert run(real_git, '--git-dir=' + str(remote), 'rev-list', '--count',
                       before.strip() + '..main').stdout.strip() == '1', name
        print('PASS ' + name)


scenario('identical bases do not publish', lambda values, worktree: None, 0)


def change_bases(values, worktree):
    values['inrage/docker-php:8.1']['images'][0]['digest'] = 'sha256:' + '1' * 64
    values['inrage/frankenphp:8.4']['images'][0]['digest'] = 'sha256:' + '2' * 64


scenario('two changed bases publish once', change_bases, 1)


def change_metadata(values, worktree):
    for value in values.values():
        value['last_updated'] = '2026-11-26T00:00:00Z'
        value['digest'] = 'sha256:' + '6' * 64
        value['images'][2]['digest'] = 'sha256:' + '7' * 64


scenario('timestamp and attestations alone do not publish', change_metadata, 0)


def fail_second_base(values, worktree):
    change_bases(values, worktree)
    values['inrage/frankenphp:8.4'] = 'error'


scenario('API failure after a change does not publish', fail_second_base, 0, False)
scenario('invalid JSON does not publish',
         lambda values, worktree: values.update({'inrage/docker-php:8.1': 'malformed'}), 0, False)
scenario('missing architecture does not publish',
         lambda values, worktree: values['inrage/docker-php:8.1'].update({'images': []}), 0, False)
scenario('ambiguous architecture does not publish',
         lambda values, worktree: values['inrage/docker-php:8.1']['images'].append(
             {'os': 'linux', 'architecture': 'amd64', 'digest': 'sha256:' + '3' * 64}), 0, False)
scenario('legacy timestamps require an explicit WordPress baseline',
         lambda values, worktree: (worktree / '.php').write_text('8.1#' + timestamp + '\n'), 0, False)
scenario('FrankenPHP retains its timestamp baseline',
         lambda values, worktree: values['dunglas/frankenphp:1-php8.4'].update(
             {'last_updated': '2026-11-26T00:00:00Z'}), 1, legacy=True)
