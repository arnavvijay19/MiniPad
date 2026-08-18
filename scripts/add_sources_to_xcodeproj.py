#!/usr/bin/env python3
"""Add Swift sources to the Minis Xcode project.

The Minis app target is not a file-system-synchronized group, so a new .swift
file has to be declared explicitly: a PBXFileReference, membership in a
PBXGroup so the file is visible in Xcode's navigator, and a PBXBuildFile in
each target's Sources phase that should compile it.

Editing project.pbxproj by hand is how you get a project that opens with a red
file or silently doesn't compile something. This script does it mechanically and
idempotently: running it twice is a no-op, and it verifies its own output.
"""
import re
import sys
import hashlib

import os
PROJ = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    '..', 'src', 'ios', 'Minis.xcodeproj', 'project.pbxproj')

# (path relative to src/ios, in-app-target, in-test-target)
#
# Note on the test target: Xcode makes every resolved package product visible
# to every target in the project, so `canImport(MLXLLM)` is TRUE in MinisTests
# even though MinisTests links no MLX product. That means the MLX-gated half of
# MLXLocalProvider.swift compiles there too, and everything it names has to be
# in the target — which is why LocalModelStore, LocalModelLifecycle and
# LocalAgentProviderFactory are compiled into the tests as well. The result is
# a stronger check, not a workaround: the test target type-checks the on-device
# path under Swift 6 strict concurrency.
FILES = [
    ('Agent/Unified/ExecutionTarget.swift', True, True),
    ('Agent/Unified/UnifiedPath.swift', True, True),
    ('Agent/Unified/RemoteEndpointConfig.swift', True, True),
    ('Agent/Unified/ToolSurfacePolicy.swift', True, True),
    ('Agent/Unified/UnifiedToolRouting.swift', True, True),
    ('Agent/Unified/UnifiedToolRouter.swift', True, False),
    ('Agent/Unified/RemoteEndpointStore.swift', True, False),
    ('Agent/Unified/AIChatViewModel+UnifiedCapabilities.swift', True, False),
    ('Agent/Unified/RemoteCommandRisk.swift', True, True),
    ('Agent/Unified/RemoteActionApproval.swift', True, False),
    ('Agent/Unified/ToolDisclosureState.swift', True, False),
    ('Agent/Unified/Shortcuts/ShortcutRunCoordinator.swift', True, False),
    ('Providers/Local/LocalModelStore.swift', True, True),
    ('Providers/Local/LocalAgentProviderFactory.swift', True, True),
    ('Providers/Local/LocalModelLifecycle.swift', True, True),
    # Puts a downloaded model into the picker. Without it the whole on-device
    # path is unreachable: nothing else creates a ModelEntry with a `local/` id.
    ('Providers/Local/LocalProviderRegistration.swift', True, False),
    ('Views/Settings/UnifiedAgentSettingsView.swift', True, False),
    # Resolves the durable-state container, with a sandbox fallback for builds
    # signed without the App Group entitlement. App target only: an extension
    # falling back to its own sandbox would silently diverge from the app.
    ('Shared/AppGroupContainer.swift', True, False),
    ('Agent/Unified/MCP/MCPWireProtocol.swift', True, True),
    ('Agent/Unified/MCP/HTTPStreamTransport.swift', True, True),
    ('Agent/Unified/MCP/URLSessionStreamTransport.swift', True, False),
    ('Agent/Unified/MCP/MCPHTTPClient.swift', True, True),
    ('Agent/Unified/Windows/DesktopCommanderAdapter.swift', True, True),
    ('Agent/Unified/Windows/WindowsResultParser.swift', True, True),
    ('Agent/Unified/Windows/WindowsExecutor.swift', True, True),
    ('Agent/Unified/Shortcuts/ShortcutsBridge.swift', True, True),
    ('Providers/Local/LocalModelCatalog.swift', True, True),
    ('Providers/Local/LocalToolCallSalvage.swift', True, True),
    ('Providers/Local/LocalTranscriptDelta.swift', True, True),
    ('Providers/Local/MLXLocalProvider.swift', True, True),
    # Compiled into the test target for real (not stubbed): it defines the
    # canonical agent tool/message types the new sources are built on.
    ('Providers/AgentProvider.swift', False, True),
]

APP_SOURCES = 'E51000041'    # Minis target Sources phase
TEST_SOURCES = 'BB1000030F700000000000AA'   # MinisTests Sources phase


# The OpenStep plist grammar Xcode uses allows a bare (unquoted) string only
# for [A-Za-z0-9_$/:.-]. A filename with any other character — '+' is the one
# this project actually has — must be quoted, and Xcode itself always quotes
# them. Emitting `path = AIChatViewModel+UnifiedCapabilities.swift;` produced a
# project file that every regex-based check accepted and that Xcode refused to
# open at all: "The project 'Minis' is damaged and cannot be opened due to a
# parse error."
_BARE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$/:.-")


