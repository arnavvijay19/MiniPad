#!/usr/bin/env python3
"""Check that every switch over ProviderType handles `.local`.

Adding a case to `ProviderType` breaks exhaustiveness at ~28 sites across the
app. On a Mac the compiler finds them all; without one, this script does.

The invariant it checks is precise: `.unsupported` is the forward-compatibility
sentinel that *every* exhaustive switch over ProviderType must already handle,
so any switch mentioning `case .unsupported` must also mention `case .local`.
A switch with a `default:` needs neither and is not flagged.

Two enums elsewhere in the app also have an `.unsupported` case
(ModelQuickTestSheet.TestError, VoiceInputModels) and are excluded by name.

Exit code 1 if any site is missing a branch.
"""
import os
import re
import sys

IOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'ios')

# Files whose `.unsupported` belongs to an unrelated enum.
EXCLUDE_FILES = {
    'ModelQuickTestSheet.swift',   # TestError.unsupported(String)
    'VoiceInputModels.swift',      # VoiceInputError.unsupported(String)
}

# Only a bare `.unsupported` is ProviderType's sentinel. `.unsupported(...)`
# carries a payload, and `.unsupportedScheme` / `.unsupportedArchitecture` are
# different enums entirely — matching those would produce false failures that
# train the reader to ignore this check.
SENTINEL = re.compile(r'case\s+\.unsupported\s*(?::|$)')


def switch_blocks(lines, index):
    """Return the body of the `switch` that owns the `case` at `index`.

    A `case` belongs to the nearest preceding `switch` at the SAME indentation —
    that is the convention Swift and this codebase use. Matching merely the
    nearest `switch` at any indent is wrong: a nested `switch` inside an earlier
    case (e.g. `switch instance.credentialType` inside `case .kimiCode`) would
    steal the match and report a false failure.
    """
    indent = len(lines[index]) - len(lines[index].lstrip())
    start = None
    for i in range(index, -1, -1):
        if not re.search(r'\bswitch\b.*\{', lines[i]):
            continue
        if len(lines[i]) - len(lines[i].lstrip()) == indent:
            start = i
            break
    if start is None:
        return None
    depth = 0
    for j in range(start, len(lines)):
        depth += lines[j].count('{') - lines[j].count('}')
        if depth <= 0 and j > start:
            return lines[start:j + 1]
    return lines[start:]


def main():
    missing = []
    checked = 0
    for root, _, files in os.walk(IOS):
        if '.build' in root:
            continue
        for name in files:
            if not name.endswith('.swift') or name in EXCLUDE_FILES:
                continue
            path = os.path.join(root, name)
            lines = open(path, encoding='utf-8').read().split('\n')
            for i, line in enumerate(lines):
                if not SENTINEL.search(line.rstrip()):
                    continue
                block = switch_blocks(lines, i)
                if block is None:
                    continue
                checked += 1
                if not any(re.search(r'case\s+\.local\b', b) for b in block):
                    rel = os.path.relpath(path, IOS)
                    missing.append(f'{rel}:{i + 1}  {line.strip()}')

    if missing:
        print(f'FAIL — {len(missing)} of {checked} ProviderType switches lack a `.local` branch:')
        for m in missing:
            print('  ', m)
        return 1
    print(f'OK — all {checked} ProviderType switches handle `.local`')
    return 0


if __name__ == '__main__':
    sys.exit(main())
