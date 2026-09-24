"""Match Apple's literal requirement contract; compile with macOS csreq when available."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def requirements():
    line=next(line for line in (ROOT/'install.sh').read_text().splitlines() if 'run 30 codesign ' in line)
    args=shlex.split(line)
    installer=args[args.index('-R')+1]
    updater=(ROOT/'Sources/FairyStackCompanion/AppUpdater.swift').read_text()
    native=json.loads(re.search(r'"-R", ("(?:\\.|[^"\\])*")',updater).group(1))
    return installer,native


class CodeSigningRequirementsTests(unittest.TestCase):
    def test_installer_and_updater_pass_the_same_literal_requirement(self):
        installer,native=requirements()
        self.assertEqual(installer,native)
        self.assertEqual(installer, '=anchor apple generic and identifier "com.fairystack.companion" and certificate leaf[subject.OU] = "7ZPTPEXGRC"')

    @unittest.skipUnless(sys.platform=='darwin','Requires the real macOS requirement compiler')
    def test_macos_compiles_both_literal_arguments_and_rejects_file_form(self):
        with tempfile.TemporaryDirectory() as folder:
            for i,requirement in enumerate(requirements()):
                result=subprocess.run(['/usr/bin/csreq','-r',requirement,'-b',str(Path(folder)/str(i))],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr)
                bad=subprocess.run(['/usr/bin/csreq','-r',requirement[1:],'-b',str(Path(folder)/'bad')],capture_output=True,text=True,timeout=10)
                self.assertNotEqual(bad.returncode,0)
