# Verification and handoff

Everything in this fork that has **not** been run, and exactly how to run it.

The design notes are in [ARCHITECTURE.md](ARCHITECTURE.md). This file is the
checklist.

---

## 1. What has already been verified, and how to reproduce it

### Off-device unit tests — 303 tests, 0 failures

The new code is written to compile against Foundation alone, so it can be
tested without a Mac. The harness compiles the production sources directly,
exactly as the Xcode `MinisTests` target does.

```sh
./scripts/linux_test_harness.sh [/path/to/swift-6.0.3/usr/bin]
```

The script builds a SwiftPM harness from a manifest of the production sources
and the `MinisTests` files that depend only on them, exactly as the Xcode
`MinisTests` target compiles them, and fails if a listed file has gone missing.
CI runs the same script on every push, so the manifest cannot rot.

Note `URLSessionStreamTransport.swift` is deliberately excluded —
`URLSession.AsyncBytes` does not exist in swift-corelibs-foundation.

This runs under Swift 6 strict concurrency, which is **stricter** than the app
target's Swift 5 language mode, so passing here implies these files compile in
the app target.

### Tool-context measurement

```sh
pip install tokenizers
./scripts/measure_tool_context.sh                                  # Qwen 3.5 4B
./scripts/measure_tool_context.sh mlx-community/gemma-4-e2b-it-4bit
```

Re-run this after editing any tool description. A few sentences added to a
description is a few hundred tokens taken out of every request a 4B model ever
makes, and that cost is otherwise invisible.

### MLX adapter, against the real package API

```sh
./scripts/typecheck_mlx_adapter.sh /path/to/swift-6.3+/usr/bin
```

Resolves mlx-swift-lm at the revision `scripts/add_mlx_package.py` pins — read
from that file, so the assertions and the Xcode build can never see different
commits — copies the MLX-free type definitions verbatim, extracts the
`Chat.Message` mapping straight out of MLXLocalProvider so it cannot drift,
typechecks it, then asserts 25 further API facts.

It has found five real defects so far: three in ARCHITECTURE §3, plus the two
this branch fixed — salvage parsing `String(describing:)` of a rejection
rather than the model's own `rawTextPreview`, and the two Hugging Face modules
the `#huggingFaceLoadModelContainer` expansion names but mlx-swift-lm does not
depend on, whose absence failed the first real Xcode build.

Needs **Swift 6.3+**: mlx-swift-lm declares swift-tools 6.2 and mlx-swift
declares 6.3, so nothing older can resolve the package at all.

### Windows backend, end to end over a real socket

```sh
./scripts/integration_test_mcp.sh /path/to/swift/usr/bin
```

Runs the real client, adapter and executor against
`scripts/mock_desktop_commander.py` — a genuine MCP server on localhost — in
four scenarios (36 checks): full surface, compact surface with shell-emulation
fallback, SSE responses, and a session dropped mid-run. Everything runs under a
temp directory that is removed on exit.

The user's real LAN endpoint is not reachable from a container or from CI, so
this is the strongest available substitute. It cannot verify that the remote OS
is Windows — see §3.4 for the checks that still need the real machine.

### ProviderType exhaustiveness

```sh
python3 scripts/check_provider_type_exhaustive.py
```

Adding `ProviderType.local` broke exhaustiveness at 28 sites. On a Mac the
compiler finds them; this finds them without one.

### Free-provisioning capability audit

```sh
python3 scripts/audit_entitlements.py
```

Classifies every entitlement in every target against what Xcode's free
provisioning can issue, and fails if the PersonalFree configuration asks for
something it cannot. See [FREE_DEVELOPER_CAPABILITIES.md](FREE_DEVELOPER_CAPABILITIES.md).

### Runtime reachability

```sh
python3 scripts/check_runtime_wiring.py
```

Thirteen features, each paired with the file that must reference it for the
feature to be reachable from a running app. This is the check for the failure
that keeps recurring on this branch: correct code that nothing calls.

### Local model catalog

```sh
python3 scripts/check_local_models.py
```

