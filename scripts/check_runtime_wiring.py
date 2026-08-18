#!/usr/bin/env python3
"""Assert that each new feature is actually reachable at runtime.

The recurring failure mode on this branch has not been broken code — the unit
tests catch that — it has been *correct code that nothing calls*. A settings
screen with no entry point, a permission prompt attached to no view (so
`request()` waits forever), a tool-surface policy that is never consulted, a
progress state that is never set. Every one of those compiles, passes its
tests, and does nothing.

Each row below names one feature, the symbol that implements it, and the file
that has to mention that symbol for the feature to be reachable from a running
app. It is a coarse check — a reference is not proof of correct behavior — but
it is exactly strong enough to catch the thing that keeps happening, and it
costs nothing to run.

Usage: python3 scripts/check_runtime_wiring.py
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOS = os.path.join(ROOT, "src/ios")

# (what it gives the user, symbol, file that must reference it)
WIRING = [
    ("Unified settings screen has an entry point",
     "UnifiedAgentSettingsView", "Views/ContentView.swift"),

    ("Windows approval prompt is attached to a presented view "
     "(without this, request() never returns)",
     "remoteActionApprovalPrompt", "Views/ContentView.swift"),

    ("Lazy tool disclosure is applied when building the tool list",
     "ToolSurfacePolicy", "Agent/Chat/AIChatViewModel+ToolDefinitions.swift"),

    ("Disclosure stays sticky across turns, so the local KV cache survives",
     "ToolDisclosureState", "Agent/Chat/AIChatViewModel+ToolDefinitions.swift"),

    ("Memory warnings reach the model runtime",
     "LocalModelLifecycle", "AppDelegate.swift"),

    ("A local model can become the active AgentProvider",
     "LocalAgentProviderFactory", "Agent/Chat/AIChatViewModel+ProviderFactory.swift"),

    ("A Shortcuts callback resumes the run that is waiting for it",
     "ShortcutRunCoordinator", "Shared/DeepLinkRouter.swift"),

    ("Configured remote endpoints reach the agent's capability description",
     "RemoteEndpointStore", "Agent/Unified/AIChatViewModel+UnifiedCapabilities.swift"),

    ("Tool calls are routed to the machine the model named",
     "UnifiedToolRouter", "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"),

    ("Download progress reaches the settings UI",
     "LocalModelStore.shared.setState", "Providers/Local/MLXLocalProvider.swift"),

    ("The workspace root survives a build with no App Group entitlement",
     "AppGroupContainer", "Agent/Chat/AIChatViewModel+RequestBudget.swift"),

    ("The local provider is offered in the provider picker",
     ".local", "Views/Providers/AddProviderView.swift"),

    ("Remote shell output is redacted the same way local output is",
     "EnvVarRedactor.redactIfEnabled(remote.output)",
     "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"),
]


def main() -> int:
    problems = []
    for description, symbol, rel in WIRING:
        path = os.path.join(IOS, rel)
        if not os.path.exists(path):
            problems.append((symbol, f"{rel} does not exist"))
            print(f"  DEAD  {symbol:<44} {description}")
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        # Strip comments so a symbol mentioned only in prose does not count as
        # wiring — that is precisely the illusion this script exists to break.
        code = re.sub(r"//[^\n]*", "", text)
        code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
        if symbol in code:
            print(f"  ok    {symbol:<44} {description}")
        else:
            problems.append((symbol, f"not referenced in code by {rel}"))
            print(f"  DEAD  {symbol:<44} {description}")

    if problems:
        print("\nFAIL — implemented but unreachable:", file=sys.stderr)
        for symbol, why in problems:
            print(f"  {symbol}: {why}", file=sys.stderr)
        return 1

    print(f"\nOK  {len(WIRING)} features reachable from running code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
