"""Regression tests without a Docker daemon or real credentials."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
path = pathlib.Path(os.environ['MOCK_STATE'])
state = json.loads(path.read_text())
with open(os.environ['MOCK_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
def save(): path.write_text(json.dumps(state))
def option(flag): return args[args.index(flag) + 1]
def pairs(flag): return [args[i + 1] for i, a in enumerate(args) if a == flag]
if args[:2] == ['image', 'inspect']:
    if not state.get('image'): sys.exit(1)
    if '-f' in args:
        key = 'straitjacket.managed' if 'managed' in option('-f') else 'straitjacket.build'
        print(state['image'].get(key, '<no value>'))
elif args[0] == 'build':
    if os.environ.get('FAIL_BUILD'): sys.exit(37)
    state['image'] = dict(v.split('=', 1) for v in pairs('--label')); save()
elif args[:2] == ['ps', '-aq']:
    workspace = option('--filter').split('=', 2)[2]
    for cid, container in state['containers'].items():
        if container['workspace'] == workspace: print(cid)
elif args[0] == 'inspect':
    container = state['containers'].get(args[-1])
    if not container: sys.exit(1)
    fmt = option('-f')
    print(container['profile'] if 'profile' in fmt else '/' + container['name'])
elif args[0] == 'run':
    labels = dict(v.split('=', 1) for v in pairs('--label'))
    state['sequence'] = state.get('sequence', 0) + 1
    cid = 'container-' + str(state['sequence'])
    state['containers'][cid] = dict(workspace=labels['straitjacket.workspace'],
        profile=labels['straitjacket.profile'], name=option('--name'))
    save(); print(cid)
elif args[0] == 'exec':
    if args[-1] == 'straitjacket-postcreate' and os.environ.get('FAIL_SETUP'): sys.exit(42)
elif args[0] == 'rm':
    del state['containers'][args[-1]]; save()
elif args[0] not in ('start', 'ps'):
    sys.exit('unexpected mock call: ' + str(args))
'''


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='straitjacket-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        docker = self.bin / 'docker'
        docker.write_text(DOCKER)
        docker.chmod(0o755)
        self.checkout = self.root / 'checkout'
        self.checkout.mkdir()
        for name in ('Dockerfile', '.dockerignore'):
            shutil.copyfile(ROOT / name, self.checkout / name)
        shutil.copytree(ROOT / 'scripts', self.checkout / 'scripts')
        self.workspace = self.root / 'workspace with spaces'
        self.workspace.mkdir()
        self.state_file = self.root / 'state.json'
        self.state_file.write_text(json.dumps({'containers': {}}))
        self.log = self.root / 'calls.jsonl'
        self.log.touch()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        MOCK_STATE=str(self.state_file), MOCK_LOG=str(self.log),
                        STRAITJACKET_HOME=str(self.checkout), STRAITJACKET_PROFILE='default')

    def invoke(self, *args, **env):
        self.log.write_text('')
        return subprocess.run(['bash', str(ROOT / 'bin/straitjacket'), *map(str, args)],
                              env=dict(self.env, **env), cwd=self.workspace,
                              capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def state(self):
        return json.loads(self.state_file.read_text())

    def up(self, **env):
        result = self.invoke('up', self.workspace, **env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_up_builds_once_then_reuses_image(self):
        self.up()
        build = next(c for c in self.calls() if c[0] == 'build')
        self.assertNotIn('--no-cache', build)
        self.assertIn('straitjacket.managed=true', build)
        self.up()
        self.assertFalse(any(c[0] in ('build', 'run') for c in self.calls()))

    def test_rebuild_refreshes_only_selected_container_and_forwards_run_args(self):
        self.up()
        other = self.root / 'other'
        other.mkdir()
        self.assertEqual(self.invoke('up', other).returncode, 0)
        before = self.state()['containers']
        result = self.invoke('rebuild', self.workspace, '--', '--memory', '2g')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        build = next(c for c in calls if c[0] == 'build')
        self.assertIn('--pull', build)
        self.assertIn('--no-cache', build)
        removal = next(c for c in calls if c[0] == 'rm')
        self.assertEqual(before[removal[-1]]['workspace'], str(self.workspace))
        self.assertNotIn('-v', removal)
        self.assertLess(calls.index(build), calls.index(removal))
        self.assertIn('--memory', next(c for c in calls if c[0] == 'run'))
        for cid, container in before.items():
            if container['workspace'] == str(other):
                self.assertEqual(self.state()['containers'][cid], container)

    def test_failed_build_keeps_existing_container(self):
        self.up()
        before = self.state()
        result = self.invoke('rebuild', self.workspace, FAIL_BUILD='1')
        self.assertEqual(result.returncode, 37)
        self.assertEqual(self.state(), before)
        self.assertFalse(any(c[0] == 'rm' for c in self.calls()))

    def test_profile_mismatch_rejected_before_actions(self):
        self.up()
        for command in ('up', 'rebuild', 'shell', 'exec', 'claude', 'codex', 'init', 'down'):
            with self.subTest(command=command):
                args = ['--', 'true'] if command == 'exec' else []
                result = self.invoke(command, self.workspace, *args, STRAITJACKET_PROFILE='client-x')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("uses profile 'default'", result.stderr)
                self.assertFalse(any(c[0] in ('run', 'start', 'exec', 'rm', 'build') for c in self.calls()))

    def test_profile_passed_to_container(self):
        self.up(STRAITJACKET_PROFILE='client-x')
        run = next(c for c in self.calls() if c[0] == 'run')
        self.assertIn('STRAITJACKET_PROFILE=client-x', run)
        self.assertTrue(any('source=straitjacket-client-x-secrets,' in a for a in run))

    def test_setup_failure_cleans_up_and_retry_runs_setup(self):
        result = self.invoke('up', self.workspace, FAIL_SETUP='1')
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.state()['containers'], {})
        self.assertNotIn('-v', next(c for c in self.calls() if c[0] == 'rm'))
        self.up()
        self.assertTrue(any(c[-1] == 'straitjacket-postcreate' for c in self.calls()))

    def test_unrecognized_image_rejected(self):
        self.state_file.write_text(json.dumps({'containers': {}, 'image': {'unrelated': 'true'}}))
        result = self.invoke('up', self.workspace)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rebuild', result.stderr)
        self.assertFalse(any(c[0] in ('run', 'start') for c in self.calls()))

    def test_changed_build_inputs_require_rebuild(self):
        self.up()
        for name in ('Dockerfile', '.dockerignore', 'scripts/init.sh', 'scripts/postCreate.sh'):
            with self.subTest(name=name):
                path = self.checkout / name
                original = path.read_text()
                path.write_text(original + '\n# changed\n')
                result = self.invoke('up', self.workspace)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('differs from this checkout/user', result.stderr)
                path.write_text(original)
        self.up()

    def test_linux_user_ids_are_built_in_and_checked_before_reuse(self):
        for name, script in {
            'uname': '#!/bin/sh\necho Linux\n',
            'id': '#!/bin/sh\ncase "$1" in -u) echo "$MOCK_UID" ;; -g) echo 1001 ;; esac\n',
        }.items():
            path = self.bin / name
            path.write_text(script)
            path.chmod(0o755)
        self.up(MOCK_UID='1001')
        build = next(c for c in self.calls() if c[0] == 'build')
        self.assertIn('USER_UID=1001', build)
        self.assertIn('USER_GID=1001', build)
        result = self.invoke('up', self.workspace, MOCK_UID='1002')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('differs from this checkout/user', result.stderr)

    def test_agent_arguments_preserve_boundaries_without_shell_execution(self):
        self.up()
        marker = self.root / 'must-not-exist'
        args = ['--help', 'a b', f'$(touch {marker})', 'semi;colon', "single'quote"]
        names = ['claude', 'codex']
        if '  grok [DIR]' in (ROOT / 'bin/straitjacket').read_text():
            names.append('grok')
        for name in names:
            with self.subTest(agent=name):
                result = self.invoke(name, '--', *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                shell_command = next(c for c in self.calls() if c[0] == 'exec')[-1]
                program = self.bin / name
                program.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
                program.chmod(0o755)
                executed = subprocess.run(['bash', '-c', shell_command], env=self.env,
                                          capture_output=True, text=True, check=True)
                self.assertEqual(json.loads(executed.stdout), args)
                self.assertFalse(marker.exists())

    def test_unexpected_arguments_fail(self):
        for args in [('shell', self.workspace, 'ignored'), ('list', 'ignored'),
                     ('codex', self.workspace, '--help'), ('up', self.workspace, '--memory', '2g')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.invoke(*args).returncode, 0)


class InitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='straitjacket-init-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.secret = self.root / '.config/straitjacket/env'
        self.secret.parent.mkdir(parents=True)
        self.secret.write_text('export GH_TOKEN=fake_existing_token\n')
        self.secret.chmod(0o600)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        mv = self.bin / 'mv'
        mv.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
src = pathlib.Path(sys.argv[-2])
with open(os.environ['MODE_LOG'], 'a') as log:
    log.write(json.dumps(dict(mode=src.stat().st_mode & 0o777, content=src.read_text())) + '\\n')
if os.environ.get('FAIL_MV'): sys.exit(1)
os.replace(src, sys.argv[-1])
''')
        mv.chmod(0o755)
        self.log = self.root / 'modes.jsonl'
        self.env = dict(os.environ, HOME=str(self.root),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'], MODE_LOG=str(self.log))
        self.env.pop('BASH_ENV', None)

    def invoke(self, command, data, **env):
        return subprocess.run(['bash', '-c', command, 'test', str(ROOT / 'scripts/init.sh')],
                              input=data, capture_output=True, text=True, env=dict(self.env, **env))

    def test_private_complete_replacements_and_sourced_values(self):
        result = self.invoke('umask 022; source "$1" && printf "RESULT:%s:%s" "$GH_TOKEN" "$GIT_AUTHOR_NAME"',
                             "new_fake_token\nSam O'Name\nsam@example.test\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT:new_fake_token:Sam O'Name", result.stdout)
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(records)
        self.assertTrue(all(r['mode'] == 0o600 for r in records))
        self.assertTrue(all('export GH_TOKEN=new_fake_token\n' in r['content'] for r in records))
        self.assertEqual(self.secret.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.secret.parent.glob('env.*')), [])

    def test_failed_replace_preserves_original_and_does_not_exit_sourcing_shell(self):
        original = self.secret.read_text()
        result = self.invoke('source "$1"; status=$?; echo "SURVIVED:$status"',
                             'new_fake_token\n', FAIL_MV='1')
        self.assertIn('SURVIVED:1', result.stdout)
        self.assertEqual(self.secret.read_text(), original)
        self.assertEqual(list(self.secret.parent.glob('env.*')), [])
        self.assertIn('initialization failed', result.stderr)

    def test_blank_input_keeps_existing_values(self):
        result = self.invoke('source "$1" && printf "RESULT:%s" "$GH_TOKEN"', '\n\n\n\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('RESULT:fake_existing_token', result.stdout)


if __name__ == '__main__':
    unittest.main()