Confirms each catalog entry's Hugging Face repository exists and is public,
that its `model_type` appears in the pinned mlx-swift-lm revision's
`ModelTypeRegistry`, that a tokenizer is present, and that the declared
download size matches the repository's real weights. Run 3 of iOS CI:
`qwen3_5` ×3 and `gemma4`, all constructible, sizes within 1.6%.

### Xcode project integrity

```sh
python3 scripts/validate_xcodeproj.py
```

Parses `project.pbxproj` with the real OpenStep plist grammar before checking
anything else, then verifies dangling references, build-phase membership, group
membership, that every Swift reference resolves on disk, and that nothing is
compiled twice.

The grammar step is not ceremony. An earlier regex-based version of this script
called the project healthy while Xcode refused to open it at all — one file
reference contained an unquoted `+`, which is not legal in a bare OpenStep
string, and the project had been unopenable ever since those sources were
added. `scripts/add_sources_to_xcodeproj.py` remains idempotent; re-running it
prints `No changes`.

---

## 2. Requires macOS and Xcode — which CI has

None of this needs a Mac *you own*. `.github/workflows/ios-ci.yml` runs it on a
GitHub-hosted `macos-26` arm64 runner on every push and uploads an installable
unsigned `.ipa`; see [PRE_MAC_HANDOFF.md](PRE_MAC_HANDOFF.md). The commands
below are what CI runs, and what to run locally once a Mac is available.

### Build

```sh
git clone --recurse-submodules <this fork>
cd MiniPad
cp src/ios/Configs/ProviderCustomization.xcconfig.example \
   src/ios/Configs/ProviderCustomization.xcconfig

brew install ninja llvm libarchive pkg-config
pip3 install meson

./deps/build_lame.sh
./deps/build_ffmpeg.sh
./deps/build_ish.sh
./deps/prepare_alpine_rootfs.sh
```

(~30–60 minutes the first time. See `BUILDING.md`.)

```sh
xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis \
           -configuration Debug -destination 'generic/platform=iOS' \
           CODE_SIGNING_ALLOWED=NO build
```

**Simulator builds will not link** — the native deps are built for device
arm64. Use a device destination.

### Run the unit tests in Xcode

CI compiles the test target for a device (`build-for-testing`) but cannot run
it: the native dependencies are built for device arm64, so a simulator build
does not link, and a hosted runner has no device. So the Xcode tests are
compile-verified on every push and **run** only on the iPad. The 303 new tests
run on every push through the Linux harness, which is the same source.


```sh
xcodebuild test -project src/ios/Minis.xcodeproj -scheme Minis \
                -destination 'platform=iOS,name=<your iPad>'
```

Expect the 303 new tests plus the pre-existing suites. If a new suite fails
here but passes on Linux, the cause is almost certainly a type collision
between `TestSupport_AgentTypes.swift` and a production source newly added to
the test target — check the `MinisTests` Sources phase.

### On-device inference is already linked

`mlx-swift-lm` is declared in the Xcode project (products `MLXLLM`,
`MLXLMCommon`, `MLXHuggingFace`, pinned to `d7dc03d8447e`), so an ordinary
build compiles `MLXLocalProvider` and `LocalInferenceAvailability.isCompiledIn`
is `true`. Nothing to add by hand. `python3 scripts/add_mlx_package.py --check`
fails if that ever stops being true.

The package requires iOS 17, which is why the app target's deployment target is
17.0 rather than upstream's 16.0. The extensions are untouched at 16.0.

Recommended for the 9B model: request the
`com.apple.developer.kernel.increased-memory-limit` entitlement. Without it,
`LocalModelMemoryBudget` plans against ~55% of RAM rather than ~72%. Whether a
free Apple ID can sign it is the one open question in
[FREE_DEVELOPER_CAPABILITIES.md](FREE_DEVELOPER_CAPABILITIES.md), which also
describes the ten-minute experiment that settles it.

---

## 3. Requires a physical M4 iPad

Nothing below has been run. Work top to bottom — a failure early makes the
later items meaningless.

### 3.1 Local inference

