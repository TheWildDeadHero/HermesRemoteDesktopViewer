# Hermes

**Hermes** is an Android remote-desktop client for [Apollo](https://github.com/ClassicOldSong/Apollo) hosts, with an interface modelled on Chrome Remote Desktop. It's built on [Artemis](https://github.com/ClassicOldSong/moonlight-android), so it keeps Moonlight/Artemis' low-latency streaming, but it only does one thing: show you your computers and put you on their desktop.

Where Moonlight and Artemis list every application a host exposes, Hermes lists **computers**. Tap one and you're on its desktop — on an Apollo virtual display sized to your phone when the host supports it.

## Features

**Computer list**
- Material 3 home screen with Material You colors, online/offline/pairing status for each computer
- Tap to connect straight to the desktop; if a session is already running, Hermes rejoins it
- Add a computer by IP or hostname (Tailscale names work), or let it be discovered on your network
- Pair with Apollo's one-time PIN (OTP) or the classic "type this PIN into Apollo" flow
- Wake-on-LAN, with automatic connect once the computer comes online
- Per-computer menu: end remote session, choose which host entry counts as the desktop, open Apollo's web UI, network test, unpair, remove
- Home-screen shortcuts open a computer's desktop directly

**In a session** (tap the menu handle in the top-right, or press Back)
- Show keyboard
- Mouse input: **Trackpad** (default) or **Touch**, remembered between sessions
- Quick keys: Task Manager, Windows, Alt+Tab, Esc, Show desktop, Print Screen, plus all of Artemis' special-key shortcuts
- Display: Fit / Fill / Stretch, pinch-to-zoom, rotate, stream stats overlay
- Clipboard: send to / get from the computer (Apollo clipboard sync)
- Apollo server commands
- Disconnect (leave the session running) or End session
- **More options** opens Artemis' full advanced menu, so nothing upstream is lost

## How Hermes picks the desktop

Apollo exposes a list of "applications". For each computer Hermes uses, in order: the entry you chose for it, an entry named **Desktop**, anything containing "desktop", or the only entry if there's just one. If none match it asks you once and remembers. You can change it later from the computer's ⋮ menu → *Choose desktop entry…*.

## Install

Every push to `main` is built by GitHub Actions. Download the newest APK from the
[**Latest build** release](https://github.com/TheWildDeadHero/HermesRemoteDesktopViewer/releases/tag/latest) —
most phones (including Pixels) want the file ending in **`arm64-v8a-release.apk`**.

Hermes uses its own package name (`io.github.thewilddeadhero.hermes`), so it installs alongside Moonlight or Artemis.

## Signing

So that new builds install as updates over old ones, CI signs releases with a key from two repository secrets (Settings → Secrets and variables → Actions):

| Secret | Contents |
| --- | --- |
| `HERMES_KEYSTORE_BASE64` | The release keystore, base64-encoded on one line |
| `HERMES_KEYSTORE_PASSWORD` | The keystore and key password (key alias `hermes`) |

Without them, builds are signed with a throwaway debug key and each new build has to be installed fresh (uninstall first).

## Building locally

Open the project in Android Studio (with the NDK installed), let it sync, and run the `nonRoot_game` variant. Clone with submodules (`git clone --recursive`), or use Android Studio's *Get from VCS*, which handles them.

## Credits and license

Hermes is a fork of [Artemis](https://github.com/ClassicOldSong/moonlight-android) by ClassicOldSong, which is itself a fork of [Moonlight for Android](https://github.com/moonlight-stream/moonlight-android). Licensed under the GNU GPL v3, like its upstreams — see [LICENSE.txt](LICENSE.txt).
