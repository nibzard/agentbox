import hashlib
import io
import shlex
import sys
import tarfile
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, region, heredoc


class NodeRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture();self.addCleanup(self.shell.close)
        self.source=SOURCE.read_text()
        self.helpers=region(self.source,'# User-local Node runtime helpers.\n','# End user-local Node runtime helpers.')
        self.predicate=region(self.helpers,'node_version_supported() {','\nselect_node_release()')
        self.predicate='node_version_supported() {'+self.predicate
        self.preamble='set -euo pipefail\nAGENT_USER=fixture\nok() { echo "$*"; }\nwarn() { echo "$*" >&2; }\nas_agent() { PATH="$HOME/.local/bin:$PATH" /bin/bash -c "$*"; }\n'
        for name,path in [('mkdir','/bin/mkdir'),('mktemp','/usr/bin/mktemp'),('rm','/bin/rm'),('mv','/bin/mv'),('ln','/bin/ln'),('chmod','/bin/chmod'),('head','/usr/bin/head'),('cat','/bin/cat'),('awk','/usr/bin/awk'),('tar','/usr/bin/tar')]:
            self.shell.allow(name,path)
        self.shell.stub('node',stdout='v20.0.0\n')
        self.shell.stub('uname',stdout='x86_64\n')
        self.shell.stub('jq',stdout='v24.21.0\n')
        self.shell.env['PAYLOAD_ROOT']=str(self.shell.root)
        self.python_command('curl', '''
with open(os.environ['STUB_LOG'],'a') as log: log.write(json.dumps({'command':'curl','argv':sys.argv[1:]})+'\\n')
if '-o' not in sys.argv:
    print('synthetic-index');sys.exit(int(os.environ.get('INDEX_STATUS','0')))
destination=Path(sys.argv[sys.argv.index('-o')+1])
source=root/('checksums' if sys.argv[-1].endswith('SHASUMS256.txt') else 'archive')
destination.write_bytes(source.read_bytes())
''')
        self.python_command('sha256sum', '''
line=sys.stdin.read().strip().split()
sys.exit(0 if len(line)==2 and hashlib.sha256(Path(line[1]).read_bytes()).hexdigest()==line[0] else 1)
''')
        self.archive()
        local=self.shell.home/'.local';local.mkdir(exist_ok=True)
        (local/'keep').write_text('unrelated')

    def python_command(self,name,body):
        p=self.shell.bin/name
        if p.is_symlink():p.unlink()
        p.write_text(f'#!{sys.executable}\nimport os,sys,json,hashlib\nfrom pathlib import Path\nroot=Path(os.environ["PAYLOAD_ROOT"])\n'+body);p.chmod(0o755)

    def archive(self,version='v24.21.0',status=0,corrupt=False):
        payload=io.BytesIO()
        node=f'#!/bin/bash\nif [ "$1" = -v ]; then echo {shlex.quote(version)}; exit {status}; fi\necho 11.0.0\n'
        files={'bin/node':node,'lib/node_modules/npm/bin/npm-cli.js':'#!/bin/bash\necho npm-local\n','lib/node_modules/npm/bin/npx-cli.js':'#!/bin/bash\necho npx-local\n'}
        with tarfile.open(fileobj=payload,mode='w:xz') as tar:
            for name,body in files.items():
                data=body.encode();info=tarfile.TarInfo('node-v24.21.0-linux-x64/'+name);info.size=len(data);info.mode=0o755
                tar.addfile(info,io.BytesIO(data))
        content=b'bad archive' if corrupt else payload.getvalue()
        (self.shell.root/'archive').write_bytes(content)
        checksum=hashlib.sha256(content).hexdigest()
        (self.shell.root/'checksums').write_text(checksum+'  node-v24.21.0-linux-x64.tar.xz\n'+checksum+'  node-v24.21.0-linux-arm64.tar.xz\n')

    def run_node(self,command='ensure_node_runtime',env=None):
        return self.shell.run(self.preamble+self.helpers+'\n'+command,env=env,timeout=8)

    def assert_unpromoted(self):
        runtime=self.shell.home/'.local/lib/agentbox-node'
        self.assertEqual(list(runtime.glob('runtime-*')),[])
        self.assertEqual(list(runtime.glob('.staging.*')),[])
        self.assertFalse((self.shell.home/'.local/bin/node').exists())
        self.assertEqual((self.shell.home/'.local/keep').read_text(),'unrelated')

    def test_numeric_boundary_and_malformed_versions(self):
        for version,expected in [('v18.0.0',1),('v20.10.0',1),('v22.0.0',1),('v22.18.9',1),('v22.19.0',0),('v22.19.1',0),('v24.0.0',0),('',1),('v22.019.0',1),('v24.0.0-rc.1',1),('v999999999999999999.0.0',1),('v$(touch sentinel).0.0',1)]:
            with self.subTest(version=version):self.assertEqual(self.run_node('node_version_supported '+shlex.quote(version)).returncode,expected)

    def test_healthy_runtime_skips_download(self):
        self.shell.stub('node',stdout='v22.19.0\n')
        self.assertEqual(self.run_node().returncode,0)
        self.assertFalse(any(c['command']=='curl' for c in self.shell.calls()))

    def test_failed_query_requires_install_even_with_numeric_output(self):
        self.shell.stub('node',stdout='v24.21.0\n',status=1)
        self.assertEqual(self.run_node().returncode,0)
        self.assertTrue(any(c['command']=='curl' for c in self.shell.calls()))

    def test_index_failures_and_no_eligible_release(self):
        for http,jq_status,candidates in [(22,0,'v24.21.0'),(0,4,''),(0,0,''),(0,0,'null'),(0,0,'v22.18.9'),(0,0,'v24.0.0-rc.1')]:
            with self.subTest(candidates=candidates,http=http):
                self.shell.stub('jq',stdout=candidates+'\n',status=jq_status)
                self.assertNotEqual(self.run_node(env={'INDEX_STATUS':str(http)}).returncode,0)
                self.assert_unpromoted()

    def test_architecture_mapping_and_rejection(self):
        for arch,wanted in [('x86_64','x64'),('aarch64','arm64')]:
            self.shell.stub('uname',stdout=arch+'\n')
            result=self.run_node('select_node_release\nprintf "%s" "$NODE_ARCH"')
            self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,wanted)
        self.shell.log.unlink()
        self.shell.stub('uname',stdout='riscv64\n')
        self.assertNotEqual(self.run_node().returncode,0)
        self.assertFalse(any(c['command']=='curl' for c in self.shell.calls()))

    def test_checksum_extract_and_staged_health_failure(self):
        for failure in ('missing','wrong','extract','version','nonzero'):
            with self.subTest(failure=failure):
                self.archive(version='v22.18.9' if failure=='version' else 'v24.21.0',status=7 if failure=='nonzero' else 0,corrupt=failure=='extract')
                if failure in ('missing','wrong'):(self.shell.root/'checksums').write_text('' if failure=='missing' else '0'*64+'  node-v24.21.0-linux-x64.tar.xz\n')
                result=self.run_node()
                self.assertNotEqual(result.returncode,0)
                self.assert_unpromoted()

    def test_success_preserves_root_path_and_unrelated_files(self):
        result=self.run_node('ensure_node_runtime\nas_agent "node -v; npm --version"\nnode -v')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('v24.21.0\nnpm-local\nv20.0.0',result.stdout)
        self.assertEqual((self.shell.home/'.local/keep').read_text(),'unrelated')
        self.assertEqual(list((self.shell.home/'.local/lib/agentbox-node').glob('.staging.*')),[])
        count=len([c for c in self.shell.calls() if c['command']=='curl'])
        self.assertEqual(self.run_node().returncode,0)
        self.assertEqual(len([c for c in self.shell.calls() if c['command']=='curl']),count)

    def test_verifier_embeds_same_predicate(self):
        fragment=heredoc(self.source,'cat > /usr/local/bin/agentbox-verify <<EOF')
        config=self.shell.root/'agentbox.conf'
        config.write_text('AGENT_USER=fixture\nWORKSPACE=/fixture\n')
        result=self.shell.run(self.predicate+'\n/bin/cat <<END\n'+fragment.body.replace('/etc/agentbox.conf',str(config))+'END\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.shell.run(result.stdout+'\nnode_version_supported v22.18.9').returncode,1)
        self.assertEqual(self.shell.run(result.stdout+'\nnode_version_supported v22.19.0').returncode,0)


if __name__=='__main__':unittest.main()
