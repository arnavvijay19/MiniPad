#!/usr/bin/env python3
"""Add Swift sources to the Minis Xcode project.

The Minis app target is not a file-system-synchronized group, so a new .swift
file has to be declared explicitly: a PBXFileReference, a PBXGroup membership,
and a PBXBuildFile in each target's Sources phase that should compile it.

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
FILES = [
    ('Agent/Unified/ExecutionTarget.swift', True, True),
    ('Agent/Unified/UnifiedPath.swift', True, True),
    ('Agent/Unified/RemoteEndpointConfig.swift', True, True),
    ('Agent/Unified/ToolSurfacePolicy.swift', True, True),
    ('Agent/Unified/UnifiedToolRouting.swift', True, True),
    ('Agent/Unified/UnifiedToolRouter.swift', True, False),
    ('Agent/Unified/RemoteEndpointStore.swift', True, False),
    ('Agent/Unified/AIChatViewModel+UnifiedCapabilities.swift', True, False),
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

        # 1. PBXFileReference. `sourceTree = SOURCE_ROOT` with the full relative
        #    path avoids having to create PBXGroups for the new directories —
        #    Xcode resolves it from the project directory.
        if not existing:
            ref_line = (f'\t\t{file_ref} /* {basename} */ = {{isa = PBXFileReference; '
                        f'lastKnownFileType = sourcecode.swift; name = {basename}; '
                        f'path = {path}; sourceTree = SOURCE_ROOT; }};\n')
            src = src.replace('/* End PBXFileReference section */',
                              ref_line + '/* End PBXFileReference section */', 1)

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


if __name__ == '__main__':
    main()
