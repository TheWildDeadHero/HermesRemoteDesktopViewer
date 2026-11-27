# Hermes

**Hermes** is a remote-desktop client for [Apollo](https://github.com/ClassicOldSong/Apollo) hosts, with an interface modelled on Chrome Remote Desktop, for **Android** and **macOS**. It keeps Moonlight's low-latency streaming, but it only does one thing: show you your computers and put you on their desktop.

- **Android** — built on [Artemis](https://github.com/ClassicOldSong/moonlight-android). Source in the repository root.
- **macOS** — native app (universal: Apple Silicon + Intel, macOS 12 Monterey or later), built on [Moonlight macOS](https://github.com/MichaelMKenny/moonlight-macos). Source in [`desktop/macos`](desktop/macos). See [Hermes for macOS](#hermes-for-macos).

**After pairing a new device, open Apollo's web UI → Clients and allow Mouse Input and Keyboard Input (and Clipboard, if you want it) for that device.** Apollo gives newly paired devices view-only access by default.

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

## Install (Android)

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

## Hermes for macOS

### Install

Download **`Hermes-macOS-universal.dmg`** from the [**Latest macOS build** release](https://github.com/TheWildDeadHero/HermesRemoteDesktopViewer/releases/tag/latest-macos), open it and drag Hermes to Applications. One universal app runs natively on both Apple Silicon and Intel Macs.

The app isn't signed with an Apple Developer ID yet, so the first time macOS will block it. **Right-click Hermes → Open → Open**, or open it once and then choose **Open Anyway** in System Settings → Privacy & Security. When asked, allow Hermes to find devices on your local network; that's how it discovers your computers.

### What it does

- **Computer list** — your computers as cards with online / offline / needs-pairing / session-running status. Click one to go straight to its desktop; if a session is already running, Hermes rejoins it. The **⋯** menu (or right-click) has Connect, End Remote Session, Choose Desktop Entry, Wake, Open Apollo Web UI, Unpair and Remove.
- **Add a computer** with the **+** toolbar button: an IP address or host name, including Tailscale names.
- **Pairing** with Apollo's one-time PIN + passphrase, or by showing a PIN to type into Apollo.
- **Wake-on-LAN**, with automatic connect once the computer is up.
- **Pixel-perfect desktop** — by default Hermes streams at your Mac's own display resolution and asks Apollo for a virtual display of exactly that size. Set the text size once in Windows' Display settings; Windows remembers it for Hermes' virtual display.
- **Desktop pointer** (default) — the Mac pointer moves freely and clicks exactly where you point, like Chrome Remote Desktop. Switch to **Captured** for games (Control-Option releases it).
- **Session controls** — click the tab on the right edge of the stream, or press **⌃⌥⌘S**:
  - Quick keys: Task Manager, Start menu, Alt+Tab, Alt+F4, Show desktop, Esc, Print Screen (⌘ is sent as the Windows key)
  - Pointer: Desktop / Captured
  - Display: Fit / Fill / Stretch, full screen, actual size
  - Clipboard: send this Mac's clipboard (**⌃⌥⌘V**) or copy the computer's clipboard (**⌃⌥⌘C**)
  - Live resolution, frame rate and round-trip time
  - Disconnect (leaves the session running) or End session
- A **Session** menu in the menu bar with the same commands.
- **Settings → Remote Desktop**: match display resolution, use Apollo's virtual display, picture fit, pointer mode, and whether to show the session tab. The other panes (resolution, frame rate, bitrate, codec, HDR, controllers) are Moonlight's.

Limitations: Ctrl+Alt+Del can't be sent remotely (Windows blocks it); Apollo's server commands aren't available on macOS yet; hosts must use Apollo's default ports.

### Building

GitHub Actions builds every push that touches `desktop/macos` (workflow **Build macOS app**): an arm64 + x86_64 build, a check that both architectures are present, a launch test, then the DMG. To build locally, open `desktop/macos/Moonlight.xcodeproj` in Xcode 16 or later, download the [prebuilt dependencies](https://github.com/coofdy/moonlight-mobile-deps/releases/download/latest/moonlight-apple-xcframeworks.zip) into `desktop/macos/xcframeworks`, and build the **Moonlight for macOS** scheme.

## Credits and license

Hermes for Android is a fork of [Artemis](https://github.com/ClassicOldSong/moonlight-android) by ClassicOldSong, which is itself a fork of [Moonlight for Android](https://github.com/moonlight-stream/moonlight-android). Hermes for macOS is a fork of [Moonlight macOS](https://github.com/MichaelMKenny/moonlight-macos) by Michael and Martin Kenny, based on [Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios). Licensed under the GNU GPL v3, like its upstreams — see [LICENSE.txt](LICENSE.txt).
