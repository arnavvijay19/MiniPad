# Handoff

The queue between the two sessions. One section per direction.

They run on different machines. Read your section at the start of a session;
write to the other one before you finish.

Going **local → cloud** you have a faster route: comment on
[PR #1](https://github.com/arnavvijay19/MiniPad/pull/1). The cloud session is
subscribed to it and wakes on the comment. Use this for anything that needs a
code change; use the queue below for anything that can wait.

Going **cloud → local** there is no such route — nothing can wake the Windows
session. This file is the whole channel, surfaced by `Sync-MiniPad.ps1`, so
write entries that make sense to someone reading them cold.

**Format:** newest at the top of each section. `- [ ]` open, `- [x]` done. Sign
it with the date so a stale item is obvious.

---

## For the local session — things to try on the iPad

*Written by the cloud session. Anything here needs the device.*

- [x] **2026-08-19 · First install.** Done. Launches, Qwen 3.5 4B downloads,
      loads and answers. In [DEVICE_LOG.md](DEVICE_LOG.md).

- [x] **2026-08-19 · Confirm reasoning works.** Done - the `<think>` routing
      from `d412f09` is confirmed on device.

- [ ] **2026-08-19 · Read the storage line.** Still open, and still the last
      unverified item in the launch path. Settings -> Agent -> Diagnostics,
      *second* line. Expect *storage: app sandbox*. This is the App Group
      fallback, which crashed the app before its first screen once. One glance.

- [ ] **2026-08-20 · Install `01b6803` and drive Windows from the app.** The
      gateway proofs so far were made against `:8770` directly, so nothing
      unified-Windows has been exercised *through MiniPad*. That is the whole
      point of the feature. `windows_control` end-to-end is the one that
      matters; a screenshot round-tripping into the chat proves the image path
      survives the app's own serialization.

- [ ] **2026-08-20 · Re-sync before installing.** `Sync-MiniPad.ps1` now names
      the folder after the commit the build was made *from*, read from
      `BUILD-INFO.txt` inside the artifact. The build you have in
      `builds\944fe6f6\` is really `01b6803`; after a re-sync it will land in
      `builds\01b6803\`. Old folders have no BUILD-INFO.txt and will re-download
      once - that is expected, not a loop.

- [ ] **2026-08-20 · Fix the stale iPad address.** `192.168.1.58` is still in
      both the firewall rule and `config.toml`; the iPad is `.60`. A DHCP
      reservation stops this recurring - the failure mode is a timeout, not a
      401, so it costs real debugging time every time it drifts.

- [ ] **2026-08-19 · Check the download indicator.** Needs a model that is not
      cached - delete the files for one first. A cached model should say
      `Loading`, not `Downloading`; that distinction is the part most likely to
      be wrong.

---

## For the Mac session — the machine that can actually build

*New. Start at [MAC_HANDOFF.md](MAC_HANDOFF.md), not here.*

- [ ] **2026-08-22 · Two signing fixes before the first build.** The app target
      signs with `Minis.entitlements` (HealthKit, HomeKit, WeatherKit, NFC,
      iCloud) and `Minis-PersonalFree.entitlements` is wired to nothing —
      `grep -c Minis-PersonalFree src/ios/Minis.xcodeproj/project.pbxproj` is 0.
      Also the three extensions need App Groups and cannot be signed free.
      MAC_HANDOFF.md §"before you press Run" has both fixes.

- [ ] **2026-08-22 · Settle the memory entitlement.** Two minutes here, versus
      a 150-minute round trip from Windows, and it is the most likely cause of
      the intermittent load crash. Result goes in DEVICE_LOG.md *and*
      FREE_DEVELOPER_CAPABILITIES.md either way.

---

## For the cloud session — things to fix or build

*Written by the local session. Anything here needs a code change and a CI run.*

- [ ] _(nothing yet)_

---

## How to write a good item

For a bug, the cloud session cannot see your screen. It needs:

* what you did — the exact steps, or the exact prompt you typed
* what happened instead
* the crash log if there is one ([DEVICE_LOG.md](DEVICE_LOG.md) explains how to
  get one without a cable)
* the build id — first 8 characters of the `.ipa` sha256

For a request, say what you want to be able to do, not how you think it should
be built. The cloud session has the design context and will usually see a
cheaper way.

---

## What each side can actually do

|  | cloud | local |
|---|---|---|
| edit Swift, push, iterate CI | ✅ | ✅ but cannot verify — Windows has no Xcode |
| know whether it compiles | ✅ via CI | ✅ via CI |
| install and run on the iPad | ❌ | ✅ |
| capture a crash log | ❌ | ✅ |
| re-sign before day 7 | ❌ | ✅ |

The asymmetry is the point: **the cloud session can change anything and verify
nothing on hardware; the local session can observe everything and verify no
code.** Neither is useful alone.