- [ ] Model list shows all four seed entries with real download sizes.
- [ ] The **On-device** provider appears in the model picker and can be made
      the active provider for a session. `ProviderInstance.hasAnyCredential`
      gates this: it returns true for `.local` precisely because there is no
      credential to have, and the picker and `ModelGroupRouter` both skip an
      instance without one.
- [ ] A deliberately incompatible repo (e.g. a GGUF-only one) is refused
      **before** downloading, with the GGUF explanation.
- [ ] Qwen 3.5 4B downloads, with visible progress, and resumes after the app
      is backgrounded.
- [ ] It loads. Record load time and memory before/after.
- [ ] A plain chat turn streams tokens. Record generation tok/s.
- [ ] Stop mid-generation actually stops within ~1s.
- [ ] Switching models unloads the previous one (memory returns to baseline).
- [ ] A memory warning triggers unload rather than a jetsam kill.

### 3.2 Local tool calling

- [ ] The model emits a `shell_execute` call and it runs in iSH.
- [ ] A multi-step task completes: write a file, run it, read the output.
- [ ] `LocalToolCallSalvage` fires on real malformed output — check the log for
      `repairs` entries and note which rules earn their place.
- [ ] KV-cache reuse works: after a tool result, the next turn's
      `promptTokenCount` should be a fraction of the transcript, not all of it.
      **This is the single most important measurement.** If it doesn't hold,
      the local agent loop will feel unusable and `LocalTranscriptDelta` is
      where to look.

### 3.3 Local-first acceptance

With Wi-Fi cellular data off / cloud providers removed:

- [ ] Reason about a multi-step request.
- [ ] Inspect a local file.
- [ ] Run a script through iSH.
- [ ] Write the result into the workspace.
- [ ] Invoke one native tool (a Reminder is the easiest to verify).

### 3.4 Windows target

Requires the Desktop Commander MCP endpoint reachable on the LAN.

**Do this first, from a-Shell or Termius on the iPad itself:**

```sh
python3 scripts/probe_desktop_commander.py http://<your-endpoint>/mcp --call-echo
```

Same device, same Wi-Fi, no app involved. It speaks the same protocol the app
does and reports the server name, the session id, which of the five core verbs
bind natively and which capabilities will be emulated. If this fails, the
problem is the network or the server, not the app — and the error says which.

Exercised against `scripts/mock_desktop_commander.py` in four configurations:
compact surface, full surface, SSE responses, and a refused connection. Add
`--token <bearer>` if the endpoint wants one.

- [ ] Probe reports the server and its tool surface.
- [ ] Endpoint added in Settings; "Test connection" reports server name and
      version.
- [ ] The capability summary matches the endpoint's real tool set — check
      which verbs bound natively and which are emulated.
- [ ] `shell_execute` with `target: "windows"` runs on the PC and the result
      carries the `[ran on Windows (…)]` prefix.
- [ ] A long-running command streams output rather than arriving all at once.
- [ ] Stop actually terminates the remote process (verify in Task Manager —
      this is the path a fake implementation would silently fail).
- [ ] Restart the endpoint mid-session; the next call re-handshakes
      transparently instead of erroring.
- [ ] `file_read` / `file_write` / `file_edit` with `win:` paths.
- [ ] If the endpoint has no `write_file`, confirm the base64 shell emulation
      round-trips a file containing quotes, backticks, `$`, CRLF and non-ASCII
      **byte for byte**.
- [ ] Cross-machine copy in both directions, with the permission prompt showing
      the `⇢` summary.

### 3.5 Shortcuts

- [ ] Register a shortcut that ends in "Stop and Output".
- [ ] The agent runs it; Shortcuts foregrounds and returns; the result lands in
      the tool result.
- [ ] A shortcut *without* "Stop and Output" produces the explanatory message
      rather than looking like a failure.
- [ ] Cancelling in Shortcuts produces the cancelled outcome, not a hang.
- [ ] Two runs of the same shortcut in one turn don't cross-resolve.
- [ ] Asking "what shortcuts do I have?" gets the registry, plus the honest
      statement that the full list isn't visible.

### 3.6 Coherence — the actual product test

