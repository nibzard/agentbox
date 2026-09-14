import os
from pathlib import Path
import shlex
import socket
import sys
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, heredoc, region


class VerifierTests(unittest.TestCase):
    def setUp(self):
        self.shell = ShellFixture()
        self.addCleanup(self.shell.close)
        body = heredoc(SOURCE.read_text(), "cat >> /usr/local/bin/agentbox-verify <<'EOF'").body
        self.helpers = region(body, '# Verifier resource helpers: acquisition must run in the parent shell.\n', '# End verifier resource helpers.')
        self.reporting = region(body, 'pass=0; fail=0; skip=0\n', '# Verifier resource helpers:')
        for name, path in [('mktemp','/usr/bin/mktemp'), ('rm','/bin/rm'), ('sleep','/bin/sleep'), ('grep','/usr/bin/grep'), ('sort','/usr/bin/sort')]:
            self.shell.allow(name, path)
        self.shell.env['WORKSPACE'] = str(self.shell.root)
        self.shell.env['FIXTURE_ROOT'] = str(self.shell.root)
        (self.shell.root / 'ab-verify-selftest').mkdir()
        (self.shell.root / 'ab-verify-selftest' / 'sentinel').write_text('keep')
        (self.shell.root / 'session-abverify').write_text('keep')
        self.python_command('tmux', '''
name = sys.argv[-1]
path = root / ('session-' + name)
if sys.argv[1] == 'new':
    if path.exists(): sys.exit(1)
    path.write_text('owned')
elif sys.argv[1] == 'has':
    sys.exit(0 if path.exists() else 1)
elif sys.argv[1] == 'kill-session':
    path.unlink()
''')

    def python_command(self, name, code):
        target = self.shell.bin / name
        if target.is_symlink(): target.unlink()
        target.write_text(f'#!{sys.executable}\nimport os, sys, signal\nfrom pathlib import Path\nroot = Path(os.environ["FIXTURE_ROOT"])\n' + code)
        target.chmod(0o755)

    def run_helpers(self, script, **kwargs):
        return self.shell.run(self.helpers + '\n' + script, **kwargs)

    def assert_sentinels(self):
        self.assertEqual((self.shell.root / 'ab-verify-selftest' / 'sentinel').read_text(), 'keep')
        self.assertEqual((self.shell.root / 'session-abverify').read_text(), 'keep')
        self.assertEqual(list(self.shell.root.glob('.agentbox-verify.*')), [])
        self.assertEqual(list(self.shell.root.glob('session-*')), [self.shell.root / 'session-abverify'])

    def test_cleanup_success_failure_and_signals(self):
        for ending, expected in [('exit 0',0), ('exit 7',7), ('kill -TERM $$',143), ('kill -INT $$',130)]:
            with self.subTest(ending=ending):
                result = self.run_helpers('allocate_resources && create_session || exit 9\n' + ending)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assert_sentinels()

    def test_failed_session_creation_is_not_cleaned(self):
        self.shell.stub('tmux', status=1)
        result = self.run_helpers('allocate_resources\ncreate_session\nexit 3')
        self.assertEqual(result.returncode, 3)
        self.assertEqual([c['argv'][0] for c in self.shell.calls()], ['new'])
        self.assert_sentinels()

    def test_concurrent_invocations_have_distinct_resources(self):
        script = self.shell.root / 'owned.sh'
        script.write_text(self.helpers + '''
allocate_resources && create_session || exit 1
printf '%s\n' "$verify_tmp" > "$1"
sleep 0.2
test -d "$verify_tmp" && tmux has -t "$verify_session"
''')
        result = self.shell.run(f'/bin/bash {shlex.quote(str(script))} one &\na=$!\n/bin/bash {shlex.quote(str(script))} two &\nb=$!\nwait "$a" && wait "$b"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((self.shell.root/'one').read_text(), (self.shell.root/'two').read_text())
        self.assert_sentinels()

    def listener_commands(self, wrong=False):
        self.python_command('python3', f'''
(root / 'listener.pid').write_text(str(os.getpid()))
os.execv({sys.executable!r}, [{sys.executable!r}] + sys.argv[1:])
''')
        self.python_command('ss', '''
pid = (root / 'listener.pid').read_text()
print('users:(("python3",pid=' + ''' + ("'999999'" if wrong else 'pid') + ''' + ',fd=3))')
''')
        self.python_command('killport', '''
(root / 'kill-called').write_text(sys.argv[1])
os.kill(int((root / 'listener.pid').read_text()), signal.SIGTERM)
''')

    def test_listener_success_and_unrelated_socket_survives(self):
        self.listener_commands()
        with socket.socket() as unrelated:
            unrelated.bind(('127.0.0.1',0)); unrelated.listen()
            result = self.run_helpers('allocate_resources\ncheck_listener', timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreater(int((self.shell.root/'kill-called').read_text()),0)
            self.assertGreater(unrelated.getsockname()[1], 0)
        self.assert_sentinels()

    def test_listener_wrong_pid_does_not_call_killport(self):
        self.listener_commands(wrong=True)
        result = self.run_helpers('allocate_resources\ncheck_listener', timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.shell.root/'kill-called').exists())
        pid = int((self.shell.root/'listener.pid').read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid,0)
        self.assert_sentinels()

    def test_listener_start_failure_and_exit_before_ready(self):
        for publish in (False, True):
            self.python_command('python3', "Path(sys.argv[2]).write_text('12345\\n')\nsys.exit(1)\n" if publish else 'sys.exit(1)\n')
            self.shell.stub('killport')
            result = self.run_helpers('allocate_resources\ncheck_listener', timeout=8)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(c['command']=='killport' for c in self.shell.calls()))
            self.assert_sentinels()

    def test_alias_exit_status_with_and_without_banner(self):
        for banner in ('', 'printf "Welcome banner\\n"\n'):
            (self.shell.home / '.bashrc').write_text(banner + "alias present='true'\n")
            self.assertEqual(self.run_helpers('check_alias present').returncode, 0)
            self.assertNotEqual(self.run_helpers('check_alias missing_fixture_alias').returncode, 0)

    def test_custom_git_configuration_parses(self):
        self.shell.allow('git','/usr/bin/git')
        self.shell.env['GIT_CONFIG_NOSYSTEM']='1'
        config=self.shell.home/'.gitconfig'
        config.write_text('[core]\n pager = custom-pager --flag\n[pull]\n rebase = false\n[push]\n autoSetupRemote = false\n')
        self.assertEqual(self.run_helpers('check_git_configuration').returncode,0)
        config.write_text('[broken\n')
        self.assertNotEqual(self.run_helpers('check_git_configuration').returncode,0)

    def test_numeric_version_failure_is_failure(self):
        for status in (0,1):
            self.shell.stub('pi',stdout='0.85.1\n',status=status)
            result = self.run_helpers('command_matches "[0-9]" pi --version')
            self.assertEqual(result.returncode,status)
        self.shell.stub('pi',stdout='broken\n')
        self.assertNotEqual(self.run_helpers('command_matches "[0-9]" pi --version').returncode,0)

    def test_reporting_preserves_intentional_nonzero_pipeline(self):
        self.shell.stub('shim',stdout='use work\n',status=1)
        result = self.shell.run('pass=0; fail=0; skip=0\n'+self.reporting+'''\nt shim 'shim | grep -q work'\ntest "$pass" -eq 1 && test "$fail" -eq 0\n''')
        self.assertEqual(result.returncode,0,result.stderr)


if __name__ == '__main__':
    unittest.main()
