# Tether Ink

A free vector drawing app for iPad, laid out like the drawing apps you already know, with proper stroke stabilisation:

- **Streamline** (amount and pressure), **stabilisation** (amount and speed), **motion filtering** (amount and expression), per brush, plus global smoothing for every brush. Stabilisation and motion filtering smooth the line just behind the pen, so the line stays on the pen with no lag; streamline adds an optional rope-like glide.
- **Pressure curve** you can shape by hand. Pressure only changes as the pencil travels, so pausing or pressing at the start never swells the line.
- **Hold-to-snap** straight lines, smooth arches, ellipses and circles.
- **Vector strokes** that stay sharp at any zoom, layers, a stroke eraser and a vector eraser, and SVG/PNG export.
- **Apple Pencil double-tap** swaps brush and eraser; **squeeze** (Apple Pencil Pro) opens colours.
- Drawings are saved in the app's folder as `.tether.json` files, which show up in the Files app.

## Install with SideStore (free Apple Account)

You need a computer once, for the first install. After that, everything happens on the iPad.

1. **On the iPad**, install **LocalDevVPN** from the App Store, open it, and allow the VPN configuration.
2. **On the computer**, install **iloader** from <https://iloader.app> (on Windows, install iTunes first).
3. Connect the iPad with a cable, trust the computer, open iloader, sign in with your Apple Account, select the iPad, and choose **Install SideStore (Stable)**.
4. **On the iPad**: Settings → General → VPN & Device Management → trust your Apple Account. Then Settings → Privacy & Security → turn on **Developer Mode** (the iPad restarts).
5. Connect **LocalDevVPN**, open **SideStore**, and sign in with the same Apple Account.
6. In SideStore, go to **Sources**, tap **+**, and add:

   `https://github.com/kylelekyle/tether-ink/releases/download/latest/source.json`

   Then install **Tether Ink** from that source. (Or download `TetherInk.ipa` from the Releases page and add it in SideStore → My Apps → **+**.)

Free Apple Accounts sign apps for 7 days. Open SideStore with LocalDevVPN connected and refresh before the counter runs out. Free accounts can have 3 sideloaded apps at once (SideStore counts as one).

Full SideStore documentation: <https://docs.sidestore.io>

## How it's built

Every push to `main` builds the app on GitHub's macOS runners, runs the unit tests, takes simulator screenshots, and publishes an unsigned `TetherInk.ipa` plus a SideStore source to the `latest` release. SideStore signs it on the iPad with your own Apple Account.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

The stroke outline engine is a Swift port of [perfect-freehand](https://github.com/steveruizok/perfect-freehand) (MIT License, Copyright (c) 2021 Stephen Ruiz Ltd).
