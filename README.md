# FairyStack for Mac 1.5.1

The official FairyStack client for macOS 13+: FairyStack.app, bundle
com.fairystack.companion (kept from its Companion era). It opens your
FairyStack in a native window and can optionally run agent commands on this Mac.
No Voice Feed dependency, microphone permission or capture token. Source lives
with FairyStack. Existing hosted Mac builders receive only this credential-free
source archive and its exact revision/checksum; they build Intel/Apple silicon,
run process ownership tests, native window tests and launch checks, then
sign/notarize the universal app.

Build with `swift build -c release`; `swift test` exercises WebKit mouse routing
and image file promises; behavioral process tests use
`python3 -m unittest discover -s tests -v`. The checked-in Info.plist and icon
source define the signed app bundle. Download and pairing links are documented
in FairyStack's live agent guide, FairyStack for Mac section.

## FairyStack window

Fairy menu-bar icon → Open FairyStack window shows your FairyStack (https origin only) in a
WebKit window with its own Dock icon while open. Other sites open in your default
browser. Drag a conversation image to Finder to save the full-resolution original:
the page announces the hovered image with a short-lived signed link, and the app
downloads it through a file promise (two-minute limit; failures show an alert).
A plain click still opens the image viewer. Downloads go to ~/Downloads.
Download the signed disk image, drag FairyStack to Applications and open it. On first
launch it asks for your FairyStack address. Your stack's Mac page can also hand the
address over with a `fairystack://open?origin=https://…` link, which the app always
confirms before switching. Opened straight from the disk image, it offers to move
itself to Applications so it can update. The Terminal installer passes the address
directly. Change it from the FairyStack menu.

Pair from the app's fairy menu-bar icon after creating a code at your control origin's
`/companions`. The app uses its own Keychain service and requires explicit local
workspace selection. The folder sets a working directory, not a sandbox.
Commands run as the logged-in Mac user, with no interactive password or elevated
approval support. Disconnect revokes authority and stops its process group.

Automatic updates use only FairyStack's own public manifest and signed product
identity. Updates stop active commands before relaunch. Both network and command
execution are bounded; disconnection never replays a claimed command. Deliberately
detached background processes are unsupported. Local activity and owner-scoped
server receipts retain output; never print credentials.

Physical laptop pairing, macOS login-item approval, and real iPhone installation
require device verification beyond CI.

## Open-source client

This directory is MIT-licensed (see LICENSE). The license applies to the client,
its icon, tests and documentation, not the surrounding FairyStack server.
The client uses Apple system frameworks and its included C process runner;
there are no third-party package dependencies. The public source archive includes
this complete standalone Swift package, tests and protocol documentation.

Install and open without a browser download using the one-liner in DOWNLOAD.txt.
The open-source install.sh runs the published signed app through SHA-256, Apple
signature, exact identity and Gatekeeper checks, installs into ~/Applications,
and opens both the app and your pairing page. It never disables Gatekeeper or
removes quarantine attributes. Keep any error output. Pairing remains local consent.
The installer uses the macOS shell, Perl core runtime and Apple command-line tools;
no Homebrew, Python installation or administrator password is required.

## Build from source on a Mac

Requirements: macOS 13 or later, Xcode Command Line Tools with Swift 5.9 or later,
and Python 3 for tests. Run these commands in the extracted source directory:

```sh
swift build -c release
swift test
python3 -m unittest discover -s tests -v
```

The executable is `.build/release/FairyStackCompanion`; builds before 1.2 were
named FairyStack Companion.app, and their updaters pin this executable name and
the bundle identifier. A legacy install renames itself to FairyStack.app on first
launch. A development build is
not the signed/notarized downloadable app. For normal use, install that published
app; building locally does not confer the official signing identity. The bundled
Info.plist and Resources/AppIcon.png are inputs for an app bundle. Signing and
notarization require your own Apple credentials; none are included here. Automatic
updates use the official FairyStack distribution; fork maintainers must change
that policy and the bundle/Keychain identities before distributing their own app.

See PROTOCOL.md for pairing, commands, timeouts, disconnection and revocation.
The server and account service are separate from this open-source client.

Version 1.1.1 replaces the generic link icon with FairyStack's fairy in the Dock and
menu bar. Version 1.1.0 added the FairyStack window. The installer upgrades an older verified
installation in place when the app is not running, because the 1.0.1 updater
cannot verify its own replacement.
