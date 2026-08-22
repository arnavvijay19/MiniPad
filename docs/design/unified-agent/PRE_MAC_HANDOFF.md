# Getting MiniPad onto an M4 iPad before owning a Mac

> **There is a Mac now.** This document describes the Windows path, which
> still works and is still the fallback. If you are at the MacBook, read
> [MAC_HANDOFF.md](MAC_HANDOFF.md) instead — it is faster in every respect,
> and it covers two signing fixes this path never needed.

The question this file answers: **what still actually requires a personal Mac?**

The short answer is **nothing about building the app**. A GitHub-hosted
macOS runner is a Mac with Xcode on it, and it can do every step from
submodules to a packaged `.ipa`. What a Mac is not needed for, and what people
assume it is needed for, are different things — the only steps that genuinely
need hardware you own are the ones that need *your Apple ID* and *your iPad*,
and both of those work from Windows.

Sections 1–2 are the conclusion and the evidence. Section 3 is what to do.
Sections 4–6 are what is left, honestly separated by what is blocking it.

---

## 1. Conclusion

| Route | Verdict |
|---|---|
| Build for a physical iPad without a Mac | **works** — GitHub Actions, `macos-26` arm64, Xcode 26.6 |
| Package an installable unsigned `.ipa` | **works** — `scripts/make_ipa.sh`, artifact `ipa` |
| Sign it with a free Apple ID from Windows | **works by design; needs your Apple ID to confirm** — Sideloadly |
| Keep it installed past 7 days | **works, two ways** — re-run Sideloadly weekly, or SideStore refreshes on-device |
| Keep every core agent feature | **yes** — see [FREE_DEVELOPER_CAPABILITIES.md](FREE_DEVELOPER_CAPABILITIES.md) |
| Personal Mac required for | **nothing in the build**; see §6 |

The assumption worth discarding: *"a personal Mac with Xcode is required before
this can run on the physical iPad."* It is not. The build needs macOS and
Xcode; it does not need *your* macOS and Xcode. Signing needs your Apple ID,
and Apple's signing service is reachable from Windows — that is exactly what
Sideloadly and AltStore do.

---

## 2. Why this route and not another

Four candidates were evaluated for the last mile (unsigned `.ipa` → running on
the iPad). All four are non-jailbreak, use your own Apple ID against Apple's
own service, and are established rather than exotic.

