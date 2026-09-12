"""Infrastructure checks; feature regressions live in separate test modules."""
import os
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, heredoc, region


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.source = SOURCE.read_text()
        self.shell = ShellFixture()
        self.addCleanup(self.shell.close)

    def test_unique_and_invalid_anchors(self):
        self.assertEqual(region('start\nbody\nend', 'start\n', '\nend'), 'body')
        for source, start, end in [('x', 'missing', 'x'), ('a a z', 'a', 'z'), ('end start', 'start', 'end')]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                region(source, start, end)

    def test_invalid_heredocs(self):
        anchor = "cat <<'END'"
        for source in ['', anchor + '\nx\n', anchor + '\nEND\n' + anchor + '\nEND\n', 'cat <<\n']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                heredoc(source, anchor if source != 'cat <<\n' else 'cat <<')

    def test_quoted_vm_share_and_stub_behavior(self):
        fragment = heredoc(self.source, "cat > /usr/local/bin/vm-share <<'EOF'")
        self.assertTrue(fragment.quoted)
        script = self.shell.render(fragment)
        self.assertEqual(self.shell.run(script, syntax=True).returncode, 0)
        self.shell.stub('id', stdout='1000\n')
        for status, output in [(0, 'first\n'), (17, 'second\n')]:
            self.shell.stub('tailcat', stdout=output, status=status)
            result = self.shell.run('set -- 3000\n' + script)
            self.assertEqual(result.returncode, status)
            self.assertEqual(result.stdout, output)
            self.assertEqual(self.shell.calls()[-1]['argv'], ['serve', '3000'])
        self.assertEqual(self.shell.run(script).returncode, 2)

    def test_interpolated_work(self):
        fragment = heredoc(self.source, 'cat > /usr/local/bin/work <<EOF')
        self.assertFalse(fragment.quoted)
        script = self.shell.render(fragment, env={'AGENT_USER': 'fixtureuser', 'WORKSPACE': str(self.shell.root)})
        self.assertEqual(self.shell.run(script, syntax=True).returncode, 0)
        self.shell.stub('infocmp')
        self.shell.stub('id', stdout='0\n')
        self.shell.stub('su')
        self.assertEqual(self.shell.run('set -- session\n' + script).returncode, 0)
        call = self.shell.calls()[-1]
        self.assertEqual(call['command'], 'su')
        self.assertEqual(call['argv'][:3], ['-', 'fixtureuser', '-c'])
        self.assertIn('cd ' + str(self.shell.root), call['argv'][3])
        self.assertIn('session', call['argv'][3])

    def test_concatenated_verifier_syntax_only(self):
        fragments = [heredoc(self.source, 'cat > /usr/local/bin/agentbox-verify <<EOF'),
                     heredoc(self.source, "cat >> /usr/local/bin/agentbox-verify <<'EOF'")]
        script = self.shell.render_many(fragments, env={'AGENT_USER': 'fixtureuser', 'WORKSPACE': str(self.shell.root)})
        self.assertEqual(self.shell.run(script, syntax=True).returncode, 0)
        self.assertIn('AGENT_USER=fixtureuser', script)
        self.assertTrue(script.endswith(fragments[1].body))
        self.assertEqual(self.shell.calls(), [])

    def test_syntax_negative_control(self):
        self.assertNotEqual(self.shell.run('if then\n', syntax=True).returncode, 0)

    def test_child_environment_and_cleanup(self):
        original = os.environ.copy()
        with ShellFixture() as shell:
            root = shell.root
            result = shell.run('printf "%s" "$HOME" > child-home; printf "%s" "$PRIVATE_TEST"', env={'PRIVATE_TEST': 'synthetic'})
            self.assertEqual(result.stdout, 'synthetic')
            self.assertEqual((root / 'child-home').read_text(), str(shell.home))
        self.assertFalse(root.exists())
        self.assertEqual(os.environ, original)

    def test_timeout_kills_descendants(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.shell.run('(while :; do :; done) &\nprintf "%s" "$!" > child.pid\nwait\n', timeout=0.2)
        # A second invocation succeeds after the timeout; the fixture remains usable.
        self.assertEqual(self.shell.run('printf recovered').stdout, 'recovered')
        pid = int((self.shell.root / 'child.pid').read_text())
        # A killed child may briefly remain as an orphan zombie. ps never runs
        # provisioner code and distinguishes that harmless state from a live leak.
        state = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
        self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith('Z'), state.stdout)

    def test_forbidden_command_is_stubbed(self):
        result = self.shell.run('sudo true')
        self.assertEqual(result.returncode, 126)
        self.assertIn('Forbidden host command', result.stderr)


if __name__ == '__main__':
    unittest.main()
