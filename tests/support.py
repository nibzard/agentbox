"""Source-derived shell fixtures. Never source the complete provisioner."""
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "agentbox.sh"


def unique_offset(source, anchor):
    if not anchor or source.count(anchor) != 1:
        raise ValueError(f"Expected exactly one anchor: {anchor!r}")
    return source.index(anchor)


def region(source, start, end):
    """Extract only the body between two unique, ordered textual anchors."""
    first = unique_offset(source, start) + len(start)
    last = unique_offset(source, end)
    if last < first:
        raise ValueError("End anchor precedes start anchor")
    return source[first:last]


@dataclass(frozen=True)
class Heredoc:
    body: str
    quoted: bool


def heredoc(source, anchor):
    """Anchor must identify the declaration line, including its << delimiter."""
    offset = unique_offset(source, anchor)
    line_start = source.rfind("\n", 0, offset) + 1
    line_end = source.find("\n", offset)
    if line_end < 0:
        raise ValueError("Missing heredoc body")
    declaration = source[line_start:line_end]
    match = re.search(r"<<(?P<quote>['\"]?)(?P<word>[A-Za-z_][A-Za-z_0-9]*)(?P=quote)\s*$", declaration)
    if not match:
        raise ValueError("Unsupported heredoc declaration")
    terminator = match['word']
    remaining = source[line_end + 1:].splitlines(keepends=True)
    body = []
    for line in remaining:
        if line.rstrip("\n") == terminator:
            return Heredoc(''.join(body), bool(match['quote']))
        body.append(line)
    raise ValueError(f"Unterminated heredoc: {terminator}")


class ShellFixture:
    """Child-only environment and PATH; commands must be explicitly allowed/stubbed.

    This is test isolation, not a sandbox for untrusted shell. Callers must select
    safe source regions and stub every external dependency before executing them.
    """
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agentbox-test-")
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.bin = self.root / 'bin'
        self.home.mkdir()
        self.bin.mkdir()
        self.log = self.root / 'argv.jsonl'
        self.env = os.environ.copy()
        self.env.clear()
        self.env.update(HOME=str(self.home), PATH=str(self.bin), LANG='C',
                        TMPDIR=str(self.root), STUB_LOG=str(self.log))
        self.allow('bash', '/bin/bash')
        for name in ('su', 'sudo', 'mount', 'apt', 'apt-get', 'steel', 'curl', 'wget'):
            self.stub(name, status=126, stderr=f"Forbidden host command: {name}\n")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        self.temporary.cleanup()

    def allow(self, name, path):
        target = self.bin / name
        if target.exists() or target.is_symlink():
            target.unlink()
        target.symlink_to(path)

    def stub(self, name, *, stdout='', stderr='', status=0):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
            raise ValueError('Invalid command name')
        target = self.bin / name
        if target.is_symlink():
            target.unlink()
        target.write_text(f'''#!{sys.executable}
import json, os, sys
with open(os.environ['STUB_LOG'], 'a') as log:
    log.write(json.dumps({{'command': {name!r}, 'argv': sys.argv[1:], 'cwd': os.getcwd()}}) + '\\n')
sys.stdout.write({stdout!r})
sys.stderr.write({stderr!r})
sys.exit({status!r})
''')
        target.chmod(0o755)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def run(self, script, *, env=None, timeout=3, syntax=False):
        child_env = self.env.copy()
        child_env.update(env or {})
        argv = ['/bin/bash', '--noprofile', '--norc']
        if syntax:
            argv.append('-n')
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, cwd=self.root,
                                   env=child_env, start_new_session=True)
        try:
            stdout, stderr = process.communicate(script, timeout=timeout)
            return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        finally:
            # Also remove descendants that outlive an otherwise successful shell.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()

    def render(self, fragment, *, env=None):
        if fragment.quoted:
            return fragment.body
        delimiter = 'AGENTBOX_FIXTURE_END'
        if delimiter in fragment.body.splitlines():
            raise ValueError('Rendering delimiter collision')
        result = self.run('/bin/cat <<' + delimiter + '\n' + fragment.body + delimiter + '\n', env=env)
        if result.returncode or result.stderr:
            raise ValueError(f'Heredoc rendering failed: {result.stderr}')
        return result.stdout

    def render_many(self, fragments, *, env=None):
        return ''.join(self.render(fragment, env=env) for fragment in fragments)
