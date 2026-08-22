#!/usr/bin/env python3
"""Validate src/ios/Minis.xcodeproj/project.pbxproj the way Xcode reads it.

Why a parser and not a regex
----------------------------
An earlier version of this script checked the project file with regular
expressions and reported it healthy. Xcode disagreed:

    xcodebuild: error: Unable to read project 'Minis.xcodeproj'
        Reason: The project 'Minis' is damaged and cannot be opened due to a
        parse error.

The cause was one character. `project.pbxproj` is an OpenStep property list,
whose grammar permits a bare (unquoted) string only for [A-Za-z0-9_$/:.-]. A
reference emitted as

    path = AIChatViewModel+UnifiedCapabilities.swift;

is a syntax error, because '+' ends the token. Every regex check passed it;
Xcode refused to open the project at all. So this script parses the file with
the real grammar first, and only then checks the object graph — against parsed
objects, not against text.

Checks:
  1. The file parses as an OpenStep plist.
  2. Every PBXBuildFile has a fileRef or productRef that resolves.
  3. Every build-phase member is a declared PBXBuildFile.
  4. Every group child is a declared object.
  5. Every Swift file reference resolves to a file on disk, via the group tree.
  6. No file reference is orphaned (declared but in no group).
  7. No file is compiled twice within one build phase.

Usage: python3 scripts/validate_xcodeproj.py
"""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "src/ios/Minis.xcodeproj/project.pbxproj")
IOS_DIR = os.path.join(ROOT, "src/ios")

# Written by build phases before compilation, so absent from a clean checkout.
GENERATED = {
    "Generated/ProviderCustomizationGenerated.swift",
    "Generated/DebugSkillGenerated.swift",
}

BARE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$/:.-")


class PlistError(Exception):
    def __init__(self, msg: str, text: str, pos: int) -> None:
        line = text.count("\n", 0, pos) + 1
        col = pos - (text.rfind("\n", 0, pos) + 1)
        excerpt = text[max(0, pos - 120):pos + 120].replace("\n", "\\n")
        super().__init__(f"{msg} at line {line}, column {col}\n  ...{excerpt}...")


