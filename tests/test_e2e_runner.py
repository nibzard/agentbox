import json
import shlex
import sys
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, heredoc


class E2ERunnerTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture(); self.addCleanup(self.shell.close)
        self.shell.allow('dirname','/usr/bin/dirname')
        self.shell.env['STEEL_API_KEY']='synthetic'
        jq=self.shell.bin/'jq'
        jq.write_text(f'''#!{sys.executable}
import json,sys
try:
 value=json.load(sys.stdin)['data']['id']
 if not isinstance(value,str): raise ValueError()
 print(value)
except (ValueError,KeyError,TypeError): sys.exit(1)
''');jq.chmod(0o755)
        steel=self.shell.bin/'steel'
        steel.write_text(f'''#!{sys.executable}
import json,os,sys
args=sys.argv[1:]; command=args[1]
body=sys.stdin.read() if command=='ssh' else ''
# Model Steel's shell_join contract: each remote argv is individually quoted.
if command=='ssh':
 import shlex
 remote=args[args.index('--')+1:]
 assert shlex.split(shlex.join(remote))==remote
phase=command
if command=='ssh':
 phase='install' if body.startswith('#!/usr/bin/env bash') else args[-1]
with open(os.environ['STUB_LOG'],'a') as log:
 log.write(json.dumps({{'command':command,'phase':phase,'argv':args,'body':body}})+'\\n')
if phase==os.environ.get('FAIL_PHASE'): sys.exit(19)
if command=='create': print(os.environ.get('CREATE_JSON','{{"data":{{"id":"cmp_Fixture123"}}}}'))
''');steel.chmod(0o755)

    def run_runner(self, **env):
        return self.shell.run('bash '+shlex.quote(str(SOURCE.parent/'tests/e2e.sh')),env=env,timeout=15)

    def test_embedded_remote_scripts_parse(self):
        source=(SOURCE.parent/'tests/e2e.sh').read_text()
        for stage in ('preserve','assertions'):
            body=heredoc(source, f"remote bash -s -- {stage} <<'REMOTE'").body
            self.assertEqual(self.shell.run(body,syntax=True).returncode,0)
            if stage=='assertions':
                python=heredoc(body, 'python3 - "$AGENT_USER" "$WORKSPACE" "$E2E_TOKEN" <<\'PY\'').body
                compile(python,'remote-pty','exec')

    def test_exact_argv_and_preservation_order(self):
        result=self.run_runner(AGENTBOX_AGENT_USER='dev',AGENTBOX_WORKSPACE="/src space 'quoted'",AGENTBOX_ARGS='--lean\n--no-tailcat',AGENTBOX_TEST_PRESERVATION='1')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.shell.calls()
        self.assertEqual([c['phase'] for c in calls],['create','install','preserve','install','assertions','exec','delete'])
        install=calls[1]['argv'];self.assertIn("WORKSPACE=/src space 'quoted'",install);self.assertIn('AGENT_USER=dev',install)
        self.assertEqual(install[-5:],['bash','-s','--','--lean','--no-tailcat'])
        self.assertIn('sha256sum --check --status',calls[4]['body'])
        self.assertIn('pty.fork()',calls[4]['body'])
        self.assertIn('for creator_root in (True,False):',calls[4]['body'])
        self.assertIn('for root in (creator_root,not creator_root,creator_root,not creator_root):',calls[4]['body'])
        self.assertIn('curl -fsS --max-time',calls[4]['body'])
        self.assertIn('for name in claude codex opencode pi',calls[4]['body'])

    def test_failure_status_and_owned_cleanup(self):
        for phase in ('install','preserve','assertions','exec'):
            with self.subTest(phase=phase):
                self.shell.log.unlink(missing_ok=True)
                result=self.run_runner(FAIL_PHASE=phase,AGENTBOX_TEST_PRESERVATION='1')
                self.assertEqual(result.returncode,19,result.stderr)
                self.assertEqual(self.shell.calls()[-1]['phase'],'delete')
                self.assertNotIn('e2e passed',result.stdout)
        self.assertNotEqual(self.run_runner(FAIL_PHASE='delete').returncode,0)

    def test_keep_and_borrowed_computers(self):
        for env in ({'KEEP':'1'},{'COMPUTER_ID':'cmp-Existing123'}):
            with self.subTest(env=env):
                self.shell.log.unlink(missing_ok=True)
                self.assertEqual(self.run_runner(**env).returncode,0)
                self.assertFalse(any(c['phase']=='delete' for c in self.shell.calls()))
        self.shell.log.unlink()
        self.assertEqual(self.run_runner(COMPUTER_ID='cmp_Existing123',AGENTBOX_TEST_PRESERVATION='1').returncode,2)
        self.assertEqual(self.shell.calls(),[])

    def test_invalid_inputs_never_provision_or_delete(self):
        for payload in ('not json','{"data":{"id":null}}','{"data":{"id":"../../other"}}','{"data":{"id":"cmp_"}}'):
            with self.subTest(payload=payload):
                self.shell.log.unlink(missing_ok=True)
                self.assertNotEqual(self.run_runner(CREATE_JSON=payload).returncode,0)
                self.assertEqual([c['phase'] for c in self.shell.calls()],['create'])
        for env in ({'AGENTBOX_ARGS':'--lean;touch x'},{'AGENTBOX_ARGS':'--lean\n--bad'},{'COMPUTER_ID':'cmp_x;bad'}):
            self.shell.log.unlink(missing_ok=True)
            self.assertEqual(self.run_runner(**env).returncode,2)
            self.assertEqual(self.shell.calls(),[])
        (self.shell.bin/'jq').unlink()
        self.assertEqual(self.run_runner().returncode,2)
        self.assertEqual(self.shell.calls(),[])


if __name__=='__main__': unittest.main()
