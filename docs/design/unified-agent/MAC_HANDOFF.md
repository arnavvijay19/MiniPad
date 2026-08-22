# Building MiniPad on the Mac

For a Claude session, or a person, sitting at the MacBook with the iPad on the
desk. Assumes nothing about what came before.

Read [CLAUDE.md](../../../CLAUDE.md) first if you have not — it says which side
of this project you are and which invariants not to break. This file replaces
[PRE_MAC_HANDOFF.md](PRE_MAC_HANDOFF.md), which existed only because nobody had
a Mac. Keep that one for now; it documents the Windows path, which still works
and is still the fallback when the Mac is not to hand.

---

## What just changed, and what did not

**Changed:** the project's oldest constraint is gone. Until today the honest
statement was *only CI can tell you whether Swift compiles* — 150 minutes to
find out that a line was wrong. `xcodebuild` on this machine answers in
minutes, and Xcode's editor answers before you build at all.

**Did not change: the 7-day expiry.** This is the one that gets assumed away.
A free Apple ID issues provisioning profiles that expire **7 days from
issuance** — that is a property of the *account*, not of the toolchain. With a
Mac and a free Apple ID you still re-sign every week; you do it in Xcode
instead of Sideloadly. Only the $99/year membership buys a 365-day signature.
See [FREE_DEVELOPER_CAPABILITIES.md §3](FREE_DEVELOPER_CAPABILITIES.md).

---

## Read this before you press ⌘R, or you will lose an hour

Opening the project and hitting Run **will fail** on a free Personal Team, for
two reasons that have nothing to do with your code. Both are one-time fixes.

### 1. The app target is signed with the wrong entitlements file

There are two entitlements files. `Minis-PersonalFree.entitlements` is empty on
purpose — an empty file is exactly what a free Apple ID can sign.

**It is wired to nothing.** `CODE_SIGN_ENTITLEMENTS` on the app target points at
`Minis.entitlements` in both Debug and Release, and that file asks for HealthKit,
HomeKit, WeatherKit, NFC and iCloud containers — every one of which free
provisioning refuses outright.

```sh
grep -c "Minis-PersonalFree" src/ios/Minis.xcodeproj/project.pbxproj   # 0
```

Nothing caught this because nothing could. CI builds with
`CODE_SIGNING_ALLOWED=NO`, so entitlements are never applied; Sideloadly
rewrites them when it re-signs. **The Mac is the first thing in this project's
history that actually applies them**, which is why this surfaces now.

*Quick fix, for getting a build today:* select the **Minis** target →
Build Settings → search `Code Signing Entitlements` → set it to
`Minis-PersonalFree.entitlements`.

*Proper fix, once it runs:* add a real `PersonalFree` build configuration that
sets it, so Release keeps the full entitlements for a future paid build. Do
this in Xcode rather than by hand — this repo has already lost a day to a
malformed `project.pbxproj`, and `python3 scripts/validate_xcodeproj.py` is the
check to run afterwards either way.

### 2. Three extensions cannot be signed at all

`ShareExtension`, `FileProvider` and `AgentWidget` each require
`com.apple.security.application-groups`, and an App Group must be registered in
a portal free accounts cannot reach. They are also three more App IDs against a
budget of ten per seven days.

This is why the installable artifact has always been the `--strip-extensions`
one. **"PersonalFree" is not a build configuration** — it is the same Release
build packaged twice, and the difference is only which pieces get included.

In Xcode: **Minis** target → General → *Frameworks, Libraries, and Embedded
Content* — remove the three extensions, or set each extension target's
*Skip Install*. You lose the Share sheet, Files provider and widget. Nothing
the agent is for depends on them.

### 3. Possible, not yet confirmed: the bundle id

`com.openminis.app` belongs to upstream. App IDs are globally unique, so if
that identifier is registered to another team, Xcode will say *"the app
identifier cannot be registered to your development team."*

If that happens, change **PRODUCT_BUNDLE_IDENTIFIER** to something of your own —
`com.<yourname>.minipad`. Nothing in the code reads the bundle id.

Flagged as *possible* because it has not been hit yet: Sideloadly rewrites the
identifier when it re-signs, so the Windows path never had to answer this.

---

## Day 1 — get one build onto the iPad

```sh
xcode-select --install                       # if you have not already
git clone https://github.com/arnavvijay19/MiniPad.git
cd MiniPad
git checkout claude/pre-mac-ipad-ready
open src/ios/Minis.xcodeproj
```

Swift Package Manager will resolve MLX and friends on first open. It is a large
graph and takes a few minutes. `Package.resolved` is committed, so it should
resolve to exactly the pinned versions — **if Xcode changes that file, that is a
finding, not a nuisance.** Do not commit the change without deciding it.

Then, in order:

1. Xcode → Settings → Accounts → add your Apple ID. It becomes a *Personal Team*.
2. **Minis** target → Signing & Capabilities → Team = your Personal Team,
   *Automatically manage signing* on.
