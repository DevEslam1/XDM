# Rollback plan: `libtorrent_flutter` → pub.dev 1.9.2

**Audience:** the agent executing this rollback (Gemini).
**Author:** prior investigation session, 2026-08-23.
**Repo:** `d:\Courses\Projectss\dmx` — branch `main`, baseline commit `7c2da25d`.

---

## 1. Objective

Replace the vendored local package at `packages/libtorrent_flutter` (a 2.0.0-shaped
API) with the pub.dev release **`libtorrent_flutter: 1.9.2`**, and adapt the app so
it compiles and runs against 1.9.2's smaller API surface.

The user's rationale: 1.9.2 was stable in this app. That rationale is **correct and
verified** — see §2.2. This is not a superstition; do not try to talk the user out
of it, and do not silently substitute a different fix.

---

## 2. Findings you must not re-derive (and must not get wrong)

Read this whole section before touching anything. Two prior attempts were burned on
the mistakes described here.

### 2.1 The shipped binary is a hybrid: ABI-2 struct, ABI-1 export set

`packages/libtorrent_flutter/prebuilt/android/<abi>/liblibtorrent_flutter.so`:

| Property | Value |
|---|---|
| `lt_`-prefixed exports | **30** (arm64-v8a, armeabi-v7a, x86_64 all agree) |
| ABI-2 exports required by the vendored Dart bindings but **absent** | **15** |
| `lt_torrent_status` layout actually written | **1880 bytes** (ABI-2, includes `num_complete`/`num_incomplete`) |
| `lt_version()` ABI marker | none emitted |

**The export table is not evidence about the struct layout.** A prior attempt read
the 29/30-symbol export table, matched it to 1.9.2, and "fixed" the Dart struct down
to 1.9.2's 1872-byte layout. That shifted `numPieces`…`queuePosition` 8 bytes early
and landed `hasMetadata` on native `is_paused` — which is `0` for any running
torrent. Result: a `.torrent` file with fully-known metadata reported *"no
metadata"*, the UI showed `0/1 FILES`, per-file progress never populated, and
`haltTorrent` skipped the graceful pause every time.

**What settled it:** native logged `lt_get_files: successfully processed 1 files`
and knew the 6.1 GB total, so native `has_metadata` was unambiguously `1`, while
Dart read `0` at the 1872-byte offset. Only the 1880-byte layout explains that.

> If you ever need to re-verify exports, use `tool/probe_elf_symbols.py` (a real
> ELF `.dynsym`/`.dynstr` parser). **Do not use `strings` or ripgrep** — both give
> false negatives on these binaries, including for control symbols that certainly
> exist (`lt_add_magnet`, `lt_get_status`, `lt_version`). That false negative is
> what produced the wrong diagnosis in the first place.

### 2.2 Why 1.9.2 is genuinely stable — the actual justification for this rollback

1.9.2 is **self-consistent**: its Dart bindings and its prebuilt binary ship from
the same GitHub Release, so they cannot disagree.

- 1.9.2 C header `lt_torrent_status` → 1872 bytes, no `num_complete`/`num_incomplete`.
- 1.9.2 Dart `LtTorrentStatus` → 1872 bytes, field named **`totalDone`**.
- 1.9.2 looks up exactly the ~29 symbols its binary exports.
- 1.9.2 has **no** ABI-marker / `abiReport` / `verifyStatusStructContract` machinery,
  because it does not need any.

The vendored package broke this invariant: 2.0.0-era Dart bindings paired with a
binary that never got the 2.0.0 exports.

### 2.3 The 15 absent ABI-2 exports

```
lt_add_magnet_resume        lt_add_torrent_file_resume  lt_add_tracker
lt_force_dht_announce       lt_force_reannounce         lt_get_file_priorities
lt_get_file_progress        lt_get_trackers             lt_load_resume_data
lt_remove_tracker           lt_save_resume_data         lt_set_piece_deadline
lt_set_sequential_download  lt_set_super_seeding        lt_take_saved_resume_data
```

Note: `lt_poll_alerts` and `lt_set_alert_callback` are **present** in 1.9.2 — see §5.2.

### 2.4 Torrent id numbering — no change needed

Native allocates from `std::atomic<int64_t> next_id{1}`, identical in 1.9.2 and
2.0.0. First torrent is id **1**; **0 is never issued**; failures return **-1**.
App-side `id >= 0` guards therefore catch every failure sentinel. `0` is a dead
value the guards needlessly admit — harmless. **Do not "fix" this**; it is not a bug.

