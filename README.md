# Feed Readiness — Demo App

**Fling through a short-video feed and watch what the engine actually holds. The console shows which clips own a hardware decoder, which have bytes on disk and at what quality. It also shows what happens to all of that when the phone goes offline, overheats, or the user turns out to be a skipper.**

[![CI](https://github.com/rajatslakhina/video-feed-readiness-kit-demo-app/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/video-feed-readiness-kit-demo-app/actions/workflows/ci.yml)
[![Simulator run](https://github.com/rajatslakhina/video-feed-readiness-kit-demo-app/actions/workflows/simulator.yml/badge.svg)](https://github.com/rajatslakhina/video-feed-readiness-kit-demo-app/actions/workflows/simulator.yml)

This app is the runnable companion to **[FeedReadiness](https://github.com/rajatslakhina/video-feed-readiness-kit)**, a resource-budgeted readiness engine for vertical video feeds. It is a separate Xcode project. It consumes the library as a **remote Swift package pinned to a release** (`upToNextMajorVersion` from `1.0.0`), never through a local path or a branch.

<!-- SCREENSHOTS -->

## Why this matters

"Prefetch the next N videos" is the whiteboard answer to the feed system-design question. On a phone it fails in ways that only show up under real conditions:

- the hardware decoder budget;
- flings that race your own teardown;
- playback commands that overtake each other;
- device state (network, heat, battery, memory) that should shrink the window;
- users whose attention makes a fixed prefetch depth wrong.

This console makes each of those visible. Every number on screen comes from the engine's own snapshot or from the contract-checking player port, not from the UI.

## What you can do in the app

The app launches into the **steady** state: two swipes into the feed on Wi-Fi. Each row below starts from that state.

| Control | What happens | What to look at |
|---|---|---|
| **▼ / ▲** | Moves the cursor one clip | The window card re-plans around the new clip: 1 **PLAYING**, 3 **PREPARED** (holding a decoder: one behind, two ahead) and 3 **PREFETCH** (bytes on disk, no decoder). The next row is **cold** |
| **Fling ×10** | Ten swipes with no pause, while every decoder takes 120 ms to prepare | *Deferred releases* rises (4 when this exact sequence was run headless), and downloads for clips that left the window are cancelled. *Releases while still preparing*, *Leaked decoders*, *Hardware peak above budget*, *Two clips playing at once* and *Commands to released players* all stay at **0**. The fling also teaches the skip model a skipper, so new prefetches shrink to 1.5 s |
| **Conditions → Offline** | The network drops | The PREFETCH rows disappear: nothing new is fetched, and downloads still in flight would be cancelled. The playing clip keeps playing and the next clip stays prepared, because their players already buffered. Nothing else gets a decoder unless its first segment is on disk. Add Low Power Mode or heat on top and the clip still plays at its prepared 1080p: offline, the quality cap is a preference, not a reason to stop |
| **Conditions → Thermal: critical** | The phone overheats | Decoders drop to 1, the quality cap falls to 0.6 Mbps, and the playing clip switches to 360p *make-before-break* (*Make-before-break hand-offs* = 1). While the switch is in progress, its row reads 1080p→360p. Clips whose cached bytes are 1080p show **–** at 360p, because 1080p bytes cannot feed a 360p decoder |
| **Conditions → Thermal: nominal** (after critical) | The phone cools | Quality does not jump straight back. It climbs one level per 4 s of sustained headroom, and each swipe, condition change or completed download checks the timer. Swipe every few seconds and the cap goes 0.6 → 1.2 → 2.5 → 5.0 Mbps (*Quality up* = 3) |
| **Conditions → Toggle Low Power Mode** | Low Power Mode turns on | One clip prepared ahead, none behind, prefetch +2, and the quality cap drops to 1.2 Mbps (540p) |
| **Train → 10 swipes as a skipper** | The on-device skip model learns this user | *P(skip next)* rises past 0.70 and the window title switches to "× 1.5 s": new prefetches fetch only the first segment |

Every 17th clip in the compiled-in catalog has a broken manifest (no renditions). It shows as a cold row with no rendition, and the engine plans around it instead of crashing.

The launch argument `-scenario <steady|fling|hot|offline|skipper|cellular-low-power>` plays one of these on launch. The shared scheme carries all six, disabled, under *Edit Scheme → Run → Arguments*.

## How to run it

1. `git clone https://github.com/rajatslakhina/video-feed-readiness-kit-demo-app.git`
2. Open `Demo.xcodeproj` in Xcode 16 or later. Xcode resolves `video-feed-readiness-kit` from GitHub at the pinned release.
3. Select the **Demo** scheme and any iPhone Simulator running iOS 17 or later.
4. **Build & Run** (⌘R).

## How it is put together

```
Demo/
  DemoApp.swift          @main; owns the compiled-in catalog (80 clips, 4-rung ladder),
                         the engine budgets (4 decoders, 48 MB cache) and the -scenario parsing
  FeedConsoleModel.swift @MainActor @Observable model: drives FeedEngine with SimulatedPlayer
                         (120 ms prepare) and SimulatedTransport (6 MB/s); one action at a time;
                         swipes use the engine's own cursor (move(by:)), never a stale snapshot
  ConsoleView.swift      one screen: conditions, metrics, the window, contract checks, counters
Scripts/
  simulator-screenshots.sh  CI: build, install, launch each scenario, check it is alive, screenshot
```

No real video is decoded. `SimulatedPlayer` stands in for `AVPlayer`, and it also *checks the port contract*:

- how many decoders are live at once;
- any release that arrives while that player is still being created;
- how many clips are playing at once;
- any command sent to a player that was already released, or whose prepare failed.

That is how the fling result above is measured rather than asserted. The library's tests also drive this simulated player with deliberate contract violations, to prove that each of its counters really counts.

<!-- VERIFICATION -->

MIT licensed.
