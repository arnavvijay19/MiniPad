#!/bin/sh
# Measure the permanent context cost of the agent's tool surface, using the
# real tokenizers of the local models Minis can run.
#
# The numbers this prints are what justify ToolSurfacePolicy's lazy disclosure.
# Re-run it after editing any tool description — a few sentences added to a
# description is a few hundred tokens taken out of every request a 4B model
# ever makes, and that cost is invisible without this.
#
# Usage:
#   ./scripts/measure_tool_context.sh                       # Qwen 3.5 4B
#   ./scripts/measure_tool_context.sh mlx-community/gemma-4-e2b-it-4bit
#
# Requires: python3, `pip install tokenizers`, and network access to fetch the
# tokenizer once (cached in .tokenizer-cache/, which is gitignored).

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE="$ROOT/.tokenizer-cache"
TOOLS_SRC="$ROOT/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift"

REPOS="${*:-mlx-community/Qwen3.5-4B-4bit}"

mkdir -p "$CACHE"

TOKENIZERS=""
for repo in $REPOS; do
    file="$CACHE/$(echo "$repo" | tr '/' '_').tokenizer.json"
    if [ ! -f "$file" ]; then
        echo "Fetching tokenizer for $repo ..." >&2
        curl -sSLf -o "$file" "https://huggingface.co/$repo/resolve/main/tokenizer.json" \
            || { echo "Could not fetch the tokenizer for $repo" >&2; rm -f "$file"; exit 1; }
    fi
    TOKENIZERS="$TOKENIZERS $file"
done

TOOLS_JSON="$CACHE/tools.json"
python3 "$ROOT/scripts/extract_agent_tools.py" "$TOOLS_SRC" > "$TOOLS_JSON"
# shellcheck disable=SC2086
python3 "$ROOT/scripts/measure_tool_context.py" "$TOOLS_JSON" $TOKENIZERS