| | Sideloadly | AltStore + AltServer | SideStore | Paid membership |
|---|---|---|---|---|
| Runs on Windows | yes | yes (needs Apple's Windows iTunes/iCloud for device services) | setup only | n/a |
| Free Apple ID | yes | yes | yes | n/a |
| Refresh without the PC | **no** — reconnect and re-sign weekly | no — AltServer must be running on the PC | **yes** — refreshes on-device after one-time setup | n/a (365-day signature) |
| Can strip app extensions | **yes**, built in | no | no | not needed |
| Setup complexity | lowest — one app, drag the `.ipa` | medium | highest — pairing file + on-device VPN | just money |
| Signature lifetime | 7 days | 7 days | 7 days | 365 days |

**Chosen: Sideloadly first, SideStore if the weekly step becomes annoying.**

Sideloadly wins the first install because it is the shortest path to a running
app and because it can remove app extensions itself — a useful second line of
defence behind the PersonalFree IPA, which removes them at build time. Its real
weakness is that refreshing needs the PC and a cable every seven days.

SideStore is the better *steady state* precisely there: after a one-time setup
it re-signs from the iPad itself, with no computer involved. It costs more to
set up (a pairing file and an on-device VPN shim), which is why it is the
second step rather than the first.

AltStore sits between the two and adds a dependency this setup does not need:
on Windows, AltServer relies on Apple's own iTunes/iCloud device services being
installed, and it must be running on the PC for a refresh. It offers nothing
here that Sideloadly does not.

The $99/year membership remains the only way to get a 365-day signature, App
Groups, iCloud sync and the extensions. Whether that is worth it is a real
question — [FREE_DEVELOPER_CAPABILITIES.md](FREE_DEVELOPER_CAPABILITIES.md) is
the itemised answer — but it is not required to run the agent.

**Sources.** Free-account limits and the Certificates, Identifiers & Profiles
restriction: [Apple, Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).
Runner images and Xcode versions: [actions/runner-images](https://github.com/actions/runner-images).
Sideloadly's free-account behaviour and extension removal: [sideloadly.io](https://sideloadly.io).
SideStore's "you only need a computer once during installation": [SideStore FAQ](https://docs.sidestore.io/docs/faq).

---

## 3. What to do

### 3.1 First install

```powershell
# On the Windows PC. Needs the GitHub CLI signed in (artifacts are not
# downloadable anonymously, even from a public repository).
winget install GitHub.cli ; gh auth login
winget install iOSGods.Sideloadly

.\scripts\windows\Get-MiniPadIPA.ps1
```

The script finds the newest green `iOS CI` run on this branch, downloads the
`ipa` artifact, verifies its SHA-256 against the checksum CI recorded, and
opens Sideloadly with the folder ready. Then, in Sideloadly: drop in
`MiniPad-PersonalFree-unsigned.ipa`, enter your Apple ID, Start. Use an
[app-specific password](https://account.apple.com) if your Apple ID has 2FA.

Finally, on the iPad: **Settings → General → VPN & Device Management → trust
your developer certificate**. Once per certificate, and it cannot be automated
from the PC.

### 3.2 Which of the two IPAs

`MiniPad-PersonalFree-unsigned.ipa` — use this one. It is the app with
`PlugIns/` removed: no share extension, no widget, no File Provider. Each of
those is a separate App ID against your 10-per-7-days limit, each wants an App
Group a free account cannot register, and none of them is part of the agent.

`MiniPad-unsigned.ipa` — the complete build, for a paid membership.

### 3.3 Day 7

The provisioning profile expires and the app stops launching. Either:

* re-run `Get-MiniPadIPA.ps1` and repeat the Sideloadly step, or
* install SideStore once and let the iPad refresh itself.

---

## 4. Already proven, and how

### Proven off-device (Linux CI, every push)

| What | Evidence |
|---|---|
| 303 unit tests, Swift 6 strict concurrency | `scripts/linux_test_harness.sh` |
| Windows MCP client against a real socket, 36 checks, 4 scenarios | `scripts/integration_test_mcp.sh` |
| `project.pbxproj` parses as Xcode reads it | `scripts/validate_xcodeproj.py` |
| All 28 `ProviderType` switches handle `.local` | `scripts/check_provider_type_exhaustive.py` |
| No entitlement in the free-signable config that free provisioning cannot issue | `scripts/audit_entitlements.py` |
| 13 features reachable from running code, not merely implemented | `scripts/check_runtime_wiring.py` |
| All 4 catalog models exist, are public, and are constructible by the linked MLX revision | `scripts/check_local_models.py` |
| The MLX adapter matches the real package API (26 assertions, against the pinned revision) | `scripts/typecheck_mlx_adapter.sh` |

### Proven on GitHub-hosted macOS + Xcode

Runner `macos-26`, arm64, Xcode 26.6 (17F113), iPhoneOS 26.5 SDK, Swift 6.3.3,
3 CPUs / 7 GB / 97 GB free.

| What | Status |
|---|---|
| Submodules (iSH, PRoot, libapps, libarchive) initialise | ✅ |
| Xcode opens the project (`xcodebuild -list`, `plutil -lint`) | ✅ |
| LAME builds for device arm64 | ✅ ~37 s |
| FFmpeg builds — 7 framework bundles, LGPL config | ✅ ~3 min |
| iSH builds (`libish.a`, `libish_emu.a`, `libfakefs.a`, VDSO) | ✅ ~6 s |
| Alpine rootfs prepared (`alpine-rootfs.zip`, 3.98 MB) | ✅ |
| App compiles and links for `generic/platform=iOS`, unsigned | ✅ `** BUILD SUCCEEDED **` |
| MinisTests target compiles | ✅ `** TEST BUILD SUCCEEDED **` |
| Dependency graph matches the committed lockfile | ✅ 35 packages, unchanged |
| `.ipa` produced and validated, both variants | ✅ |

The packaged bundle: `com.openminis.app`, `MinimumOSVersion 17.0`, arm64
(non-fat), 8 embedded frameworks (the seven FFmpeg libraries plus
RealTimeCutVADCXXLibrary), and — in the full variant only —
`AgentWidgetExtension.appex`, `MinisFileProvider.appex`, `MinisShare.appex`.
`make_ipa.sh` refuses a bundle missing the Alpine rootfs or built for the wrong
architecture, and strips any unit-test bundle it finds.

### Not proven, and cannot be from here

Anything that needs the device or your Apple ID. That is §5.

---

## 5. Requires the physical M4 iPad

**Write down what happens in [DEVICE_LOG.md](DEVICE_LOG.md)** — say it in plain
words to whichever session is handy, or run
`scripts\windows\Add-DeviceLogEntry.ps1`. It is the only record of how the app
behaves on hardware, and the only channel between the session holding the iPad
and the session editing the code.

Anything that needs a code change is faster said on
[PR #1](https://github.com/arnavvijay19/MiniPad/pull/1) — the cloud session is
subscribed to it and wakes on a comment. [HANDOFF.md](HANDOFF.md) is the queue
for everything that can wait, and the only route in the other direction.

The full checklist is [VERIFICATION.md §3](VERIFICATION.md#3-requires-a-physical-m4-ipad)
— it is long because it is honest, and it is ordered so an early failure makes
the later items moot. The first-run subset, in order:

1. **App launches**, sandbox initialises, workspace exists.
   *Watch for:* the App Group fallback. The launch log prints
   `[Container] App Group unavailable (not entitled) — using sandbox fallback: …`. That
   line is expected in a PersonalFree build; its absence in one means
   something is wrong.
2. **Local inference.** Download Qwen 3.5 4B (≈3.0 GB) with visible progress;
   load it; stream a plain answer. Record load time, tokens/s and memory —
   no number in this repository is invented, and these are the first real ones.
3. **Local tool use.** *"Create a file called agent-test.txt in my local
   workspace containing 'MiniPad local agent works', read it back, and tell me
   what you read."*
4. **Local terminal.** *"Use the iPad terminal to print the OS information,
   create a temporary file, verify it, and remove it."*
5. **Native action.** *"Create a Reminder called 'MiniPad local agent test'."*
6. **Shortcut.** Register a shortcut ending in *Stop and Output*, then ask the
   agent to run it.
7. **Windows.** First, from a-Shell or Termius on the iPad — same device, same
   Wi-Fi, no app involved:
   `python3 scripts/probe_desktop_commander.py http://<endpoint>/mcp --call-echo`.
   That separates "the endpoint is unreachable from the iPad" from "the app's
   client is wrong", which look identical from inside the app. Then, with the
   endpoint configured in Settings: *"Tell me the Windows hostname and current
   Git branch of the DesktopCommander repository. Do not modify anything."*
8. **Mixed.** *"Create a local iPad file, read it, send its contents to a
   temporary Windows file, verify the Windows copy, then delete the Windows
   temporary file."*
9. **Lifecycle.** Load, unload, background, memory warning, reload.
10. **Performance.** Real measurements, recorded in VERIFICATION.md.

The one measurement that matters most is in VERIFICATION.md §3.2: after a tool
result, the next turn's prompt-token count should be a *fraction* of the
transcript, not all of it. If KV-cache reuse does not hold, the local agent
loop will feel unusable, and `LocalTranscriptDelta` is where to look.

---

## 6. Requires a personal Mac specifically

**Nothing, for building or installing.** Stating that precisely, because
"Xcode" is usually where this conversation stops:

| Often assumed to need your own Mac | Actually |
|---|---|
| Compiling for a physical device | A hosted macOS runner compiles it. Signing is a separate step. |
| Producing an installable `.ipa` | An `.ipa` is a zip with the app under `Payload/`. No signature is needed to build one. |
| Signing with your Apple ID | Apple's signing service is reachable from Windows; that is what Sideloadly does. |
| Provisioning the iPad | Free provisioning registers the device through the same service. |
| Installing | USB from Windows. |

What a Mac would genuinely improve, none of which is a blocker:

* **Interactive debugging.** LLDB attached to the app on the device — reading a
  crash from a log is slower than stepping through it.
* **Instruments.** Memory-graph and Metal profiling for the model runtime. The
  numbers in §5.2 can be recorded without it; understanding *why* they are what
  they are is much easier with it.
* **Iteration speed.** A CI round trip is minutes; a local rebuild is seconds.

---

## 7. Live CI status

The current state of the macOS jobs is whatever the badge and the run history
say — this file does not restate a number that changes every push.

* Runs: <https://github.com/arnavvijay19/MiniPad/actions/workflows/ios-ci.yml>
* Artifacts on a green run: `ipa` (both variants, plus `.sha256`),
  `native-deps`, `xcodebuild-log`, `native-deps-logs`.

To re-run without pushing: *Actions → iOS CI → Run workflow*.
