from pathlib import Path
import plistlib
import unittest
ROOT=Path(__file__).resolve().parents[1]
class StandaloneProductTests(unittest.TestCase):
    def test_independent_identity_and_no_audio_permission(self):
        info=plistlib.loads((ROOT/'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'],'com.fairystack.companion')
        self.assertEqual(info['CFBundleExecutable'],'FairyStackCompanion')
        self.assertNotIn('NSMicrophoneUsageDescription',info)
        sources='\n'.join(p.read_text() for p in (ROOT/'Sources').rglob('*.swift'))
        self.assertNotIn('AVFoundation',sources)
        self.assertNotIn('voice-feed.aisloppy.com',sources)
        self.assertNotIn('com.fairystack.mac-commands',sources)
    def test_version_matches_bundle_and_updater(self):
        version=(ROOT/'VERSION').read_text().strip()
        self.assertEqual(plistlib.loads((ROOT/'Info.plist').read_bytes())['CFBundleShortVersionString'],version)
        self.assertIn('currentVersion: "'+version+'"',(ROOT/'Sources/FairyStackCompanion/CompanionUpdater.swift').read_text())

    def test_companion_icon_is_distinct_from_main_app(self):
        import hashlib
        source=(ROOT/'Sources/FairyStackCompanion/main.swift').read_text()
        self.assertIn('systemSymbolName: "link"',source)
        self.assertNotIn('systemSymbolName: "leaf.fill"',source)
        old_leaf_digest='68d37ee086925d81d2b001f9c006519d40679c8127f0c80cdd93c55e96ae88f3'
        self.assertNotEqual(hashlib.sha256((ROOT/'Resources/AppIcon.png').read_bytes()).hexdigest(),old_leaf_digest)
