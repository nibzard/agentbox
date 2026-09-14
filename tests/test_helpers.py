import json
from pathlib import Path
import shlex
import sys
import unittest

sys.dont_write_bytecode=True
from support import SOURCE, ShellFixture, heredoc, region


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture();self.addCleanup(self.shell.close)
        self.source=SOURCE.read_text()
        self.config=self.shell.root/'agentbox.conf'
        self.workspace=self.shell.root/"work space's $literal"
        self.workspace.mkdir()
        self.config.write_text('AGENT_USER=dev\nWORKSPACE='+shlex.quote(str(self.workspace))+'\n')
        self.shell.stub('id',stdout='1000\n')
        self.shell.stub('infocmp')
        self.shell.stub('tailcat')
        self.shell.stub('tmux')
        tmux=self.shell.bin/'tmux'
        tmux.write_text(f'''#!{sys.executable}
import json,os,sys
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({{'command':'tmux','argv':sys.argv[1:],'cwd':os.getcwd(),'term':os.environ.get('TERM')}})+'\\n')
''')
        tmux.chmod(0o755)
        self.shell.stub('getent',status=2)
        self.shell.stub('realpath',stdout='/valid/workspace\n')
        self.identity=region(self.source,'# Configured identity helpers.\n','# End configured identity helpers.')
        self.serialize='ca_export() {'+region(self.source,'ca_export() {','\nemit_ca_profile()')
        self.shell.env.update(AGENT_USER='dev',WORKSPACE=str(self.workspace))
        for name,path in [('mktemp','/usr/bin/mktemp'),('sh','/bin/sh'),('chmod','/bin/chmod'),('mv','/bin/mv'),('rm','/bin/rm'),('mkdir','/bin/mkdir'),('ln','/bin/ln'),('cat','/bin/cat')]:
            self.shell.allow(name,path)

    def body(self,name):
        if name=='agentbox-verify':
            first=heredoc(self.source,'cat > /usr/local/bin/agentbox-verify <<EOF')
            second=heredoc(self.source,"cat >> /usr/local/bin/agentbox-verify <<'EOF'")
            # Reexec-only fixture: no acceptance checks or host mutations run.
            body=first.body.replace('$(declare -f node_version_supported)','')+region(second.body,'# A fresh exec session can have a stale /proc (see /etc/profile.d/10-agentbox.sh).\n','pass=0; fail=0; skip=0')
        else: body=heredoc(self.source,"cat > /usr/local/bin/"+name+" <<'EOF'").body
        return body.replace('/etc/agentbox.conf',str(self.config))

    def execute(self,name,args=(),env=None):
        return self.shell.run('set -- '+' '.join(shlex.quote(a) for a in args)+'\n'+self.body(name),env=env)

    def test_config_roundtrip_and_validation_before_mutations(self):
        for user,workspace in [('agent','/workspace'),('dev','/src'),('dev',str(self.workspace))]:
            result=self.shell.run('set -euo pipefail\nwarn() { echo "$*"; }\n'+self.serialize+'\n'+self.identity+'\nvalidate_agentbox_configuration\npersist_agentbox_configuration "$CONFIG"\n. "$CONFIG"\nprintf "%s|%s" "$AGENT_USER" "$WORKSPACE"',env={'AGENT_USER':user,'WORKSPACE':workspace,'CONFIG':str(self.config)})
            self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,user+'|'+workspace)
            self.assertNotIn('TOKEN',self.config.read_text())
        for user,workspace,canonical in [('root','/src','/src'),('bad;user','/src','/src'),('dev','relative','/relative'),('dev','/','/'),('dev','/tmp/..','/'),('dev','/src\nbad','/src')]:
            self.shell.stub('realpath',stdout=canonical+'\n')
            self.shell.stub('useradd')
            result=self.shell.run('set -e\nwarn() { echo "$*"; }\n'+self.identity+'\nvalidate_agentbox_configuration\nuseradd should-not-run',env={'AGENT_USER':user,'WORKSPACE':workspace})
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(any(c['command']=='useradd' for c in self.shell.calls()))

    def test_existing_account_rejects_unsupported_shell_group_uid(self):
        for uid,shell,group in [('0','/bin/bash','dev'),('1000','/bin/zsh','dev'),('1000','/bin/bash','other')]:
            self.shell.stub('getent',stdout=f'dev:x:{uid}:1000::/home/dev:{shell}\n')
            self.shell.stub('id',stdout=group+'\n')
            result=self.shell.run('warn() { echo "$*"; }\n'+self.identity+'\nvalidate_agentbox_configuration')
            self.assertNotEqual(result.returncode,0,result.stderr)
        self.shell.stub('getent',stdout='dev:x:1000:1000::/home/dev:/bin/bash\n')
        self.shell.stub('id',stdout='dev\n')
        self.assertEqual(self.shell.run('warn() { echo "$*"; }\n'+self.identity+'\nvalidate_agentbox_configuration').returncode,0)

    def test_work_attach_or_create_workspace_and_term(self):
        for term_status in (0,1):
            for existing in ('present','absent'):
                self.shell.stub('infocmp',status=term_status)
                result=self.execute('work',["session ' ; $(touch nope)"],{'TERM':'known-term','SESSION_STATE':existing})
                self.assertEqual(result.returncode,0,result.stderr)
                call=self.shell.calls()[-1]
                self.assertEqual(call['command'],'tmux')
                self.assertEqual(call['term'],'known-term' if term_status==0 else 'xterm-256color')
                self.assertEqual(call['argv'],['new-session','-A','-s',"session ' ; $(touch nope)",'-c',str(self.workspace)])
                self.assertEqual(Path(call['cwd']),self.workspace.resolve())
                self.assertFalse((self.workspace/'nope').exists())
        self.config.write_text('AGENT_USER=dev\nWORKSPACE=/missing-fixture-workspace\n')
        result=self.execute('work')
        self.assertNotEqual(result.returncode,0);self.assertIn('Cannot access configured workspace',result.stderr)

    def test_root_transitions_preserve_all_arguments(self):
        self.shell.stub('id',stdout='0\n')
        args=['3000','',"a 'quote'",'$(touch no-execution); *', 'line\nbreak']
        # su stub logs target then evaluates the real quoted command in a child
        # Bash with a harmless function of the same helper name capturing argv.
        target=self.shell.bin/'su'
        target.write_text(f'''#!{sys.executable}
import json,os,subprocess,sys
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({{'command':'su','argv':sys.argv[1:]}})+'\\n')
command=sys.argv[sys.argv.index('-c')+1]
name=command.split()[0]
script=name+'() {{ printf "%s\\\\0" "$@"; }}; '+command
sys.exit(subprocess.run(['/bin/bash','-c',script]).returncode)
''');target.chmod(0o755)
        for name in ('work','vm-ssh','vm-share','agentbox-verify'):
            result=self.execute(name,args)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.split('\0')[:-1],args)
            self.assertEqual(self.shell.calls()[-1]['argv'][:3],['-','dev','-c'])
            self.assertFalse((self.shell.root/'no-execution').exists())

    def test_direct_sharing_and_project_use_config(self):
        self.assertEqual(self.execute('vm-share',['3000','']).returncode,0)
        self.assertEqual(self.shell.calls()[-1]['argv'],['serve','3000',''])
        self.assertEqual(self.execute('vm-ssh',['arg']).returncode,0)
        self.assertEqual(self.shell.calls()[-1]['argv'],['serve','no-auth-ssh','arg'])
        self.shell.stub('git')
        result=self.execute('new-project',['fixture-project'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.workspace/'fixture-project/CLAUDE.md').exists())
        self.assertTrue((self.workspace/'fixture-project/AGENTS.md').is_symlink())

    def test_profile_and_aliases_load_same_configuration(self):
        profile=heredoc(self.source,"cat > /etc/profile.d/10-agentbox.sh <<'EOF'").body
        loading=region(profile,'# agentbox: shared defaults for every login shell (root and agent user)\n','# Steel runs ssh')
        loading=loading.replace('/etc/agentbox.conf',str(self.config))
        bashrc=heredoc(self.source,'put_block "$home/.bashrc" "agentbox" <<\'EOF\'').body
        w=next(line for line in bashrc.splitlines() if line.startswith('alias w='))
        result=self.shell.run(loading+'\nshopt -s expand_aliases\n'+w+'\nw\nprintf "%s|%s" "$AGENT_USER" "$PWD"',env={'AGENT_USER':'wrong','WORKSPACE':'/wrong'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'dev|'+str(self.workspace))
        become=next(line.strip() for line in bashrc.splitlines() if 'alias become=' in line)
        self.shell.stub('su')
        result=self.shell.run(loading+'\nshopt -s expand_aliases\n'+become+'\nbecome')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.shell.calls()[-1]['argv'],['-','dev'])


if __name__=='__main__':unittest.main()
