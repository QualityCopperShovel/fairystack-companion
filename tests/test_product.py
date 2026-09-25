from pathlib import Path
import plistlib
import unittest
ROOT=Path(__file__).resolve().parents[1]
class StandaloneProductTests(unittest.TestCase):
    def test_independent_identity_and_scoped_audio_permission(self):
        info=plistlib.loads((ROOT/'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'],'com.fairystack.companion')
        self.assertEqual(info['CFBundleExecutable'],'FairyStackCompanion')
        self.assertIn('NSMicrophoneUsageDescription',info)
        self.assertEqual(plistlib.loads((ROOT/'Entitlements.plist').read_bytes()), {'com.apple.security.device.audio-input': True})
        sources='\n'.join(p.read_text() for p in (ROOT/'Sources').rglob('*.swift'))
        self.assertNotIn('AVFoundation',sources)
        # Voice Feed is an auxiliary web approval origin, never a native capture client.
        self.assertNotIn('voice-feed.aisloppy.com',(ROOT/'Sources/FairyStackCompanion/main.swift').read_text())
        self.assertNotIn('com.fairystack.mac-commands',sources)
    def test_version_matches_bundle_and_updater(self):
        version=(ROOT/'VERSION').read_text().strip()
        self.assertEqual(plistlib.loads((ROOT/'Info.plist').read_bytes())['CFBundleShortVersionString'],version)
        self.assertIn("version='"+version+"'", (ROOT/'install.sh').read_text(), 'installer URL and release version must advance together')
        self.assertIn('currentVersion: "'+version+'"',(ROOT/'Sources/FairyStackCompanion/AppUpdater.swift').read_text())

    def test_product_is_named_fairystack_but_keeps_identifiers_old_updaters_pin(self):
        info=plistlib.loads((ROOT/'Info.plist').read_bytes())
        self.assertEqual((info['CFBundleName'],info['CFBundleDisplayName']),('FairyStack','FairyStack'))
        main=(ROOT/'Sources/FairyStackCompanion/main.swift').read_text()
        updater=(ROOT/'Sources/FairyStackCompanion/AppUpdater.swift').read_text()
        self.assertIn('let appBundleName = "FairyStack.app"',main)
        self.assertIn('let legacyBundleName = "FairyStack Companion.app"',main)
        # 1.1.1 updaters stage exactly this executable path and signing identity.
        self.assertIn('Contents/MacOS/FairyStackCompanion',updater)
        self.assertIn('identifier \\"com.fairystack.companion\\"',updater)
        self.assertIn('appendingPathComponent(appBundleName, isDirectory: true)',updater)
        self.assertIn('https://fairystack.com/assets/mac-version.json',updater,'the legacy manifest only bridges pre-1.2 builds')
        visible='\n'.join(p.read_text() for p in (ROOT/'Sources').rglob('*.swift')).replace('let legacyBundleName = "FairyStack Companion.app"','')
        self.assertNotIn('FairyStack Companion',visible)
    def test_downloaded_app_opens_from_its_page_and_offers_to_move(self):
        info=plistlib.loads((ROOT/'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleURLTypes'][0]['CFBundleURLSchemes'],['fairystack'])
        main=(ROOT/'Sources/FairyStackCompanion/main.swift').read_text()
        window=(ROOT/'Sources/WorkspaceWindow/WorkspaceWindows.swift').read_text()
        self.assertIn('urls.forEach(workspace.handleOpenURL)',main)
        self.assertIn('guard confirm.runModal() == .alertFirstButtonReturn else { return }',window,'a web link never switches the address silently')
        self.assertIn('self.workspace.welcomeIfNeeded()',main,'first launch asks for an address')
        self.assertIn('current.path.hasPrefix("/Volumes/") || current.path.contains("/AppTranslocation/")',main)
        self.assertLess(main.index('offerMoveToApplications()'),main.index('adoptBundleName()'))
    def test_welcome_offers_the_same_trial_as_the_landing_page(self):
        window=(ROOT/'Sources/WorkspaceWindow/WorkspaceWindows.swift').read_text()
        self.assertIn('static let trialOrigin = URL(string: "https://trial-01.fairystack.com")!',window)
        self.assertIn('dialog.addButton(withTitle: "Try FairyStack")',window)
        self.assertIn('?? store.selected ?? trialSession',window,'trial selection stays local to the process')
        store=(ROOT/'Sources/WorkspaceWindow/SavedStacks.swift').read_text()
        self.assertIn('canonical.host != WorkspaceAddress.trialOrigin.host',store)
    def test_legacy_bundle_moves_once_then_relaunches(self):
        main=(ROOT/'Sources/FairyStackCompanion/main.swift').read_text()
        self.assertIn('guard let renamed = adoptBundleName() else { finishLaunching(updates: true); return }',main)
        self.assertIn('current.lastPathComponent == legacyBundleName',main)
        self.assertIn('try FileManager.default.moveItem(at: current, to: renamed)',main)
        self.assertIn('arguments.append(loginItemArgument)',main,'a login item follows the renamed bundle')
        self.assertIn('finishLaunching(updates: false)',main,'a failed relaunch never updates into the old path')

    def test_companion_icon_is_distinct_from_main_app(self):
        import hashlib
        source=(ROOT/'Sources/FairyStackCompanion/main.swift').read_text()
        self.assertIn('status.button?.image = FairyIcon.menuBar()',source,'the menu bar shows the FairyStack fairy, not a generic link')
        self.assertNotIn('systemSymbolName: "link"',source)
        self.assertNotIn('systemSymbolName: "leaf.fill"',source)
        self.assertIn('image.isTemplate = true',(ROOT/'Sources/WorkspaceWindow/FairyIcon.swift').read_text())
        old_leaf_digest='68d37ee086925d81d2b001f9c006519d40679c8127f0c80cdd93c55e96ae88f3'
        digest=hashlib.sha256((ROOT/'Resources/AppIcon.png').read_bytes()).hexdigest()
        self.assertNotEqual(digest,old_leaf_digest)
        self.assertNotEqual(digest,'5d5376c701e5a995103764ff2a251090773fccc7895c50c8b0ce6fdb39ca1c34','retired generic link icon')


class WorkspaceWindowTests(unittest.TestCase):
    source=(ROOT/'Sources/WorkspaceWindow/WorkspaceWindows.swift').read_text()
    def test_menu_title_uses_the_bundle_version(self):
        version=(ROOT/'VERSION').read_text().strip()
        self.assertIn('let appVersion = "'+version+'"',(ROOT/'Sources/FairyStackCompanion/main.swift').read_text())
    def test_window_is_limited_to_the_https_origin_and_identifies_itself(self):
        self.assertIn('parts.scheme == "https"',self.source)
        self.assertIn('applicationNameForUserAgent = "FairyStackMac/',self.source)
        self.assertIn('static let dragMessage = "fairystackDrag"',self.source)
        self.assertIn('launchExternal(url); decisionHandler(.cancel)',self.source,'other sites open in the default browser')
    def test_image_drag_downloads_are_bounded_and_fail_visibly(self):
        self.assertIn('timeoutIntervalForResource = 120',self.source)
        self.assertIn('status == 200',self.source)
        self.assertIn('self.failed(message)',self.source)
        self.assertIn('context == .outsideApplication ? .copy : []',self.source,'drops back onto the page are not uploads')
