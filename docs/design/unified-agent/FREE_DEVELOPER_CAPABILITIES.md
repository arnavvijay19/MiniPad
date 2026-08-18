# What a free Apple ID can and cannot sign

The durable answer to: *what exactly am I losing by not paying Apple $99/year?*

Short version: **nothing the unified agent is for.** Local MLX inference, the
iSH/Alpine terminal, the workspace, Files access, App Intents and Shortcuts,
MCP, skills, memory and the Windows Desktop Commander executor need no
entitlement at all. What a free account cannot sign is the app's *extensions*
and five optional native integrations.

`scripts/audit_entitlements.py` enforces this file. It fails the build if the
PersonalFree configuration ever asks for something free provisioning cannot
issue.

---

## 1. The rule everything follows

Apple's own account documentation is the primary evidence, and it makes the
rule structural rather than a matter of folklore. On
[Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account),
the feature table lists **Certificates, Identifiers & Profiles** as available
to "Apple Developer Program member" and "Apple Developer Enterprise Program
member" — and *not* to someone "Registered for free". The same page states the
free-account limits directly:

> You can register up to 10 App IDs, which expire after 7 days.
> You can register up to 3 devices, which expire after 7 days.
> You can install up to 3 apps per device. Provisioning profiles that enable
> apps to be installed on a device will expire 7 days from issuance.

Two consequences follow, and between them they explain every row in the table
below:

1. **A capability whose entitlement names an identifier you must register**
   — an App Group, an iCloud container — cannot be signed by a free account,
   because registering that identifier happens only in the portal a free
   account cannot reach.

2. **A capability that must be switched on as a service for an App ID**
   — HealthKit, HomeKit, WeatherKit, NFC, Push — cannot be signed either, for
   the same reason. Xcode's free provisioning issues a bare App ID with no
   services enabled.

Anything that is *not* a provisioning-profile entitlement — a framework you
link, an Info.plist declaration, a usage-description prompt — is untouched by
the account tier, because it never reaches a provisioning profile at all. That
is the category almost everything in this app falls into.

---

## 2. The matrix

| Target / feature | Entitlement or capability | Free Personal Team? | Required for the core agent? | Sideload behaviour | Decision |
|---|---|---|---|---|---|
| **Minis (app)** | — | — | — | — | — |
| On-device MLX inference (Qwen, Gemma) | none | ✅ yes | **yes** | unaffected | **keep** |
| iSH / Alpine terminal | none — in-process emulation, no JIT, no entitlement | ✅ yes | **yes** | unaffected | **keep** |
| Local workspace, skills, memory | none once `AppGroupContainer` falls back (§4) | ✅ yes | **yes** | unaffected | **keep** |
| Files access via document picker | none — `UIDocumentPicker` is a plain API | ✅ yes | **yes** | unaffected | **keep** |
| App Intents / App Shortcuts | none — App Intents needs no entitlement; only legacy SiriKit needs `com.apple.developer.siri`, which this project does not request | ✅ yes | **yes** | unaffected | **keep** |
| MCP servers, skills, memory | none — plain HTTP and files | ✅ yes | **yes** | unaffected | **keep** |
| Windows Desktop Commander executor | none — plain HTTP to a LAN address | ✅ yes | **yes** | unaffected | **keep** |
| Share data with extensions | `com.apple.security.application-groups` | ❌ no — needs a registered App Group | no | container is `nil`; fallback used | **drop in PersonalFree** |
| iCloud sync between devices | `com.apple.developer.icloud-container-identifiers`, `…ubiquity-container-identifiers` | ❌ no — needs a registered container | no | sync disabled | **drop in PersonalFree** |
| CloudKit | `com.apple.developer.icloud-services` | ❌ no — App ID service | no | disabled | **drop in PersonalFree** |
| Health offload tool | `com.apple.developer.healthkit`, `…healthkit.access` | ❌ no — App ID service | no | tool unavailable | **drop in PersonalFree** |
| Home offload tool | `com.apple.developer.homekit` | ❌ no — App ID service | no | tool unavailable | **drop in PersonalFree** |
| Weather offload tool | `com.apple.developer.weatherkit` | ❌ no — App ID service | no | tool unavailable | **drop in PersonalFree** |
| NFC tag reading | `com.apple.developer.nfc.readersession.formats` | ❌ no — App ID service | no | unused in code anyway | **drop in PersonalFree** |
| **MinisShare** (share extension) | `com.apple.security.application-groups` | ❌ no | no | separate App ID; cannot share data | **strip from the IPA** |
| **MinisFileProvider** | `com.apple.security.application-groups` | ❌ no | no — the document picker covers file access | separate App ID; cannot share data | **strip from the IPA** |
| **AgentWidgetExtension** | `com.apple.security.application-groups` | ❌ no | no | separate App ID; cannot share data | **strip from the IPA** |

