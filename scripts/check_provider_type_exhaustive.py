#!/usr/bin/env python3
"""Check that every switch over ProviderType handles `.local`.

Adding a case to `ProviderType` breaks exhaustiveness at ~28 sites across the
app. On a Mac the compiler finds them all; without one, this script does.

The invariant it checks is precise: `.unsupported` is the forward-compatibility
sentinel that *every* exhaustive switch over ProviderType must already handle,
so any switch whose case labels include a bare `.unsupported` must also have a
`.local` branch. A switch with a `default:` needs neither and is not flagged.

It works on switch *blocks*, collecting the full case-label text of each one,
rather than on single lines. An earlier version matched the line pattern
`case .unsupported:`, which silently ignored every switch where the sentinel
was not the first item in its list — `case .anthropic, .gemini, .unsupported:`
was invisible to it. It reported 28 sites healthy while the compiler found five
of them non-exhaustive.

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
# A bare `.unsupported` in a case label. `.unsupported(...)` carries a payload
# and `.unsupportedScheme` / `.unsupportedArchitecture` are different enums, so
# the token must be followed by a comma, a colon, or the end of the line.
BARE = r'(?<![A-Za-z0-9_.])\.{name}\s*(?:[,:]|$)'
SENTINEL = re.compile(BARE.format(name='unsupported'))
LOCAL = re.compile(BARE.format(name='local'))
SWITCH = re.compile(r'\bswitch\b.*\{')


def switch_blocks(lines):
    """Yield (start_line_index, block_lines) for every switch in the file."""
    for i, line in enumerate(lines):
        if not SWITCH.search(line):
            continue
        depth = 0
        for j in range(i, len(lines)):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth <= 0 and j > i:
                yield i, lines[i:j + 1]
                break
        else:
            yield i, lines[i:]


def case_labels(block):
    """The text of every case label in this switch, excluding nested switches.

    A label may wrap across lines, so text is accumulated from `case` up to the
    colon that ends the label.
    """
    labels = []
    depth = 0
    collecting = None
    for line in block[1:]:
        stripped = line.strip()
        if SWITCH.search(line):
            depth += 1
        if depth > 0:
            # Inside a nested switch; its labels belong to another enum.
            depth += line.count('{') - line.count('}') - (1 if SWITCH.search(line) else 0)
            if depth < 0:
                depth = 0
            continue
        if collecting is not None:
            collecting += ' ' + stripped
            if ':' in stripped:
                labels.append(collecting)
                collecting = None
            continue
        if re.match(r'case\b', stripped):
            if ':' in stripped:
                labels.append(stripped)
            else:
                collecting = stripped
    return labels


def main():
    missing = []
    checked = 0
    for root, _, files in os.walk(IOS):
        if '.build' in root:
            continue
        for name in sorted(files):
            if not name.endswith('.swift') or name in EXCLUDE_FILES:
                continue
            path = os.path.join(root, name)
            lines = open(path, encoding='utf-8').read().split('\n')
            for index, block in switch_blocks(lines):
                labels = case_labels(block)
                if not any(SENTINEL.search(label) for label in labels):
                    continue
                checked += 1
                if not any(LOCAL.search(label) for label in labels):
                    rel = os.path.relpath(path, IOS)
                    missing.append(f'{rel}:{index + 1}  {lines[index].strip()}')

    if missing:
        print(f'FAIL — {len(missing)} of {checked} ProviderType switches lack a '
              f'`.local` branch:')
        for m in missing:
            print('  ', m)
        return 1
    print(f'OK — all {checked} ProviderType switches handle `.local`')
    return 0


if __name__ == '__main__':
    sys.exit(main())
