# Verification and handoff

Everything in this fork that has **not** been run, and exactly how to run it.

The design notes are in [ARCHITECTURE.md](ARCHITECTURE.md). This file is the
checklist.

---

## 1. What has already been verified, and how to reproduce it

### Off-device unit tests — 267 tests, 0 failures

The new code is written to compile against Foundation alone, so it can be
tested without a Mac. The harness compiles the production sources directly,
exactly as the Xcode `MinisTests` target does.

```sh
# Swift 6.0.3 toolchain (matches the project's SWIFT_VERSION)
curl -LO https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04.tar.gz
tar xzf swift-6.0.3-RELEASE-ubuntu24.04.tar.gz
export PATH=$PWD/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH

# Build a harness that compiles the sources + the MinisTests test files
mkdir -p harness/Tests/UnifiedCoreTests && cd harness
cat > Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "UnifiedCoreHarness",
    targets: [.testTarget(name: "UnifiedCoreTests", path: "Tests/UnifiedCoreTests")]
)
EOF
IOS=../src/ios
cd Tests/UnifiedCoreTests
for f in \
  Agent/Unified/ExecutionTarget.swift \
  Agent/Unified/UnifiedPath.swift \
  Agent/Unified/RemoteEndpointConfig.swift \
  Agent/Unified/ToolSurfacePolicy.swift \
  Agent/Unified/MCP/MCPWireProtocol.swift \
  Agent/Unified/MCP/HTTPStreamTransport.swift \
  Agent/Unified/MCP/MCPHTTPClient.swift \
  Agent/Unified/Windows/DesktopCommanderAdapter.swift \
  Agent/Unified/Windows/WindowsResultParser.swift \
  Agent/Unified/Windows/WindowsExecutor.swift \
  Agent/Unified/Shortcuts/ShortcutsBridge.swift \
  Providers/AgentProvider.swift \
  Providers/Local/LocalModelCatalog.swift \
  Providers/Local/LocalToolCallSalvage.swift \
  Providers/Local/LocalTranscriptDelta.swift \
  Providers/Local/MLXLocalProvider.swift ; do ln -sf "$(cd ../../..; pwd)/src/ios/$f" . ; done
for f in ../../../src/ios/MinisTests/*.swift; do ln -sf "$(cd ../../..; pwd)/src/ios/MinisTests/$(basename $f)" . ; done
cd ../.. && swift test
```

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

### Xcode project integrity

`scripts/add_sources_to_xcodeproj.py` is idempotent; re-running it should print
`No changes`. The result was checked for brace/paren balance, dangling
`fileRef`s, duplicate object ids and double-compiled sources.

---

## 2. Requires a Mac

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

```sh
xcodebuild test -project src/ios/Minis.xcodeproj -scheme Minis \
                -destination 'platform=iOS,name=<your iPad>'
```

Expect the 267 new tests plus the pre-existing suites. If a new suite fails
here but passes on Linux, the cause is almost certainly a type collision
between `TestSupport_AgentTypes.swift` and a production source newly added to
the test target — check the `MinisTests` Sources phase.

### Enable on-device inference

Optional; the app builds and runs without it.

1. *File → Add Package Dependencies…* →
   `https://github.com/ml-explore/mlx-swift-lm`
2. Add products **MLXLLM** and **MLXLMCommon** to the **Minis** target.
3. Ensure the iOS deployment target is **17.0 or later** (the package requires
   it).
4. Add a row to `THIRD_PARTY_LICENSES.md`: *mlx-swift-lm — MIT — Apple*.
5. Rebuild. `LocalInferenceAvailability.isCompiledIn` flips to `true` and
   `MLXLocalProvider` compiles in.

Recommended for the 9B model: request the
`com.apple.developer.kernel.increased-memory-limit` entitlement. Without it,
`LocalModelMemoryBudget` plans against ~55% of RAM rather than ~72%.

---

## 3. Requires a physical M4 iPad

Nothing below has been run. Work top to bottom — a failure early makes the
later items meaningless.

### 3.1 Local inference

- [ ] Model list shows all four seed entries with real download sizes.
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
| MLX `ChatSession` history rehydration | needs the package | **medium** — the mapping from `AgentMessage` to `Chat.Message` is written against the package source, not run against it |
| `LLMModelFactory.loadContainer` progress reporting | needs the package | low |
| `MLX.GPU.set(cacheLimit:)` value | needs the device | medium — 512MB is a starting point, not a measured one |
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
