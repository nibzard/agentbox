import shlex
import sys
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, heredoc


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.shell = ShellFixture(); self.addCleanup(self.shell.close)
        self.fragment = heredoc(SOURCE.read_text(), "cat > /usr/local/bin/agent-status <<'EOF'")
        config = self.shell.root/'agentbox.conf'
        config.write_text('AGENT_USER=dev\nWORKSPACE='+shlex.quote(str(self.shell.root))+ '\n')
        release = self.shell.root/'os-release'; release.write_text('PRETTY_NAME=fixture\n')
        self.helper = self.shell.bin/'agent-status'
        body = self.shell.render(self.fragment).replace('/etc/agentbox.conf', str(config)).replace('/etc/os-release', str(release)).replace('/usr/local/bin/agent-status', str(self.helper))
        self.helper.write_text(body); self.helper.chmod(0o755)
        self.assertEqual(self.shell.calls(), [])
        self.shell.stub('getent', stdout=f'dev:x:1000:1000::{self.shell.home}:/bin/bash\n')
        self.executable('id', 'if [ "$1" = -u ]; then echo "${FIXTURE_UID:-1000}"; else echo "${FIXTURE_USER:-dev}"; fi')
        for name in ('hostname', 'uname', 'nproc', 'cut', 'free', 'awk', 'df', 'tmux', 'sed', 'ss', 'sort', 'ls'):
            self.executable(name, 'exit 0')
        self.shell.stub('pgrep', stdout='2\n')
        local = self.shell.home/'.local/bin'; local.mkdir(parents=True)
        self.local = local
        for name in ('claude', 'codex', 'opencode'):
            self.executable(name, 'echo local-'+name, local)
        self.executable('node', 'echo agent-node', local)
        self.executable('pi', 'node --version', local)
        self.shell.stub('node', stdout='wrong-root-node\n')
        self.executable('tailcat', 'if [ "$1" = version ]; then echo "${TAILCAT_VERSION:-v1}"; else printf "%s\\n" "${KEY_NAMES:-one}"; fi')

    def executable(self, name, body, directory=None):
        path = (directory or self.shell.bin)/name
        path.write_text('#!/bin/bash\n'+body+'\n'); path.chmod(0o755)
        return path

    def invoke(self, env=None):
        return self.shell.run('agent-status', env=env, timeout=10)

    def test_quoted_render_and_two_runtime_states(self):
        self.assertTrue(self.fragment.quoted)
        first = self.invoke({'TAILCAT_VERSION':'v1', 'KEY_NAMES':'one'})
        second = self.invoke({'TAILCAT_VERSION':'v2', 'KEY_NAMES':'two\nthree'})
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn('v1', first.stdout); self.assertIn('saved-keys: 1', first.stdout)
        self.assertIn('v2', second.stdout); self.assertIn('saved-keys: 2', second.stdout)
        self.assertIn('processes: 2', second.stdout)
        self.assertEqual([c['argv'] for c in self.shell.calls() if c['command']=='pgrep'], [['-xc','tailcat']]*2)

    def test_same_user_local_agents_and_auth_presence(self):
        auth = self.shell.home/'.codex/auth.json'; auth.parent.mkdir(); auth.write_text('{}')
        result = self.invoke()
        for name in ('claude','codex','opencode'):
            self.assertIn('local-'+name, result.stdout)
        self.assertIn('agent-node', result.stdout); self.assertNotIn('wrong-root-node', result.stdout)
        self.assertIn('auth-file present', result.stdout); self.assertIn('auth-file absent', result.stdout)
        self.assertNotIn('signed in', result.stdout)
        self.assertFalse(any(c['command']=='su' for c in self.shell.calls()))

    def test_root_uses_configured_login_and_preserves_argv(self):
        su = self.shell.bin/'su'
        su.write_text(f'''#!{sys.executable}
import json,os,subprocess,sys
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({{'command':'su','argv':sys.argv[1:]}})+'\\n')
env=os.environ.copy();env['FIXTURE_UID']='1000';env['FIXTURE_USER']='dev'
sys.exit(subprocess.run(['/bin/bash','-c',sys.argv[sys.argv.index('-c')+1]],env=env).returncode)
'''); su.chmod(0o755)
        args=['', "space 'quote'", '$(touch no-execution)']
        result = self.shell.run('agent-status '+' '.join(shlex.quote(a) for a in args), env={'FIXTURE_UID':'0'}, timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('agent-node', result.stdout)
        calls = [c for c in self.shell.calls() if c['command']=='su']
        self.assertEqual(len(calls),1); self.assertEqual(calls[0]['argv'][:3], ['-','dev','-c'])
        # Bash %q preserves the exact spellings even for empty arguments.
        recorded = self.shell.run('set -- '+calls[0]['argv'][3]+'; printf "<%s>" "$@"')
        self.assertEqual(recorded.stdout, ''.join('<'+a+'>' for a in [str(self.helper)]+args))
        self.assertFalse((self.shell.root/'no-execution').exists())

    def test_session_and_workspace_fallbacks(self):
        for status in (0, 1):
            with self.subTest(status=status):
                self.executable('tmux', f'exit {status}')
                self.executable('ls', f'exit {status}')
                result = self.invoke()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('  (none)', result.stdout)
                workspace = result.stdout.split('workspace', 1)[1]
                self.assertIn('  (empty)' if status == 0 else '  (unavailable)', workspace)
        self.executable('tmux', 'echo stale-session; exit 1')
        self.executable('ls', 'echo partial-listing; exit 1')
        result = self.invoke()
        self.assertNotIn('stale-session', result.stdout)
        self.assertNotIn('partial-listing', result.stdout)
        self.assertIn('  (none)', result.stdout)
        self.assertIn('  (unavailable)', result.stdout)

    def test_unavailable_commands_and_other_caller(self):
        (self.local/'claude').unlink()
        self.executable('codex', 'echo 9.9.9; exit 1', self.local)
        self.executable('opencode', 'exit 0', self.local)
        self.executable('tailcat', 'echo 8.8.8; exit 1')
        result = self.invoke()
        self.assertGreaterEqual(result.stdout.count('(unavailable)'),4)
        self.assertNotIn('9.9.9',result.stdout); self.assertNotIn('8.8.8',result.stdout)
        self.assertIn('saved-keys: unavailable',result.stdout)
        self.shell.log.unlink()
        other = self.invoke({'FIXTURE_USER':'outsider'})
        self.assertIn('unavailable for this caller', other.stdout)
        self.assertEqual(self.shell.calls(), [])


if __name__ == '__main__': unittest.main()
