# FairyStack Companion 1.0.1

Standalone menu-bar client for macOS 13+, bundle com.fairystack.companion.
Let your FairyStack agent work on your Mac after you explicitly pair it.
This MIT-licensed repository contains only the standalone client, installer,
tests and protocol documentation. The FairyStack server is not included.

Install from [your Companion page](https://fairystack.com/companions), or see
[DOWNLOAD.txt](DOWNLOAD.txt) for the Terminal one-liner. Pair through your own
FairyStack account. No microphone access is required.

Build with `swift build -c release`; behavioral process tests use
`python3 -m unittest discover -s tests -v`. The checked-in Info.plist and icon
source define the signed app bundle. Download and pairing links are documented
in FairyStack's live agent guide, Mac companions section.

Pair from the app's link menu after creating a code at your control origin's
`/companions`. The app uses its own Keychain service and requires explicit local
workspace selection. The folder sets a working directory, not a sandbox.
Commands run as the logged-in Mac user, with no interactive password or elevated
approval support. Disconnect revokes authority and stops its process group.

Automatic updates use only FairyStack's own public manifest and signed product
identity. Updates stop active commands before relaunch. Both network and command
execution are bounded; disconnection never replays a claimed command. Deliberately
detached background processes are unsupported. Local activity and owner-scoped
server receipts retain output; never print credentials.

Physical laptop pairing and macOS login-item approval require device verification
beyond automated tests.

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
and Python 3 for tests:

```sh
git clone https://github.com/QualityCopperShovel/fairystack-companion.git
cd fairystack-companion
```

Then build and test:

```sh
swift build -c release
python3 -m unittest discover -s tests -v
```

The executable is `.build/release/FairyStackCompanion`. A development build is
not the signed/notarized downloadable app. For normal use, install that published
app; building locally does not confer the official signing identity. The bundled
Info.plist and Resources/AppIcon.png are inputs for an app bundle. Signing and
notarization require your own Apple credentials; none are included here. Automatic
updates use the official FairyStack distribution; fork maintainers must change
that policy and the bundle/Keychain identities before distributing their own app.

See PROTOCOL.md for pairing, commands, timeouts, disconnection and revocation.
The server and account service are separate from this open-source client.

Source release 3 corrects the literal codesign requirement in the installer and
updater source. The previously signed 1.0.1 binary is unchanged; its updater fix
requires a new signed native release. The public installer is independently
published and retains the same Apple identity and Gatekeeper checks.

## Publication boundary

The initial public import contains the 20 explicitly allowlisted files from
FairyStack Companion 1.0.1 source release 3, plus this repository’s `.gitignore`.
No parent repository history, server code, account data, logs, signing keys or
credentials are included. The README was adapted for this standalone repository.
Public Apple signing identifiers and download checksums are intentional: they
let the installer verify the official app and do not grant signing authority.

Before the initial publication, the export was manually reviewed and scanned
with Gitleaks 8.30.1 (no findings). The icon contains only PNG image/palette data,
without text metadata. This review is not a guarantee against all vulnerabilities.
