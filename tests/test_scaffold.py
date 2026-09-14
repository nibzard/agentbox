from pathlib import Path
import shlex
import sys
import unittest

sys.dont_write_bytecode=True
from support import SOURCE, ShellFixture, heredoc


class ScaffoldTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture();self.addCleanup(self.shell.close)
        self.parent=self.shell.root/"parent space's";self.parent.mkdir()
        self.config=self.shell.root/'agentbox.conf'
        self.config.write_text('AGENT_USER=fixture\nWORKSPACE='+shlex.quote(str(self.parent))+'\n')
        self.body=heredoc(SOURCE.read_text(),"cat > /usr/local/bin/new-project <<'EOF'").body.replace('/etc/agentbox.conf',str(self.config))
        for name,path in [('git','/usr/bin/git'),('mkdir','/bin/mkdir'),('cat','/bin/cat'),('ln','/bin/ln')]:self.shell.allow(name,path)
        realpath=self.shell.bin/'realpath'
        realpath.write_text(f'#!{sys.executable}\nimport os,sys\nprint(os.path.realpath(sys.argv[-1]))\n');realpath.chmod(0o755)
        self.hooks=self.shell.root/'hooks';self.hooks.mkdir()
        config=self.shell.home/'.gitconfig'
        config.write_text('[user]\n name = Fixture\n email = fixture@example.test\n[init]\n defaultBranch = main\n[commit]\n gpgsign = false\n[core]\n hooksPath = '+str(self.hooks)+'\n')
        self.shell.env['GIT_CONFIG_NOSYSTEM']='1'

    def run_scaffold(self,args,env=None):
        return self.shell.run('set -- '+' '.join(shlex.quote(str(a)) for a in args)+'\n'+self.body,env=env,timeout=6)

    def git(self,path,*args):
        result=self.shell.run('git -C '+shlex.quote(str(path))+' '+' '.join(shlex.quote(a) for a in args))
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout

    def repository(self,name='repository'):
        path=self.parent/name;path.mkdir()
        self.git(path,'init','-q')
        (path/'tracked').write_text('original')
        self.git(path,'add','tracked');self.git(path,'commit','-qm','initial')
        return path

    def test_fresh_and_empty_targets_commit_exact_scaffold(self):
        for name in ('fresh','empty'):
            if name=='empty':(self.parent/name).mkdir()
            result=self.run_scaffold([name])
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('created ',result.stdout)
            path=self.parent/name
            self.assertEqual(set(self.git(path,'ls-tree','--name-only','HEAD').splitlines()),{'.gitignore','CLAUDE.md','AGENTS.md'})
            self.assertTrue((path/'.tmp').is_dir())
            self.assertEqual((path/'AGENTS.md').readlink(),Path('CLAUDE.md'))

    def test_rejects_nonempty_and_dirty_staged_repository_without_mutation(self):
        ordinary=self.parent/'ordinary';ordinary.mkdir();(ordinary/'untracked').write_text('keep')
        self.assertNotEqual(self.run_scaffold(['ordinary']).returncode,0)
        self.assertEqual(list(ordinary.iterdir()),[ordinary/'untracked'])
        repo=self.repository()
        (repo/'tracked').write_text('staged');self.git(repo,'add','tracked')
        (repo/'tracked').write_text('dirty');(repo/'untracked').write_text('keep')
        before=((repo/'.git/HEAD').read_bytes(),(repo/'.git/index').read_bytes(),self.git(repo,'rev-parse','HEAD'))
        self.assertNotEqual(self.run_scaffold(['repository']).returncode,0)
        self.assertEqual(before,((repo/'.git/HEAD').read_bytes(),(repo/'.git/index').read_bytes(),self.git(repo,'rev-parse','HEAD')))
        self.assertEqual((repo/'tracked').read_text(),'dirty');self.assertEqual((repo/'untracked').read_text(),'keep')

    def test_worktree_and_enclosing_repository_rejected(self):
        repo=self.repository()
        worktree=self.parent/'worktree'
        self.git(repo,'worktree','add','-qb','fixture-worktree',str(worktree))
        before=(worktree/'.git').read_bytes()
        self.assertNotEqual(self.run_scaffold(['worktree']).returncode,0)
        self.assertEqual((worktree/'.git').read_bytes(),before)
        for parent in (repo,repo/'missing/nested'):
            self.assertNotEqual(self.run_scaffold(['new',parent]).returncode,0)
            self.assertFalse((parent/'new').exists())
        self.assertFalse((repo/'missing').exists())

    def test_invalid_names_parents_symlink_and_environment(self):
        for name in ('','.', '..','../escape','nested/name','-option','bad\nname'):
            result=self.run_scaffold([name])
            self.assertNotEqual(result.returncode,0)
        self.assertNotEqual(self.run_scaffold(['valid','']).returncode,0)
        self.assertNotEqual(self.run_scaffold(['valid',self.parent,'extra']).returncode,0)
        outside=self.shell.root/'outside';outside.mkdir()
        (self.parent/'link').symlink_to(outside,target_is_directory=True)
        self.assertNotEqual(self.run_scaffold(['link']).returncode,0)
        self.assertEqual(list(outside.iterdir()),[])
        repo=self.repository();before=(repo/'.git/index').read_bytes()
        result=self.run_scaffold(['redirected'],env={'GIT_DIR':str(repo/'.git')})
        self.assertNotEqual(result.returncode,0);self.assertIn('GIT_DIR',result.stderr)
        self.assertFalse((self.parent/'redirected').exists());self.assertEqual((repo/'.git/index').read_bytes(),before)

    def test_commit_failure_keeps_files_and_never_stages_unrelated_work(self):
        hook=self.hooks/'pre-commit';hook.write_text('#!/bin/bash\nprintf unrelated > unrelated\nexit 1\n');hook.chmod(0o755)
        result=self.run_scaffold(['failed'])
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('created ',result.stdout);self.assertIn('files remain',result.stderr)
        path=self.parent/'failed'
        self.assertTrue((path/'CLAUDE.md').exists());self.assertTrue((path/'unrelated').exists())
        self.assertEqual(set(self.git(path,'diff','--cached','--name-only').splitlines()),{'.gitignore','CLAUDE.md','AGENTS.md'})

    def test_nonexistent_parent_outside_repository_succeeds(self):
        parent=self.parent/'new parent'/'deeper'
        result=self.run_scaffold(['new',parent])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((parent/'new/.git').is_dir())


if __name__=='__main__':unittest.main()