### 2.5 Untested change in the baseline

Baseline `7c2da25d` contains a struct restore to the correct 1880-byte layout that
was **never run on device**. It specifically fixes the `hasMetadata` misread in §2.1.
Note this in your final report, because it means "1880 is broken" has not actually
been demonstrated — only "1872 is broken" has. Proceed with the rollback anyway;
the user has decided. But do not claim the rollback fixed something the untested
change might also have fixed.

---

## 3. Baseline state

```
HEAD                7c2da25d  "still v2.0.0 feat: implement libtorrent FFI service layer and add ELF symbol validation tool"
working tree        clean
pubspec.yaml:54     libtorrent_flutter:\n    path: packages/libtorrent_flutter
pubspec.yaml:97     ffi: ^2.1.0          (dev_dependencies — test-only, added for the offset test)
ffi_bindings.dart   kExpectedStatusSize = 1880, numComplete/numIncomplete present
```

**Last known-good 1.9.2 commit: `86e2a0e3`** (`refactor(9.5+): harden production
readiness and optimize resource management`). At that commit `pubspec.yaml` read
`libtorrent_flutter: 1.9.2 # exact pin: no saveResumeData API in this version`.

`cb070209` is the commit that vendored the local package and switched to `path:`.

**Do this before anything else:**

```bash
git checkout -b rollback/libtorrent-192
git tag pre-rollback-192          # abort anchor, see §8
```

---

## 4. Choose a route

### Route A — revert the torrent layer to `86e2a0e3` (recommended)

Restore the torrent layer wholesale from the last commit that actually worked on
1.9.2, rather than hand-writing ~30 API removals.

**Pro:** the 1.9.2-compatible call sites already existed and were tested.
**Con:** discards torrent-layer work from `cb070209`, `7d32f524`, `dcd06e2d`,
`692fb522`, `2b5947fa`, `444d93ab`, `7c2da25d`.

**Get the user's explicit confirmation that losing that work is acceptable before
executing Route A.** If they say no, use Route B.

```bash
# Inspect the blast radius first — do not skip this.
git diff --stat 86e2a0e3 HEAD -- lib/core/services/ lib/features/downloads/ test/
```

Then restore the torrent layer and pubspec pin:

```bash
git checkout 86e2a0e3 -- pubspec.yaml
git checkout 86e2a0e3 -- lib/core/services/torrent_service_ffi.dart \
                         lib/core/services/torrent_service_stub.dart \
                         lib/core/services/torrent/ \
                         lib/core/services/engine/torrent_download_handler.dart \
                         lib/core/services/torrent_resume_store.dart \
                         lib/core/services/interfaces/i_torrent_native.dart \
                         lib/core/services/interfaces/i_torrent_service.dart
git rm -r --cached packages/libtorrent_flutter && rm -rf packages/libtorrent_flutter
```

Expect `flutter analyze` failures where *non*-torrent code (providers, UI,
`metadata_probe_service.dart`) evolved past `86e2a0e3`. Resolve those by adapting
the newer callers to the older torrent API — **not** by reintroducing 2.0.0 APIs.

### Route B — keep current app code, pin 1.9.2, shim the gap

**Pro:** preserves all recent work. **Con:** you must write the shim in §5.

Use Route B if the user will not accept losing the recent torrent commits.

```bash
rm -rf packages/libtorrent_flutter
```

`pubspec.yaml` — replace the `path:` dependency:

```yaml
  # Exact pin. 1.9.2's Dart bindings and its prebuilt .so ship from the same
  # GitHub Release, so the struct layout cannot drift (see
  # docs/ROLLBACK_LIBTORRENT_1.9.2_PLAN.md §2.2).
  libtorrent_flutter: 1.9.2
```

Also **remove `ffi: ^2.1.0` from `dev_dependencies`** and delete the offset test it
supports (§6).

---

## 5. Route B: the API gap

The app calls **47** `LibtorrentFlutter` members; **30 do not exist in 1.9.2**. Nine
of those 30 are `supports*` helpers added in the baseline and simply disappear with
the vendored package. The remaining **21** need a disposition.

Verify the list yourself after switching the pin — `flutter analyze` is the
authority, not this table:

```bash
flutter pub get && flutter analyze 2>&1 | grep -E "isn't defined|not defined|undefined"
```

### 5.1 Disposition table

