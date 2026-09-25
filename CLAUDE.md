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
- `LidLatchManager.swift` holds all logic. Sensor readings come from two sources, both feeding `processLidReading(_:)` on the main run loop: a 10ms `Timer` polling `AppleClamshellState` (`checkLidState()`), and `kIOPMMessageClamshellStateChange` interest messages from `IOPMrootDomain` (`handlePowerMessage`). The messages report every transition, including fast-close blips that flip back before the next poll. A `ProcessInfo` activity keeps App Nap from throttling the timer. The state machine over `userIntendsToClose` / `wasInOvershoot` must stay idempotent for repeated identical readings, since both sources report the same transitions:
  - sensor `true` while unlatched → trip latch, call `displaySleeper()` (suppressed for 2s after a release, since opening the lid passes back through the sensor zone)
  - sensor `false` while latched → overshoot; re-call `displaySleeper()` at most once per 1.0s (`lastSleepCallTime`)
  - sensor `true` while latched *and* after an overshoot → lid is being opened; release latch and call `wakeTrigger()`
  - resuming from sleep while latched (a >5s gap between readings): the sensor reads `false` whether the lid is flush or was opened while asleep, so overshoot enforcement is held. A full wake (`NSWorkspace.didWakeNotification`) extends the hold to 30s for the user to unlock (`com.apple.screenIsUnlocked`) or press a key. DarkWakes don't post that notification, so enforcement resumes after 5s.
  - while latched (>1s after trip), recent key/flags/click activity from `CGEventSource.secondsSinceLastEventType` (no Accessibility permission needed) releases the latch via `handleKeyPress()`; an `NSEvent` global keyDown monitor does the same when Accessibility is granted.
- Side effects are injected through the init (`clamshellReader`, `displaySleeper`, `wakeTrigger`, `clock`, `inputIdleReader`, `autoStart`, `dryRun`); the static `default*` functions are the real IOKit / `pmset` / `CGEventSource` / synthetic-mouse-move implementations. Tests pass closures and `autoStart: false`, then drive `checkLidState()` / `handlePowerMessage(_:argument:)` / `handleSystemDidWake()` / `handleScreenUnlocked()` / `handleKeyPress()` manually, moving time forward with `advanceTime(by:)`.

## Constraints and gotchas

- **Adding a source file** means updating `SOURCES` in the `Makefile` *and* the file list in `Scripts/build.sh`. Tests compile only `LidLatchManager.swift` alongside `Tests/main.swift`, so `LidLatchManager` must not depend on `AppDelegate` or other app files.
- Tests read `userIntendsToClose` directly (it's `private(set)` internal), which works because both files are compiled into one module.
- Logging convention: each message is emitted via both `NSLog` and `print` followed by `fflush(stdout)` — launchd redirects stdout/stderr to the log file, and the README relies on log gaps as proof of hardware sleep.
- `Resources/com.custom.DisplaySleeper.plist` hardcodes absolute paths under `/Users/sagar/...` for the executable and log file; `install-daemon` copies it verbatim, so it only works for that path layout unless edited.
- All time-based logic (1.0s sleep pacing, 1.0s input-check delay, 2.0s re-latch cooldown) must read time through `clock()`, not `Date()`, or it can't be tested. Tests default `inputIdleReader` to `.infinity`, so the real `CGEventSource` never sees a recent keypress (like the one that launched `make test`) and releases the latch.
- Git history includes a reverted attempt at bag-wake protection (removing single-keypress disarm, SMC lid wake detection, triple-keypress override); see commits `267312f` / `b652035` before re-attempting similar changes.
