"""Run the shipped relaunch helper against a stand-in `open` and real processes."""
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / 'Sources/FairyStackCompanion/main.swift').read_text()
SCRIPT = re.search(r'let relaunchScript = """\n(.*?)\n"""', MAIN, re.S).group(1)


class RelaunchHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.calls = self.root / 'calls'

    def opener(self, failures=0):
        path = self.root / 'open'
        path.write_text(f'''#!/bin/sh
echo "$*" >> "{self.calls}"
n=$(wc -l < "{self.calls}")
[ "$n" -gt {failures} ]
''')
        path.chmod(0o755); return str(path)

    def helper(self, pid, opener, *args):
        return subprocess.Popen(['/bin/sh', '-c', SCRIPT, 'fairystack-relaunch', str(pid), opener,
                                 '/Users/me/Applications/FairyStack.app', *args])

    def test_opens_the_new_build_only_after_the_old_process_exits(self):
        old = subprocess.Popen(['sleep', '30'])
        helper = self.helper(old.pid, self.opener(), '--fairystack-resume', 'https://me.fairystack.com/?session=s1')
        time.sleep(0.6)
        self.assertFalse(self.calls.exists(), 'never runs beside the old build')
        old.terminate(); old.wait(timeout=5)
        self.assertEqual(helper.wait(timeout=5), 0)
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['-n -g /Users/me/Applications/FairyStack.app --args --fairystack-resume https://me.fairystack.com/?session=s1'])

    def test_a_hung_old_process_is_killed_rather_than_blocking_the_update(self):
        old = subprocess.Popen(['sh', '-c', 'trap "" TERM; sleep 60'])
        started = time.monotonic()
        helper = self.helper(old.pid, self.opener())
        self.assertEqual(helper.wait(timeout=20), 0)
        self.assertLess(time.monotonic() - started, 14)
        self.assertGreater(time.monotonic() - started, 9, 'waits its full grace period first')
        old.wait(timeout=5)  # killed, so it exits
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_retries_a_failed_open_and_reports_final_failure(self):
        self.assertEqual(self.helper(99999999, self.opener(failures=2)).wait(timeout=15), 0)
        self.assertEqual(len(self.calls.read_text().splitlines()), 3)
        self.calls.unlink()
        self.assertEqual(self.helper(99999999, self.opener(failures=9)).wait(timeout=15), 1)
        self.assertEqual(len(self.calls.read_text().splitlines()), 3)


class RelaunchWiringTests(unittest.TestCase):
    def test_update_restart_resumes_the_page_and_never_kills_the_new_build(self):
        self.assertIn('relaunch(Bundle.main.bundleURL, arguments: workspace.resumeArguments)', MAIN)
        self.assertNotIn('createsNewApplicationInstance', MAIN)
        self.assertNotIn('application?.terminate()', MAIN)
        self.assertIn('do { try helper.run() } catch { failed(); return }', MAIN)
        window = (ROOT / 'Sources/WorkspaceWindow/WorkspaceWindows.swift').read_text()
        self.assertIn('persistWindows()', window.split('public var resumeArguments')[1].split('}')[0])
        self.assertIn('open(URLRequest(url: url, timeoutInterval: 30), origin: stack.url, configuration: nil, activate: activateOnResume)', window)

    def test_background_update_never_automatically_restarts_capture(self):
        callback = MAIN.split('installed: {')[1].split('})')[0]
        self.assertNotIn('restart()', callback)
        self.assertIn('Update ready', callback)
        self.assertIn('if updater.stagedVersion != nil { restart() } else { updater.check(announce: true) }', MAIN)

    def test_quitting_does_not_record_the_window_as_closed(self):
        # 1.3.0 CI evidence: AppKit closed the window while quitting for an update, the close
        # handler saved workspaceWindowOpen = false, and the relaunched build stayed menu-bar only.
        window = (ROOT / 'Sources/WorkspaceWindow/WorkspaceWindows.swift').read_text()
        close = window.split('public func windowWillClose')[1].split('\n    }\n')[0]
        self.assertLess(close.index('if terminating { return }'), close.index('pages.remove(at: index)'))
        self.assertIn('workspace.terminating = true', MAIN.split('func applicationShouldTerminate')[1].split('}')[0])
