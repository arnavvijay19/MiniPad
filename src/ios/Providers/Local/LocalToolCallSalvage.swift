//
//  LocalToolCallSalvage.swift
//  MinisApp
//
//  Recovering tool calls that a 4B model *nearly* got right.
//
//  MLXLMCommon has a proper tool-call parser and it handles well-formed output.
//  This is the layer underneath: what to do when a small model emits something
//  that is obviously a tool call and is not valid JSON.
//
//  This matters more than it sounds. A frontier model malforms a tool call
//  rarely enough that "reject and let it retry" is fine. A 4B model does it
//  often enough that rejection dominates the experience: each rejection costs a
//  full round trip, and the retry frequently reproduces the same mistake
//  because the model doesn't know what was wrong. On a 15 tok/s local model
//  that is 30+ seconds of user-visible nothing, repeatedly.
//
//  The salvage rules below all come from the same principle: recover only when
//  the intent is unambiguous. Every rule is reversible in the sense that if it
//  fires wrongly, the resulting call still fails validation upstream — none of
//  them can invent an argument or change which tool is being called.
//
//  Pure Foundation, exhaustively unit-tested against real small-model output
//  shapes.
//

import Foundation

/// A tool call recovered from raw model text.
struct SalvagedToolCall: Equatable, Sendable {
    let name: String
    let arguments: [String: MCPValue]
    /// Which repairs were applied, for logging and for the telemetry that tells
    /// us whether a rule is still earning its place.
    let repairs: [String]
}

enum LocalToolCallSalvage {

    /// Extract tool calls from an assistant turn's raw text.
    ///
    /// Returns an empty array when the text contains no tool-call-shaped
    /// content at all — which is the common case and must stay cheap.
    static func salvage(from raw: String) -> [SalvagedToolCall] {
        var results: [SalvagedToolCall] = []
        for (body, wrapperRepairs) in extractCandidateBodies(raw) {
            guard let call = parseBody(body, priorRepairs: wrapperRepairs) else { continue }
            results.append(call)
        }
        return results
    }

    // MARK: - Stage 1: find the candidate bodies

    /// Locate the JSON-ish payloads that claim to be tool calls.
    ///
    /// Three wrappers are recognised, in decreasing order of confidence:
    ///   1. `<tool_call>…</tool_call>` — the Hermes/Qwen convention
    ///   2. a fenced ```json / ```tool_code block
    ///   3. a bare top-level object carrying both a name and an arguments key
    ///
    /// Case 3 is the risky one, so it is gated on the object actually having
    /// tool-call keys rather than merely being JSON — otherwise a model that
    /// answers a question *about* JSON would have its answer executed.
    static func extractCandidateBodies(_ raw: String) -> [(body: String, repairs: [String])] {
        var out: [(String, [String])] = []

        // 1. Explicit tags, including the very common unterminated form where
        //    the model ran out of tokens or simply forgot the closing tag.
        var searchStart = raw.startIndex
        while let open = raw.range(of: "<tool_call>", range: searchStart..<raw.endIndex) {
            let after = open.upperBound
            if let close = raw.range(of: "</tool_call>", range: after..<raw.endIndex) {
                out.append((String(raw[after..<close.lowerBound]), []))
                searchStart = close.upperBound
            } else {
                // Unterminated: take the balanced object that starts here. A
                // truncated call still often has complete arguments, and
                // discarding it wastes the whole turn.
                let tail = String(raw[after...])
                out.append((tail, ["unterminated-tool_call-tag"]))
                break
            }
        }
        if !out.isEmpty { return out }

        // 2. Fenced blocks.
        for fence in ["```json", "```tool_code", "```tool_call", "```"] {
            guard let open = raw.range(of: fence) else { continue }
            let after = open.upperBound
            guard let close = raw.range(of: "```", range: after..<raw.endIndex) else { continue }
            let body = String(raw[after..<close.lowerBound])
            if looksLikeToolCall(body) {
                out.append((body, ["markdown-fence"]))
                return out
            }
        }

        // 3. A bare object.
        if let body = firstBalancedObject(in: raw), looksLikeToolCall(body) {
            out.append((body, ["bare-object"]))
        }
        return out
    }

