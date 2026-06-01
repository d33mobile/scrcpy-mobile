# scrcpy-mobile — Android client (WIP fork)

> ⚠️ **Work in progress.** This is a fork of
> [wsvn53/scrcpy-mobile](https://github.com/wsvn53/scrcpy-mobile) whose goal is to
> let **Android users control other Android phones** — i.e. run the scrcpy client
> *on an Android device* and use it to remotely view and control a second Android
> device over ADB-over-WiFi.
>
> The upstream project ports [scrcpy](https://github.com/Genymobile/scrcpy) to iOS
> (controlling Android from an iPhone). Upstream notes that "Android controlling
> Android will be supported in the future" — **this fork is that future work.** It
> is not finished and not on any app store yet.

## Goal

Enable a phone-to-phone workflow: **install this app on Android device A, point it
at Android device B, and control B from A** — screen mirroring plus touch,
keyboard, navigation buttons and clipboard — reusing the same native scrcpy port
that the upstream iOS app uses.

## Approach

This fork reuses the existing native C scrcpy port in [`porting/`](porting/) (the
same code the iOS app links as `libscrcpy.a`) and retargets it to the **Android
NDK**, then wraps it in a minimal Android app:

- Cross-compile the native stack (scrcpy client + FFmpeg + SDL2 + OpenSSL +
  `adb-mobile`) for `arm64-v8a` / `x86_64`.
- Build a thin Kotlin app that hosts the SDL surface, calls `scrcpy_main()`, and
  exposes a touchable remote-view that maps gestures to scrcpy control messages.
- Connect to the target device over ADB-over-WiFi; the existing
  `scrcpy-server` (runs on the *target*) is reused unchanged.

See [`ai/plans/`](ai/plans/) for the full, phased implementation plan and
[`ai/research/`](ai/research/) for the architecture analysis.

## End-to-end test

A one-script, Dockerized e2e harness boots **two x86_64 Android emulators on a
single host** (target B + controller A running this app) and proves that A
controls B — driving the app's remote view on A via UI automation and asserting
that B reacts. It runs on the `d-claude` host over SSH, requires only Docker +
KVM, and makes as few assumptions about the outside environment as possible. See
[`e2e/`](e2e/) (added as the harness lands) and the plan for details.

## Status

| Piece | State |
|-------|-------|
| iOS app (upstream) | ✅ works (unchanged in this fork) |
| Native port → Android NDK | 🚧 in progress |
| Android client app | 🚧 in progress |
| Dockerized two-emulator e2e | 🚧 in progress |

## License

Same as upstream — see [LICENSE](LICENSE). scrcpy is © Genymobile and contributors.

---

### Upstream documentation

For the iOS app, App Store install, ADB/VNC connection modes and pairing-code
instructions, see the original upstream README:
<https://github.com/wsvn53/scrcpy-mobile>.
