import Foundation

/// CSV import/export for glossaries. Columns:
/// original, preferred, alternatives (|-separated), character (yes/no), honorifics, notes, case_sensitive (yes/no)
public enum GlossaryIO {
    public static let header = ["original", "preferred", "alternatives", "character", "honorifics", "notes", "case_sensitive"]

    public static func csv(_ entries: [GlossaryEntry]) -> String {
        var rows = [header.joined(separator: ",")]
        for e in entries {
            rows.append([e.original, e.preferred, e.alternatives.joined(separator: "|"), e.isCharacterName ? "yes" : "no",
                         e.honorificRule, e.notes, e.caseSensitive ? "yes" : "no"].map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// RFC 4180-style parser (quoted fields, escaped quotes, embedded newlines).
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < it.count && it[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        it.removeAll()
        return rows
    }

    public static func parseCSV(_ text: String) -> [GlossaryEntry] {
        var rs = rows(text)
        guard !rs.isEmpty else { return [] }
        let first = rs[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        var idx: [String: Int] = [:]
        if first.contains("original") { for (i, h) in first.enumerated() { idx[h] = i }; rs.removeFirst() }
        else { for (i, h) in header.enumerated() { idx[h] = i } }
        func get(_ r: [String], _ k: String) -> String { idx[k].flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
        let yes: (String) -> Bool = { ["yes", "true", "1", "y"].contains($0.lowercased()) }
        return rs.compactMap { r in
            let o = get(r, "original"), p = get(r, "preferred")
            guard !o.isEmpty else { return nil }
            return GlossaryEntry(original: o, preferred: p,
                                 alternatives: get(r, "alternatives").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                 isCharacterName: yes(get(r, "character")), honorificRule: get(r, "honorifics"),
                                 notes: get(r, "notes"), caseSensitive: yes(get(r, "case_sensitive")))
        }
    }
}
