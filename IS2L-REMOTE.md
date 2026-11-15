# is2l Remote

is2l Remote is a modified copy of [RustDesk](https://github.com/rustdesk/rustdesk), the open-source remote desktop program. It is part of the is2l family. It starts from upstream RustDesk commit `7949eca` and adds three things for playing PC games from a handheld:

1. **Real game controller passthrough.** The buttons, sticks and triggers of the handheld (an AYN Thor, or a controller connected to a phone or a trifold) arrive on the PC as a real controller, not as keyboard keys.
2. **A button-mapping screen.** Every physical button can be assigned to a different controller button, and the assignments are saved as named profiles.
3. **The AYN Thor's bottom screen as a control panel.** The game picture stays on the top screen; the bottom screen shows the connection state and buttons such as disconnect, keyboard, Esc, frame rate and quality.

Licence: AGPL-3.0, the same as RustDesk (see `LICENCE`). The complete source of the modified program is this repository. See the last section of `IS2L-BUILD.md` for what the licence asks of you.

> **Nothing in this fork has been built or run yet.** Everything below describes what the code is written to do. See "Not tested yet" at the end.

## What was changed relative to upstream 7949eca

### The app is its own Android app

- The Android application id is `com.isleep2late.remote` (upstream: `com.carriez.flutter_hbb`), so it installs **beside** the stock RustDesk app and does not replace it or share its settings.
- The name under the icon is "is2l Remote". The accessibility service (only used when the handheld's own screen is shared) is listed as "is2l Remote Input".
- Not changed in this round: texts inside the app still say "RustDesk" in many places, the icon is still the RustDesk icon, and the Linux PC program is still called RustDesk (same window title, same `.desktop` file, same `rustdesk` service and settings folder). On the PC the modified program therefore **replaces** a stock RustDesk installation; it cannot be installed next to one.

### A new network message for controllers

RustDesk's network protocol (`libs/base/protos/message.proto`) had no message for game controllers. The fork adds one, `GamepadEvent`, sent from the handheld to the PC each time the controller state changes:

| Field | Meaning |
| --- | --- |
| `index` | which controller (0 for the first) |
| `connected` | false when the controller was unplugged or the session stopped using it |
| `buttons` | one bit per button, in this order: A, B, X, Y, L1, R1, Select, Start, Mode, L3, R3, D-pad up, down, left, right |
| `lx`, `ly`, `rx`, `ry` | left and right stick, -32768 to 32767, up and left are negative |
| `lt`, `rt` | left and right trigger, 0 to 255 |

The PC announces that it understands this message with a new `gamepad` flag in the `Features` it sends at connection time. Programs that do not know the message ignore it, so the modified app and the modified host can still talk to stock RustDesk.

### Capture on Android

In stock RustDesk on Android the face buttons, shoulder buttons, Start, Select and stick clicks are silently dropped, and stick and trigger movement never reaches the app at all. The fork reads the controller in the Android part of the app (`MainActivity`) and hands every change to the Flutter part over a channel named `is2l/gamepad`. Capture is only switched on while a remote session with controller passthrough enabled is on screen, or while the Controller screen is open.

### A virtual controller on the Linux PC

On the PC, a new module (`src/server/gamepad_service.rs`) receives `GamepadEvent` messages and feeds them to a virtual Xbox-style controller. The virtual controller is created through Linux `uinput` by the RustDesk service, which runs as root, the same way RustDesk already creates its virtual keyboard and mouse. Games see an ordinary controller. It is removed when the connection closes.

The host only accepts controller input when the new setting "Allow game controller input" (settings, Security, Permissions; Linux only) is ticked and the connection has the keyboard/mouse permission. The setting is ticked by default: the option behind it, `allow-gamepad`, counts as on unless it is set to `N`.

### Mapping profiles

A "Controller" screen in the app shows the live state of the controller and lets each physical button or trigger be assigned to a controller button, a keyboard key, a mouse button or nothing. Each stick can drive the left stick, the right stick, the D-pad, the mouse pointer or nothing, with its own deadzone and inversion. Assignments are stored as named profiles, and the profile last used with a PC is remembered for that PC.

### The control panel on the Thor's bottom screen

While a session is open, the bottom screen shows a panel (channel `is2l/panel`) with the PC's name, frame rate, codec, delay and quality, whether controller passthrough is active, and the current mapping profile. Its buttons: disconnect (tap twice), show keyboard, send Esc, send Ctrl+Alt+Del, send Alt+Tab, switch between fitted and 1:1 view, frame rate up/down, quality up/down, next codec, switch controller passthrough on/off, open the mapping screen, previous/next mapping profile, and a touchpad area that moves, clicks and scrolls the PC's mouse. On a device without a second screen the same panel opens from the session menu ("Control panel").

## How to use it

On the PC (Linux):

1. Install the modified RustDesk built from this repository (see `IS2L-BUILD.md`). Remove stock RustDesk first; the two cannot be installed together on the PC.
2. Make sure it is installed **as a service** (the `.deb` does this; the service is called `rustdesk`). The service is what creates the virtual controller. A portable copy started by hand cannot do it.
3. Open its settings and check that **Allow game controller input** is ticked (it is by default).
4. In the same settings, enable **Direct IP access**. Set a permanent password.
5. Install Tailscale and sign in.

On the handheld:

6. Install Tailscale and sign in to the same account.
7. Install is2l Remote.
8. Open is2l Remote and, in the ID field, type the PC's Tailscale address (it looks like `100.x.y.z`) and connect. Direct IP access uses port 21118 unless it was changed on the PC.
9. In the session's display settings set image quality to **Custom**, the frame rate to **60**, and the codec to **H264**.
10. Open **Controller** to check that the buttons arrive, or to change the mapping.

## Against a stock RustDesk host

If the PC runs stock RustDesk, it does not announce the `gamepad` feature. The app then does not send controller messages; buttons, triggers and sticks fall back to fixed keyboard keys (for example A is Z, B is X, the D-pad and the left stick are the arrow keys, the right stick is I/J/K/L); a trigger or stick counts as pressed past half of its travel, so there is no analog input. Everything else works as in stock RustDesk.

## Known limits

These come from reading the code, not from measurements.

- **Video is captured on the CPU** on the Linux PC and **decoded in software on the handheld**. The Android build that this repository's CI produces includes only a software H264/H265 decoder. Expect noticeable CPU use and battery drain at 60 fps and high resolutions.
- **More than 30 fps needs a direct connection.** When the connection goes through RustDesk's public servers and is not direct, the app caps a custom frame rate at 30 (`src/client.rs`). Connecting by Tailscale address is a direct connection.
- **Audio can lag** behind the picture by a few hundred milliseconds.
- Rumble (vibration) is not sent back to the handheld; the new message only travels from the handheld to the PC.
- The remote-control protocol adds delay that a purpose-built game streaming program does not have. Fast action games will feel it.

## Not tested yet

Everything. Nothing in this fork has been compiled, installed or run. In particular, nobody has yet checked that:

- the Rust code, the Kotlin code and the Dart code compile;
- the Android app builds, installs beside stock RustDesk, and starts;
- controller buttons, sticks and triggers are captured on an AYN Thor, on a phone or on a trifold with a connected controller;
- the virtual controller appears on the Linux PC and games accept it;
- the "Allow game controller input" setting works and is on by default;
- mapping profiles save and load;
- the control panel appears on the Thor's bottom screen and its buttons work;
- the fallback against a stock RustDesk host behaves as described;
- 60 fps H264 over Tailscale is actually reached, and how large the delay is;
- the app-name change left no place where Android confuses the fork with stock RustDesk. Known leftovers: both apps answer `rustdesk://` links (Android will ask which one to open), and the in-app help text for the accessibility permission still tells you to switch on "RustDesk Input" although the fork's service is listed as "is2l Remote Input".
