#!/usr/bin/env python3
"""Audit every iOS entitlement against what free Apple ID provisioning can sign.

Why this exists
---------------
The question "what exactly do I lose by not paying Apple $99/year?" has a
structural answer, not a folklore one. Apple's own account documentation says
that **Certificates, Identifiers & Profiles is a paid-membership feature**;
someone "Registered for free" does not have it
(https://developer.apple.com/help/account/basics/about-your-developer-account).

Two consequences follow, and they are the whole classification below:

  * A capability whose entitlement names an identifier you must *register*
    (an App Group, an iCloud container, a merchant id) cannot be signed by a
    free account, because registering that identifier happens only in the
    portal a free account cannot reach.

  * A capability that must be *switched on for an App ID* as a service
    (HealthKit, HomeKit, WeatherKit, NFC, Push) cannot be signed either, for
    the same reason: Xcode's free provisioning issues a bare App ID with no
    services enabled.

Everything else — anything that is a plain Info.plist declaration, a framework
you just link, or a usage-description prompt — is unaffected by the account
tier, because it never touches a provisioning profile at all.

This script encodes that rule, applies it to the repository's real entitlement
files, and fails when a build configuration intended for free provisioning asks
for something free provisioning cannot issue. It is the durable form of
docs/design/unified-agent/FREE_DEVELOPER_CAPABILITIES.md.

Usage:
    python3 scripts/audit_entitlements.py            # report + check
    python3 scripts/audit_entitlements.py --markdown # emit the doc table
"""
from __future__ import annotations

import os
import plistlib
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOS = os.path.join(ROOT, "src/ios")

# Reason codes -------------------------------------------------------------
REGISTERED_ID = (
    "names an identifier that must be registered in Certificates, "
    "Identifiers & Profiles"
)
APPID_SERVICE = (
    "must be enabled as a service on the App ID in Certificates, "
    "Identifiers & Profiles"
)
FREE_OK = "issued by Xcode free provisioning as part of the base profile"

# key -> (available to a free Personal Team?, reason)
CLASSIFICATION: dict[str, tuple[bool, str]] = {
    "com.apple.security.application-groups": (False, REGISTERED_ID),
    "com.apple.developer.icloud-container-identifiers": (False, REGISTERED_ID),
    "com.apple.developer.ubiquity-container-identifiers": (False, REGISTERED_ID),
    "com.apple.developer.icloud-services": (False, APPID_SERVICE),
    "com.apple.developer.healthkit": (False, APPID_SERVICE),
    "com.apple.developer.healthkit.access": (False, APPID_SERVICE),
    "com.apple.developer.homekit": (False, APPID_SERVICE),
    "com.apple.developer.weatherkit": (False, APPID_SERVICE),
    "com.apple.developer.nfc.readersession.formats": (False, APPID_SERVICE),
    "aps-environment": (False, APPID_SERVICE),
    "com.apple.developer.associated-domains": (False, APPID_SERVICE),
    "com.apple.developer.siri": (False, APPID_SERVICE),
    "com.apple.developer.networking.networkextension": (False, APPID_SERVICE),
    # Issued in every profile, free included.
    "keychain-access-groups": (True, FREE_OK),
    "application-identifier": (True, FREE_OK),
    "com.apple.developer.team-identifier": (True, FREE_OK),
    "get-task-allow": (True, FREE_OK),
    # Not a provisioning-profile entitlement: a plain capability flag.
    "com.apple.developer.kernel.increased-memory-limit": (True, FREE_OK),
    "com.apple.developer.kernel.extended-virtual-addressing": (True, FREE_OK),
}

# Which entitlements file each target signs with, and whether that target is
# part of a configuration meant to be signed by a free Apple ID.
TARGETS = [
    ("Minis (app)", "Minis.entitlements", False),
    ("MinisShare (share extension)", "ShareExtension/ShareExtension.entitlements", False),
    ("MinisFileProvider", "FileProvider/FileProvider.entitlements", False),
    ("AgentWidgetExtension", "AgentWidget/AgentWidget.entitlements", False),
    ("Minis (PersonalFree)", "Minis-PersonalFree.entitlements", True),
]


def read_entitlements(rel: str) -> dict | None:
    path = os.path.join(IOS, rel)
    if not os.path.exists(path):
        return None
    with open(path, "rb") as fh:
        return plistlib.load(fh)


def main() -> int:
    markdown = "--markdown" in sys.argv
    rows = []
    failures = []
    unknown = []

    for label, rel, must_be_free_signable in TARGETS:
        ents = read_entitlements(rel)
        if ents is None:
            if must_be_free_signable:
                failures.append(f"{label}: {rel} is missing")
            continue
        if not ents:
            rows.append((label, "(none)", "yes", FREE_OK))
            continue
        for key in sorted(ents):
            known = CLASSIFICATION.get(key)
            if known is None:
                unknown.append(f"{label}: unclassified entitlement {key}")
                rows.append((label, key, "?", "unclassified — add it to CLASSIFICATION"))
                continue
            free_ok, reason = known
            rows.append((label, key, "yes" if free_ok else "no", reason))
            if must_be_free_signable and not free_ok:
                failures.append(
                    f"{label} requests {key}, which free provisioning cannot issue "
                    f"({reason})"
                )

    if markdown:
        print("| Target | Entitlement | Free Personal Team? | Why |")
        print("|---|---|---|---|")
        for label, key, ok, reason in rows:
            print(f"| {label} | `{key}` | {ok} | {reason} |")
    else:
        width = max(len(r[0]) for r in rows) if rows else 10
        for label, key, ok, reason in rows:
            print(f"{label:<{width}}  {ok:<4} {key}")

    if unknown:
        print("\nUNCLASSIFIED:", file=sys.stderr)
        for u in unknown:
            print("  " + u, file=sys.stderr)
        return 2
    if failures:
        print("\nFAIL — a free-signable configuration asks for a paid capability:",
              file=sys.stderr)
        for f in failures:
            print("  " + f, file=sys.stderr)
        return 1

    free_targets = [t for t in TARGETS if t[2]]
    print(f"\nOK  {len(rows)} entitlements classified; "
          f"{len(free_targets)} free-signable configuration(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