Legend: "required for the core agent" means one of the eleven capabilities the
project brief names as non-negotiable.

### The one genuine unknown

| Feature | Entitlement | Status |
|---|---|---|
| Larger memory ceiling for a 4B–9B model | `com.apple.developer.kernel.increased-memory-limit` | **needs an experiment on the device** |

This entitlement is not a registered identifier and not an App ID service, so
the rule above does not settle it, and the project does not currently request
it in any configuration. It matters because a 4-bit 4B model plus its KV cache
is a large fraction of an app's memory budget, and iOS jetsams rather than
asks.

The code already handles both answers without being told which is true:
`LocalModelStore` reads the *embedded* entitlements at runtime
(`LocalModelStore.swift`, `hasIncreasedMemoryLimit`) and `LocalModelCatalog`
sizes the model budget from what it finds — 55% of physical memory without the
entitlement. So the honest position is: ship without it, and if a model is
killed on load, run the experiment.

**The experiment**, ten minutes on the device: add the key to
`Minis-PersonalFree.entitlements`, re-sign, and install.
* If Sideloadly/AltStore signs and the app installs — it is available, keep it.
* If signing fails with "provisioning profile doesn't include the
  `com.apple.developer.kernel.increased-memory-limit` entitlement" — it is not,
  revert. `scripts/audit_entitlements.py` will need the key moved to the
  supported side of `CLASSIFICATION` in the first case.

---

## 3. What the free-account limits mean in practice

| Limit | Number | What it costs here |
|---|---|---|
| App IDs per 7 days | 10 | The full build needs **4** (app + 3 extensions); PersonalFree needs **1**. Re-signing an existing bundle id does not consume another. |
| Devices | 3 | One iPad. Not binding. |
| Apps installed per device | 3 | MiniPad is one of them. Not binding unless you sideload two other apps. |
| Provisioning profile lifetime | **7 days** | The app stops launching after a week unless it is re-signed. This is the real ongoing cost, and it is what makes the choice of installer matter (see PRE_MAC_HANDOFF §3). |

---

## 4. What the code had to change

One thing genuinely blocked a free-provisioned build, and it was not an
entitlement — it was a force-unwrap.

`AIChatViewModel.minisAppGroupRoot` — the root of the shared workspace, skills
and memory — was:

```swift
FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
)!.appendingPathComponent("MinisFileProvider", isDirectory: true)
```

Without the entitlement that call returns `nil`, so the app did not degrade —
it crashed on launch, before the first screen, and the crash log pointed at a
directory path rather than at a missing capability.

`Shared/AppGroupContainer.swift` resolves the container once, falling back to
`Library/Application Support/AppGroupFallback` inside the app's own sandbox,
and every path derived from it is unchanged. Extensions deliberately do **not**
use the fallback: an extension falling back would land in *its own* sandbox and
silently diverge from the app, which is worse than doing nothing. They keep
using the shared container directly, and PersonalFree ships no extensions.

---

## 5. Rebuilding this table

```sh
python3 scripts/audit_entitlements.py             # check, and print the classification
python3 scripts/audit_entitlements.py --markdown  # emit the raw table
```

The script fails when an entitlements file grows a key it does not know, so a
new capability cannot be added without a decision being recorded here.
