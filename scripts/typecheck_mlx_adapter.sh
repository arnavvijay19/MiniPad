#!/bin/sh
# Typecheck the AgentMessage -> MLXLMCommon.Chat.Message mapping against the
# REAL upstream type definitions.
#
# WHY THIS EXISTS
#
# MLXLocalProvider is the one component in this fork that cannot be compiled
# without the MLX package, and the mapping inside it is the highest-risk code we
# have: it is written against an API we can read but not link. "Reviewed against
# the source" is not verification.
#
# The full MLXLMCommon target does not build on Linux — mlx-swift's CPU backend
# fails in svd.cpp against Ubuntu's LAPACK. But the types the mapping actually
# touches (Chat, ToolCall, JSONValue, ToolSpec, ToolParameter) are pure Swift
# with no MLX imports. This script copies those files VERBATIM from the resolved
# package checkout, supplies a minimal stand-in for the three opaque media types
# Chat.Message declares, and typechecks the mapping against them.
#
# It has already earned its keep: it caught that `[String: Any]` does not
# convert to `ToolSpec` (`[String: any Sendable]`), which would have failed the
# first Xcode build with the package enabled.
#
# Requires: a Swift 6.3+ toolchain (mlx-swift-lm declares swift-tools 6.2 and
# mlx-swift 0.31.6 declares 6.3, so nothing older can even resolve it).
#
# Usage: ./scripts/typecheck_mlx_adapter.sh [path-to-swift-bin-dir]

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${TMPDIR:-/tmp}/minipad-mlx-adapter-probe"
[ $# -ge 1 ] && PATH="$1:$PATH"

if ! swift --version >/dev/null 2>&1; then
    echo "No swift toolchain on PATH. Pass one: $0 /path/to/swift/usr/bin" >&2
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/pkg/Sources/Probe" "$WORK/probe"

# 1. Resolve mlx-swift-lm to get the real sources. Resolve only — the C++
#    backend is never built, which is what keeps this fast and portable.
cat > "$WORK/pkg/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Probe",
    dependencies: [.package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main")],
    targets: [.target(name: "Probe")]
)
EOF
echo "// resolve-only" > "$WORK/pkg/Sources/Probe/x.swift"

echo "Resolving mlx-swift-lm ..."
(cd "$WORK/pkg" && SPM_CUDA=0 swift package resolve >/dev/null 2>&1) || {
    echo "Could not resolve mlx-swift-lm (network? toolchain older than 6.3?)" >&2
    exit 1
}

COMMON="$WORK/pkg/.build/checkouts/mlx-swift-lm/Libraries/MLXLMCommon"
[ -d "$COMMON" ] || { echo "MLXLMCommon not found at $COMMON" >&2; exit 1; }

# 2. Copy the real, MLX-free type definitions verbatim.
cp "$COMMON/Chat.swift" \
   "$COMMON/Tool/ToolCall.swift" \
   "$COMMON/Tool/Value.swift" \
   "$COMMON/Tool/Tool.swift" \
   "$COMMON/Tool/ToolParameter.swift" \
   "$WORK/probe/"

REV=$(cd "$WORK/pkg/.build/checkouts/mlx-swift-lm" && git rev-parse --short HEAD)
echo "Using mlx-swift-lm @ $REV"

# 3. Stand-ins for the few symbols those files reference from MLX-importing
#    files. The adapter never constructs any of them.
cat > "$WORK/probe/_Shim.swift" <<'EOF'
import Foundation
public typealias Message = [String: any Sendable]
public struct UserInput {
    public enum Image {}
    public enum Video {}
    public enum Audio {}
    public enum Prompt {
        case text(String)
        case messages([Message])
        case chat([Chat.Message])
    }
    public var prompt: Prompt = .text("")
}
EOF

# 4. The mapping under test, extracted from MLXLocalProvider.swift so it cannot
#    drift from the shipped implementation without this failing.
python3 - "$ROOT/src/ios/Providers/Local/MLXLocalProvider.swift" "$WORK/probe/_Mapping.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

# chatMessages(_:) — the Chat.Message construction.
m = re.search(r'( {4}private static func chatMessages\(.*?\n {4}\})', src, re.S)
if not m:
    sys.exit("could not find chatMessages(_:) in MLXLocalProvider.swift")
mapping = m.group(1).replace('private static func', 'func')
mapping = mapping.replace('LocalTranscriptRenderer.RenderedMessage', 'Rendered')
mapping = mapping.replace('message.kind', 'message')

out = '''import Foundation

// Stands in for LocalTranscriptRenderer.RenderedMessage (tested separately).
enum Rendered {
    case user
    case assistant(toolCalls: [(id: String, name: String, argumentsJSON: String)])
    case toolResult(id: String, name: String)
    var text: String { "" }
}

'''  + mapping + '''

// The two other places the adapter crosses the API boundary.
func toolSpecsAreSendableDicts(_ schemas: [[String: any Sendable]]) -> [ToolSpec] { schemas }
func argumentsBack(_ call: ToolCall) -> [String: Any] {
    call.function.arguments.mapValues { $0.anyValue }
}
'''
open(sys.argv[2], 'w').write(out)
PY

# 5. Typecheck the mapping.
cd "$WORK/probe"
if ! swiftc -typecheck -swift-version 6 -package-name MLXLMCommon ./*.swift; then
    echo
    echo "FAIL — the adapter does not match the current MLXLMCommon API" >&2
    exit 1
fi
echo "  mapping typechecks"

# 6. Assert the rest of the API surface the provider uses.
#
#    These symbols live in files that import MLX and so cannot be typechecked
#    here. Grepping the real checkout for their declarations is weaker than a
#    compile, but it is the difference between "verified against upstream" and
#    "assumed" — and it is what caught `loadContainer(configuration:)` (which
#    does not exist) and `GPU.set(cacheLimit:)` (deprecated).
CHECKOUT="$WORK/pkg/.build/checkouts"
LM="$CHECKOUT/mlx-swift-lm/Libraries"
SWIFTMLX="$CHECKOUT/mlx-swift/Source/MLX"
fails=0

assert_present() {   # description, pattern, file...
    desc="$1"; pat="$2"; shift 2
    if grep -qE "$pat" "$@" 2>/dev/null; then
        printf "  ok    %s\n" "$desc"
    else
        printf "  FAIL  %s  (no match for /%s/)\n" "$desc" "$pat" >&2
        fails=$((fails + 1))
    fi
}

# Comment lines are stripped first: the provider's comments deliberately NAME
# the wrong APIs to explain why they aren't used, and matching those would make
# this check permanently red.
assert_absent() {    # description, pattern, file...
    desc="$1"; pat="$2"; shift 2
    if grep -vE '^[[:space:]]*//' "$@" 2>/dev/null | grep -qE "$pat"; then
        printf "  FAIL  %s  (unexpectedly present: /%s/)\n" "$desc" "$pat" >&2
        fails=$((fails + 1))
    else
        printf "  ok    %s\n" "$desc"
    fi
}

