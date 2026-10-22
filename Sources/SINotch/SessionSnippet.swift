import Foundation

/// Small local display excerpts. Raw transcripts and tool output are never retained.
enum SessionSnippet {
    // Streaming snapshots sanitize many small strings. Compile the fixed
    // redaction rules once; NSRegularExpression supports concurrent matching.
    private static let redactions: [(NSRegularExpression, String)] = [
            ("\u{001B}\\[[0-?]*[ -/]*[@-~]", ""),
            ("-----BEGIN [^-]*PRIVATE KEY-----[\\s\\S]*", "[redacted]"),
            ("\\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16})\\b", "[redacted]"),
            ("(?i)\\b(bearer\\s+)[A-Za-z0-9._~+/-]+=*", "$1[redacted]"),
            ("(?i)(--(?:api[_-]?key|access[_-]?token|token|password|secret)(?:=|\\s+))(?:\"[^\"]*\"|'[^']*'|[^\\s;]+)", "$1[redacted]"),
            ("(?i)\\b([\\w-]*(?:api[_-]?key|access[_-]?token|token|password|secret)\\s*[:=]\\s*)(?:\"[^\"]*\"|'[^']*')", "$1[redacted]"),
            ("(?i)\\b((?:api[_-]?key|access[_-]?token|token|password|secret)\\s*[:=]\\s*)[^\\s,;]+", "$1[redacted]")
        ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func text(_ value: Any?, limit: Int = 1200) -> String? {
        guard let raw = value as? String else { return nil }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<send_user_message_question_reply>") { return nil }
        var text = String(raw.prefix(max(8192, min(65536, limit * 2))))
        for (expression, replacement) in redactions {
            text = expression.stringByReplacingMatches(in: text,
                range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func message(_ content: Any?, limit: Int = 1200) -> String? {
        if let string = content as? String { return text(string, limit: limit) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return text(blocks.prefix(16).compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return (block["text"] as? String).map { String($0.prefix(max(4096, limit))) }
        }.joined(separator: "\n"), limit: limit)
    }
}
