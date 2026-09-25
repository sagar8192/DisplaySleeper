# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS-only menu bar agent (`LSUIElement`) in Swift that works around a faulty MacBook lid Hall sensor: the `AppleClamshellState` IORegistry flag reads `true` only when the lid is ~1–2" open and falsely flips back to `false` when fully closed ("overshoot"). The app latches on the first `true` and keeps forcing `pmset sleepnow` through the overshoot. Building and running requires macOS with Xcode command line tools (`xcrun`, `swiftc`, `codesign`); nothing here builds on Linux.

## Commands

There is no Swift Package / Xcode project — everything is plain `swiftc` driven by the `Makefile` (with `Scripts/build.sh` and `Scripts/run_tests.sh` as equivalent standalone scripts).

- `make build` — compile `DisplaySleeper.app` into the repo root and ad-hoc sign it
- `make test` — compile `LidLatchManager.swift` + `Tests/main.swift` into `.build/test_runner` and run it
- `make run` — build and `open` the app
- `make install-daemon` / `make uninstall-daemon` / `make status-daemon` — manage the LaunchAgent via `launchctl bootstrap|bootout gui/<uid>`
- `make logs` — tail `~/Library/Logs/DisplaySleeper.log`
- `make clean`

Tests are a hand-rolled runner (no XCTest) using `assert`. To run a single test, temporarily trim the calls in `LidLatchManagerTests.runAll()` in `Tests/main.swift`. Tests are compiled without `-O`, so `assert` is active; don't add `-O` to the test target.

## Architecture

- `main.swift` → `AppDelegate` (status bar menu, Accessibility prompt) → owns one `LidLatchManager`.
- `LidLatchManager.swift` holds all logic. A 10ms `Timer` on the main run loop calls `checkLidState()`, which runs a small state machine over `userIntendsToClose` / `wasInOvershoot`:
  - sensor `true` while unlatched → trip latch, call `displaySleeper()` (suppressed for 2s after a release, since opening the lid passes back through the sensor zone)
  - sensor `false` while latched → overshoot; re-call `displaySleeper()` at most once per 1.0s (`lastSleepCallTime`)
  - sensor `true` while latched *and* after an overshoot → lid is being opened; release latch and call `wakeTrigger()`
  - while latched (>1s after trip), recent key/flags/click activity from `CGEventSource.secondsSinceLastEventType` (no Accessibility permission needed) releases the latch via `handleKeyPress()`; an `NSEvent` global keyDown monitor does the same when Accessibility is granted.
- Side effects are injected through the init (`clamshellReader`, `displaySleeper`, `wakeTrigger`, `autoStart`, `dryRun`); the static `default*` functions are the real IOKit / `pmset` / synthetic-mouse-move implementations. Tests pass closures and `autoStart: false`, then drive `checkLidState()` / `handleKeyPress()` manually.

## Constraints and gotchas

- **Adding a source file** means updating `SOURCES` in the `Makefile` *and* the file list in `Scripts/build.sh`. Tests compile only `LidLatchManager.swift` alongside `Tests/main.swift`, so `LidLatchManager` must not depend on `AppDelegate` or other app files.
- Tests read `userIntendsToClose` directly (it's `private(set)` internal), which works because both files are compiled into one module.
- Logging convention: each message is emitted via both `NSLog` and `print` followed by `fflush(stdout)` — launchd redirects stdout/stderr to the log file, and the README relies on log gaps as proof of hardware sleep.
- `Resources/com.custom.DisplaySleeper.plist` hardcodes absolute paths under `/Users/sagar/...` for the executable and log file; `install-daemon` copies it verbatim, so it only works for that path layout unless edited.
- Time-based logic (1.0s sleep pacing, 1.0s input-check delay, 2.0s re-latch cooldown) uses `Date()` directly and isn't injectable, so tests that call `checkLidState()` back-to-back never cross these thresholds. Check tests against the current pacing when changing that logic — e.g. `testHardwareOvershootInterception` expects a sleep call on every overshoot poll, which the 1.0s throttle doesn't produce.
- Git history includes a reverted attempt at bag-wake protection (removing single-keypress disarm, SMC lid wake detection, triple-keypress override); see commits `267312f` / `b652035` before re-attempting similar changes.