    /// Cheap gate for case 2/3: does this payload actually name a tool?
    static func looksLikeToolCall(_ body: String) -> Bool {
        let lowered = body.lowercased()
        let hasName = lowered.contains("\"name\"") || lowered.contains("'name'")
        let hasArgs = lowered.contains("\"arguments\"") || lowered.contains("'arguments'")
            || lowered.contains("\"parameters\"") || lowered.contains("'parameters'")
            || lowered.contains("\"args\"") || lowered.contains("'args'")
        return hasName && hasArgs
    }

    /// First brace-balanced `{…}` in the text, respecting string literals and
    /// escapes so a `}` inside an argument value doesn't end the object early.
    static func firstBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Stage 2: parse one body

    static func parseBody(_ body: String, priorRepairs: [String] = []) -> SalvagedToolCall? {
        var repairs = priorRepairs
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip anything before the first '{' / after the last '}' — models
        // routinely narrate around the payload ("Here is the call: {...}").
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            let trimmed = String(text[start...end])
            if trimmed != text {
                text = trimmed
                repairs.append("stripped-surrounding-prose")
            }
        }

        var object = decodeObject(text)
        if object == nil {
            // Repair passes, cheapest and safest first.
            for pass in repairPasses {
                guard let candidate = pass.apply(text) else { continue }
                if let decoded = decodeObject(candidate) {
                    object = decoded
                    text = candidate
                    repairs.append(pass.name)
                    break
                }
            }
        }
        guard let object else { return nil }

        // Name: `name` at the top level, or nested under `function` (the
        // OpenAI-shaped variant some models imitate).
        let nameValue = object["name"] ?? object["function"]?["name"]
        guard let name = nameValue?.stringValue, !name.isEmpty else { return nil }
        if object["name"] == nil { repairs.append("openai-function-wrapper") }

        // Arguments: several spellings, plus the very common
        // "arguments as a JSON string" form.
        var argumentsValue = object["arguments"] ?? object["parameters"] ?? object["args"]
            ?? object["function"]?["arguments"]
        if object["arguments"] == nil && object["function"]?["arguments"] == nil
            && (object["parameters"] != nil || object["args"] != nil) {
            repairs.append("arguments-key-alias")
        }
        if let stringified = argumentsValue?.stringValue {
            guard let reparsed = decodeObject(stringified) else { return nil }
            argumentsValue = .object(reparsed)
            repairs.append("stringified-arguments")
        }

        // No arguments at all is legitimate for a zero-parameter tool.
        let arguments = argumentsValue?.objectValue ?? [:]
        if argumentsValue == nil { repairs.append("missing-arguments-defaulted-to-empty") }

