# Unified iPad + Windows Computer Agent

Design notes for the MiniPad fork of OpenMinis.

**Goal:** one agent, one conversation, one workspace model, one skills/memory
system, one tool framework — with two execution targets: the iPad itself and
the user's Windows PC. Plus in-process local inference, so the whole thing
works with cloud model access switched off.

**Status:** the core is implemented and unit-tested off-device. Nothing here
has run on an iPad. See [Verification status](#verification-status) for the
exact line between "tested" and "reviewed but not run".

---

## 1. What OpenMinis already is

Read the code before designing anything, and the code had a surprise in it.

### The tool surface is already small — deliberately

`AIChatViewModel.makeAgentTools()` returns **eight** tools, and two of those
are conditional:

| tool | always present? |
|---|---|
| `shell_execute` | yes |
| `file_read`, `file_write`, `file_edit` | yes |
| `browser_use` | yes |
| `memory_get`, `memory_write` | only when memory is enabled |
| `read_image` | only for vision-capable models |

Everything else the agent can do — every MCP server, every skill — is reached
**through the shell**, not through a tool schema:

- **MCP**: `MCPStore.systemPromptSnippet()` injects a Top-20 list of server
  *names and notes*, and tells the agent to run `minis-mcp-cli tools <server>`
  and `minis-mcp-cli call <server> <tool>`. The CLI is Python running inside the
  iSH sandbox (`src/ios/default_mount/usr/local/lib/minis-mcp-cli/`). Not one
  MCP tool schema ever enters a prompt.
- **Skills**: `SkillStore.skillPromptFragment()` injects up to 20
  `<available_skills>` entries — name and a 200-character description — and the
  agent reads the `SKILL.md` body with `file_read` when it decides it needs it.

This is already the "dynamic capability discovery, lazy tool loading, compact
schemas, on-demand skill bodies" architecture the brief asks for. The right
move was to extend it, not to build a parallel one.

### The rest of the relevant machinery

- **Provider abstraction** — `AgentProvider` (streaming + tools) and
  `LLMProvider` (simple completion). `AgentProvider` has one requirement:
  `streamAgentMessageClamped(messages:systemPrompt:tools:maxTokens:thinkingLevel:)`
  returning `AsyncThrowingStream<AgentStreamEvent, Error>`. Anything that can
  produce those events is a first-class model.
- **Agent loop** — `AIChatViewModel` + ~19 extensions. Stateless per request:
  the full transcript is rebuilt and sent every turn. Tool dispatch fans out
  concurrently (`+ConcurrentTools`), with JSON repair and preflight validation
  already in place before a tool runs.
- **Execution** — `ISHExecutionCoordinator` is an actor; each `execute()` forks
  a fresh `/bin/sh` with its own pipes and an `fs_context` routing token, so
  commands run concurrently within and across sessions.
- **Filesystem** — `MinisFsRouter` installs a path-translate hook in the iSH
  kernel, mapping `/var/minis/{workspace,attachments,offloads,browser}` to
  per-session host directories. Global paths (`memory`, `skills`, `shared`)
  fall through to a static bind-mount table.
- **Native integrations** — Calendar, Reminders, Contacts, Health, HomeKit,
  clipboard, browser automation, File Provider extension, Share extension, and
  App Intents (`Agent/Intents/`, ten intents plus an `AppShortcutsProvider`).
- **Build** — Swift 6.0 toolchain. **App target builds in Swift 5 language
  mode; MinisTests builds in Swift 6 with strict concurrency.** That asymmetry
  matters and is why `TestSupport_AgentTypes.swift` exists.

### Licensing

GPLv3, because it links iSH (GPLv3) and PRoot (GPLv2). Every dependency added
here is permissively licensed and GPL-compatible:

| addition | license | compatible |
|---|---|---|
| `ml-explore/mlx-swift-lm` (optional) | MIT | yes |
| everything else added | no new dependencies | — |

`THIRD_PARTY_LICENSES.md` needs one row added when the MLX package is actually
enabled. No relicensing, no notices removed.

---

## 2. Gap analysis

| capability | state before | what was needed |
|---|---|---|
| Local inference | none — every provider is a network client | a new `AgentProvider` backed by an in-process runtime |
| Second execution target | none — `shell_execute` is iSH-only | a target parameter, a remote executor, unified process semantics |
| Remote files | none | scheme-qualified paths and explicit cross-machine copy |
| Shortcuts (app → Shortcuts) | none; only Shortcuts → app via App Intents | URL-scheme bridge with result callback |
| Tool-schema budget | unmeasured | measurement, then lazy disclosure |
| KV-cache reuse | irrelevant for remote providers | required on-device, or the agent loop is unusable |

Unchanged by design: memory, skills, MCP, conversation persistence, sync,
compaction, the browser stack, native integrations, and every existing
provider.

---

## 3. Local inference

### Stack

Apple's `ml-explore/mlx-swift-lm` (`MLXLLM` + `MLXLMCommon` + `MLXHuggingFace`).
Verified against the package at commit `d7dc03d` (2026-08-15): it provides `ChatSession` with
KV-cache continuity, native tool-call parsing (`ToolCallProcessor`,
`Generation.toolCall`), quantized KV cache, and a `ModelFactory` that downloads
from Hugging Face. Writing an inference engine instead would be slower, more
fragile, and less correct.

### It is compile-gated, and the gate is now open

Everything MLX-dependent sits inside `#if MINIS_LOCAL_INFERENCE`. The gate
stays because without the package the app must still build and report local
inference as unavailable *with a reason* — MLX raises the deployment floor,
pulls in Metal kernels and a large dependency tree, and only works on Apple
silicon.

The condition used to be `canImport(MLXLLM) && canImport(MLXHuggingFace)`, and
that was wrong in a way only a real Xcode build could show. Xcode makes every
resolved package product visible to every target in the project, so `canImport`
is true inside `MinisTests` — a target that links no MLX product and therefore
cannot load the macro plugin behind `#huggingFaceLoadModelContainer`. The build
failed with *plugin for module 'MLXHuggingFaceMacros' not found*. "Is this
module visible" and "is this target built against it" are different questions,
and only the second is a safe gate. `scripts/add_mlx_package.py` defines
`MINIS_LOCAL_INFERENCE` on exactly the target that links the packages.

The packages are now declared in the project, so an ordinary build compiles the
on-device path. `scripts/add_mlx_package.py` is the single place that wiring
lives, and `--check` fails if any of it goes missing:

| Package | Products | Pin |
|---|---|---|
| `ml-explore/mlx-swift-lm` | `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace` | revision `d7dc03d8447e` |
| `huggingface/swift-transformers` | `Tokenizers` | 1.3.x |
| `huggingface/swift-huggingface` | `HuggingFace` | 0.9.x |

The last two look like dead dependencies — nothing in this repository imports
them except two `import` lines in `MLXLocalProvider.swift`, and no MLX product
requires them. They are there because `#huggingFaceLoadModelContainer` is a
**macro**: its expansion is inserted into the *calling* file and names
`HuggingFace.HubClient` and `Tokenizers.AutoTokenizer`, and mlx-swift-lm
depends on neither. Removing them fails the build with "no such module".

The app target's deployment target is 17.0, up from upstream's 16.0, because
mlx-swift-lm declares `.iOS(.v17)`. The extensions stay at 16.0. Building needs
**Xcode with a Swift 6.3+ toolchain** — mlx-swift-lm declares swift-tools 6.2
and mlx-swift declares 6.3.

#### Five defects this verification caught

`scripts/typecheck_mlx_adapter.sh` typechecks the mapping against the real
upstream types rather than against a reading of them. That found:

1. `[String: Any]` does **not** convert to `ToolSpec` (`[String: any Sendable]`).
   The schema builder now produces Sendable dictionaries directly.
2. `LLMModelFactory.loadContainer(configuration:progressHandler:)` **does not
   exist** — every non-macro entry point requires an explicit `Downloader` and
   `TokenizerLoader`. The load path now uses `#huggingFaceLoadModelContainer`,
   which is also why `MLXHuggingFace` must be linked.
3. `GPU.set(cacheLimit:)` / `GPU.clearCache()` are deprecated, renamed to
   `Memory.cacheLimit` / `Memory.clearCache()`.

4. The rejected-tool-call salvage path was reading `String(describing:)` of the
   rejection — Swift's rendering of a struct — so the JSON repair rules were
   parsing punctuation this code had emitted. `RejectedToolCall.rawTextPreview`
   is the model's own output, and is what salvage reads now. Reading the rest
   of that type also produced two real behaviours: a truncated preview is
   refused outright (bytes are missing from the *middle*, and completing JSON
   across a hole invents arguments rather than recovering them), and
   `rejection.toolName` overrides ours when the two disagree.
5. `Tokenizers` and `HuggingFace` were imported but not linked, because
   mlx-swift-lm does not depend on them. This one was caught by the Xcode build
   rather than the script — see the table above — and the script now asserts it
   so it cannot recur.

All five would have failed a real Xcode build; the first four before it, the
fifth as it. The script also asserts negatively that the wrong APIs stay
unused, and that salvage never parses a description again.

### Model compatibility is checked before download, not after

Three ways an on-device model wastes gigabytes and then fails:

1. MLX has no model class for its `model_type` — new releases appear on Hugging
   Face weeks before MLX supports them.
2. The repo ships GGUF. A GGUF downloaded by another app is **not** reusable;
   MLX reads safetensors in its own quantization layout. They look
   interchangeable in a file browser.
3. It doesn't fit. iOS kills a process well below physical RAM.

`LocalModelCompatibilityChecker` answers all three from the repo's
`config.json` and file listing — a few kilobytes — and the app refuses to load
anything it rejects. The seed catalog is data, and users can add any Hugging
Face repo; the same check runs on both.

### Seed catalog

Repo ids, `model_type`s and sizes verified against the Hugging Face API and
MLXLLM's architecture registry on 2026-08-17:

| model | repo | `model_type` | download | MLX support |
|---|---|---|---|---|
| Qwen 3.5 4B | `mlx-community/Qwen3.5-4B-4bit` | `qwen3_5` | 3.06 GB | registered |
| Qwen 3.5 9B | `mlx-community/Qwen3.5-9B-4bit` | `qwen3_5` | 5.98 GB | registered |
| Gemma 4 E2B | `mlx-community/gemma-4-e2b-it-4bit` | `gemma4` | 3.58 GB | registered |
| Qwen 3.5 2B | `mlx-community/Qwen3.5-2B-4bit` | `qwen3_5` | 1.75 GB | registered |

**These are candidates, not measured results.** The repos exist, the
architectures are in MLXLLM's registry, the sizes are real. Whether a 9B 4-bit
model actually generates at a usable rate within an M4 iPad's per-process
memory limit is a question only the device answers — see
[Benchmarks](#7-benchmarks).

### KV-cache reuse is the load-bearing decision

The Minis agent loop is stateless per request. For a remote provider that is
exactly right — the server does prefix caching and the app gets retries, edits,
compaction and model switching for free.

On-device it is ruinous. An agent turn is *send transcript → tool call →
append result → send transcript again*. Re-processing the whole transcript each
time means prompt processing dominates: a three-tool task on an 8K transcript
re-processes ~24K tokens of prompt to generate a few hundred.

`LocalTranscriptDelta` decides whether the live `ChatSession` can keep its
cache. It reuses **only** when the previous transcript is an exact prefix of
the new one, message for message by content hash, with an unchanged system
prompt and tool set. Everything else rebuilds:

| situation | decision |
|---|---|
| transcript grew by tool result + reply | `appendSuffix` |
| a message was edited | `rebuild(historyDiverged)` |
| compaction ran | `rebuild(transcriptShortened)` |
| system prompt changed | `rebuild(systemPromptChanged)` |
| tool set changed | `rebuild(toolsChanged)` |

The asymmetry is the whole design: a needless rebuild costs seconds; a wrong
reuse makes the model answer a conversation the user no longer has, silently.

### Malformed tool calls

A frontier model malforms a tool call rarely enough that "reject and retry" is
fine. A 4B model does it often enough that rejection dominates the experience —
each one costs a full round trip at ~15 tok/s, and the retry frequently
reproduces the same mistake.

`LocalToolCallSalvage` recovers unterminated `<tool_call>` tags, markdown
fences, `parameters`/`args` aliases, stringified arguments, single-quoted JSON,
Python literals (`True`/`None`), trailing commas, and truncated objects.

Two invariants, both tested: it can never invent a tool name, and it **refuses**
to close a truncation that landed inside a string literal — completing a
half-written `rm -rf /ho` would hand a wrong argument to a tool that then runs
it, which is far worse than losing the turn.

---

## 4. Unified execution

### One optional parameter, not a second tool family

The obvious approach — Windows equivalents of each tool — costs ~1200 tokens of
permanent schema and forces the model to learn two vocabularies for one
concept. Instead, `shell_execute` / `file_read` / `file_write` / `file_edit`
gain one optional `target` parameter.

Measured cost: **176 Qwen tokens** across all four tools.

`ExecutionTarget.parse` is deliberately forgiving — small models emit "local",
"pc", "iSH", "windows (my desktop)" — and **unknown values resolve to `.ipad`**.
An unintended local command is recoverable; an unintended command on the user's
PC may not be. Absent means iPad, so every persisted tool call and every model
that has never heard of a second machine keeps working unchanged.

### Native MCP client, only for this target

Minis already reaches MCP servers through `minis-mcp-cli` in the sandbox, and
that stays exactly as it is — it is the right design for the general case.

It is the wrong design for the Windows target specifically. iSH is an x86
emulator, so every response is parsed by CPython under emulation (~1s of
overhead per call before the PC does any work); a stop tap can't reliably tear
down an in-flight HTTP request inside an emulated process; and a shell-mediated
call can't carry a permission prompt or a health indicator into the UI.

So: `MCPHTTPClient`, implementing Streamable HTTP (revision 2025-06-18) with
session-id continuity, transparent re-handshake on 404 (the PC rebooted),
SSE streaming with correlation-id matching, and a `notifications/cancelled`
sent from a detached task so cancelling actually stops the remote build.

Networking sits behind `HTTPStreamTransport`, which is what makes all of the
above testable against a scripted transport instead of a real PC.

### The endpoint's tools are discovered, never assumed

The endpoint is the user's own Desktop Commander build. Different builds name
things differently (`read_file` vs `read_text_file`, `pid` vs `process_id`,
`timeout_ms` vs `timeout`) and a compact build may omit operations entirely.

`DesktopCommanderAdapter` discovers the tool list once per session and binds it
to seven verbs by exact name, then by unambiguous schema shape. **Ambiguity
loses to "not bound"** — a coin-flip binding runs the wrong operation on the
user's PC. Unbound verbs are either emulated over the shell or reported
unavailable. The endpoint's tool schemas never enter a prompt.

Shell emulation carries every payload as base64. Not paranoia: a build log, a
Python script and a JSON blob each contain characters that break at least one
PowerShell quoting rule, and a file write that mangles a quote is a corruption
bug in the user's own repository. Patching uses `IndexOf`/`Replace` rather than
`-replace`, so a literal `.` or `(` in the search string is never treated as a
regex.

### Same semantics on both sides

`ExecutionRequest` in, `ExecutionResult` out, for either machine: start,
streamed output, interactive stdin, terminal state, cancel. Remote results
carry a one-line provenance prefix (`[ran on Windows (Desktop)]`); local
results don't, so the common case costs nothing and existing behaviour is
unchanged.

Long output is clipped from the **middle**. The two informative parts of a
build log are the invocation at the top and the error at the bottom;
tail-truncation loses the former and head-truncation loses the latter, which is
usually the thing that was asked about.

---

## 5. Unified workspace

### No synthetic mount tree

It is tempting to expose `/workspace/ipad`, `/workspace/windows`,
`/workspace/repos`. On iPadOS that would be a lie. The app cannot mount a
remote share into its sandbox, cannot expose a File Provider directory as a
POSIX path, and cannot give iSH a view of iCloud that behaves like local disk
(files are evicted, downloads are async, security-scoped access is
time-limited). An agent that believes a fake mount is real writes to paths that
silently don't persist — the worst possible failure for a personal agent.

So location is made explicit and real paths stay real:

```
/var/minis/workspace/report.md      iPad Linux sandbox (default — unchanged)
win:C:\Users\me\repo\main.py        the Windows host
win:\\build01\share\out.log         a UNC path on the Windows host
files:/Notes/todo.md                user-authorized iOS Files location
minis://workspace/report.md         the app's existing scheme, untouched
```

A bare path is an iPad path. That single rule is what keeps every existing tool
call and every persisted history entry working.

`UnifiedPath` parsing never throws — a malformed path is still parsed and fails
`validate()` with a specific diagnostic, so the model gets "that Windows path
has no drive letter" rather than a generic error it can't act on. `C:\` is
recognised before scheme splitting, or every Windows path would parse as an
unknown scheme.

`..` is **rejected, not resolved**: this layer can't know whether an
intermediate segment is a symlink, the remote shell resolves it anyway, and
rejecting stops `..` climbing out of a directory a permission was scoped to.

### No implicit sync

`CrossTargetCopy` is one named operation with a stated overwrite policy and a
summary shown in the permission prompt (`⇢` for cross-machine, `→` for local).
There is no background sync, no watched folder, no mirroring. Those move user
data quietly and are impossible to reason about when two machines disagree.

Working Copy is reached through the normal Files/File Provider integration, per
the brief — no proprietary Git storage layer.

---

## 6. Tool and context architecture

### Measured, then optimised

`scripts/measure_tool_context.sh` extracts the app's real tool definitions and
tokenizes them with the real tokenizers of the target models. Run 2026-08-17:

| tool | chars | Qwen 3.5 | Gemma 4 E2B |
|---|---:|---:|---:|
| `browser_use` | 7355 | **1632** | **1720** |
| `shell_execute` | 1316 | 288 | 297 |
| `file_edit` | 1296 | 277 | 298 |
| `file_read` | 1128 | 261 | 274 |
| `memory_write` | 991 | 211 | 221 |
| `file_write` | 970 | 213 | 226 |
| `memory_get` | 977 | 208 | 217 |
| `read_image` | 846 | 190 | 199 |
| **total** | | **3280** | **3452** |

`browser_use` is **half the entire tool surface on its own** — a 2718-character
description and 23 declared parameters. Free on a frontier model with a 200K
window. On a 4B model with 32K it is 5% of the context, in every request, for a
capability most turns never touch — and 23 parameters of schema for a model
that struggles to fill four correctly.

### Lazy disclosure

`ToolSurfacePolicy` gives local models four permanent core tools and discloses
specialists when the conversation indicates one is wanted. Measured effect:

| | Qwen 3.5 | Gemma 4 E2B |
|---|---:|---:|
| full surface | 3280 | 3452 |
| core only | 1039 | 1095 |
| **saved** | **2241 (68%)** | **2357 (68%)** |

Withheld capabilities are named in a **41-token** hint, so the model never
claims it cannot browse the web — a 54x return against the 2241 tokens their
schemas would cost.

Disclosure is **sticky**: adding a tool changes the prompt prefix and
invalidates the local KV cache, so once disclosed a capability stays disclosed.
At most one rebuild per capability, rather than one per turn as triggers
flicker.

Triggers are deliberately broad. A false positive costs one extra schema for
the session; a false negative means the model can't do what was just asked and
has no way to discover that it could. Not symmetric.

**Remote providers are unaffected** — `.full` mode reproduces existing
behaviour exactly.

### Total permanent budget

| component | Qwen 3.5 tokens |
|---|---:|
| core tool schemas | 1039 |
| `target` parameter × 4 | 176 |
| `<execution_targets>` fragment | 147 |
| `<shortcuts>` fragment (2 registered) | 104 |
| withheld-capability hint | 41 |
| **total** | **1507 — 4.6% of a 32K window** |

Skills and MCP metadata are on top of this and are unchanged from upstream
(capped at 20 entries each). Both new capability fragments are **conditional**:
a user with no Windows endpoint and no registered shortcuts pays zero for them.

---

## 7. Native automation

### What iPadOS actually allows

There is **no public API to enumerate a user's shortcuts**. Shortcuts exposes
no list to third-party apps, App Intents describes only our own intents, and
the shortcuts database is outside the sandbox. Any "list my shortcuts" feature
would be invented, and an agent that hallucinates a shortcut name and reports
success is worse than one that admits it can't see the list.

So the agent works from a registry the user fills in, and the prompt fragment
says outright: *"This is the complete list you can see; iOS gives no way to
enumerate the user's other shortcuts."*

Running is supported via `shortcuts://x-callback-url/run-shortcut`, with the
output returned to a `minis://shortcut-callback` URL. Two consequences are
surfaced rather than hidden:

- It **foregrounds the Shortcuts app**. There is no supported background path.
  The prompt tells the model to say so before doing it.
- A shortcut without a "Stop and Output" step returns nothing. That is the
  shortcut's design, and the result text says so instead of looking like a
  failure the model should retry.

Correlation is by generated token, not by name — two concurrent runs of the
same shortcut would otherwise deliver each other's results.

### Third-party app control

Supported: `agent → Shortcut / App Intent / URL scheme → app`. Not attempted,
and not attemptable: system-wide GUI automation, touch injection, private
Accessibility APIs, inspecting third-party UIs, sandbox bypass. An app with no
automation surface is reported as such.

---

## 8. Security

| risk | control |
|---|---|
| Unintended machine | unknown `target` resolves to iPad, never to the PC |
| Plaintext over the internet | `http` refused to any non-private host; RFC1918 / loopback / link-local / CGNAT / `.local` allowed, since that is the real deployment and TLS there means self-signed cert management for no gain |
| Endpoint credentials | URL in UserDefaults (not secret); bearer token in Keychain, never in a file, log or synced record; `$$VAR` placeholders resolved at runtime and **reported when unset** rather than sent literally |
| Hardcoded addresses | none. The LAN endpoint from the brief appears only in test fixtures |
| Command injection via pid | pids are opaque strings from the endpoint and are digit-filtered before interpolation |
| Path traversal | `..` rejected in every scheme |
| Log leakage | `redactedURL` strips query strings, which is where tunnel tokens ride |
| Silent data movement | no implicit sync; cross-machine copy is one explicit operation with a summary |
| Destructive remote actions | routed through the existing `OffloadPermissionManager` pattern (see [Remaining work](#10-remaining-work)) |

**Anthropic account safety:** nothing here touches Claude authentication.
No OAuth internals were read or modified, no browser automation points at
claude.ai, no token extraction, no account rotation. The existing Anthropic
provider is untouched.

**No search features** were added, per the brief.

---

## 9. Verification status

Honest, per component.

### Verified — compiled and unit-tested off-device

Swift 6.0.3 on Linux, **303 tests, 0 failures**, run by
`scripts/linux_test_harness.sh` on every push. Strict concurrency, which is
stricter than the app target's Swift 5 mode, so passing here implies passing
there for these files.

| suite | tests |
|---|---:|
| `UnifiedExecutionTests` — targets, handles, results, `UnifiedPath`, cross-target copy | 37 |
| `MCPWireProtocolTests` — JSON-RPC framing, SSE parser (incl. byte-by-byte UTF-8 split fuzz) | 33 |
| `LocalToolCallSalvageTests` | 29 |
| `ShortcutsBridgeTests` | 22 |
| `MCPHTTPClientTests` — handshake, session id, re-handshake, correlation, pagination, secrets | 21 |
| `UnifiedToolRoutingTests` | 19 |
| `ToolSurfacePolicyTests` | 17 |
| `RemoteEndpointConfigTests` — private-range detection, redaction, secrets | 15 |
| `DesktopCommanderAdapterTests` | 14 |
| `RemoteCommandRiskTests` | 13 |
| `LocalModelCompatibilityTests` | 12 |
| `LocalTranscriptDeltaTests` — session reuse | 12 |
| `WindowsResultParserTests` | 11 |
| `WindowsShellEmulationTests` | 10 |
| `LocalTranscriptRendererTests` | 8 |
| `ShortcutRegistryTests` | 8 |
| `LocalModelCatalogTests` | 7 |
| `LocalToolSchemaBuilderTests` | 5 |
| `OutputClipperTests` | 4 |
| `LocalModelRegistrationTests` | 4 |
| `LocalInferenceAvailabilityTests` | 2 |
| `LocalToolSchemaBuilderTests` | 5 |
| `OutputClipperTests` | 4 |
| `LocalInferenceAvailabilityTests` | 2 |
| `UnifiedToolRoutingTests` | 19 |
| **total** | **286** |

Also verified: the tool-context measurement runs end-to-end from a clean
checkout, and `project.pbxproj` is structurally valid (balanced, no dangling
fileRefs, no duplicate ids, no double-compiled sources).

### Statically reviewed — not compiled

- `URLSessionStreamTransport.swift` — `URLSession.AsyncBytes` does not exist in
  swift-corelibs-foundation, so it cannot compile on Linux. It is ~40 lines of
  plumbing with no branching, which is precisely why the transport seam was
  introduced.
- `MLXLocalProvider`'s gated section — requires the MLX package and Metal. The
  non-gated parts (schema building, transcript rendering, availability) **are**
  compiled and tested.

### Requires a Mac

Full `xcodebuild`, SwiftUI, the app target's Swift 5 build, code signing, and
running `MinisTests` in Xcode.

### Requires a physical M4 iPad

Model download, load, generation, tok/s, memory behaviour, KV-cache reuse in
practice, the Shortcuts round trip, and reaching a real Windows endpoint over
the LAN.

---

## 10. Remaining work

Not "polish" — these are the real gaps between this and a daily driver.

Everything the brief listed as remaining after the first pass is now done:
provider registration, the settings UI, the Shortcuts callback route,
permission prompts, and the memory-pressure ladder. What is genuinely left:

1. **Benchmarks on hardware.** See §11. No number here is invented.
2. **Cross-machine copy as a single tool.** The primitives exist and are tested
   (`CrossTargetCopy`, remote read/write), and the agent can already do it in
   two steps. A dedicated tool would spend permanent context on something the
   model composes correctly today, so it is deliberately deferred until the
   device benchmarks show whether that context is affordable.
3. **`LLMProvider` (non-agent) support for local models.** Title generation and
   other sub-tasks use the simple-completion protocol, which `MLXLocalProvider`
   does not implement; those fall back to their defaults rather than silently
   reaching for a cloud model the user may have disabled on purpose.

---

## 11. Benchmarks

No numbers are invented here. The procedure, for an M4 iPad with the MLX
package enabled:

**Per model** (Qwen 3.5 4B, Qwen 3.5 9B, Gemma 4 E2B):

| measure | how |
|---|---|
| download size | Settings → model row (already displayed from the HF API) |
| load time | `ContinuousClock` around `LocalModelRuntime.load` |
| idle / loaded / peak memory | `os_proc_available_memory()` before load, after load, during generation |
| prompt-processing tok/s | `GenerateCompletionInfo.promptTokensPerSecond` |
| generation tok/s | `GenerateCompletionInfo.tokensPerSecond` |
| KV growth | `ChatSession.cacheStatus()` after each turn |
| cache-reuse win | one agent task twice, with `LocalTranscriptDelta` forced to `.rebuild` and allowed to `appendSuffix`; compare total prompt tokens |
| memory-pressure recovery | run generation while opening a large photo library; confirm unload and reload |
| background/foreground | background mid-generation, return, confirm the session is intact or cleanly rebuilt |

**Acceptance tasks** (the brief's, in order of increasing scope):

1. Local-only: write a Python file in the workspace, run it through iSH, save
   the output, create a Reminder from it — with network access disabled.
2. Mixed: read an iPad document, inspect the Windows repo, patch it, run its
   tests, write the report back to the iPad.
3. Windows dev: diagnose a failing test on the PC, patch, re-run, summarise.
4. Shortcut: run a registered shortcut with input and use its result.

Record which model completed which task, and how many turns it took. A 4B model
failing task 2 is a useful result, not a bug to hide.

---

## 12. Staying close to upstream

Divergence is the long-term cost of a fork, so:

- **Every change to an upstream file is additive.** Four upstream files are
  touched — `AIChatViewModel.swift` (+10), `+ToolDefinitions.swift` (+46),
  `+ConcurrentTools.swift` (+59) and `project.pbxproj` (+94) — with **zero
  deleted or modified lines** between them. Everything else is a new file.
- **No upstream behaviour changed.** `.full` tool mode is the default; remote
  providers, memory, skills, MCP, sync and the browser stack are untouched.
- **MLX is optional**, so upstream can be merged without resolving a dependency
  graph.
- Keep future edits to `AIChatViewModel` extensions additive in the same way —
  a new `case` and a new branch, never a restructuring — so a rebase resolves
  textually rather than by hand.

Recommended: `git remote add upstream https://github.com/OpenMinis/OpenMinis`,
then **rebase** feature work onto upstream tags rather than merging, so this
fork stays a readable patch series rather than a tangle.