def plist_str(value):
    """Quote `value` when the OpenStep grammar requires it."""
    if value and all(c in _BARE for c in value):
        return value
    escaped = value.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def stable_id(seed):
    """Deterministic 24-hex-char object id, so re-running produces no diff."""
    return hashlib.sha1(('minipad-unified:' + seed).encode()).hexdigest()[:24].upper()


def main():
    src = open(PROJ, encoding='utf-8').read()
    original = src
    added = []

    for path, in_app, in_test in FILES:
        basename = path.rsplit('/', 1)[-1]

        # A file already referenced by another target (AgentProvider.swift is in
        # the app target) keeps its existing PBXFileReference; only the missing
        # PBXBuildFile entries are added.
        existing = re.search(
            r'^\t\t([0-9A-Za-z]{6,32}) /\* ' + re.escape(basename)
            + r' \*/ = \{isa = PBXFileReference', src, re.M)
        file_ref = existing.group(1) if existing else stable_id('ref:' + path)
        app_build = stable_id('app:' + path)
        test_build = stable_id('test:' + path)

        # 1. PBXFileReference, group-relative. Xcode resolves a `<group>` path
        #    against the parent group's path, so the reference carries only the
        #    basename and step 1b puts it in the group for its directory. An
        #    orphaned reference still *builds* (Xcode falls back to the project
        #    directory) but is invisible in the navigator, which is how you get
        #    a project nobody can edit by hand.
        if not existing:
            ref_line = (f'\t\t{file_ref} /* {basename} */ = {{isa = PBXFileReference; '
                        f'lastKnownFileType = sourcecode.swift; '
                        f'path = {plist_str(basename)}; sourceTree = "<group>"; }};\n')
            src = src.replace('/* End PBXFileReference section */',
                              ref_line + '/* End PBXFileReference section */', 1)
        else:
            src = normalize_ref(src, file_ref, path, basename)

        # 1b. Group membership for the file's directory.
        if not group_contains(src, path, basename):
            src = add_to_group(src, path, file_ref, basename)

        # 2. PBXBuildFile entries — only the ones not already present.
        in_app = in_app and not phase_contains(src, APP_SOURCES, basename)
        in_test = in_test and not phase_contains(src, TEST_SOURCES, basename)
        if not in_app and not in_test:
            continue

        build_lines = ''
        if in_app:
            build_lines += (f'\t\t{app_build} /* {basename} in Sources */ = '
                            f'{{isa = PBXBuildFile; fileRef = {file_ref} /* {basename} */; }};\n')
        if in_test:
            build_lines += (f'\t\t{test_build} /* {basename} in Sources */ = '
                            f'{{isa = PBXBuildFile; fileRef = {file_ref} /* {basename} */; }};\n')
        src = src.replace('/* End PBXBuildFile section */',
                          build_lines + '/* End PBXBuildFile section */', 1)

        # 3. Sources build phases.
        if in_app:
            src = add_to_phase(src, APP_SOURCES, app_build, basename)
        if in_test:
            src = add_to_phase(src, TEST_SOURCES, test_build, basename)

        added.append(path)

    if src == original:
        print('No changes — every file is already declared.')
        return

    open(PROJ, 'w', encoding='utf-8').write(src)
    print(f'Added {len(added)} file(s):')
    for path in added:
        print('  ', path)


def phase_contains(src, phase_id, basename):
    """True when a Sources phase already compiles this file."""
    m = re.search(re.escape(phase_id) + r' /\* Sources \*/ = \{.*?files = \((.*?)\);',
                  src, re.DOTALL)
    return bool(m) and f'/* {basename} in Sources */' in m.group(1)


def add_to_phase(src, phase_id, build_id, basename):
    pattern = re.compile(
        r'(' + re.escape(phase_id) + r' /\* Sources \*/ = \{.*?files = \(\n)',
        re.DOTALL)
    m = pattern.search(src)
    if not m:
        raise SystemExit(f'Could not find Sources phase {phase_id}')
    entry = f'\t\t\t\t{build_id} /* {basename} in Sources */,\n'
    return src[:m.end()] + entry + src[m.end():]


# ---------------------------------------------------------------------------
# PBXGroup handling
#
# Groups mirror the directory layout under src/ios. `group_for` walks down from
# the project's main group, creating any missing level, and returns the id of
# the group that should hold a file in `directory`.
# ---------------------------------------------------------------------------

def _objects(src):
    """id -> body, for every object in the file."""
    matches = list(re.finditer(r'^\t\t([A-Za-z0-9_]{6,32})\s*(?:/\*.*?\*/)?\s*=\s*\{',
                               src, re.M))
    out = {}
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(src)
        out[m.group(1)] = src[m.start():end]
    return out