| Missing in 1.9.2 | Disposition |
|---|---|
| `abiReport` | Delete all ABI machinery. `bridgeCompatible` becomes a `const true` — 1.9.2 cannot mismatch itself. Also delete `kExpectedStatusSize`, `kExpectedBridgeAbi`, `verifyStatusStructContract`, `BridgeAbiReport`. |
| `saveResumeData`, `loadResumeData`, `takeSavedResumeData` | Remove. `resumeDataSupported => false`. Fall back to the existing Dart-side `.dmxstate` persistence in `torrent_resume_store.dart`. **Consequence: torrents re-check on next launch.** Tell the user plainly. |
| `getFileProgress` | `fileProgressSupported => false`. The repo already has a Dart estimator — `lib/core/domain/` + `test/core/domain/torrent_file_progress_estimator_test.dart`. Route per-file bytes through it. |
| `getFilePriorities` | `filePrioritiesSupported => false`. 1.9.2 **does** have `setFilePriorities`, so keep a Dart-side cache of what was written and read back from that. |
| `getTrackers`, `addTracker`, `removeTracker` | `trackersSupported => false`; hide the **Trackers Panel** in the download-details UI. |
| `getWebSeeds`, `addWebSeed`, `removeWebSeed` | Hide the web-seed section of **Advanced Controls**. |
| `announceNow` | No-op. Also remove the 10-minute "forcing reannounce" branch of the stall watchdog in `torrent_download_handler.dart` — it would log a recovery action that cannot happen. |
| `setSequentialDownload`, `setSuperSeeding`, `setPieceDeadline` | Report unsupported; hide the toggles. Note 1.9.2 still uses piece deadlines *internally* for streaming — only the public setters are gone. |
| `createTorrent` | Hide the create-torrent feature. |
| `setProxy`, `setSslCertificate`, `loadIpFilter` | Hide those settings. |
| `getTorrentStatus` | Replace with the `torrents[id]` snapshot map (`Map<int, TorrentInfo> get torrents`). |
| `alertUpdates` | **Largest item — see §5.2.** |

### 5.2 `alertUpdates` — rebuild it, don't remove it

