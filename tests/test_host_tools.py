#!/usr/bin/env python3
"""Host regression tests with fake Docker/curl; no host services are modified."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.install = self.base / 'hivepanel'
        (self.install / 'runtime').mkdir(parents=True)
        (self.install / 'backups').mkdir()
        self.envfile = self.install / '.env'
        self.original_env = 'HIVEPANEL_VERSION=1.0.8\nPANEL_DOMAIN="panel.example.com"\nHTTP_PORT=9000\nAPP_KEY=keep-this-secret\nDB_PASSWORD=keep-db\nDB_ROOT_PASSWORD=keep-root\nREDIS_PASSWORD=keep-redis\n'
        self.envfile.write_text(self.original_env)
        self.envfile.chmod(0o600)
        self.compose = self.install / 'compose.yaml'
        self.compose.write_text('custom deployment, ports and mounts must be preserved\n')
        self.log = self.base / 'commands.jsonl'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        fake = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as f: f.write(json.dumps([name]+args)+'\\n')
joined=' '.join(args)
if os.environ.get('FAIL_MATCH') and os.environ['FAIL_MATCH'] in joined: sys.exit(1)
if name=='docker':
    if 'port nginx 80' in joined: print(os.environ['TEST_NGINX_BINDING'])
    elif 'mariadb-dump' in joined: print('-- valid database dump')
    elif 'config --services' in joined: print('panel\\nqueue\\nscheduler\\nnginx\\nmariadb\\nredis')
    elif 'ps -a -q' in joined or 'ps -q' in joined: print('fake-container')
    elif 'inspect' in joined: print('running healthy')
if name=='curl':
    if args[-1] != os.environ['TEST_HEALTH_URL']: sys.exit(1)
    print('200')
if name=='systemctl' and 'is-active --quiet hivepanel-update.service' in joined: sys.exit(int(os.environ.get('UPDATE_ACTIVE', '1')))
'''
        for name in ['docker', 'curl', 'sleep', 'systemctl']:
            path = self.bin / name
            path.write_text(fake)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], HIVEPANEL_INSTALL_DIR=str(self.install), HIVEPANEL_COMMON=str(ROOT / 'host/hivepanel-common.sh'), HIVEPANEL_HOST_HELPER=str(ROOT / 'host/hivepanel-host.py'), COMMAND_LOG=str(self.log), TEST_NGINX_BINDING='0.0.0.0:18080', TEST_HEALTH_URL='http://127.0.0.1:18080/up', HIVEPANEL_RUNTIME_UID=str(os.getuid()), HIVEPANEL_RUNTIME_GID=str(os.getgid()))
        self.env.pop('HIVEPANEL_VERSION', None)

    def request(self, value):
        (self.install / 'runtime/update-request.json').write_text(json.dumps(value))

    def run_update(self, **overrides):
        return subprocess.run(['bash', str(ROOT / 'host/hivepanel-update')], env=dict(self.env, **overrides), capture_output=True, text=True, timeout=15)

    def status(self):
        return json.loads((self.install / 'runtime/update-status.json').read_text())

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_success_custom_port_preserves_config(self):
        self.request({'version': '1.0.9'})
        metadata = {'version': '1.0.8', 'installed_at': 'existing', 'custom': True}
        (self.install / 'runtime/installation.json').write_text(json.dumps(metadata))
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()['state'], 'complete')
        self.assertTrue(Path(self.status()['backup']).exists())
        self.assertEqual(self.compose.read_text(), 'custom deployment, ports and mounts must be preserved\n')
        self.assertIn('APP_KEY=keep-this-secret', self.envfile.read_text())
        self.assertIn('HIVEPANEL_VERSION=1.0.9', self.envfile.read_text())
        self.assertFalse((self.install / 'runtime/update-request.json').exists())
        commands = self.commands()
        self.assertFalse(any('--force-recreate' in call for call in commands))
        self.assertIn(['docker', 'compose', 'exec', '-T', 'nginx', 'nginx', '-s', 'reload'], commands)
        self.assertTrue(any(self.env['TEST_HEALTH_URL'] in call for call in commands))
        updated = json.loads((self.install / 'runtime/installation.json').read_text())
        self.assertEqual(updated['installed_at'], 'existing')
        self.assertTrue(updated['custom'])

    def test_health_uses_actual_binding_across_ports(self):
        for binding, url in [
            ('0.0.0.0:80', 'http://127.0.0.1:80/up'),
            ('0.0.0.0:8090', 'http://127.0.0.1:8090/up'),
            ('0.0.0.0:9000', 'http://127.0.0.1:9000/up'),
            ('0.0.0.0:49152', 'http://127.0.0.1:49152/up'),
            ('127.0.0.1:32768', 'http://127.0.0.1:32768/up'),
            ('10.10.0.10:12345', 'http://10.10.0.10:12345/up'),
            ('[::]:8443', 'http://[::1]:8443/up'),
            ('[::1]:18080', 'http://[::1]:18080/up'),
        ]:
            with self.subTest(binding=binding):
                result = subprocess.run(['bash', '-c', 'INSTALL_DIR="$HIVEPANEL_INSTALL_DIR"; cd "$INSTALL_DIR"; source "$HIVEPANEL_COMMON"; health_check'], env=dict(self.env, TEST_NGINX_BINDING=binding, TEST_HEALTH_URL=url), capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands()[-1][-1], url)

    def test_invalid_binding_fails_without_curl(self):
        for binding in ['', '0.0.0.0:0', '0.0.0.0:65536', '0.0.0.0:invalid']:
            with self.subTest(binding=binding):
                before = len(self.commands()) if self.log.exists() else 0
                result = subprocess.run(['bash', '-c', 'INSTALL_DIR="$HIVEPANEL_INSTALL_DIR"; cd "$INSTALL_DIR"; source "$HIVEPANEL_COMMON"; health_check'], env=dict(self.env, TEST_NGINX_BINDING=binding), capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == 'curl' for call in self.commands()[before:]))

    def test_backup_failure_consumed_once(self):
        self.request({'version': '1.0.9'})
        result = self.run_update(FAIL_MATCH='mariadb-dump')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()['state'], 'failed')
        self.assertEqual(self.envfile.read_text(), self.original_env)
        before = self.commands()
        self.assertEqual(self.run_update().returncode, 0)
        self.assertEqual(self.commands(), before)
        self.assertEqual(len(list((self.install / 'backups/update-history').glob('*.json'))), 1)
        self.assertFalse(Path(self.status()['backup']).exists())

    def test_migration_failure_retains_backup_and_exits_maintenance(self):
        self.request({'version': '1.0.9'})
        result = self.run_update(FAIL_MATCH='migrate --force')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()['state'], 'failed')
        self.assertTrue(Path(self.status()['backup']).exists())
        self.assertIn(['docker', 'compose', 'exec', '-T', 'panel', 'php', 'artisan', 'up'], self.commands())
        self.assertFalse((self.install / 'runtime/update-request.json').exists())

    def test_invalid_request_has_failed_status(self):
        self.request({'version': '1.0.9; touch /tmp/pwned'})
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()['state'], 'failed')
        self.assertEqual(self.envfile.read_text(), self.original_env)
        self.assertFalse(self.log.exists())

    def test_failed_download_does_not_change_env(self):
        self.request({'version': '1.0.9'})
        self.assertNotEqual(self.run_update(FAIL_MATCH='pull panel').returncode, 0)
        self.assertEqual(self.envfile.read_text(), self.original_env)
        self.assertEqual(self.status()['state'], 'failed')

    def test_http_failure_retains_failed_status(self):
        self.request({'version': '1.0.9'})
        result = self.run_update(FAIL_MATCH=self.env['TEST_HEALTH_URL'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()['state'], 'failed')
        self.assertIn('HTTP health check', self.status()['message'])
        self.assertTrue(Path(self.status()['backup']).exists())
        self.assertFalse((self.install / 'runtime/update-request.json').exists())

    def test_status_json_escaping(self):
        helper = ROOT / 'host/hivepanel-host.py'
        path = self.install / 'runtime/test.json'
        message = 'quotes " and slash \\ and\nnewline'
        subprocess.run(['python3', str(helper), 'status', str(path), 'failed', '1.0.9', message, ''], check=True, env=self.env)
        self.assertEqual(json.loads(path.read_text())['message'], message)
        self.assertEqual(path.stat().st_mode & 0o777, 0o660)

    def repair_fixture(self):
        # Redirect privileged destinations into the isolated fixture. Production
        # code paths remain unmodified in the shipped archive.
        fixture = self.base / 'installer'
        (fixture / 'host').mkdir(parents=True)
        for source in (ROOT / 'host').iterdir():
            if source.is_file():
                target = fixture / 'host' / source.name
                target.write_bytes(source.read_bytes())
        hostroot = self.base / 'host-root'
        (hostroot / 'usr/local/sbin').mkdir(parents=True)
        (hostroot / 'etc/systemd/system').mkdir(parents=True)
        for source in [ROOT / 'repair.sh', ROOT / 'host/hivepanel-common.sh']:
            value = source.read_text().replace('/usr/local/', str(hostroot) + '/usr/local/').replace('/etc/systemd/', str(hostroot) + '/etc/systemd/')
            target = fixture / ('repair.sh' if source.name == 'repair.sh' else 'host/hivepanel-common.sh')
            target.write_text(value)
        chown = self.bin / 'chown'
        chown.write_text('#!/usr/bin/env bash\nexit 0\n')
        chown.chmod(0o755)
        return fixture, hostroot

    @unittest.skipUnless(os.geteuid() == 0, 'repair requires root')
    def test_repair_apply_preserves_data_and_archives_request(self):
        fixture, hostroot = self.repair_fixture()
        self.request({'version': '1.0.9'})
        data = self.install / 'cell-data'
        data.write_text('keep cell data')
        result = subprocess.run(['bash', str(fixture / 'repair.sh'), '--yes'], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.envfile.read_text(), self.original_env)
        self.assertEqual(data.read_text(), 'keep cell data')
        self.assertFalse((self.install / 'runtime/update-request.json').exists())
        self.assertEqual(self.status()['state'], 'failed')
        self.assertTrue((hostroot / 'usr/local/sbin/hivepanel-update').exists())
        unit = (hostroot / 'etc/systemd/system/hivepanel-update.service').read_text()
        self.assertIn('Environment=HIVEPANEL_INSTALL_DIR=' + str(self.install), unit)
        self.assertEqual(len(list((self.install / 'backups/update-history').glob('repair-*.json'))), 1)
        for call in self.commands():
            self.assertFalse(any(word in call for word in ['--volumes', '--force-recreate', 'pull', 'down', 'migrate']))

    @unittest.skipUnless(os.geteuid() == 0, 'repair requires root')
    def test_repair_refuses_running_update(self):
        fixture, hostroot = self.repair_fixture()
        self.request({'version': '1.0.9'})
        result = subprocess.run(['bash', str(fixture / 'repair.sh'), '--yes'], env=dict(self.env, UPDATE_ACTIVE='0'), capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Update runner is active', result.stderr)
        self.assertTrue((self.install / 'runtime/update-request.json').exists())
        self.assertFalse((hostroot / 'usr/local/sbin/hivepanel-update').exists())

    @unittest.skipUnless(os.geteuid() == 0, 'repair requires root')
    def test_repair_check_is_read_only(self):
        result = subprocess.run(['bash', str(ROOT / 'repair.sh'), '--check'], env=self.env, capture_output=True, text=True, timeout=15)
        # Current host runner may be absent; diagnostic failure is expected.
        self.assertIn(result.returncode, [0, 1], result.stderr)
        self.assertIn('No changes applied', result.stdout)
        self.assertEqual(self.envfile.read_text(), self.original_env)
        self.assertEqual(sorted(p.name for p in (self.install / 'backups').iterdir()), [])
        for call in self.commands():
            self.assertFalse(any(word in call for word in ['up', 'restart', 'stop', 'enable', 'daemon-reload', 'pull', 'down', 'rm']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
