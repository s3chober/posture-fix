<div align="center">

<img src="docs/icon.png" width="110" alt="PostureFix" />

# Posture Focus prototype

**A quiet AirPods-powered head-position companion for focus sessions.**

[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

Posture Focus sits in the menu bar and reads AirPods head-motion sensors. After
a sustained downward tilt it fades in a click-through glow around the screen
edges. The centre of the screen remains clear, and audio is disabled by default
so Brain.fm, music, and calls are left alone.

## Build and run

Requires macOS 14+ and Xcode Command Line Tools:

```bash
./build.sh
ditto -x -k "dist/Posture Focus.zip" /Applications
open -a "Posture Focus"
```

The archive is assembled and signed in a temporary non-synced directory before
being placed in `dist`. This avoids Finder/iCloud metadata invalidating the
local signature when the source project lives on the Desktop.

## First run

1. Connect AirPods 3 (or another compatible model) and start Brain.fm or your
   preferred focus audio normally.
2. Open the menu-bar icon and choose an untimed, 25, 50, or 90-minute session.
3. Click **Start**, allow Motion & Fitness access, and wait for live pitch data.
4. Sit in a comfortable neutral position and click **Calibrate**.
5. A sustained head drop produces a warm edge glow. Lift your head and it
   disappears automatically.

## Features

- Reads head pitch via Apple's Core Motion — no extra hardware.
- One-tap calibration of your upright baseline.
- Public-AppKit screen-edge cue that does not capture clicks or alter audio.
- Silent by default; sound, voice, and notifications are optional escalations.
- Untimed monitoring for external Pomodoro apps plus 25/50/90-minute sessions.
- Live stats and a 7-day history chart.
- Tunable sensitivity, hold time, cooldown, and alert sound.
- Start at login. Fully local — nothing leaves your Mac.

## Settings

| Setting | Description |
| --- | --- |
| Head-drop threshold | Difference from the calibrated pitch before a cue can begin |
| Hold before cue | How long the tilt must be sustained; default 8 seconds |
| Screen-edge glow | Quiet primary feedback; enabled by default |
| Escalate after | Total sustained tilt required before optional audio/notification |
| Repeat cooldown | Minimum gap between interruptive cues; default 3 minutes |
| Reverse detection | Flip if alerts fire when you sit up instead of slouch |
| Start at login | Launch PostureFix automatically |

## How it works

Modern AirPods expose a 9-axis IMU through `CMHeadphoneMotionManager` — the data
behind Spatial Audio head tracking. PostureFix streams your head pitch, captures
an upright baseline when you calibrate, filters the signal, and flags a slouch
when your head stays dropped past your threshold. AirPods measure head
orientation rather than spine or shoulder position, so this is intentionally a
head-tilt reminder—not a medical posture assessment.

## Tests

Run the deterministic filter and timing checks with:

```bash
bash test.sh
```

## Compatibility

macOS 14+. AirPods Pro (1st/2nd gen), AirPods (3rd gen), AirPods Max, or
Beats Fit Pro.

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). This prototype is derived from
[chandansgowda/posture-fix](https://github.com/chandansgowda/posture-fix); the
original copyright and license notice are preserved.
