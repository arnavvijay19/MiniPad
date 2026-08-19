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

- [ ] **2026-08-19 · First install.** Nothing has ever run on hardware. Follow
      [PRE_MAC_HANDOFF.md §3](PRE_MAC_HANDOFF.md), then §5 in order. The three
      things worth reporting before anything else:
      1. Does it launch, or does it die on the rootfs unpack?
      2. Settings → Agent → Diagnostics — what do the two lines say? Expect
         *inference: available* and *storage: app sandbox*.
      3. Does *Use* on Qwen 3.5 4B put it in the model picker, and can you
         select it for a chat?
      Record it in [DEVICE_LOG.md](DEVICE_LOG.md) either way.

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
