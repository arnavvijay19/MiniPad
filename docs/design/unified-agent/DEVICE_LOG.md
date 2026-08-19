# Device log

What actually happened on the iPad. Nothing else in this repository can know
that: CI proves the app builds, the tests prove the logic holds, and neither
has ever run a model on hardware.

This file is also the only channel between the session that edits the code and
the session sitting next to the iPad. They cannot talk to each other. They can
both read this.

---

## How to use it

**Easiest:** tell your local session, in plain words —

> Add a device log entry: I tapped Use on Qwen 3.5 4B, it downloaded in about
> four minutes, loading took 22 seconds, and the first reply streamed at
> roughly 11 tokens a second.

It will fill in the template, commit and push. Then the other session can read
it.

**By hand:** copy a template below into *Entries*, fill in what you know, leave
anything you don't as `?`, commit, push.

A half-filled entry beats no entry. "It crashed and I didn't catch the log" is
still worth writing down — it tells the next person where to look.

---

## Template — it worked

```
### <date> — <what you tried>

Build:      <ipa sha256 first 8 chars, or the CI run number>
Variant:    PersonalFree | full
iPadOS:     <version>

What happened:
  <a sentence or two>

Numbers (leave ? for anything you didn't measure):
  model                 ?
  download time         ?
  load time             ?
  generation tok/s      ?
  memory after load     ?     (Settings → General → iPad Storage, or Xcode later)
  prompt tokens, turn 2 ?     ← see "the one that matters" below

Diagnostics screen said:
  On-device inference   available | unavailable: <reason>
  Workspace storage     app sandbox | shared container
```

## Template — it broke

```
### <date> — <what broke>

Build:      <ipa sha256 first 8 chars, or the CI run number>
Variant:    PersonalFree | full
iPadOS:     <version>

What I did:
  <the exact steps, or the exact prompt you typed>

What happened instead:
  <what you saw>

Crash log attached:  yes | no | app didn't crash, just misbehaved
Diagnostics screen:
  On-device inference   available | unavailable: <reason>
  Workspace storage     app sandbox | shared container
```

---

## The one number that matters most

`VERIFICATION.md` §3.2 explains why: after the agent runs a tool and comes
back, the **next turn's prompt-token count should be a fraction of the whole
transcript, not all of it.** If it is the whole transcript every time, KV-cache
reuse is not working, the local agent loop will feel unusable, and
`LocalTranscriptDelta` is where to look.

Ask the agent for its usage after a tool-using turn, or read it from the usage
display. Two numbers are enough: prompt tokens on turn 1, prompt tokens on
turn 2.

---

## Getting a crash log off the iPad

No cable needed.

1. **Settings → Privacy & Security → Analytics & Improvements → Analytics
   Data**.
2. Scroll to entries beginning `Minis-` — they are dated, newest at the bottom
   of that letter group.
3. Tap it, then the share button, and send it to yourself (AirDrop to the PC,
   Mail, Files — anything).
4. Paste the top ~40 lines into your entry, or commit the whole `.ips` file
   next to this one.

The first four lines and the `Exception Type` / `Triggered by Thread` block are
usually enough to identify it. If the app died on launch, that log is the whole
story.

**For a hang rather than a crash**, there is no `.ips`. Say what the screen was
showing and what you had just done — that is genuinely more useful here.

---

## Entries

_Newest first._

_Nothing recorded yet. The app has never run on hardware._
