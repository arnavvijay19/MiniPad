//
//  WindowsResultParser.swift
//  MinisApp
//
//  Pulls process ids, exit codes and liveness out of a remote tool result.
//
//  This is the most fragile part of the Windows integration and therefore the
//  part that is pure logic and exhaustively tested. Different Desktop Commander
//  builds report a process id as `structuredContent.pid`, as
//  `"Process started with PID 41208"`, or as `"pid=41208"`. A misparse doesn't
//  fail loudly — it makes the next `interact_with_process` write the user's
//  input into some *other* process. Structured content is therefore always
//  preferred, and the prose fallback is deliberately narrow.
//

import Foundation

enum WindowsResultParser {

    // MARK: Process id

    /// Extract a process id. Structured content wins; prose is the fallback.
    static func processID(from result: MCPToolCall.Result) -> String? {
        if let structured = result.structured?.objectValue {
            for key in ["pid", "processId", "process_id", "id", "sessionId", "session_id"] {
                guard let v = structured[key] else { continue }
                if let i = v.intValue { return String(i) }
                if let s = v.stringValue, !s.isEmpty { return s }
            }
        }
        return processID(fromText: result.text)
    }

    /// Number of characters after the "pid" marker we're willing to search.
    ///
    /// Bounded because the failure mode of an unbounded scan is silently
    /// grabbing an unrelated number from later in a build log and treating it
    /// as a live process id. 40 characters covers every observed phrasing
    /// ("Process started with PID 41208", "PID: 41208", "pid=41208") with room
    /// to spare, and stops well short of the next sentence.
    private static let pidSearchWindow = 40

    static func processID(fromText text: String) -> String? {
        let lowered = text.lowercased()
        guard let marker = lowered.range(of: "pid") else { return nil }
        let window = lowered[marker.upperBound...].prefix(pidSearchWindow)
        // First run of digits inside the window.
        guard let firstDigit = window.firstIndex(where: \.isNumber) else { return nil }
        // Anything between the marker and the digits must be punctuation,
        // whitespace or letters — never another digit (already excluded) and
        // never a newline, which would mean the number belongs to a later line.
        let gap = window[window.startIndex..<firstDigit]
        if gap.contains("\n") { return nil }
        let digits = window[firstDigit...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }

    // MARK: Exit code

    static func exitCode(from result: MCPToolCall.Result) -> Int? {
        if let structured = result.structured?.objectValue {
            for key in ["exitCode", "exit_code", "returnCode", "return_code", "code", "status"] {
                if let v = structured[key]?.intValue { return v }
            }
        }
        return exitCode(fromText: result.text)
    }

    /// `Process exited with code 1`, `exit code: 1`, `return code -1073741819`.
    static func exitCode(fromText text: String) -> Int? {
        let lowered = text.lowercased()
        // Longest markers first: "exited with code" contains "code", and
        // matching the short one first would start the scan in the wrong place.
        for marker in ["exited with code", "exit code", "exitcode", "return code", "returncode"] {
            guard let r = lowered.range(of: marker) else { continue }
            let window = lowered[r.upperBound...].prefix(24)
            guard let start = window.firstIndex(where: { $0.isNumber || $0 == "-" }) else { continue }
            if window[window.startIndex..<start].contains("\n") { continue }
            let token = window[start...].prefix { $0.isNumber || $0 == "-" }
            if let code = Int(token) { return code }
        }
        return nil
    }

    // MARK: Liveness

    /// True when the endpoint says the process is still alive.
    ///
    /// Ordering matters: an explicit structured flag beats an explicit exit
    /// code, which beats prose. Prose is checked for "finished" phrasings
    /// before "running" ones because "the process is running in the background;
    /// it has now completed" is a real shape and the later clause is the
    /// authoritative one.
    static func isStillRunning(_ result: MCPToolCall.Result) -> Bool {
        if let structured = result.structured?.objectValue {
            for key in ["isRunning", "is_running", "running", "active"] {
                if let v = structured[key]?.boolValue { return v }
            }
            if exitCode(from: result) != nil { return false }
        }
        let lowered = result.text.lowercased()
        for marker in ["process exited", "has exited", "exited with", "process completed", "process finished"] {
            if lowered.contains(marker) { return false }
        }
        if exitCode(fromText: lowered) != nil { return false }
        for marker in ["still running", "is running", "running in the background", "process started"] {
            if lowered.contains(marker) { return true }
        }
        // Unknown. Reporting "not running" is the safer default: it ends the
        // call with whatever output arrived instead of polling a process that
        // may not exist until the caller's timeout expires.
        return false
    }
}

// MARK: - Output clipping

enum OutputClipper {

    /// Clip from the MIDDLE, not the end.
    ///
    /// The two informative parts of a long build log are the beginning (what
    /// was invoked, which config it picked up) and the end (the error and the
    /// summary line). Tail-truncation throws away the former; head-truncation
    /// throws away the latter, which is usually the thing the user asked about.
    /// Keeping both halves costs nothing and is what makes a truncated
    /// `npm test` result still actionable.
    static func clip(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard limit > 0 else { return ("", !text.isEmpty) }
        guard text.count > limit else { return (text, false) }
        let headLen = limit / 2
        let tailLen = limit - headLen
        let head = text.prefix(headLen)
        let tail = text.suffix(tailLen)
        let omitted = text.count - headLen - tailLen
        return (head + "\n… [\(omitted) characters omitted] …\n" + tail, true)
    }
}