3. Apply the two fixes above.
4. Plug in the iPad, trust the Mac, select it as the run destination.
5. ⌘R.
6. On the iPad, first launch only: Settings → General → VPN & Device Management
   → trust your developer certificate.

**When it fails, read the actual error before changing anything.** Xcode
signing errors name the exact entitlement or identifier that was refused, and
that string is the answer. Paste it at an agent rather than describing it.

---

## Day 2 — the experiment your own docs have been waiting on

`com.apple.developer.kernel.increased-memory-limit` is the one open question in
[FREE_DEVELOPER_CAPABILITIES.md](FREE_DEVELOPER_CAPABILITIES.md#the-one-genuine-unknown).
It is neither a registered identifier nor an App ID service, so the structural
rule that settles everything else does not settle it. Nobody has tested it.

It matters: without it the app budgets **55%** of physical memory for a model;
with it, more. A 4-bit 4B model plus its KV cache is a large fraction of that,
and iOS jetsams rather than asking. This is the most likely explanation for a
model that loads twice and dies the third time.

From Windows this was a 150-minute round trip, which is why it never happened.
Here it is about two minutes:

1. Add the key to `Minis-PersonalFree.entitlements`.
2. Build to the device.

* **It installs** — free provisioning grants it. Keep it, and move the key to
  the supported side of `CLASSIFICATION` in `scripts/audit_entitlements.py`.
* **Signing fails** naming that entitlement — it does not. Revert.

Either result closes the question permanently. Record it in
[DEVICE_LOG.md](DEVICE_LOG.md) and in the capabilities doc.

---

## Crash logs, which are now one click

Xcode → Window → Devices and Simulators → select the iPad → **View Device Logs**.
No cable-free Analytics-Data spelunking any more.

Two lines tell you which kind of problem you have:

```
Exception Type:       ...
Termination Reason:   ...
```

`per-process-limit` means iOS killed it for memory — that is the entitlement
experiment above, or a smaller model. `EXC_BAD_ACCESS` means a real code bug.
Different fixes, and guessing between them wastes the most time.

---

## What to keep, what to retire

| | |
|---|---|
| **Keep — iOS CI** | Still the regression gate. It compiles the *full* build including the extensions the Mac cannot sign, so it catches breakage the Mac path silently skips. It is also what you have when the Mac is in a bag. |
| **Keep — the Windows gateway** | Only if you want the agent to reach a computer that is always on. A MacBook sleeps and travels; a desktop does not. If that is not the use case, retarget MCP at the Mac — Desktop Commander runs natively — and delete a lot of apparatus. |
| **Retire — `adhoc-sign-ipa.yml`** | It exists solely because `CODE_SIGNING_ALLOWED=NO` leaves no `LC_CODE_SIGNATURE` for Sideloadly to overwrite. Xcode signs properly. Leave the workflow in place until the Mac path is proven, then delete it. |
| **Retire — `Get-MiniPadIPA.ps1`, `Sync-MiniPad.ps1`** | Same: keep as the fallback until the Mac path has installed a build, then they are dead weight. |

Do not delete anything until the Mac has put a working build on the iPad. The
Windows path works today; the Mac path is unproven until it is not.

---

## The ceiling — worth knowing before aiming at it

The Mac removes every *build and signing* obstacle. It does not move what iOS
permits, and no amount of work will:

* **An app cannot drive other apps.** No third-party Accessibility automation.
  There is no iOS equivalent of the click/type tools the Windows backend gives
  you, and there will not be one.
* **No arbitrary code execution.** iSH is a userspace x86 emulator with no JIT,
  because JIT is not permitted. It is genuinely slow, by rule rather than by bug.
* **No long-running background processes.**
* The sanctioned cross-app surface is **App Intents / Shortcuts**, and that is it.

So the honest maximum on the device is: an in-app agent with a local model,
real access to your own data through entitled frameworks, a real shell, App
Intents for cross-app actions, and **remote control of a real computer over
MCP**. That last one is where actual computer use lives, and it is already
built.

The useful reframe: the iPad is the interface; the computer being used is
somewhere else. A 24GB Mac is a considerably better *somewhere else* than the
iPad was ever going to be — it runs models the iPad structurally cannot.

---

## Is the $99 membership worth it now?

Not required. The whole point of
[FREE_DEVELOPER_CAPABILITIES.md](FREE_DEVELOPER_CAPABILITIES.md) is that nothing
the unified agent is *for* needs an entitlement.

What it buys, now that a Mac makes everything else cheap:

* **365-day signatures** instead of re-signing weekly — the only thing that fixes it.
* **App Groups**, which brings back the three extensions and the shared
  container, so `AppGroupContainer` stops falling back to the sandbox.
* It settles the memory-limit question rather than leaving it to an experiment.

Given how much of this project's effort went into working around free
provisioning, it is cheap. It is still a choice, not a requirement.
