# is2l Remote

This program lets you use a controller to play games remotely on your desktop.

is2l Remote is its own project in its own public repository, https://github.com/isleep2late/is2l-remote. It is a fork of [RustDesk](https://github.com/rustdesk/rustdesk), the open-source remote desktop program, starting from upstream commit `7949eca`. Licence: AGPL-3.0, the same as RustDesk (see `LICENCE`). The complete source of the modified program is this repository; the last section of `IS2L-BUILD.md` says what the licence asks of you.

Its controller set-up app is [Hackmons Controller](https://github.com/isleep2late/Hackmons-Controller) (MIT licence, a separate project and a separate app). is2l Remote has no button-mapping screen of its own.

## Status

- **It compiles.** The Android app (APK) and the Linux host build from this source.
- **It has NEVER been run.** Not on a device, and not between two machines. Nobody has seen a controller button arrive on a computer through it. Everything below describes what the code is written to do, not what has been seen working.
- **The virtual controller exists on a Linux host only.** A Windows or macOS computer running this fork behaves like stock RustDesk for controller input.

## What the fork adds over stock RustDesk

Stock RustDesk carries keyboard, mouse and touch only. A game controller connected to the Android device does nothing useful in a stock session: its buttons are dropped and its sticks and triggers never reach the app.

The fork adds one thing: **controller input is carried to a virtual controller on a Linux host.** Buttons, sticks and triggers of the controller on the Android side arrive on the computer as an ordinary game controller that games can use. Around that it adds:

1. A network message for controller state, and a flag with which the host announces that it understands it.
2. Controller capture in the Android app, for a controller that Android itself recognises.
3. A feed from Hackmons Controller, for controllers Android does not recognise.
4. A virtual Xbox-style controller on the Linux host, created through `uinput`.
5. A control panel for the second screen of a two-screen handheld such as the AYN Thor (on other devices it opens from the session menu).

## What the fork does not change

- **The video pipeline.** Capture, encoding, transport and decoding are RustDesk's, untouched.
- **Latency.** Nothing here makes the picture or the input faster than stock RustDesk. It is a remote desktop program with controller input added, not a purpose-built game streaming program.
- Audio, file transfer, the rendezvous and relay servers, and the connection and security model.

## How it works

### The app is its own Android app

- The Android application id is `com.isleep2late.remote` (upstream: `com.carriez.flutter_hbb`), so it installs **beside** the stock RustDesk app and does not replace it or share its settings.
- The name under the icon is "is2l Remote". The accessibility service (only used when the Android device's own screen is shared) is listed as "is2l Remote Input".
- Not changed: texts inside the app still say "RustDesk" in many places, the icon is still the RustDesk icon, and the Linux program is still called RustDesk (same window title, same `.desktop` file, same `rustdesk` service and settings folder). On the computer the modified program therefore **replaces** a stock RustDesk installation; it cannot be installed next to one.

### A network message for controllers

RustDesk's network protocol (`libs/base/protos/message.proto`) had no message for game controllers. The fork adds one, `GamepadEvent`, sent from the Android device to the computer each time the controller state changes:

| Field | Meaning |
| --- | --- |
| `index` | which controller (0 for the first) |
| `connected` | false when the controller was unplugged or the session stopped using it |
| `buttons` | one bit per button, in this order: A, B, X, Y, L1, R1, Select, Start, Mode, L3, R3, D-pad up, down, left, right |
| `lx`, `ly`, `rx`, `ry` | left and right stick, -32768 to 32767, up and left are negative |
| `lt`, `rt` | left and right trigger, 0 to 255 |

The host announces that it understands this message with a `gamepad` flag in the `Features` it sends at connection time. Programs that do not know the message ignore it, so the modified app and the modified host can still talk to stock RustDesk.

### Built-in capture on Android

The Android part of the app (`MainActivity`, `GamepadCapture`) reads a controller that Android recognises and hands every change to the Flutter part over a channel named `is2l/gamepad`. Buttons are passed through as a standard controller, with no remapping. Capture is only switched on while a remote session with controller passthrough enabled is on screen.

### The feed from Hackmons Controller

Hackmons Controller is the place to set up and check a controller, and to use controllers that Android does not recognise (it reads them itself over USB or Bluetooth). While is2l Remote is on screen it sends only the controllers it reads itself; a controller that Android recognises is left to the built-in capture, so its buttons are not remapped. It sends the finished controller state to is2l Remote on the same device:

- is2l Remote exports a bound service, `com.carriez.flutter_hbb.PadFeedService`, with the action `com.isleep2late.remote.PAD_FEED`. It only accepts messages from a sender that passes two checks: its package name is `com.controllerlog.gcbridge` or `com.controllerlog.gcbridge.dev` (Hackmons Controller and its DEV build), and the SHA-256 of its signing certificate is in the pinned list `SENDER_CERT_SHA256` in `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/PadFeedService.kt`. An app that only carries the package name is refused.
- The pinned list holds the Hackmons Controller release certificate, `1e08a903aef9c3a721510b64ec764d01d3d094eb954161b62544ea8f187b5953`. A Hackmons Controller you build and sign yourself has a different certificate, so its feed is refused until you add its SHA-256 (lowercase hex, no colons; `apksigner verify --print-certs` shows it) to that list and rebuild is2l Remote.
- Message 1 carries the state: a button bitmask in SDL gamepad order (south, east, west, north, back, guide, start, left stick, right stick, left shoulder, right shoulder, D-pad up, down, left, right), and six axes (left x, left y, right x, right y from -32768 to 32767 with down positive, then left and right trigger from 0 to 32767). Message 2 means the controller is gone.
- The south, east, west and north buttons become A, B, X and Y by position, the way an Xbox pad is laid out. The triggers are scaled to 0 to 255. No further mapping is applied by is2l Remote.
- The feed is treated as controller 0. While it is live (a state message within the last 2 seconds) it takes precedence over the built-in capture. After a "gone" message or 2 seconds of silence everything is released and the built-in capture is used again.

During a session, the menu item **Controller set-up (Hackmons Controller)** opens Hackmons Controller if it is installed, and otherwise opens its releases page.

### A virtual controller on the Linux host

On the computer, a module (`src/server/gamepad_service.rs`) receives `GamepadEvent` messages and feeds them to a virtual Xbox-style controller. The virtual controller is created through Linux `uinput` by the RustDesk service, which runs as root, the same way RustDesk already creates its virtual keyboard and mouse. Games see an ordinary controller. It is removed when the connection closes.

The host only accepts controller input when the setting "Allow game controller input" (settings, Security, Permissions; Linux only) is ticked and the connection has the keyboard/mouse permission. A connection that only views a camera, or one whose keyboard/mouse permission is off, has its controller messages dropped, the same as its key and mouse messages. The setting is ticked by default: the option behind it, `allow-gamepad`, counts as on unless it is set to `N`.

### The control panel

While a session is open, the second screen of an AYN Thor shows a panel (channel `is2l/panel`) with the computer's name, frame rate, codec, delay and quality, whether controller passthrough is on, and where controller input comes from (this device or Hackmons Controller). Its buttons: disconnect (tap twice), show keyboard, send Esc, send Ctrl+Alt+Del, send Alt+Tab, switch between fitted and 1:1 view, frame rate up/down, quality up/down, next codec, switch controller passthrough on/off, Controller set-up (Hackmons Controller), and a touchpad area that moves, clicks and scrolls the computer's mouse. On a device without a second screen the same panel opens from the session menu ("Control panel").

## How to install

Downloads are on the releases page: https://github.com/isleep2late/is2l-remote/releases. To build from source instead, see `IS2L-BUILD.md`.

On the computer (Linux):

1. Remove stock RustDesk first; the two cannot be installed together on the computer.
2. Install the `.deb` package of is2l Remote (`sudo apt install ./<file>.deb`). This installs it **as a service** (the service is called `rustdesk`). The service is what creates the virtual controller. A portable copy started by hand cannot do it.
3. Open its settings and check that **Allow game controller input** is ticked (it is by default).
4. In the same settings, enable **Direct IP access**. Set a permanent password.
5. Install Tailscale and sign in.

On the Android device:

6. Install Tailscale and sign in to the same account.
7. Install the is2l Remote APK.
8. Optional, for a controller Android does not recognise: install Hackmons Controller from https://github.com/isleep2late/Hackmons-Controller/releases (its Android app is called GC Bridge), start its USB capture or Bluetooth capture and, in its **is2l Remote** section, switch on **Send this controller to is2l Remote**.
9. Open is2l Remote and, in the ID field, type the computer's Tailscale address (it looks like `100.x.y.z`) and connect. Direct IP access uses port 21118 unless it was changed on the computer.
10. In the session's display settings set image quality to **Custom**, the frame rate to **60**, and the codec to **H264**.

## Against a stock RustDesk host

If the computer runs stock RustDesk, it does not announce the `gamepad` feature. The app then does not send controller messages; buttons, triggers and sticks fall back to fixed keyboard keys (for example A is Z, B is X, the D-pad and the left stick are the arrow keys, the right stick is I/J/K/L); a trigger or stick counts as pressed past half of its travel, so there is no analog input. Everything else works as in stock RustDesk.

## Known limits

These come from reading the code, not from measurements.

- **Video is captured on the CPU** on the Linux host and **decoded in software on the Android device**. The Android build that this repository's CI produces includes only a software H264/H265 decoder. Expect noticeable CPU use and battery drain at 60 fps and high resolutions.
- **More than 30 fps needs a direct connection.** When the connection goes through RustDesk's public servers and is not direct, the app caps a custom frame rate at 30 (`src/client.rs`). Connecting by Tailscale address is a direct connection.
- **Audio can lag** behind the picture by a few hundred milliseconds.
- Rumble (vibration) is not sent back; the controller message only travels from the Android device to the computer.
- The remote-control protocol adds delay that a purpose-built game streaming program does not have. Fast action games will feel it.
- The feed from Hackmons Controller carries one controller.

## Not tested yet

Everything beyond compiling. Nothing in this fork has been installed or run. In particular, nobody has yet checked that:

- the Android app installs beside stock RustDesk, and starts;
- controller buttons, sticks and triggers are captured on an AYN Thor, on a phone or on a foldable with a connected controller;
- Hackmons Controller can bind to the feed service, and its state arrives with the right buttons, directions and trigger range;
- the hand-over between the feed and the built-in capture, and the 2 second timeout, behave as described;
- the virtual controller appears on the Linux host and games accept it;
- the "Allow game controller input" setting works and is on by default;
- the control panel appears on the Thor's second screen and its buttons work;
- the fallback against a stock RustDesk host behaves as described;
- 60 fps H264 over Tailscale is actually reached, and how large the delay is;
- the app-name change left no place where Android confuses the fork with stock RustDesk. Known leftovers: both apps answer `rustdesk://` links (Android will ask which one to open), and the in-app help text for the accessibility permission still tells you to switch on "RustDesk Input" although the fork's service is listed as "is2l Remote Input".
