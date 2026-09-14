import shlex
import sys
import unittest

sys.dont_write_bytecode=True
from support import SOURCE, ShellFixture, heredoc


class SharingTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture();self.addCleanup(self.shell.close)
        self.config=self.shell.root/'agentbox.conf';self.config.write_text('AGENT_USER=dev\nWORKSPACE=/src\n')
        for name in ('vm-share','vm-ssh'):
            body=heredoc(SOURCE.read_text(),f"cat > /usr/local/bin/{name} <<'EOF'").body.replace('/etc/agentbox.conf',str(self.config))
            path=self.shell.bin/name;path.write_text(body);path.chmod(0o755)
        self.shell.stub('tailcat')
        self.shell.stub('id',stdout='1000\n')

    def invoke(self,args,name='vm-share',env=None):
        return self.shell.run(name+' '+' '.join(shlex.quote(arg) for arg in args),env=env)

    def test_default_ports_all_and_ordinary_flags(self):
        for args in (['3000'],['3000,8080'],['all'],['--key=saved','3000'],['--key','saved','all'],['--verbose','3000','',"space 'quote'",'$(touch nope)']):
            with self.subTest(args=args):
                self.assertEqual(self.invoke(args).returncode,0)
                self.assertEqual(self.shell.calls()[-1]['argv'],['serve']+args)
        self.assertFalse((self.shell.root/'nope').exists())

    def test_ephemeral_translation_and_ssh_equivalence(self):
        self.assertEqual(self.invoke(['--ephemeral','3000','']).returncode,0)
        self.assertEqual(self.shell.calls()[-1]['argv'],['serve','--key=new','3000',''])
        command=['--ephemeral','3000','--','app','--key','value']
        self.assertEqual(self.invoke(command).returncode,0)
        self.assertEqual(self.shell.calls()[-1]['argv'],['serve','--key=new']+command[1:])
        self.assertEqual(self.invoke(['--ephemeral'],name='vm-ssh').returncode,0)
        self.assertEqual(self.shell.calls()[-1]['argv'],['serve','--key=new','no-auth-ssh'])

    def test_missing_operands_and_key_conflicts(self):
        for args in ([],[''],['--ephemeral'],['--ephemeral',''],['--ephemeral','--','app'],['--','app'],['--key=saved'],['--key','saved'],['--verbose'],['--ephemeral','--key=saved','3000'],['--ephemeral','3000','--key','saved']):
            with self.subTest(args=args):
                result=self.invoke(args)
                self.assertEqual(result.returncode,2,result.stderr)
        self.assertFalse(any(call['command']=='tailcat' for call in self.shell.calls()))

    def test_root_custom_user_has_identical_final_argv(self):
        id_script=self.shell.bin/'id'
        id_script.write_text('#!/bin/bash\nprintf "%s\\n" "${FIXTURE_UID:-0}"\n');id_script.chmod(0o755)
        su=self.shell.bin/'su'
        su.write_text(f'''#!{sys.executable}
import json,os,subprocess,sys
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({{'command':'su','argv':sys.argv[1:]}})+'\\n')
env=os.environ.copy();env['FIXTURE_UID']='1000'
sys.exit(subprocess.run(['/bin/bash','-c',sys.argv[sys.argv.index('-c')+1]],env=env).returncode)
''');su.chmod(0o755)
        args=['--ephemeral','3000','',"space 'quoted'",'$(touch not-run); *']
        for uid in ('1000','0'):
            result=self.invoke(args,env={'FIXTURE_UID':uid})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(self.shell.calls()[-1]['argv'],['serve','--key=new']+args[1:])
        switches=[c for c in self.shell.calls() if c['command']=='su']
        self.assertEqual(len(switches),1);self.assertEqual(switches[0]['argv'][:3],['-','dev','-c'])
        self.assertFalse((self.shell.root/'not-run').exists())


if __name__=='__main__':unittest.main()
