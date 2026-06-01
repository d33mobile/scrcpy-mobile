# Open questions (ordered by importance)

Batches of ≤3 asked interactively. Defaults in **bold** are what I'll do if you
don't override.

## Batch 1 (ANSWERED 2026-06-01)

- **Q1 → (A) Reuse `porting/` via Android NDK.** Faithful path: cross-compile the
  native scrcpy port to Android, build the client around it. Higher effort accepted.
- **Q2 → Full GUI automation of A.** The e2e must drive our app's rendered remote
  view on emulator A (uiautomator taps over the surface) and verify propagation to B.
  Implies the app must expose a touchable surface mapping touches → scrcpy control.
- **Q3 → Green e2e proving control.** Done = reproducible one-script Docker e2e on
  d-claude showing A controlling B (input verified). SW-decode/low-fps + minimal UI
  acceptable; README/plan say WIP.

Batch-2 (Q4–Q7) proceeding on defaults: minSdk 26 / target 36; SDL2-backed surface
for the remote view (NDK path) with a minimal Kotlin launcher; fork to
`d33mobile/scrcpy-mobile`, push to a branch; harness requires `/dev/kvm`.

## Batch 1 — original wording

### Q1. Android client strategy
How should the new Android controller be built?
- **(B) Fresh Kotlin client** — new app speaking the scrcpy protocol directly
  (dadb for ADB, MediaCodec decode, SurfaceView render). Fastest to a working,
  testable WIP; idiomatic; doesn't reuse the iOS C port. *(my default)*
- (A) Reuse `porting/` C lib via Android NDK + SDL2 — faithful, shares iOS code,
  but weeks of cross-compilation and high risk to get green.
- (C) Hybrid — ship the fresh Kotlin client now to reach a green e2e, keep the
  NDK retarget as a documented future phase.

### Q2. e2e success bar (what the test must prove)
- **Stack/control-level** — emulator A's client connects to emulator B and we
  assert real input from A changes B's UI (verified via B screenshot/dumpsys).
  Proves "A controls B" without fragile pixel automation of A's own UI. *(default)*
- Full GUI automation of A — also uiautomator-tap inside A's rendered remote view
  and verify propagation to B. Most realistic, much more brittle.
- Both, staged — stack-level as the gate, GUI automation as an optional deeper check.

### Q3. Definition of "fully realized" (when the review loop may stop)
- **Green e2e proving control** — one-script Docker e2e on d-claude reliably shows
  our client on A controlling B (input verified), built+run reproducibly. Video may
  be SW-decoded/low-fps, UI minimal. README/plan say WIP. *(default)*
- Control + live video verified — also assert B's framebuffer actually renders on A
  (pixel/diff check), not just input.
- Control + video + polished app — plus a usable UI approaching the iOS feature set.

## Batch 2 (defaults, will not block on these)

### Q4. Min SDK / target — default minSdk 26, target latest stable (36). OK?
### Q5. App UI shell — default Kotlin + Jetpack Compose for the device-list/connect
  screen, SurfaceView for the remote video. OK?
### Q6. Fork — default fork to `d33mobile/scrcpy-mobile`, push README+plan+code to a
  branch (not master), open nothing upstream. OK?
### Q7. Requiring KVM — the harness will require `/dev/kvm` (present on d-claude),
  with a documented slow fallback. OK?
