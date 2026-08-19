# Working on MiniPad

A fork of OpenMinis adding on-device MLX inference, a Windows execution target
over MCP, and one agent loop across both machines.

**Two Claude sessions work on this repository, on different machines.** This
file is how each one works out which it is and what it can actually verify.
Read it before doing anything.

---

## Which side am I?

| If | You are | You have | You cannot |
|---|---|---|---|
| Linux, no `xcodebuild` | **cloud** | the code, git, GitHub Actions | build for iOS, touch the iPad |
| Windows | **local** | the iPad over USB, Sideloadly, the signed `.ipa` | build for iOS *at all* — there is no Xcode for Windows |
| macOS with `xcodebuild` | a Mac | everything | — |

The distinction that matters: **only CI can tell you whether Swift compiles.**
Neither side can do it locally today. Do not claim a code change works because
it looks right — push it and read the run.

---

## Lanes

**Cloud session — owns the code.**
Swift, the Xcode project, CI, docs. Push to the feature branch and iterate the
`iOS CI` workflow to green. A red run is the job, not an interruption.

**Local session — owns the device.**
Download the signed `.ipa`, sideload it, run it, capture what happens, re-sign
before the 7-day expiry. Record every result in
[DEVICE_LOG.md](docs/design/unified-agent/DEVICE_LOG.md).

**Either may edit the repo.** Both push to the same branch, so:

* `git pull --rebase` before pushing. Always.
* **Never force-push.** The other session may be mid-work on the same branch.
* If you need to undo something already pushed, `git revert` it.

---

## Handing work over

[HANDOFF.md](docs/design/unified-agent/HANDOFF.md) is the queue. Two sections,
one per direction. Read yours at the start of a session; write to the other's
before you finish.

The two directions do not work the same way.

**Local → cloud is live.** [PR #1](https://github.com/arnavvijay19/MiniPad/pull/1)
exists for exactly this: the cloud session is subscribed to it, so a comment
there wakes it with no human in the loop. Use it for anything needing a code
change. The PR is a draft based on the checkpoint branch and is never merged —
it is a mailbox, not a proposal.

**Cloud → local is not.** Nothing can wake a session on the Windows PC. The
cloud session writes to HANDOFF.md and `Sync-MiniPad.ps1` surfaces it on the
next sync — so write entries that make sense to someone reading them cold, a
week later.

---

## Invariants — do not quietly change these

**The on-device gate is `#if MINIS_LOCAL_INFERENCE`, not `canImport(MLXLLM)`.**
Xcode makes every resolved package product visible to every target, so
`canImport` is true in targets that link no MLX product and cannot load the
`MLXHuggingFace` macro plugin. `scripts/add_mlx_package.py` defines the
condition on exactly the target that links the packages.

**`Minis-PersonalFree.entitlements` stays empty.** Free provisioning issues a
bare App ID; any entitlement naming a registered identifier or an App ID
service makes signing fail outright rather than degrade.
`scripts/audit_entitlements.py` enforces this.

**`AppGroupContainer.root` is how the workspace is reached.** Never
force-unwrap `containerURL(forSecurityApplicationGroupIdentifier:)` — it is
`nil` in every free-signed build, and doing so crashed the app before its first
screen.

**The installable artifact is `MiniPad-PersonalFree-adhoc.ipa`** from the
`ipa-adhoc` artifact of *Ad-hoc sign IPA*. The `-unsigned` one is rejected by
Sideloadly: `CODE_SIGNING_ALLOWED=NO` leaves no `LC_CODE_SIGNATURE` load
command, and zsign-derived re-signers can only overwrite an existing one.

**`Package.resolved` is committed and CI fails if resolving changes it.** A
dependency bump is a decision, not a surprise.

---

## Before you push

```sh
./scripts/linux_test_harness.sh <swift-bin>   # 303 tests, Swift 6 strict
python3 scripts/validate_xcodeproj.py         # real OpenStep parse, not regex
python3 scripts/audit_entitlements.py
python3 scripts/check_runtime_wiring.py       # is the feature reachable at all?
python3 scripts/check_provider_type_exhaustive.py
python3 scripts/add_mlx_package.py --check
```

`check_runtime_wiring.py` exists because the recurring failure here is not
broken code — it is correct code that nothing calls. A settings screen with no
entry point, a permission prompt attached to no view, a model that downloads
and cannot be selected. All three happened.

---

## The documents

| | |
|---|---|
| [PRE_MAC_HANDOFF.md](docs/design/unified-agent/PRE_MAC_HANDOFF.md) | build → sign → install from Windows, and what still needs the iPad |
| [FREE_DEVELOPER_CAPABILITIES.md](docs/design/unified-agent/FREE_DEVELOPER_CAPABILITIES.md) | what a free Apple ID costs you, with the evidence |
| [ARCHITECTURE.md](docs/design/unified-agent/ARCHITECTURE.md) | why the design is what it is |
| [VERIFICATION.md](docs/design/unified-agent/VERIFICATION.md) | what has been checked and how to repeat it |
| [DEVICE_LOG.md](docs/design/unified-agent/DEVICE_LOG.md) | what the iPad actually did |
| [HANDOFF.md](docs/design/unified-agent/HANDOFF.md) | the queue between the two sessions |

---

## Honesty rules for this project

Never say a test ran if it did not. Never invent a benchmark number — no
figure in these documents comes from anywhere but a real run, and the device
numbers are blank because no one has measured them yet. If something is
blocked, say which step and why.