The app has an alert-driven engine (`torrent_alert_contract_test.dart`, "PROMPT
ARCH-2"). 1.9.2 exposes no public `alertUpdates` stream — **but it already binds
`lt_poll_alerts` and `lt_set_alert_callback`, and its `.so` exports both.**

So do **not** rip out the alert architecture and fall back to polling. Add a thin
Dart wrapper in the app (e.g. `lib/core/services/torrent/alert_pump.dart`) that
registers a callback via 1.9.2's existing FFI bindings and republishes it as a
`Stream`, preserving the `TorrentAlertType` enum the app already uses. No native
changes required.

Caveat: 1.9.2 posts no `save_resume_data` alerts (no such export), so any alert
consumer awaiting one must be removed rather than ported — this is the same trap
that previously caused three 5 s pause timeouts and a force-stop.

### 5.3 Signature changes (silent breakage risk — check every call site)

| API | 2.0.0 (vendored) | 1.9.2 |
|---|---|---|
| Pause | `pauseTorrent(id, {bool graceful})` | `pauseTorrent(id)` — **no `graceful`** |
| Bytes done | `TorrentInfo.totalWantedDone` | **`TorrentInfo.totalDone`** |
| Swarm totals | `numComplete`, `numIncomplete` | **absent** — keep the app fields nullable and pass `null` |
| Add magnet | named save path | `addMagnet(magnet, [savePath])` — **positional** |

`totalDone`/`totalWantedDone` is the dangerous one: if any code still reads a
`totalWantedDone` getter you add as an alias, make the alias explicit rather than
letting a rename slip past review.

---

## 6. Tests to delete or rewrite

These assert 2.0.0-only behaviour and **must not** be "made to pass" by
reintroducing 2.0.0 APIs:

- `test/unit/services/engine/ffi_struct_contract_test.dart` — **delete.** Every
  assertion (1880 bytes, `BridgeAbiReport`, swarm-counter offsets) is meaningless
  under 1.9.2. Deleting it is also what lets you drop the `ffi` dev-dependency.
- `test/unit/services/engine/torrent_alert_contract_test.dart` — rewrite against
  the §5.2 pump. Its "Graceful pause completes with stopped-announce event before
  confirmation" case encodes the resume-data handshake that 1.9.2 cannot perform.
- `test/unit/services/engine/torrent_engine_phase2_test.dart` — the
  "Stalled -> recovery transition emits retrying state" case depends on
  `announceNow`; rewrite for a no-op reannounce.

Both of the last two were **already failing at baseline `7c2da25d`** — they are
pre-existing failures, not regressions you introduced. Do not report them as such.

---

## 7. Android native cache — the step most likely to be skipped

1.9.2's `android/build.gradle` downloads `android-native-lib-<abi>.zip` from
`https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v<pubspec.version>`
and **skips the download if a `.so` already exists** at
`prebuilt/android/<abi>/liblibtorrent_flutter.so`.

If any stale hybrid `.so` survives, you will silently keep running the broken
binary and conclude the rollback failed. Purge everything:

```bash
rm -rf packages/libtorrent_flutter          # removes the vendored prebuilt/ tree
flutter clean
rm -rf ~/AppData/Local/Pub/Cache/hosted/pub.dev/libtorrent_flutter-2.0.0
cd android && ./gradlew clean && cd ..
flutter pub get
```

Then confirm from a fresh build log that it **downloads** rather than reuses:

```
libtorrent_flutter: downloading prebuilt arm64-v8a from .../v1.9.2/android-native-lib-arm64-v8a.zip
```

If you instead see `libtorrent_flutter: Using PREBUILT native libraries` with no
download line, a stale `.so` is still in place — stop and purge again.

Useful flags (from the 1.9.2 README): `-PlibtorrentFlutterSkipDownload=true`,
`-PlibtorrentFlutterAbis=arm64-v8a`.

---

## 8. Verification

Static:

```bash
flutter pub get
flutter analyze                     # must be: No issues found!
flutter test test/unit/ test/core/  # only the §6 rewrites may differ from baseline
```

Runtime — emulator is `x86_64`, so verify that ABI is downloaded. Run a real
torrent (the prior session used
`https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso.torrent`) and
confirm **all** of the following, because the earlier fix satisfied some of them
while still being wrong:

1. No `INCOMPATIBLE native bridge` line, and no ABI/`missingSymbols` log at all —
   1.9.2 has no such machinery. Its presence means a stale 2.0.0 package is loaded.
2. `hasMetadata` is true for a `.torrent` source: UI shows `1/1 FILES`, **not**
   `0/1`, and no `haltTorrent … no metadata` line. This is the §2.1 regression
   signature — check it explicitly.
3. **`DOWN` rate is plausible against real device traffic.** The prior build showed
   `220 B/s` and then `341 B/s` while the device was consuming ~1000 kbps. A small
   non-zero rate is *not* success.
4. `SEEDS`/`PEERS` are non-zero once connected. `0` peers alongside real radio
   traffic means peers are connecting and being dropped — the churn signature.
5. Downloaded bytes advance past a few KB and `progress` climbs off `0.0%`.
6. No `lt_get_files: successfully processed N files` flood. The vendored build
   emitted this hundreds of times because `getFilePriorities` fell through to
   `getFiles` uncached on every poll tick, dropping ~100% of frames. If 1.9.2's
   `getFilePriorities` path does the same, cache it.
7. No `[Jank] 100.0% frames dropped` and no `Skipped 300+ frames`.
8. Pause completes without three timeout attempts and without
   `Force-stopping torrent N after 3 failed pause attempts`.

Item 3 is the acceptance criterion the user actually cares about ("the speed was as
before" / "the device consume about 1000kbps data speed not in bytes"). **Do not
report success on items 1–2 alone.**

---

## 9. Abort

```bash
git checkout main && git reset --hard pre-rollback-192
rm -rf packages/libtorrent_flutter && git checkout -- packages/
flutter clean && flutter pub get
```

Then purge the native cache per §7 before rebuilding, or you will run 1.9.2's `.so`
against the restored 2.0.0 bindings — the exact hybrid failure this document is about.

---

## 10. Report honestly

State plainly in your final report:

- Which route was taken, and what work was discarded.
- **Resume data no longer persists** → torrents re-check on next launch. This is a
  real functional regression accepted as the cost of the rollback.
- Which features are now hidden/unsupported (§5.1).
- Which of the §8 runtime checks you actually observed versus assumed. If you could
  not run on device, say so — do not infer runtime behaviour from a clean
  `flutter analyze`.
- Whether item 3 (plausible download rate) genuinely passed. If speeds are still
  wrong after the rollback, the cause is upstream of the ABI and this rollback did
  not address it; say that rather than reframing a partial result as success.
