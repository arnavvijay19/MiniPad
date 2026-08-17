#!/usr/bin/env python3
"""Measure the permanent context cost of the agent's tool surface.

Tokenizes the OpenAI-style function schemas the local provider emits
(LocalToolSchemaBuilder) using the REAL tokenizers from the target models, so
the numbers in the design document are measurements rather than estimates.

Usage: measure_context.py <tools.json> <tokenizer.json> [...]
"""
import json
import sys
from tokenizers import Tokenizer


def schema_for(tool):
    """Mirror of LocalToolSchemaBuilder.schema(for:) in Swift."""
    properties = {}
    for name, param in tool['parameters'].items():
        entry = {'type': param['type'], 'description': param['description']}
        if param.get('enum'):
            entry['enum'] = param['enum']
        properties[name] = entry
    return {
        'type': 'function',
        'function': {
            'name': tool['name'],
            'description': tool['description'],
            'parameters': {
                'type': 'object',
                'properties': properties,
                'required': tool['required'],
            },
        },
    }


def count(tokenizer, text):
    return len(tokenizer.encode(text, add_special_tokens=False).ids)


def main():
    tools = json.load(open(sys.argv[1]))
    tokenizer_paths = sys.argv[2:]
    tokenizers = {}
    for path in tokenizer_paths:
        label = path.split('/')[-1].replace('.tokenizer.json', '').replace('mlx-community_', '')
        tokenizers[label] = Tokenizer.from_file(path)

    labels = list(tokenizers)
    width = max(len(t['name']) for t in tools) + 2

    print('=' * 78)
    print('PER-TOOL SCHEMA COST (JSON-serialized function schema)')
    print('=' * 78)
    header = 'tool'.ljust(width) + 'chars'.rjust(8)
    for label in labels:
        header += label.rjust(24)
    print(header)
    print('-' * 78)

    totals = {label: 0 for label in labels}
    per_tool = {}
    for tool in sorted(tools, key=lambda t: t['name']):
        text = json.dumps(schema_for(tool), separators=(',', ':'))
        row = tool['name'].ljust(width) + str(len(text)).rjust(8)
        counts = {}
        for label in labels:
            n = count(tokenizers[label], text)
            counts[label] = n
            totals[label] += n
            row += str(n).rjust(24)
        per_tool[tool['name']] = counts
        print(row)

    print('-' * 78)
    row = 'TOTAL'.ljust(width) + ''.rjust(8)
    for label in labels:
        row += str(totals[label]).rjust(24)
    print(row)

    # The four-tool core: what a local model would carry if the specialist
    # tools were disclosed lazily instead of permanently.
    core = {'shell_execute', 'file_read', 'file_write', 'file_edit'}
    print()
    print('=' * 78)
    print('CORE-ONLY SURFACE (shell_execute, file_read, file_write, file_edit)')
    print('=' * 78)
    for label in labels:
        core_total = sum(v[label] for k, v in per_tool.items() if k in core)
        saved = totals[label] - core_total
        pct = 100.0 * saved / totals[label] if totals[label] else 0
        print(f'{label:<24} core={core_total:>6}  full={totals[label]:>6}  '
              f'saved={saved:>6} ({pct:.0f}%)')

    # Additive cost of the new capability fragments.
    print()
    print('=' * 78)
    print('ADDITIVE COST OF THE NEW CAPABILITIES')
    print('=' * 78)

    target_param = {
        'type': 'string',
        'description': "Machine to run on: 'ipad' (default, on-device Linux) or 'windows' (the user's PC).",
        'enum': ['ipad', 'windows'],
    }
    target_json = json.dumps({'target': target_param}, separators=(',', ':'))

    exec_fragment = """<execution_targets>
You can run commands and read/write files on two machines:
- iPad (default): the on-device Alpine Linux sandbox. Paths are normal absolute POSIX paths, e.g. /var/minis/workspace/report.md
- Windows (Desktop): the user's PC. Prefix paths with `win:`, e.g. win:C:\\Users\\me\\repo\\main.py

Pass `target: "windows"` to shell_execute / file_read / file_write / file_edit to act on the PC. Omit it for the iPad.
Files do NOT sync between the machines. To move one, copy it explicitly.
Always say which machine you acted on when you report back.
</execution_targets>"""

    shortcuts_fragment = """<shortcuts>
Apple Shortcuts the user has registered. Run one with run_shortcut.
Running a shortcut briefly switches to the Shortcuts app and back — say so before you do it.
- Get Commute: Returns travel time home (takes no input, returns output)
- Log Weight: Writes a weight to Health (takes text input, returns nothing)
This is the complete list you can see; iOS gives no way to enumerate the user's other shortcuts.
</shortcuts>"""

    items = [
        ('target param x4 core tools', target_json, 4),
        ('execution_targets fragment', exec_fragment, 1),
        ('shortcuts fragment (2 registered)', shortcuts_fragment, 1),
    ]
    for label in labels:
        print(f'\n{label}:')
        grand = 0
        for name, text, multiplier in items:
            n = count(tokenizers[label], text) * multiplier
            grand += n
            print(f'  {name:<38} {n:>6} tokens')
        print(f'  {"TOTAL ADDITIVE":<38} {grand:>6} tokens')
        print(f'  {"vs. full tool surface":<38} {100.0 * grand / totals[label]:>5.0f}%')

    print()
    print('=' * 78)
    print('CONTEXT BUDGET AT 32K (core surface + additive)')
    print('=' * 78)
    for label in labels:
        core_total = sum(v[label] for k, v in per_tool.items() if k in core)
        additive = sum(count(tokenizers[label], t) * m for _, t, m in items)
        fixed = core_total + additive
        print(f'{label:<24} tools+capabilities={fixed:>6}  '
              f'= {100.0 * fixed / 32768:.1f}% of a 32K window')


if __name__ == '__main__':
    main()
