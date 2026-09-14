import shlex
import sys
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, region


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture()
        self.addCleanup(self.shell.close)
        source=SOURCE.read_text()
        self.helpers=region(source,'# Required agent installation helpers.\n','# End required agent installation helpers.')
        self.preamble='set -euo pipefail\nAGENT_USER=fixture\nas_agent() { /bin/bash -c "$*"; }\nok() { echo "OK $*"; }\nwarn() { echo "WARN $*"; }\n'
        self.final=source[source.index('required_installations_ready || exit 1'):]
        self.optional=region(source,'if [[ $WITH_DEV -eq 1 ]]; then\n  if agent_version uv','\n# Copy root\'s existing Claude')
        self.optional='if [[ $WITH_DEV -eq 1 ]]; then\n  if agent_version uv'+self.optional
        for name,path in [('mkdir','/bin/mkdir'),('mktemp','/usr/bin/mktemp'),('rm','/bin/rm'),('ln','/bin/ln'),('sh','/bin/sh'),('cp','/bin/cp'),('chmod','/bin/chmod'),('head','/usr/bin/head'),('cat','/bin/cat')]:
            self.shell.allow(name,path)
        self.shell.env.update(c_green='',c_off='',WORKSPACE=str(self.shell.root),COPY_AUTH='1')
        self.writer('curl', '''
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({'command':'curl','argv':sys.argv[1:]})+'\\n')
Path(sys.argv[sys.argv.index('-o')+1]).write_text(os.environ['INSTALLER_BODY'])
sys.exit(int(os.environ.get('CURL_STATUS','0')))
''')

    def writer(self,name,body):
        p=self.shell.bin/name
        if p.is_symlink(): p.unlink()
        p.write_text(f'#!{sys.executable}\nimport os,sys,json\nfrom pathlib import Path\n'+body)
        p.chmod(0o755)

    def binary(self,name,output='1.2.3',status=0):
        path=self.shell.home/'.local/bin'/name
        path.parent.mkdir(parents=True,exist_ok=True)
        if path.is_symlink(): path.unlink()
        path.write_text('#!/bin/bash\nprintf "%s\\n" '+shlex.quote(output)+'\nexit '+str(status)+'\n')
        path.chmod(0o755)
        return path

    def installer(self,name,output='1.2.3',status=0):
        destination='$HOME/.opencode/bin' if name=='opencode' else '$HOME/.local/bin'
        binary='#!/bin/bash\nprintf "%s\\n" '+shlex.quote(output)+'\nexit '+str(status)+'\n'
        return f'mkdir -p "{destination}"\nprintf %s {shlex.quote(binary)} > "{destination}/{name}"\nchmod +x "{destination}/{name}"\n'

    def run_install(self,name,env=None,ending='required_installations_ready'):
        return self.shell.run(self.preamble+self.helpers+f'\ninstall_required_agent {name} https://fixture.invalid/install '+('sh' if name=='codex' else 'bash')+'\n'+ending, env=env)

    def test_native_first_install_and_healthy_rerun(self):
        for name in ('claude','codex','opencode'):
            with self.subTest(name=name):
                env={'INSTALLER_BODY':self.installer(name)}
                self.assertEqual(self.run_install(name,env).returncode,0)
                count=len(self.shell.calls())
                result=self.run_install(name,{'CURL_STATUS':'22'})
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('already installed',result.stdout)
                self.assertEqual(len(self.shell.calls()),count)
        self.assertEqual(list((self.shell.home/'.agentbox').glob('installer.*')),[])

    def test_native_failure_stages_and_private_logs(self):
        for name in ('claude','codex','opencode'):
            for stage in ('download','install','version','blank'):
                with self.subTest(name=name,stage=stage):
                    path=self.shell.home/'.local/bin'/name
                    if path.exists() or path.is_symlink(): path.unlink()
                    env={'INSTALLER_BODY':self.installer(name,output='' if stage=='blank' else '1.2.3',status=9 if stage=='version' else 0),'CURL_STATUS':'22' if stage=='download' else '0'}
                    if stage=='install': env['INSTALLER_BODY']='echo detailed-error >&2\nexit 8\n'
                    result=self.run_install(name,env,self.final)
                    self.assertNotEqual(result.returncode,0)
                    self.assertIn('Required installations failed: '+name,result.stdout)
                    self.assertNotIn('Done.',result.stdout)
                    self.assertEqual(list((self.shell.home/'.agentbox').glob('installer.*')),[])
                    log=self.shell.home/'.agentbox'/('install-'+name+'.log')
                    self.assertEqual(log.stat().st_mode & 0o777,0o600)
                    if stage=='install': self.assertIn('detailed-error',log.read_text())
                    if stage in ('version','blank'):
                        health=self.shell.home/'.agentbox'/('health-'+name+'.log')
                        self.assertEqual(health.stat().st_mode & 0o777,0o600)
                        self.assertIn('Version command',health.read_text())
                        if stage=='version': self.assertIn('1.2.3',health.read_text())
                    if stage=='download': self.assertFalse(path.exists() or path.is_symlink())

    def test_broken_existing_agents_reinstall_instead_of_accepting_root_shim(self):
        for name in ('claude','codex','opencode'):
            self.shell.stub(name,stdout='healthy root shim\n')
            self.binary(name,status=7)
            result=self.run_install(name,{'INSTALLER_BODY':self.installer(name)})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('already installed',result.stdout)
        path=self.shell.home/'.local/bin/claude';path.unlink();path.symlink_to(self.shell.root/'missing')
        result=self.run_install('claude',{'INSTALLER_BODY':self.installer('claude')})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('already installed',result.stdout)

    def test_pi_success_failure_and_unhealthy_versions(self):
        self.writer('npm', '''
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({'command':'npm','argv':sys.argv[1:]})+'\\n')
if sys.argv[1]=='install':
    if os.environ.get('NPM_FAIL')=='1': sys.exit(7)
    p=Path(os.environ['HOME'])/'.local/bin/pi'
    p.write_text(os.environ['PI_BINARY']);p.chmod(0o755)
''')
        for failure,version,status,expected in [('1','1.2.3',0,1),('0','1.2.3',7,1),('0','',0,1),('0','1.2.3',0,0)]:
            path=self.shell.home/'.local/bin/pi'
            if path.exists(): path.unlink()
            env={'NPM_FAIL':failure,'PI_BINARY':'#!/bin/bash\nprintf "%s\\n" '+shlex.quote(version)+'\nexit '+str(status)}
            self.assertEqual(bool(self.run_install('pi',env).returncode),bool(expected))
        calls=[c for c in self.shell.calls() if c['command']=='npm' and c['argv'][0]=='install']
        self.assertTrue(all('--ignore-scripts' in c['argv'] for c in calls))
        count=len(self.shell.calls())
        self.assertEqual(self.run_install('pi').returncode,0)
        self.assertEqual(len(self.shell.calls()),count)

    def test_node_unavailable_and_optional_uv_failure(self):
        source=SOURCE.read_text()
        node=region(source, '# pi needs Node >=22.19.0; keep root and apt on the distro runtime.\n','if [[ $WITH_DEV -eq 1 ]]; then\n  if agent_version uv')
        result=self.shell.run(self.preamble+self.helpers+'\nensure_node_runtime() { return 1; }\n'+node+self.final)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('failed: node pi',result.stdout)
        self.assertNotIn('Done.',result.stdout)
        result=self.shell.run(self.preamble+self.helpers+'\nWITH_DEV=1\n'+self.optional+'\n'+self.final,env={'CURL_STATUS':'22','INSTALLER_BODY':'exit 0'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('uv install failed',result.stdout)
        self.assertIn('Done.',result.stdout)

    def test_large_artifact_and_bounded_private_log(self):
        log=self.shell.home/'.agentbox/install-claude.log'
        log.parent.mkdir(parents=True)
        log.write_text('old');log.chmod(0o644)
        code="from pathlib import Path; Path('large-artifact').write_bytes(b'x'*2097152); print('x'*2097152)"
        installer=shlex.quote(sys.executable)+' -c '+shlex.quote(code)+'\n'+self.installer('claude')
        result=self.run_install('claude',{'INSTALLER_BODY':installer})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.shell.root/'large-artifact').stat().st_size,2097152)
        self.assertLessEqual(log.stat().st_size,1048576)
        self.assertEqual(log.stat().st_mode & 0o777,0o600)
        (self.shell.home/'.local/bin/claude').unlink()
        failing=shlex.quote(sys.executable)+' -c '+shlex.quote(code)+'\nexit 8\n'
        result=self.run_install('claude',{'INSTALLER_BODY':failing})
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(log.stat().st_size,1048576)

    def test_summary_names_all_failures_and_optional_warning_is_success(self):
        result=self.shell.run(self.preamble+self.helpers+'\nrecord_required_failure claude\nrecord_required_failure pi\necho helpers-created\n'+self.final)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('helpers-created',result.stdout)
        self.assertIn('failed: claude pi',result.stdout)
        self.assertNotIn('Done.',result.stdout)
        source=SOURCE.read_text()
        optional=region(source, '  INSTALLED_TC=', '\n  if have tailcat; then')
        optional='  INSTALLED_TC='+optional
        self.shell.stub('dpkg-query',status=1)
        self.shell.stub('curl',status=22)
        result=self.shell.run(self.preamble+self.helpers+'\nTAILCAT_VERSION=0.6.0\nTC_ARCH=amd64\n'+optional+'\n'+self.final)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Done.',result.stdout)


if __name__=='__main__': unittest.main()