def _group_children(body):
    block = re.search(r'children\s*=\s*\((.*?)\);', body, re.S)
    if not block:
        return []
    return re.findall(r'^\s*([A-Za-z0-9_]{6,32})\s*(?:/\*|,)', block.group(1), re.M)


def find_group(src, directory):
    """Id of the PBXGroup whose resolved path is `directory`, or None.

    `directory` is relative to src/ios and uses '/' separators; '' is the
    `Minis` group, which is the project's source root in this project.
    """
    objs = _objects(src)
    main = re.search(r'mainGroup\s*=\s*([A-Za-z0-9_]+)', src).group(1)

    def isa(oid):
        m = re.search(r'isa\s*=\s*(\w+)', objs.get(oid, ''))
        return m.group(1) if m else None

    def attr(body, key):
        m = re.search(r'\b' + key + r'\s*=\s*"?([^";\n]+)"?\s*;', body)
        return m.group(1) if m else None

    found = {}

    def walk(gid, prefix, seen):
        if gid in seen:
            return
        body = objs.get(gid)
        if body is None or isa(gid) != 'PBXGroup':
            return
        tree = attr(body, 'sourceTree') or '<group>'
        path = attr(body, 'path')
        if tree == 'SOURCE_ROOT':
            base = path or ''
        elif tree == '<group>':
            base = f'{prefix}/{path}' if (prefix and path) else (path or prefix)
        else:
            return
        found.setdefault(base, gid)
        for cid in _group_children(body):
            walk(cid, base, seen | {gid})

    walk(main, '', frozenset())
    return found.get(directory)


def add_group(src, parent_id, name):
    """Create an empty PBXGroup named `name` inside `parent_id`."""
    gid = stable_id('group:' + parent_id + '/' + name)
    block = (f'\t\t{gid} /* {name} */ = {{\n'
             f'\t\t\tisa = PBXGroup;\n'
             f'\t\t\tchildren = (\n'
             f'\t\t\t);\n'
             f'\t\t\tpath = {plist_str(name)};\n'
             f'\t\t\tsourceTree = "<group>";\n'
             f'\t\t}};\n')
    src = src.replace('/* End PBXGroup section */',
                      block + '/* End PBXGroup section */', 1)
    return _insert_child(src, parent_id, gid, name), gid


def _insert_child(src, group_id, child_id, comment):
    pattern = re.compile(
        r'(' + re.escape(group_id) + r' /\* [^*]*\*/ = \{\n\t\t\tisa = PBXGroup;\n'
        r'\t\t\tchildren = \(\n)', re.M)
    m = pattern.search(src)
    if not m:
        raise SystemExit(f'Could not find children list of group {group_id}')
    entry = f'\t\t\t\t{child_id} /* {comment} */,\n'
    return src[:m.end()] + entry + src[m.end():]


def group_for(src, directory):
    """Id of the group for `directory`, creating missing levels."""
    gid = find_group(src, directory)
    if gid:
        return src, gid
    parent_dir, _, name = directory.rpartition('/')
    src, parent = group_for(src, parent_dir)
    src, gid = add_group(src, parent, name)
    return src, gid


def group_contains(src, path, basename):
    """True when the file is already a child of the group for its directory."""
    directory = path.rsplit('/', 1)[0] if '/' in path else ''
    gid = find_group(src, directory)
    if not gid:
        return False
    body = _objects(src).get(gid, '')
    block = re.search(r'children\s*=\s*\((.*?)\);', body, re.S)
    return bool(block) and f'/* {basename} */' in block.group(1)


def normalize_ref(src, file_ref, path, basename):
    """Convert a legacy `SOURCE_ROOT` + full-path reference to group-relative.

    Earlier revisions of this script emitted `sourceTree = SOURCE_ROOT` with the
    whole relative path so it would not have to create groups. That compiles,
    but leaves the file out of the navigator. Rewrite such references in place;
    references that are already group-relative are left alone.
    """
    pattern = re.compile(
        r'(\t\t' + re.escape(file_ref) + r' /\* ' + re.escape(basename)
        + r' \*/ = \{isa = PBXFileReference;[^\n]*?)'
        r'name = ' + re.escape(basename) + r'; path = ' + re.escape(path)
        + r'; sourceTree = SOURCE_ROOT;')
    return pattern.sub(
        lambda m: m.group(1) + f'path = {plist_str(basename)}; sourceTree = "<group>";', src)


def add_to_group(src, path, file_ref, basename):
    directory = path.rsplit('/', 1)[0] if '/' in path else ''
    src, gid = group_for(src, directory)
    return _insert_child(src, gid, file_ref, basename)


if __name__ == '__main__':
    main()
