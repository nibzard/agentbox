import json
import shlex
import unittest

from support import SOURCE, ShellFixture, region


class PreservationTests(unittest.TestCase):
    def setUp(self):
        self.shell=ShellFixture();self.addCleanup(self.shell.close)
        source=SOURCE.read_text()
        self.helpers='put_block() ('+region(source,'put_block() (','\nas_agent()')
        self.dotfiles='write_dotfiles() {'+region(source,'write_dotfiles() {','\nwrite_dotfiles "$AGENT_HOME"')
        self.agent=region(source,'for directory in .claude .codex .config/opencode .pi/agent .agentbox; do','\n# Secrets file')
        self.agent='for directory in .claude .codex .config/opencode .pi/agent .agentbox; do'+self.agent
        self.preamble='set -euo pipefail\nwarn() { echo "$*"; }\nhave() { command -v "$1" >/dev/null 2>&1; }\n'
        for name,path in [('mktemp','/usr/bin/mktemp'),('mkdir','/bin/mkdir'),('cat','/bin/cat'),('cp','/bin/cp'),('mv','/bin/mv'),('rm','/bin/rm'),('awk','/usr/bin/awk'),('git','/usr/bin/git'),('ln','/bin/ln')]:self.shell.allow(name,path)
        self.shell.stub('chown')
        self.shell.env.update(AGENT_HOME=str(self.shell.home),AGENT_USER='fixture',WORKSPACE='/workspace',IS_STEEL='0',TIER='small',CPUS='1',MEM_MB='1024',DISK_FREE_GB='5',GIT_CONFIG_NOSYSTEM='1',GIT_NAME='',GIT_EMAIL='')

    def run_defaults(self,extra='',env=None):
        return self.shell.run(self.preamble+self.helpers+self.dotfiles+'\nwrite_dotfiles "$HOME" fixture\n'+self.agent+'\n'+extra,env=env,timeout=8)

    def git_value(self,key):
        result=self.shell.run('git config --file "$HOME/.gitconfig" '+shlex.quote(key))
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout.rstrip('\n')

    def test_fresh_defaults_agent_and_root(self):
        for owner in ('fixture','root'):
            home=self.shell.root/owner;home.mkdir()
            result=self.run_defaults(env={'HOME':str(home),'AGENT_HOME':str(home),'AGENT_USER':owner})
            self.assertEqual(result.returncode,0,result.stderr)
            for name in ('.inputrc','.tmux.conf','.vimrc','.gitconfig','.bashrc','.claude/CLAUDE.md'):
                self.assertTrue((home/name).stat().st_size)
            for name in ('.codex/AGENTS.md','.config/opencode/AGENTS.md','.pi/agent/AGENTS.md'):
                self.assertEqual((home/name).readlink(),home/'.claude/CLAUDE.md')
            settings=json.loads((home/'.claude/settings.json').read_text())
            self.assertIn('Read(./.env)',settings['permissions']['deny'])
            self.assertIn('approval_policy = "on-request"',(home/'.codex/config.toml').read_text())
            config=self.shell.run('git config --file '+shlex.quote(str(home/'.gitconfig'))+' --get-regexp "core.pager|pull.rebase|push.autoSetupRemote"')
            self.assertEqual(config.returncode,0)
            self.assertIn('core.pager less',config.stdout);self.assertIn('pull.rebase true',config.stdout);self.assertIn('push.autosetupremote true',config.stdout)
        self.shell.stub('delta')
        fresh=self.shell.root/'delta';fresh.mkdir()
        self.assertEqual(self.run_defaults(env={'HOME':str(fresh),'AGENT_HOME':str(fresh)}).returncode,0)
        self.assertIn('pager = delta',(fresh/'.gitconfig').read_text())

    def test_rerun_preserves_edits_empty_files_and_owned_metadata(self):
        self.assertEqual(self.run_defaults().returncode,0)
        paths=['.inputrc','.tmux.conf','.vimrc','.gitconfig','.claude/CLAUDE.md','.claude/settings.json','.codex/config.toml']
        for name in paths:
            path=self.shell.home/name;path.write_text('custom '+name+'\n');path.chmod(0o600)
        (self.shell.home/'.gitconfig').write_text('[user]\n name = Manual\n email = manual@example.test\n[credential]\n helper = custom-helper\n')
        snapshots={name:(self.shell.home/name).read_bytes() for name in paths}
        self.shell.log.unlink()
        self.assertEqual(self.run_defaults().returncode,0)
        for name in paths:
            self.assertEqual((self.shell.home/name).read_bytes(),snapshots[name])
            self.assertEqual((self.shell.home/name).stat().st_mode & 0o777,0o600)
        self.assertFalse(any(c['command']=='chown' for c in self.shell.calls()))
        for name in paths:(self.shell.home/name).write_text('')
        self.assertEqual(self.run_defaults().returncode,0)
        self.assertTrue(all((self.shell.home/name).stat().st_size==0 for name in paths))

    def test_explicit_identity_changes_only_requested_key(self):
        self.assertEqual(self.run_defaults().returncode,0)
        config=self.shell.home/'.gitconfig';config.chmod(0o600)
        self.shell.run('git config --file "$HOME/.gitconfig" user.name Manual\ngit config --file "$HOME/.gitconfig" user.email manual@example.test\ngit config --file "$HOME/.gitconfig" credential.helper custom-helper')
        name='Person "Quote" \\ backslash\nnext'
        self.assertEqual(self.run_defaults(env={'GIT_NAME_SET':'x','GIT_NAME':name}).returncode,0)
        self.assertEqual(self.git_value('user.name'),name)
        self.assertEqual(self.git_value('user.email'),'manual@example.test')
        self.assertEqual(self.git_value('credential.helper'),'custom-helper')
        self.assertEqual(config.stat().st_mode & 0o777,0o600)

    def test_symlink_files_and_instruction_choices_survive(self):
        self.assertEqual(self.run_defaults().returncode,0)
        outside=self.shell.root/'outside';outside.write_text('outside unchanged');outside.chmod(0o640)
        for name in ('.inputrc','.tmux.conf','.vimrc','.gitconfig','.bashrc','.claude/CLAUDE.md','.claude/settings.json','.codex/config.toml'):
            path=self.shell.home/name;path.unlink();path.symlink_to(outside)
        regular=self.shell.home/'.codex/AGENTS.md';regular.unlink();regular.write_text('custom instructions')
        alternate=self.shell.home/'.config/opencode/AGENTS.md';alternate.unlink();alternate.symlink_to(outside)
        dangling=self.shell.home/'.pi/agent/AGENTS.md';dangling.unlink();dangling.symlink_to(self.shell.root/'missing')
        self.assertEqual(self.run_defaults(env={'GIT_NAME_SET':'x','GIT_NAME':'override'}).returncode,0)
        self.assertEqual(outside.read_text(),'outside unchanged');self.assertEqual(outside.stat().st_mode & 0o777,0o640)
        self.assertEqual(regular.read_text(),'custom instructions');self.assertEqual(alternate.readlink(),outside);self.assertTrue(dangling.is_symlink())

    def test_symlinked_config_directory_not_followed(self):
        outside=self.shell.root/'outside-config';outside.mkdir();(outside/'sentinel').write_text('keep')
        (self.shell.home/'.claude').symlink_to(outside,target_is_directory=True)
        result=self.run_defaults()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(list(outside.iterdir()),[outside/'sentinel'])

    def test_credential_copy_preserves_symlinked_destinations(self):
        source=SOURCE.read_text()
        copies=region(source, "# Copy root's existing Claude login so the agent user doesn't have to re-auth.\n", 'hdr "8/10  tailcat')
        root=self.shell.root/'synthetic-root';(root/'.claude').mkdir(parents=True);(root/'.codex').mkdir()
        (root/'.claude/.credentials.json').write_text('synthetic fixture')
        (root/'.codex/auth.json').write_text('synthetic fixture')
        outside=self.shell.root/'external';outside.mkdir()
        (self.shell.home/'.claude').symlink_to(outside,target_is_directory=True)
        (self.shell.home/'.codex').mkdir()
        (self.shell.home/'.codex/auth.json').symlink_to(outside/'missing-auth')
        self.shell.stub('install')
        result=self.shell.run(self.preamble+self.helpers+'\nCOPY_AUTH=1\n'+copies.replace('/root/',str(root)+'/'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(c['command']=='install' for c in self.shell.calls()))
        self.assertEqual(list(outside.iterdir()),[])

    def test_acceptance_allows_regular_custom_instructions(self):
        self.assertEqual(self.run_defaults().returncode,0)
        for name in ('.codex/AGENTS.md','.config/opencode/AGENTS.md','.pi/agent/AGENTS.md'):
            path=self.shell.home/name;path.unlink();path.write_text('custom regular instructions')
        (self.shell.home/'.claude/settings.json').write_text('{}')
        (self.shell.home/'.gitconfig').write_text('[core]\n pager = custom-pager\n[pull]\n rebase = false\n')
        self.shell.stub('jq')
        source=SOURCE.read_text()
        checks=region(source,'section "agent configs"\n','\nsection "interactive aliases')
        git_check='check_git_configuration() {'+region(source,'check_git_configuration() {','\n# End verifier resource helpers.')
        result=self.shell.run('set -e\nt() { eval "$2"; }\n'+git_check+'\n'+checks)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_managed_block_preserves_external_content_and_mode(self):
        bashrc=self.shell.home/'.bashrc'
        bashrc.write_text('before\n# >>> agentbox >>>\nold\n# <<< agentbox <<<\nafter\n');bashrc.chmod(0o600)
        before_owner=(bashrc.stat().st_uid,bashrc.stat().st_gid)
        for _ in range(2):self.assertEqual(self.run_defaults().returncode,0)
        text=bashrc.read_text()
        self.assertTrue(text.startswith('before\nafter\n'))
        self.assertEqual(text.count('# >>> agentbox >>>'),1)
        self.assertEqual(text.count('# <<< agentbox <<<'),1)
        self.assertEqual(bashrc.stat().st_mode & 0o777,0o600)
        self.assertEqual((bashrc.stat().st_uid,bashrc.stat().st_gid),before_owner)


if __name__=='__main__':unittest.main()
