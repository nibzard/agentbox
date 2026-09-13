import json
import sys
import unittest

sys.dont_write_bytecode = True
from support import SOURCE, ShellFixture, region


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.shell = ShellFixture()
        self.addCleanup(self.shell.close)
        self.source = SOURCE.read_text()
        self.ca = region(self.source, '# CA persistence helpers.\n', '# End CA persistence helpers.')
        self.lookup = region(self.source, 'if [[ $WITH_TAILCAT -eq 1 ]]; then\n', '  INSTALLED_TC=')
        for command, path in [('mktemp','/usr/bin/mktemp'),('sh','/bin/sh'),('chmod','/bin/chmod'),('mv','/bin/mv'),('rm','/bin/rm')]:
            self.shell.allow(command,path)
        self.profile = self.shell.root/'profile.sh'
        self.shell.env.update(PROFILE=str(self.profile), BUNDLE='/combined/public-and-egress.crt', ADDITIVE='/egress/only.crt')

    def run_ca(self, code, env=None):
        return self.shell.run('set -euo pipefail\n' + self.ca + '\n' + code, env=env)

    def read_profile(self, names):
        target = self.shell.root/'read-values'
        target.write_text(f'#!{sys.executable}\nimport json, os\nprint(json.dumps({{n:os.environ.get(n) for n in {names!r}}}))\n')
        target.chmod(0o755)
        result=self.shell.run('sh -c \' . "$PROFILE"; exec "$READER" \'',env={'READER':str(target)})
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)

    def test_file_only_detection_and_defaults(self):
        certificate=self.shell.root/'certificate'
        certificate.write_text('synthetic certificate')
        result=self.run_ca('detect_egress_ca "" "" "$CERTIFICATE"\ntest "$EGRESS_CA" = "$CERTIFICATE"\npersist_ca_profile "$PROFILE" "$BUNDLE" "$ADDITIVE"\necho reached', {'CERTIFICATE':str(certificate)})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'reached\n')
        values=self.read_profile(['SSL_CERT_FILE','REQUESTS_CA_BUNDLE','PIP_CERT','NPM_CONFIG_CAFILE','NODE_EXTRA_CA_CERTS','UV_NATIVE_TLS'])
        for key in ['SSL_CERT_FILE','REQUESTS_CA_BUNDLE','PIP_CERT','NPM_CONFIG_CAFILE']:
            self.assertEqual(values[key],'/combined/public-and-egress.crt')
        self.assertEqual(values['NODE_EXTRA_CA_CERTS'],'/egress/only.crt')
        self.assertEqual(values['UV_NATIVE_TLS'],'1')

    def test_no_ca_detected(self):
        result=self.run_ca('detect_egress_ca "" "$PROFILE"\ntest -z "$EGRESS_CA"\necho reached')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.profile.exists())

    def test_replacement_additive_and_literal_roundtrip(self):
        value="space '$HOME' $(touch should-not-exist) `touch also-not`\nsecond line"
        env={'REQUESTS_CA_BUNDLE':'/old/root.crt','NODE_EXTRA_CA_CERTS':'/keep/additive.crt','CUSTOM_CERT':value,'UV_NATIVE_TLS':'0'}
        result=self.run_ca('persist_ca_profile "$PROFILE" "$BUNDLE" "$ADDITIVE"',env)
        self.assertEqual(result.returncode,0,result.stderr)
        values=self.read_profile(list(env))
        self.assertEqual(values['REQUESTS_CA_BUNDLE'],'/combined/public-and-egress.crt')
        for key in ['NODE_EXTRA_CA_CERTS','CUSTOM_CERT','UV_NATIVE_TLS']:
            self.assertEqual(values[key],env[key])
        self.assertFalse((self.shell.root/'should-not-exist').exists())
        self.assertFalse((self.shell.root/'also-not').exists())
        self.assertEqual(list(self.shell.root.glob('profile.sh.tmp.*')),[])

    def test_validation_failure_keeps_previous_profile(self):
        self.profile.write_text('previous profile\n')
        self.shell.stub('sh',status=2)
        result=self.run_ca('persist_ca_profile "$PROFILE" "$BUNDLE" "$ADDITIVE"\necho unreachable')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('unreachable',result.stdout)
        self.assertEqual(self.profile.read_text(),'previous profile\n')
        self.assertEqual(list(self.shell.root.glob('profile.sh.tmp.*')),[])

    def test_tailcat_lookup_outcomes_under_errexit(self):
        cases=[('http',22,0,'', '0.6.0'), ('invalid-json',0,4,'','0.6.0'),
               ('missing',0,4,'','0.6.0'), ('null',0,4,'','0.6.0'),
               ('malformed',0,0,'../../bad','0.6.0'), ('valid',0,0,'v1.2.3','1.2.3')]
        for name,curl_status,jq_status,tag,expected in cases:
            with self.subTest(name=name):
                self.shell.stub('curl',stdout='synthetic response',status=curl_status)
                self.shell.stub('jq',stdout=tag+'\n',status=jq_status)
                self.shell.stub('dpkg',stdout='amd64\n')
                result=self.shell.run('set -euo pipefail\nwarn() { echo warning; }\nWITH_TAILCAT=1\nTAILCAT_VERSION=latest\nif [[ $WITH_TAILCAT -eq 1 ]]; then\n'+self.lookup+'fi\nprintf "reached:%s\\n" "$TAILCAT_VERSION"\n')
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('reached:'+expected,result.stdout)
                self.assertEqual(result.stdout.count('warning'),0 if name=='valid' else 1)

    def test_disabled_and_explicit_version_skip_lookup(self):
        self.shell.stub('dpkg',stdout='amd64\n')
        for enabled,version in [(0,'latest'),(1,'0.6.0')]:
            result=self.shell.run(f'set -euo pipefail\nWITH_TAILCAT={enabled}\nTAILCAT_VERSION={version}\nif [[ $WITH_TAILCAT -eq 1 ]]; then\n'+self.lookup+'fi\necho reached\n')
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(call['command'] in ('curl','jq') for call in self.shell.calls()))


if __name__ == '__main__':
    unittest.main()
