#!/usr/bin/env python3
"""Structural validation of src/ios/Minis.xcodeproj/project.pbxproj.

Xcode's project file is edited by `scripts/add_sources_to_xcodeproj.py` without
Xcode present, so nothing else catches a dangling reference until someone opens
the project on a Mac. This script is that check, and it runs on Linux in
seconds.

It verifies:

  1. Delimiters balance (a truncated write is the classic corruption).
  2. Every PBXBuildFile.fileRef points at a declared object.
  3. Every id listed in a build phase's `files` is a declared PBXBuildFile.
  4. Every id listed in a group's `children` is a declared object.
  5. Every source file reference resolves to a file that exists on disk.
  6. No file is compiled twice in the same target (duplicate-symbol errors are
     otherwise only discovered by a 40-minute CI build).

Exit status is non-zero on the first category that fails, and every problem in
that category is printed.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "src/ios/Minis.xcodeproj/project.pbxproj")
IOS_DIR = os.path.join(ROOT, "src/ios")

# `ID /* comment */ = { ... };` — the object header. Ids are 24 hex chars in
# Xcode's own output, but the helper script mints readable ones like
# `E52000020`, so accept any run of uppercase hex/alphanumerics.
OBJ_RE = re.compile(r"^\t\t([A-Za-z0-9_]{8,32})\s*(?:/\*.*?\*/)?\s*=\s*\{", re.M)
ISA_RE = re.compile(r"isa\s*=\s*(\w+)")


def fail(category: str, problems: list[str]) -> None:
    print(f"FAIL: {category}", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    with open(PBXPROJ, encoding="utf-8") as fh:
        text = fh.read()

    # 1. Delimiters ----------------------------------------------------------
    for open_c, close_c in (("{", "}"), ("(", ")")):
        # Braces appear inside shellScript string literals, so count only
        # outside double-quoted spans.
        depth = 0
        in_str = False
        esc = False
        for ch in text:
            if esc:
                esc = False
                continue
            if ch == "\\":
                esc = True
                continue
            if ch == '"':
                in_str = not in_str
                continue
            if in_str:
                continue
            if ch == open_c:
                depth += 1
            elif ch == close_c:
                depth -= 1
                if depth < 0:
                    fail("delimiters", [f"unbalanced '{close_c}' before its '{open_c}'"])
        if depth != 0:
            fail("delimiters", [f"{depth} unclosed '{open_c}'"])

    # Slice the file into objects so each id maps to its body. ---------------
    matches = list(OBJ_RE.finditer(text))
    objects: dict[str, str] = {}
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        objects[m.group(1)] = text[m.start():end]

    isa_of = {}
    for oid, body in objects.items():
        m = ISA_RE.search(body)
        if m:
            isa_of[oid] = m.group(1)

    if not objects:
        fail("parse", ["no objects found — is this a pbxproj?"])

    # 2. PBXBuildFile.fileRef -----------------------------------------------
    problems = []
    build_file_ref: dict[str, str] = {}
    for oid, body in objects.items():
        if isa_of.get(oid) != "PBXBuildFile":
            continue
        m = re.search(r"fileRef\s*=\s*([A-Za-z0-9_]+)", body)
        if not m:
            # A build file may instead carry a productRef (SPM product).
            if "productRef" not in body:
                problems.append(f"{oid}: PBXBuildFile with neither fileRef nor productRef")
            continue
        ref = m.group(1)
        build_file_ref[oid] = ref
        if ref not in objects:
            problems.append(f"{oid}: fileRef {ref} is not declared")
    if problems:
        fail("dangling fileRef", problems)

    # 3. Build phase membership ---------------------------------------------
    phase_isas = {
        "PBXSourcesBuildPhase",
        "PBXResourcesBuildPhase",
        "PBXFrameworksBuildPhase",
        "PBXCopyFilesBuildPhase",
        "PBXHeadersBuildPhase",
    }
    problems = []
    phase_members: dict[str, list[str]] = {}
    for oid, body in objects.items():
        if isa_of.get(oid) not in phase_isas:
            continue
        block = re.search(r"files\s*=\s*\((.*?)\);", body, re.S)
        if not block:
            continue
        ids = re.findall(r"^\s*([A-Za-z0-9_]{8,32})\s*(?:/\*|,)", block.group(1), re.M)
        phase_members[oid] = ids
        for bid in ids:
            if bid not in objects:
                problems.append(f"{oid}: member {bid} is not declared")
            elif isa_of.get(bid) != "PBXBuildFile":
                problems.append(f"{oid}: member {bid} is a {isa_of.get(bid)}, not a PBXBuildFile")
    if problems:
        fail("build phase membership", problems)

    # 4. Group children ------------------------------------------------------
    problems = []
    for oid, body in objects.items():
        if isa_of.get(oid) not in {"PBXGroup", "PBXVariantGroup"}:
            continue
        block = re.search(r"children\s*=\s*\((.*?)\);", body, re.S)
        if not block:
            continue
        for cid in re.findall(r"^\s*([A-Za-z0-9_]{8,32})\s*(?:/\*|,)", block.group(1), re.M):
            if cid not in objects:
                problems.append(f"{oid}: child {cid} is not declared")
    if problems:
        fail("group children", problems)

    # 5. Source files exist on disk -----------------------------------------
    # Xcode resolves a `<group>` path relative to its parent group, so a bare
    # `path = VoiceProvider.swift;` only makes sense once the group chain above
    # it has been walked. Rebuild that chain and check the resulting paths.
    main_group = re.search(r"mainGroup\s*=\s*([A-Za-z0-9_]+)", text)
    if not main_group:
        fail("parse", ["no mainGroup on the PBXProject"])

    def attr(body: str, key: str) -> str | None:
        m = re.search(r'\b' + key + r'\s*=\s*"?([^";\n]+)"?\s*;', body)
        return m.group(1) if m else None

    resolved: dict[str, str] = {}   # file-ref id -> path relative to src/ios
    unresolvable: set[str] = set()  # under SDKROOT/DEVELOPER_DIR/BUILT_PRODUCTS_DIR

    def walk(gid: str, prefix: str, seen: frozenset[str]) -> None:
        if gid in seen:
            return
        body = objects.get(gid)
        if body is None:
            return
        seen = seen | {gid}
        tree = attr(body, "sourceTree") or "<group>"
        path = attr(body, "path")
        if tree == "SOURCE_ROOT":
            base = path or ""
        elif tree == "<group>":
            base = os.path.join(prefix, path) if path else prefix
        else:
            # SDKROOT, DEVELOPER_DIR, BUILT_PRODUCTS_DIR, <absolute> — nothing
            # under these lives in the repository.
            base = None

        block = re.search(r"children\s*=\s*\((.*?)\);", body, re.S)
        if not block:
            return
        for cid in re.findall(r"^\s*([A-Za-z0-9_]{8,32})\s*(?:/\*|,)", block.group(1), re.M):
            kind = isa_of.get(cid)
            if kind in {"PBXGroup", "PBXVariantGroup"}:
                walk(cid, base if base is not None else "", seen)
            elif kind == "PBXFileReference":
                cbody = objects[cid]
                ctree = attr(cbody, "sourceTree") or "<group>"
                cpath = attr(cbody, "path")
                if cpath is None:
                    continue
                if ctree == "SOURCE_ROOT":
                    resolved[cid] = cpath
                elif ctree == "<group>":
                    if base is None:
                        unresolvable.add(cid)
                    else:
                        resolved[cid] = os.path.normpath(os.path.join(base, cpath))
                else:
                    unresolvable.add(cid)

    walk(main_group.group(1), "", frozenset())

    # Two files are written by build phases before compilation, so they are
    # legitimately absent from a clean checkout.
    GENERATED = {
        "Generated/ProviderCustomizationGenerated.swift",
        "Generated/DebugSkillGenerated.swift",
    }

    problems = []
    orphans = []
    path_of = dict(resolved)
    for oid, body in objects.items():
        if isa_of.get(oid) != "PBXFileReference":
            continue
        if oid in unresolvable:
            continue
        rel = resolved.get(oid)
        if rel is None:
            # Declared but not reachable from mainGroup: Xcode will not show it
            # and `add_sources_to_xcodeproj.py` should never leave one behind.
            if attr(body, "path", ) and (attr(body, "path") or "").endswith(".swift"):
                orphans.append(f"{oid}: {attr(body, 'path')} is not in any group")
            continue
        if not rel.endswith(".swift"):
            continue
        if rel in GENERATED:
            continue
        if not os.path.exists(os.path.join(IOS_DIR, rel)):
            problems.append(f"{oid}: src/ios/{rel} does not exist")
    if problems:
        fail("missing source files", problems)
    if orphans:
        fail("orphaned file references", orphans)

    # 6. No file compiled twice in one phase ---------------------------------
    problems = []
    for phase, members in phase_members.items():
        seen: dict[str, str] = {}
        for bid in members:
            ref = build_file_ref.get(bid)
            path = path_of.get(ref)
            if path is None:
                continue
            if path in seen:
                problems.append(f"{phase}: {path} appears twice ({seen[path]}, {bid})")
            seen[path] = bid
    if problems:
        fail("duplicate compilation", problems)

    swift_refs = sum(1 for p in path_of.values() if p.endswith(".swift"))
    print(
        f"OK  {len(objects)} objects, {len(build_file_ref)} build files, "
        f"{swift_refs} Swift file references, {len(phase_members)} build phases"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
