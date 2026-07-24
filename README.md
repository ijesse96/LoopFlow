# LoopFlow

iPhone DAW for loop-based vocal recording over an imported instrumental.

## V1 workflow

1. Import a beat (WAV, MP3, AIFF, M4A)
2. Set BPM and recording region length (1 / 2 / 4 / 8 bars)
3. Record — the active region loops; each pass creates a new take
4. Accept a take with a Bluetooth keyboard (`Space` = Keep Take + Next Region by default)
5. Auto-advance to the next region and keep recording
6. Export vocal, instrumental, stems, or full mix

## Requirements

- Xcode 16+
- iOS 17+
- Physical device recommended for microphone + Bluetooth keyboard

## Open & run

1. Open `LoopFlow.xcodeproj` in Xcode
2. Select your Development Team under Signing & Capabilities
3. Run on an iPhone

## Controller defaults

| Action | Key |
|--------|-----|
| Keep Take | A |
| Keep Take + Next Region | Space |
| Previous Region | ← |
| Next Region | → |
| Redo Region | R |
| Undo | Z |
| Record | O |
| Stop | Esc |

Remap anytime in **Settings → Controller Mapping**.

## Architecture

SwiftUI + MVVM with managers for audio engine, recording, timeline math, controller input, export, and project storage. Effect insert slots are stubbed for future built-in DSP / AUv3.