class Parser:
    """OpenStep plist, the subset Xcode writes."""

    def __init__(self, text: str) -> None:
        self.t = text
        self.i = 0

    def skip(self) -> None:
        t, n = self.t, len(self.t)
        while self.i < n:
            c = t[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif t.startswith("/*", self.i):
                end = t.find("*/", self.i + 2)
                if end < 0:
                    raise PlistError("unterminated /* comment", t, self.i)
                self.i = end + 2
            elif t.startswith("//", self.i):
                end = t.find("\n", self.i)
                self.i = n if end < 0 else end + 1
            else:
                return

    def value(self):
        self.skip()
        if self.i >= len(self.t):
            raise PlistError("unexpected end of file", self.t, self.i)
        c = self.t[self.i]
        if c == "{":
            return self.dictionary()
        if c == "(":
            return self.array()
        if c == '"':
            return self.quoted()
        if c == "<":
            return self.data()
        return self.bare()

    def dictionary(self) -> dict:
        start = self.i
        self.i += 1
        out: dict = {}
        while True:
            self.skip()
            if self.i >= len(self.t):
                raise PlistError("unterminated dictionary", self.t, start)
            if self.t[self.i] == "}":
                self.i += 1
                return out
            key = self.value()
            self.skip()
            if self.i >= len(self.t) or self.t[self.i] != "=":
                raise PlistError(f"expected '=' after key {key!r}", self.t, self.i)
            self.i += 1
            val = self.value()
            self.skip()
            if self.i >= len(self.t) or self.t[self.i] != ";":
                raise PlistError(
                    f"expected ';' after the value of {key!r} — an unquoted string "
                    f"may only contain [A-Za-z0-9_$/:.-]", self.t, self.i)
            self.i += 1
            out[key] = val

    def array(self) -> list:
        start = self.i
        self.i += 1
        out: list = []
        while True:
            self.skip()
            if self.i >= len(self.t):
                raise PlistError("unterminated array", self.t, start)
            if self.t[self.i] == ")":
                self.i += 1
                return out
            out.append(self.value())
            self.skip()
            if self.i < len(self.t) and self.t[self.i] == ",":
                self.i += 1
            elif self.i < len(self.t) and self.t[self.i] == ")":
                self.i += 1
                return out
            else:
                raise PlistError("expected ',' or ')' in array", self.t, self.i)

    def quoted(self) -> str:
        self.i += 1
        out = []
        while True:
            if self.i >= len(self.t):
                raise PlistError("unterminated string", self.t, self.i)
            c = self.t[self.i]
            if c == "\\":
                out.append(self.t[self.i + 1:self.i + 2])
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                return "".join(out)
            out.append(c)
            self.i += 1

    def data(self) -> str:
        end = self.t.find(">", self.i)
        if end < 0:
            raise PlistError("unterminated <data>", self.t, self.i)
        out = self.t[self.i:end + 1]
        self.i = end + 1
        return out

    def bare(self) -> str:
        start = self.i
        while self.i < len(self.t) and self.t[self.i] in BARE:
            self.i += 1
        if self.i == start:
            raise PlistError(f"unexpected character {self.t[self.i]!r}", self.t, self.i)
        return self.t[start:self.i]


def parse(text: str):
    if text.startswith("// !$*UTF8*$!"):
        text = text.split("\n", 1)[1]
    p = Parser(text)
    root = p.value()
    p.skip()
    if p.i != len(p.t):
        raise PlistError("trailing content after the root object", p.t, p.i)
    return root


def fail(category: str, problems: list[str]) -> None:
    print(f"FAIL: {category}", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    with open(PBXPROJ, encoding="utf-8") as fh:
        text = fh.read()

    # 1. Grammar -------------------------------------------------------------
    try:
        root = parse(text)
    except PlistError as exc:
        fail("project.pbxproj is not a valid OpenStep plist — Xcode will refuse "
             "to open it", [str(exc)])
        return 1  # unreachable

    objects: dict = root["objects"]
    isa = {oid: obj.get("isa") for oid, obj in objects.items()}

    # 2. Build files ---------------------------------------------------------
    problems = []
    build_file_ref: dict[str, str] = {}
    for oid, obj in objects.items():
        if isa[oid] != "PBXBuildFile":
            continue
        ref = obj.get("fileRef")
        if ref is None:
            if "productRef" not in obj:
                problems.append(f"{oid}: PBXBuildFile with neither fileRef nor productRef")
            elif obj["productRef"] not in objects:
                problems.append(f"{oid}: productRef {obj['productRef']} is not declared")
            continue
        build_file_ref[oid] = ref
        if ref not in objects:
            problems.append(f"{oid}: fileRef {ref} is not declared")
    if problems:
        fail("dangling references", problems)

    # 3. Build phase membership ---------------------------------------------
    phase_isas = {
        "PBXSourcesBuildPhase", "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase",
        "PBXCopyFilesBuildPhase", "PBXHeadersBuildPhase",
    }
    problems = []
    phases: dict[str, list[str]] = {}
    for oid, obj in objects.items():
        if isa[oid] not in phase_isas:
            continue
        members = obj.get("files", [])
        phases[oid] = members
        for member in members:
            if member not in objects:
                problems.append(f"{oid}: member {member} is not declared")
            elif isa[member] != "PBXBuildFile":
                problems.append(f"{oid}: member {member} is a {isa[member]}")
    if problems:
        fail("build phase membership", problems)

    # 4. Group children ------------------------------------------------------
    problems = []
    for oid, obj in objects.items():
        if isa[oid] not in {"PBXGroup", "PBXVariantGroup"}:
            continue
        for child in obj.get("children", []):
            if child not in objects:
                problems.append(f"{oid}: child {child} is not declared")
    if problems:
        fail("group children", problems)

    # 5/6. Resolve every file reference through the group tree ---------------
    resolved: dict[str, str] = {}
    external: set[str] = set()   # under SDKROOT/DEVELOPER_DIR/BUILT_PRODUCTS_DIR

    def walk(gid: str, prefix: str | None, seen: frozenset[str]) -> None:
        if gid in seen or gid not in objects:
            return
        group = objects[gid]
        tree = group.get("sourceTree", "<group>")
        path = group.get("path")
        if tree == "SOURCE_ROOT":
            base: str | None = path or ""
        elif tree == "<group>":
            base = None if prefix is None else (os.path.join(prefix, path) if path else prefix)
        else:
            base = None
        for cid in group.get("children", []):
            kind = isa.get(cid)
            if kind in {"PBXGroup", "PBXVariantGroup"}:
                walk(cid, base, seen | {gid})
            elif kind == "PBXFileReference":
                child = objects[cid]
                ctree = child.get("sourceTree", "<group>")
                cpath = child.get("path")
                if cpath is None:
                    continue
                if ctree == "SOURCE_ROOT":
                    resolved[cid] = cpath
                elif ctree == "<group>" and base is not None:
                    resolved[cid] = os.path.normpath(os.path.join(base, cpath))
                else:
                    external.add(cid)

    walk(root["rootObject"] and objects[root["rootObject"]]["mainGroup"], "", frozenset())

    problems, orphans = [], []
    for oid, obj in objects.items():
        if isa[oid] != "PBXFileReference" or oid in external:
            continue
        rel = resolved.get(oid)
        path = obj.get("path", "")
        if rel is None:
            if path.endswith(".swift"):
                orphans.append(f"{oid}: {path} is in no group — invisible in Xcode's navigator")
            continue
        if not rel.endswith(".swift") or rel in GENERATED:
            continue
        if not os.path.exists(os.path.join(IOS_DIR, rel)):
            problems.append(f"{oid}: src/ios/{rel} does not exist")
    if problems:
        fail("missing source files", problems)
    if orphans:
        fail("orphaned file references", orphans)

    # 7. Duplicate compilation ----------------------------------------------
    problems = []
    for phase, members in phases.items():
        seen_paths: dict[str, str] = {}
        for member in members:
            ref = build_file_ref.get(member)
            rel = resolved.get(ref) if ref else None
            if rel is None:
                continue
            if rel in seen_paths:
                problems.append(f"{phase}: {rel} appears twice ({seen_paths[rel]}, {member})")
            seen_paths[rel] = member
    if problems:
        fail("duplicate compilation", problems)

    swift = sum(1 for p in resolved.values() if p.endswith(".swift"))
    targets = sum(1 for k in isa.values() if k == "PBXNativeTarget")
    packages = sum(1 for k in isa.values() if k == "XCRemoteSwiftPackageReference")
    print(f"OK  parses as OpenStep plist; {len(objects)} objects, {targets} targets, "
          f"{packages} packages, {swift} Swift files, {len(phases)} build phases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
