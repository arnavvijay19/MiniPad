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

- [x] **2026-08-19 · First install.** Done — it launches, Qwen 3.5 4B
      downloads, loads and answers. Recorded in [DEVICE_LOG.md](DEVICE_LOG.md).
      Two of the three questions answered; the third is reopened below.

- [ ] **2026-08-19 · Read the storage line.** Settings → Agent → Diagnostics
      has two lines and only the inference one was reported. The second should
      say *storage: app sandbox*. This is the App Group fallback — the thing
      that crashed the app before its first screen — and it is the last
      unverified item in the launch path. One glance at the screen closes it.

- [ ] **2026-08-19 · Confirm reasoning actually works.** `d412f09` is installed
      but has never been seen working. A model registered before that commit
      keeps its old stored capability flag, so: **Remove the model, tap Use
      again**, then ask it something that makes it think. Expect the reasoning
      in a collapsible block, and the answer *without* `<think>` in it.

- [ ] **2026-08-19 · Check the new download indicator.** The chat now says
      `Downloading <model> — NN%` instead of "Minis is thinking…". Needs a
      model that isn't downloaded yet, so either add a small one or delete the
      files for an existing one first. A cached model should say `Loading`,
      not `Downloading` — that distinction is the part most likely to be wrong.

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