- [ ] One conversation: read an iPad file → run Python locally → inspect the
      Windows repo → patch it → run its tests → write a report back to the
      iPad → create a Reminder. Switching provider mid-conversation must not
      break state.
- [ ] Switch between a local and a remote model mid-conversation; history,
      memory and skills survive.

---

## 4. Benchmarks to record

Fill these in on the device. **Do not estimate them.**

| | Qwen 3.5 4B | Qwen 3.5 9B | Gemma 4 E2B |
|---|---|---|---|
| download size (GB) | 3.06 | 5.98 | 3.58 |
| load time (s) | | | |
| idle memory (MB) | | | |
| loaded memory (MB) | | | |
| peak generation memory (MB) | | | |
| prompt processing (tok/s) | | | |
| generation (tok/s) | | | |
| first-token latency (s) | | | |
| tool-call round trip (s) | | | |
| KV cache after 10 turns (MB) | | | |
| prompt tokens/turn — cache reused | | | |
| prompt tokens/turn — cache rebuilt | | | |
| survives memory pressure | | | |
| survives background/foreground | | | |

Instrumentation points:

- `GenerateCompletionInfo.promptTokensPerSecond` / `.tokensPerSecond` — already
  surfaced as `AgentStreamEvent.usage`.
- `ChatSession.cacheStatus()` — KV topology and progress.
- `os_proc_available_memory()` — headroom before the jetsam limit; more useful
  on iOS than resident size.
- `LocalTranscriptDelta` decisions — log the reason on every turn; a run that
  rebuilds every time is the failure mode to catch.

**Acceptance tasks:** record which model completed each of the four tasks in
[ARCHITECTURE.md §11](ARCHITECTURE.md#11-benchmarks) and in how many turns.
A 4B model failing the mixed task is a useful result, not a bug to hide.

---

## 5. Known unverified code paths

Listed so they get attention first when something misbehaves.

| path | why unverified | risk |
|---|---|---|
| `URLSessionStreamTransport` byte batching | needs Darwin | low — no branching, and the seam is exercised by a scripted transport |
| MLX `ChatSession` history rehydration | needs the device | **medium** — the mapping from `AgentMessage` to `Chat.Message` now type-checks against the pinned package and compiles in Xcode, but has never processed a real transcript |
| `#huggingFaceLoadModelContainer` progress reporting | needs a real download | low — the callback is wired and the state it sets is displayed; the fractions are the package's |
| `MLX.Memory.cacheLimit` value | needs the device | medium — 512MB is a starting point, not a measured one |
| Rejected-tool-call salvage on real 4B output | needs the device | medium — the rules are unit-tested against synthesised malformed output; which of them actually earn their place is a question only a real model answers |
| Shortcuts `x-callback` return path | needs iOS | **medium** — `result` parameter naming is from the documented interface but versions differ; the parser accepts two spellings |
| Desktop Commander binding against the *user's actual* build | needs the endpoint | medium — four tool-set shapes are covered in tests, but not theirs |
| Timeout-unit inference for a bare `timeout` parameter | needs the endpoint | low — defaults to milliseconds, which truncates rather than over-waits |

---

## 6. If something is wrong

- **A model loads but generates gibberish** — almost always a chat-template
  mismatch. Check that `ModelConfiguration` picked up the repo's
  `tokenizer_config.json`, and compare against `mlx_lm.generate` on a Mac with
  the same repo.
- **Every turn rebuilds the KV cache** — log `LocalTranscriptDelta.decide`'s
  reason. `systemPromptChanged` every turn means something non-deterministic is
  in the system prompt (a timestamp, a token count); `historyDiverged` means
  `LocalTranscriptRenderer` is producing unstable text for some message part.
- **Windows calls fail after a few minutes** — the endpoint expired the
  session. The 404 re-handshake should cover it; if not, check that the server
  returns 404 rather than 400 for an unknown session.
- **A tool "runs on the wrong machine"** — `ExecutionTarget.parse` resolves
  unknown values to `.ipad` by design. Check the model actually emitted
  `target`, and that the tool definition declares the enum.
