#!/usr/bin/env python3
"""Extract AgentToolDefinition literals from Swift source.

Used by measure_context.py to tokenize the tool schemas the model actually
receives, rather than a hand-typed approximation of them. Parsing Swift with a
small state machine is fragile in general; it is acceptable here because this
is a measurement script whose output is checked against the source, and because
the alternative (retyping ~4KB of descriptions) is fragile in a way that fails
silently.
"""
import json
import re
import sys


def strip_swift_string_concat(text):
    """Swift multi-line string concatenation: "a" + "b" -> "ab"."""
    return re.sub(r'"\s*\+\s*"', '', text)


def read_swift_string(src, i):
    """Read a Swift string literal starting at src[i] == '"'. Returns (value, next_i)."""
    assert src[i] == '"'
    i += 1
    out = []
    while i < len(src):
        c = src[i]
        if c == '\\':
            nxt = src[i + 1]
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(nxt, nxt))
            i += 2
            continue
        if c == '"':
            return ''.join(out), i + 1
        out.append(c)
        i += 1
    raise ValueError('unterminated string')


def balanced(src, i, open_ch, close_ch):
    """Return (inner_text, next_i) for a balanced region starting at src[i]==open_ch."""
    assert src[i] == open_ch
    depth = 0
    start = i
    while i < len(src):
        c = src[i]
        if c == '"':
            _, i = read_swift_string(src, i)
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return src[start + 1:i], i + 1
        i += 1
    raise ValueError('unbalanced')


def parse_params(text):
    """Parse the `parameters:` dictionary literal."""
    params = {}
    i = 0
    while i < len(text):
        if text[i] != '"':
            i += 1
            continue
        key, i = read_swift_string(text, i)
        m = re.compile(r'\s*:\s*AgentToolParam\s*\(').match(text, i)
        if not m:
            continue
        i = m.end() - 1
        inner, i = balanced(text, i, '(', ')')
        inner = strip_swift_string_concat(inner)
        type_m = re.search(r'type:\s*\.(\w+)', inner)
        desc_m = re.search(r'description:\s*"', inner)
        desc = ''
        if desc_m:
            desc, _ = read_swift_string(inner, desc_m.end() - 1)
        enum_vals = None
        enum_m = re.search(r'enumValues:\s*\[', inner)
        if enum_m:
            enum_text, _ = balanced(inner, enum_m.end() - 1, '[', ']')
            enum_vals = re.findall(r'"([^"]*)"', enum_text)
            if not enum_vals:
                # e.g. `BrowserAction.allCases.map(\.rawValue)` — a computed
                # list. Recorded as a marker so the report can note that this
                # tool's real enum is larger than what is measured here.
                enum_vals = ['<computed>']
        params[key] = {
            'type': type_m.group(1) if type_m else 'string',
            'description': desc,
            'enum': enum_vals,
        }
    return params


def extract(path):
    src = open(path, encoding='utf-8').read()
    tools = []
    for m in re.finditer(r'AgentToolDefinition\s*\(', src):
        inner, _ = balanced(src, m.end() - 1, '(', ')')
        inner_flat = strip_swift_string_concat(inner)

        name_m = re.search(r'name:\s*"', inner_flat)
        if not name_m:
            continue
        name, _ = read_swift_string(inner_flat, name_m.end() - 1)

        desc_m = re.search(r'description:\s*"', inner_flat)
        desc, _ = read_swift_string(inner_flat, desc_m.end() - 1) if desc_m else ('', 0)

        params = {}
        p_m = re.search(r'parameters:\s*\[', inner_flat)
        if p_m:
            p_text, _ = balanced(inner_flat, p_m.end() - 1, '[', ']')
            params = parse_params(p_text)

        required = []
        r_m = re.search(r'required:\s*\[', inner_flat)
        if r_m:
            r_text, _ = balanced(inner_flat, r_m.end() - 1, '[', ']')
            required = re.findall(r'"([^"]*)"', r_text)

        tools.append({
            'name': name,
            'description': desc,
            'parameters': params,
            'required': required,
        })
    return tools


if __name__ == '__main__':
    print(json.dumps(extract(sys.argv[1]), indent=2))
