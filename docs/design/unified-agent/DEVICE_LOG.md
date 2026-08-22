# Device log

What actually happened on the iPad.

Nothing else in this repository can know that. CI proves the app builds, the
tests prove the logic holds, and neither has ever run a model on hardware.

It is also the permanent record shared by the session sitting next to the iPad
and the session editing the code. They run on different machines; both can read
this file. For anything needing a code change, a comment on
[PR #1](https://github.com/arnavvijay19/MiniPad/pull/1) is faster — it wakes the
cloud session directly — but say it here too, because the PR is a conversation
and this is the record.

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

### 2026-08-19 — first install on hardware

Build:    `2ab2ab0` (Ad-hoc sign IPA run #3)
Variant:  PersonalFree adhoc
iPadOS:   ?

**Recorded by the cloud session from the local session's report on
[PR #1](https://github.com/arnavvijay19/MiniPad/pull/1#issuecomment-5341329482).
Everything below is what the local session observed; the cloud session measured
none of it.**

What happened:
  It launches. No crash, no death unpacking the rootfs — the first thing that
  could have gone wrong didn't. *Use* on Qwen 3.5 4B registers it, it appears
  in the model picker, it is selectable, and it downloaded (3.06 GB) and
  loaded. A plain local response came back.

Numbers (? for anything not measured):
  model                  mlx-community Qwen 3.5 4B (4-bit)
  download size          3.06 GB
  download time          ?
  load time              ?
  generation tok/s       ?
  prompt tokens turn 1   ?
  prompt tokens turn 2   ?

Diagnostics screen:
  On-device inference    available
  Workspace storage      NOT REPORTED

The storage line was not read off the screen, so **the App Group sandbox
fallback remains unverified on hardware.** It is the one thing on this screen
that has crashed the app before, and it is still unconfirmed.

Found on device, both fixed and in the signed build:

* `6fcde30` — no repetition penalty. `GenerateParameters.repetitionPenalty` is
  `Float?` defaulting to nil, meaning *no penalty at all*.
  `streamAgentMessageClamped` set temperature, topP, maxTokens and the KV
  fields but never that one, and Qwen 3.5 4B at temperature 0.3 fell into a
  degenerate loop restating one definition until maxTokens ran out.
* `d412f09` — reasoning rendered as the reply. Local chunks went straight to
  `.textDelta`, so Qwen's `<think>` scratchpad was the answer;
  `LocalProviderRegistration` also hardcoded `supportsReasoning: false`, hiding
  the control that would have turned it off.

**Not yet confirmed on device:** the reasoning path is built and installed but
has not been seen working. Models registered before `d412f09` keep the old
stored capability flag and need Remove + *Use* again.

Also observed: *Use* only registers a model — the weights arrive on **first
send**, and the chat showed "Minis is thinking…" for the whole multi-gigabyte
download with no progress. It reads exactly like a hang and was taken for one.
The progress bar existed only on the settings row. Fixed in the chat indicator
after this report; unverified on device.

Still untested: local file tool, iPad terminal, native Reminder, the Windows
backend end-to-end from the app, and any mixed iPad+Windows workflow.