        return SalvagedToolCall(name: name, arguments: arguments, repairs: repairs)
    }

    private static func decodeObject(_ text: String) -> [String: MCPValue]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(MCPValue.self, from: data) else { return nil }
        return value.objectValue
    }

    // MARK: - Repair passes

    /// Each pass rewrites the text and is retried through the strict decoder.
    /// Ordered so the least destructive runs first, and every one of them is
    /// incapable of inventing a tool name or an argument key.
    private static let repairPasses: [RepairPass] = [
        RepairPass(name: "trailing-comma", apply: removeTrailingCommas),
        RepairPass(name: "single-quotes", apply: convertSingleQuotedKeys),
        RepairPass(name: "python-literals", apply: replacePythonLiterals),
        RepairPass(name: "unclosed-braces", apply: closeUnbalancedBraces),
    ]

    /// A named, stateless text rewrite. `Sendable` so the pass table can be a
    /// `static let` under strict concurrency — every pass is a pure function.
    private struct RepairPass: Sendable {
        let name: String
        let apply: @Sendable (String) -> String?
    }

    /// `{"a": 1,}` → `{"a": 1}`. Small models emit these constantly.
    static func removeTrailingCommas(_ text: String) -> String? {
        var out = ""
        var inString = false
        var escaped = false
        var pendingComma = false
        for ch in text {
            if escaped {
                escaped = false
                out.append(ch)
                continue
            }
            if ch == "\\" { escaped = true; out.append(ch); continue }
            if ch == "\"" { inString.toggle(); if pendingComma { out.append(","); pendingComma = false }; out.append(ch); continue }
            if inString { out.append(ch); continue }

            if ch == "," {
                pendingComma = true
                continue
            }
            if pendingComma {
                if ch == "}" || ch == "]" {
                    pendingComma = false          // drop it
                } else if !ch.isWhitespace {
                    out.append(",")
                    pendingComma = false
                } else {
                    continue                       // hold across whitespace
                }
            }
            out.append(ch)
        }
        // A comma still pending at end-of-input is by definition trailing —
        // nothing in JSON legitimately ends with one — so it is dropped rather
        // than re-emitted.
        return out == text ? nil : out
    }

    /// `{'name': 'x'}` → `{"name": "x"}`.
    ///
    /// Only fires when the text contains no double quotes at all. That
    /// restriction is the whole safety story: a mixed-quote payload could have
    /// an apostrophe inside a legitimate double-quoted value ("don't"), and
    /// rewriting that would corrupt the argument.
    static func convertSingleQuotedKeys(_ text: String) -> String? {
        guard !text.contains("\""), text.contains("'") else { return nil }
        return text.replacingOccurrences(of: "'", with: "\"")
    }

    /// `True` / `False` / `None` → `true` / `false` / `null`.
    ///
    /// Models trained heavily on Python emit these. Only bare, delimited
    /// occurrences are rewritten, so the word "None" inside a string argument
    /// survives.
    static func replacePythonLiterals(_ text: String) -> String? {
        var out = ""
        var inString = false
        var escaped = false
        var token = ""

        func flushToken() {
            switch token {
            case "True": out += "true"
            case "False": out += "false"
            case "None": out += "null"
            default: out += token
            }
            token = ""
        }

        for ch in text {
            if escaped { escaped = false; out.append(ch); continue }
            if ch == "\\" { escaped = true; out.append(ch); continue }
            if ch == "\"" {
                flushToken()
                inString.toggle()
                out.append(ch)
                continue
            }
            if inString { out.append(ch); continue }
            if ch.isLetter {
                token.append(ch)
            } else {
                flushToken()
                out.append(ch)
            }
        }
        flushToken()
        return out == text ? nil : out
    }

    /// Close braces/brackets a truncated generation left open.
    ///
    /// This is the last resort and the most aggressive, so it refuses to fire
    /// when the truncation landed inside a string literal — completing a
    /// half-written path or command would hand a *wrong* argument to a tool
    /// that then runs it, which is far worse than losing the turn.
    static func closeUnbalancedBraces(_ text: String) -> String? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        for ch in text {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" || ch == "[" { stack.append(ch) }
            if ch == "}" { if stack.last == "{" { stack.removeLast() } else { return nil } }
            if ch == "]" { if stack.last == "[" { stack.removeLast() } else { return nil } }
        }
        guard !inString, !stack.isEmpty else { return nil }
        var out = text
        // A dangling `"key":` with no value can't be closed meaningfully.
        if out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") { return nil }
        if out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",") {
            out = String(out[out.startIndex..<out.lastIndex(of: ",")!])
        }
        for opener in stack.reversed() {
            out.append(opener == "{" ? "}" : "]")
        }
        return out
    }

    // MARK: - Text cleanup

    /// Remove tool-call markup from the visible assistant text.
    ///
    /// Without this the user sees the raw `<tool_call>{"name":…}</tool_call>`
    /// in the transcript alongside the rendered tool card, which looks broken.
    static func strippingToolCallMarkup(_ raw: String) -> String {
        var out = raw
        while let open = out.range(of: "<tool_call>") {
            if let close = out.range(of: "</tool_call>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
