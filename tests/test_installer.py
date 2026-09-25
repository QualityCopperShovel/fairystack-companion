"""Exercise the shipped shell installer with isolated macOS command fixtures."""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIGEST = 'ebfe8c9b3e93f98cf48049dab4a224a15333098a76d67b5122bd45c203bfe7c4'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'; self.home.mkdir()
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.archive = self.root / 'fixture.zip'
        with zipfile.ZipFile(self.archive, 'w') as z:
            z.writestr('FairyStack.app/Contents/MacOS/FairyStackCompanion', 'fixture')
        self.script = self.root / 'install.sh'
        self.script.write_text((ROOT / 'install.sh').read_text().replace(DIGEST, hashlib.sha256(self.archive.read_bytes()).hexdigest()))
        stub = self.bin / 'stub'
        stub.write_text('#!/usr/bin/env python3\n' + textwrap.dedent('''\
            import os,sys,time,zipfile,shutil,subprocess
            from pathlib import Path
            cmd=Path(sys.argv[0]).name; args=sys.argv[1:]
            with open(os.environ['CALLS'],'a') as f:f.write(cmd+' '+repr(args)+'\\n')
            if cmd=='uname': print('Darwin')
            elif cmd=='sw_vers': print('13.6')
            elif cmd=='id': print('501')
            elif cmd==os.environ.get('FAIL_STEP'): sys.exit(28)
            elif cmd==os.environ.get('HANG_STEP'):
                child=subprocess.Popen(['sleep','60'])
                Path(os.environ['CHILD_PID']).write_text(str(child.pid))
                time.sleep(60)
            elif cmd=='curl':
                dest=args[args.index('-o')+1]
                if os.environ.get('BAD_DIGEST'): Path(dest).write_text('corrupt')
                else: shutil.copyfile(os.environ['FIXTURE'],dest)
            elif cmd=='ditto':
                with zipfile.ZipFile(args[-2]) as z:z.extractall(args[-1])
            elif cmd=='codesign':
                if not args[args.index('-R')+1].startswith('='):
                    print('invalid requirement specification: expected a literal = prefix',file=sys.stderr);sys.exit(1)
                assert '7ZPTPEXGRC' in args[args.index('-R')+1]
                assert 'com.fairystack.companion' in args[args.index('-R')+1]
                assert Path(args[-1]).is_dir()
            elif cmd=='spctl': assert args[:3]==['--assess','--type','execute']
            elif cmd=='open': pass
            elif cmd=='defaults': print(os.environ.get('INSTALLED_VERSION','1.7.1'))
            elif cmd=='pgrep': sys.exit(0 if os.environ.get('RUNNING') else 1)
            else: sys.exit(5)
        '''))
        stub.chmod(0o755)
        for cmd in ['uname','sw_vers','id','curl','ditto','codesign','spctl','open','defaults','pgrep']:
            (self.bin/cmd).symlink_to(stub)
        self.env={**os.environ, 'HOME':str(self.home),'PATH':str(self.bin)+':'+os.environ['PATH'],
                  'FIXTURE':str(self.archive),'CALLS':str(self.root/'calls'),'CHILD_PID':str(self.root/'child')}
        self.target=self.home/'Applications/FairyStack.app'
        self.legacy=self.home/'Applications/FairyStack Companion.app'

    def run_installer(self, **env):
        return subprocess.run(['bash',str(self.script),'https://customer.fairystack.com'],
            env={**self.env,**env},capture_output=True,text=True,timeout=12)

    def assert_clean(self):
        self.assertFalse(list((self.home/'Applications').glob('.fairystack*')))

    def test_install_opens_app_and_own_origin_and_repeat_preserves_it(self):
        first=self.run_installer();self.assertEqual(first.returncode,0,first.stderr)
        self.assertTrue(self.target.is_dir());self.assert_clean()
        sentinel=self.target/'user-marker';sentinel.write_text('preserve')
        second=self.run_installer();self.assertEqual(second.returncode,0,second.stderr)
        self.assertEqual(sentinel.read_text(),'preserve')
        calls=(self.root/'calls').read_text()
        self.assertEqual(sum(line.startswith('curl ') for line in calls.splitlines()),1)
        self.assertIn('https://customer.fairystack.com/companions#pair',calls)
        self.assertIn('Installed and opened',second.stdout)

    def test_download_signature_and_gatekeeper_fail_closed(self):
        for step in ['curl','codesign','spctl']:
            with self.subTest(step=step):
                result=self.run_installer(FAIL_STEP=step)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('Installation failed while',result.stderr)
                self.assertFalse(self.target.exists());self.assert_clean()
        self.assertNotIn('open ',(self.root/'calls').read_text())

    def test_corrupted_download_never_unpacks(self):
        result=self.run_installer(BAD_DIGEST='1')
        self.assertNotEqual(result.returncode,0);self.assertIn('checksum',result.stderr)
        self.assertNotIn('ditto ',(self.root/'calls').read_text());self.assert_clean()

    def test_existing_untrusted_installation_is_not_overwritten(self):
        self.target.mkdir(parents=True);sentinel=self.target/'keep';sentinel.write_text('old')
        result=self.run_installer(FAIL_STEP='codesign')
        self.assertNotEqual(result.returncode,0);self.assertEqual(sentinel.read_text(),'old')
        self.assertNotIn('curl ',(self.root/'calls').read_text());self.assert_clean()

    def test_overlap_and_bad_origin_fail_without_download(self):
        lock=self.home/'Applications/.fairystack-install.lock';lock.mkdir(parents=True)
        result=self.run_installer();self.assertNotEqual(result.returncode,0)
        self.assertIn('Another installation',result.stderr);self.assertTrue(lock.exists())
        result=subprocess.run(['bash',str(self.script),'https://example.com/invalid'],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertNotEqual(result.returncode,0);self.assertIn('HTTPS FairyStack origin',result.stderr)
        self.assertNotIn('curl ',(self.root/'calls').read_text())

    def test_overall_deadline_kills_never_resolving_step_and_children(self):
        # Simulate 238 seconds already spent before the next owned step.
        self.script.write_text(self.script.read_text().replace('started=$SECONDS','started=$((SECONDS - 238))'))
        result=self.run_installer(HANG_STEP='curl')
        self.assertNotEqual(result.returncode,0);self.assertIn('timed out',result.stderr)
        self.assertFalse(self.target.exists());self.assert_clean()
        pid=int((self.root/'child').read_text())
        # A reaped process or a zombie is stopped; it cannot continue work.
        status=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True,timeout=3)
        self.assertTrue(status.returncode or status.stdout.strip().startswith('Z'),status.stdout)

    def test_interrupt_stops_the_owned_command_and_cleans_staging(self):
        proc=subprocess.Popen(['bash',str(self.script),'https://customer.fairystack.com'],
            env={**self.env,'HANG_STEP':'curl'},stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            text=True,start_new_session=True)
        try:
            deadline=time.monotonic()+5
            while not (self.root/'child').exists() and time.monotonic()<deadline: time.sleep(0.05)
            self.assertTrue((self.root/'child').exists())
            os.killpg(proc.pid,signal.SIGINT)
            out,err=proc.communicate(timeout=5)
            self.assertNotEqual(proc.returncode,0)
            self.assertIn('cancelled',err);self.assert_clean()
            pid=int((self.root/'child').read_text())
            status=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True,timeout=3)
            self.assertTrue(status.returncode or status.stdout.strip().startswith('Z'),status.stdout)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=3)

    def installed_old(self):
        self.target.mkdir(parents=True);sentinel=self.target/'old-build';sentinel.write_text('1.0.1');return sentinel

    def test_older_verified_installation_is_upgraded_in_place(self):
        sentinel=self.installed_old()
        result=self.run_installer(INSTALLED_VERSION='1.0.1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(sentinel.exists());self.assertTrue((self.target/'Contents/MacOS/FairyStackCompanion').exists())
        self.assertIn('Updated FairyStack 1.0.1 to 1.7.1',result.stdout);self.assert_clean()
        calls=(self.root/'calls').read_text()
        self.assertEqual(calls.count('codesign '),2,'both the old and the replacement app are verified')
        self.assertIn("'--fairystack-origin', 'https://customer.fairystack.com'",calls)

    def test_running_or_unreadable_older_installation_is_left_untouched(self):
        sentinel=self.installed_old()
        for env,message in [({'INSTALLED_VERSION':'1.0.1','RUNNING':'1'},'Choose Quit from its fairy menu-bar icon'),
                            ({'INSTALLED_VERSION':'garbled'},'Could not read the installed')]:
            with self.subTest(env=env):
                result=self.run_installer(**env)
                self.assertNotEqual(result.returncode,0);self.assertIn(message,result.stderr)
                self.assertEqual(sentinel.read_text(),'1.0.1');self.assert_clean()
        self.assertNotIn('curl ',(self.root/'calls').read_text())

    def test_newer_installation_is_kept(self):
        sentinel=self.installed_old()
        result=self.run_installer(INSTALLED_VERSION='1.7.2')
        self.assertEqual(result.returncode,0,result.stderr);self.assertTrue(sentinel.exists())
        self.assertNotIn('curl ',(self.root/'calls').read_text())

    def test_filename_requirement_regression_stops_before_installing(self):
        self.script.write_text(self.script.read_text().replace("-R '=anchor", "-R 'anchor"))
        result=self.run_installer()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('invalid requirement specification',result.stderr)
        self.assertFalse(self.target.exists());self.assert_clean()

    def installed_legacy(self):
        self.legacy.mkdir(parents=True);sentinel=self.legacy/'old-build';sentinel.write_text('1.1.1');return sentinel

    def test_legacy_companion_is_upgraded_into_fairystack_app(self):
        self.installed_legacy()
        result=self.run_installer(INSTALLED_VERSION='1.1.1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.legacy.exists(),'the Companion-era bundle is replaced, not duplicated')
        self.assertTrue((self.target/'Contents/MacOS/FairyStackCompanion').exists())
        self.assertIn('Updated FairyStack 1.1.1 to 1.7.1',result.stdout);self.assert_clean()
        calls=(self.root/'calls').read_text()
        self.assertIn('FairyStack-1.7.1.zip',calls)
        self.assertIn(str(self.target),calls.splitlines()[-2],'opens the renamed app')

    def test_current_legacy_bundle_is_renamed_without_download(self):
        sentinel=self.installed_legacy()
        result=self.run_installer(INSTALLED_VERSION='1.7.1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.legacy.exists());self.assertEqual((self.target/'old-build').read_text(),'1.1.1')
        self.assertNotIn('curl ',(self.root/'calls').read_text())

    def test_running_legacy_bundle_is_left_untouched(self):
        sentinel=self.installed_legacy()
        result=self.run_installer(INSTALLED_VERSION='1.1.1',RUNNING='1')
        self.assertNotEqual(result.returncode,0);self.assertIn('is open',result.stderr)
        self.assertEqual(sentinel.read_text(),'1.1.1');self.assertFalse(self.target.exists());self.assert_clean()

    def test_leftover_legacy_beside_current_app_is_reported_not_deleted(self):
        self.installed_old();sentinel=self.installed_legacy()
        result=self.run_installer(INSTALLED_VERSION='1.7.2')
        self.assertEqual(result.returncode,0,result.stderr);self.assertTrue(sentinel.exists())
        self.assertIn('An older FairyStack Companion.app is still in',result.stdout)
