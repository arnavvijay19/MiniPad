# Device log

What actually happened on the iPad.

Nothing else in this repository can know that. CI proves the app builds, the
tests prove the logic holds, and neither has ever run a model on hardware.

It is also the only channel between the session sitting next to the iPad and
the session editing the code. Those two run on different machines and cannot
talk to each other. They can both read this file.

---

## Writing an entry — pick whichever is easiest

**Say it in plain words** to whichever session is handy:

> Add a device log entry: I tapped Use on Qwen 3.5 4B, it downloaded in about
> four minutes, loading took 22 seconds, and the first reply came out around
> 11 tokens a second.

**Or run the helper** on Windows, which asks a few questions and pushes for
you:

```powershell
.\scripts\windows\Add-DeviceLogEntry.ps1            # it worked
.\scripts\windows\Add-DeviceLogEntry.ps1 -Broke     # it didn't
```

**Or edit this file** — copy a template below into *Entries*, fill in what you
know, commit, push.

Leave anything you didn't measure as `?`. A half-filled entry beats none: *"it
crashed and I didn't catch the log"* still tells the next person where to look.

---

## Template — it worked

```
### <date> — <what you tried>

Build:    <ipa sha256, first 8 chars — or the CI run number>
Variant:  PersonalFree adhoc
iPadOS:   <version>

What happened:
  <a sentence or two>

Numbers (? for anything you didn't measure):
  model                  ?
  download time          ?
  load time              ?
  generation tok/s       ?
  prompt tokens turn 1   ?
  prompt tokens turn 2   ?   <- the one that matters, see below

Diagnostics screen:
  On-device inference    available | unavailable: <reason>
  Workspace storage      app sandbox | shared container
```

## Template — it broke

```
### <date> — <what broke>

Build:    <ipa sha256, first 8 chars — or the CI run number>
Variant:  PersonalFree adhoc
iPadOS:   <version>

What I did:
  <the exact steps, or the exact prompt you typed>

What happened instead:
  <what you saw>

Crash log:  attached | none — it hung | none — it just misbehaved
Diagnostics screen:
  On-device inference    available | unavailable: <reason>
  Workspace storage      app sandbox | shared container
```

---

## The one number that matters most

After the agent runs a tool and comes back, **the next turn's prompt-token
count should be a fraction of the whole transcript, not all of it.**

If it is the whole transcript every time, KV-cache reuse is not working, the
local agent loop will feel unusable no matter how fast the model is, and
`LocalTranscriptDelta` is where to look. See VERIFICATION.md §3.2.

Two numbers are enough: prompt tokens on turn 1, prompt tokens on the turn
right after a tool call.

---

## Getting a crash log off the iPad

No cable needed.

1. **Settings → Privacy & Security → Analytics & Improvements → Analytics
   Data**.
2. Scroll to entries starting `Minis-`. They are dated; newest is last in that
   group.
3. Tap it, then the share button — AirDrop, Mail, Files, anything.
4. Paste the first ~40 lines into your entry, or commit the whole `.ips` file
   beside this one.

The header plus `Exception Type` and `Triggered by Thread` is usually enough to
identify it. If the app died on launch, that log is the whole story.

**A hang produces no `.ips`.** Say what was on screen and what you had just
done — for a hang that is more useful than any file.

---

## Which build am I running?

The installable artifact is **`MiniPad-PersonalFree-adhoc.ipa`**, from the
`ipa-adhoc` artifact of the *Ad-hoc sign IPA* workflow — not the `-unsigned`
one, which Sideloadly rejects outright. Its `.sha256` ships beside it; the
first 8 characters are enough to identify a build here.

---

## Entries

_Newest first._

_Nothing recorded yet. The app has never run on hardware._