echo
echo "API surface used by MLXLocalProvider:"
assert_present "ChatSession(_:instructions:generateParameters:tools:)" \
    "instructions: String\? = nil" "$LM/MLXLMCommon/ChatSession.swift"
assert_present "streamDetails(to: [Chat.Message])" \
    "to messages: consuming \[Chat.Message\]" "$LM/MLXLMCommon/ChatSession.swift"
assert_present "Generation.chunk/.toolCall/.rejectedToolCall/.info" \
    "case rejectedToolCall\(RejectedToolCall\)" "$LM/MLXLMCommon/Evaluate.swift"
assert_present "GenerateCompletionInfo.promptTokenCount" \
    "public let promptTokenCount: Int" "$LM/MLXLMCommon/Evaluate.swift"
assert_present "GenerateCompletionInfo.generationTokenCount" \
    "public let generationTokenCount: Int" "$LM/MLXLMCommon/Evaluate.swift"
for field in temperature topP maxTokens maxKVSize kvBits quantizedKVStart; do
    assert_present "GenerateParameters.$field" \
        "public var $field" "$LM/MLXLMCommon/Evaluate.swift"
done
assert_present "ModelConfiguration(id:revision:)" \
    "id: String, revision: String" "$LM/MLXLMCommon/ModelConfiguration.swift"
assert_present "#huggingFaceLoadModelContainer(configuration:progressHandler:)" \
    "macro huggingFaceLoadModelContainer" "$LM/MLXHuggingFace/Macros.swift"
assert_present "Memory.cacheLimit" \
    "public static var cacheLimit" "$SWIFTMLX/Memory.swift"
assert_present "Memory.clearCache()" \
    "public static func clearCache" "$SWIFTMLX/Memory.swift"

# The two APIs an earlier draft of the provider used. Both are wrong, and both
# would have failed the first Xcode build; assert they stay unused.
assert_absent "provider does not call the nonexistent loadContainer(configuration:)" \
    "loadContainer\(configuration:" "$ROOT/src/ios/Providers/Local/MLXLocalProvider.swift"
assert_absent "provider does not use deprecated GPU.set(cacheLimit:)/GPU.clearCache()" \
    "GPU\.(set\(cacheLimit|clearCache)" "$ROOT/src/ios/Providers/Local/MLXLocalProvider.swift"

echo
if [ "$fails" -eq 0 ]; then
    echo "OK — adapter mapping and every API assertion match mlx-swift-lm @ $REV"
else
    echo "FAIL — $fails API assertion(s) do not match mlx-swift-lm @ $REV" >&2
    exit 1
fi
