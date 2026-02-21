import Foundation

protocol BillCommandParsing {
    func parse(sentence: String) async -> (creditor: String, debtor: String, amount: Decimal, note: String)?
}

final class OnDeviceBillParser: BillCommandParsing {
    func parse(sentence: String) async -> (creditor: String, debtor: String, amount: Decimal, note: String)? {
        // Lightweight parsing strategy intended to emulate an on-device fast model.
        RuleBasedBillParser.parse(sentence: sentence, allowComplexPatterns: false)
    }
}

final class CloudBillParser: BillCommandParsing {
    func parse(sentence: String) async -> (creditor: String, debtor: String, amount: Decimal, note: String)? {
        // More permissive parsing strategy to emulate cloud fallback behavior.
        RuleBasedBillParser.parse(sentence: sentence, allowComplexPatterns: true)
    }
}

enum RuleBasedBillParser {
    static func parse(sentence: String, allowComplexPatterns: Bool) -> (creditor: String, debtor: String, amount: Decimal, note: String)? {
        let normalized = sentence
            .replacingOccurrences(of: "\\n", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        // Pattern: "Alice owes me 12.50 for lunch"
        if let match = match(lower, pattern: #"^([a-z ]+?)\s+owes\s+me\s+(?:(?:us)?\$|usd\s*)?([0-9]+(?:\.[0-9]{1,2})?)(?:\s+for\s+(.+))?$"#),
           let amount = Decimal(string: match[2]) {
            let debtor = match[1].trimmingCharacters(in: .whitespaces)
            guard isLikelyPersonName(debtor) else { return nil }
            return (creditor: "me", debtor: debtor, amount: amount, note: match[safe: 3] ?? "")
        }

        // Pattern: "I owe Alice 20"
        if let match = match(lower, pattern: #"^(?:i|me)\s+owe\s+([a-z ]+?)\s+(?:(?:us)?\$|usd\s*)?([0-9]+(?:\.[0-9]{1,2})?)(?:\s+for\s+(.+))?$"#),
           let amount = Decimal(string: match[2]) {
            let creditor = match[1].trimmingCharacters(in: .whitespaces)
            guard isLikelyPersonName(creditor) else { return nil }
            return (creditor: creditor, debtor: "me", amount: amount, note: match[safe: 3] ?? "")
        }

        // Pattern: "Add that Bob owes Alice 31 for dinner"
        if allowComplexPatterns,
           let match = match(lower, pattern: #".*?([a-z ]+?)\s+owes\s+([a-z ]+?)\s+(?:(?:us)?\$|usd\s*)?([0-9]+(?:\.[0-9]{1,2})?)(?:\s+for\s+(.+))?$"#),
           let amount = Decimal(string: match[3]) {
            let creditor = normalizePerson(match[2])
            let debtor = normalizePerson(match[1])
            guard isLikelyPersonName(creditor), isLikelyPersonName(debtor) else { return nil }
            return (
                creditor: creditor,
                debtor: debtor,
                amount: amount,
                note: match[safe: 4] ?? ""
            )
        }

        // Pattern: "Alice paid 42 for Bob"
        if let match = match(lower, pattern: #"^([a-z ]+?)\s+paid\s+(?:(?:us)?\$|usd\s*)?([0-9]+(?:\.[0-9]{1,2})?)(?:\s+for\s+([a-z ]+?))(?:\s+for\s+(.+))?$"#),
           let amount = Decimal(string: match[2]) {
            let note = match[safe: 4] ?? ""
            let creditor = normalizePerson(match[1])
            let debtor = normalizePerson(match[3])
            guard isLikelyPersonName(creditor), isLikelyPersonName(debtor) else { return nil }
            return (
                creditor: creditor,
                debtor: debtor,
                amount: amount,
                note: note
            )
        }

        return nil
    }

    private static func match(_ input: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let result = regex.firstMatch(in: input, options: [], range: range) else { return nil }
        return (0..<result.numberOfRanges).compactMap { idx in
            let r = result.range(at: idx)
            guard let range = Range(r, in: input) else { return nil }
            return String(input[range])
        }
    }

    private static func normalizePerson(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "i" || trimmed == "me" {
            return "me"
        }
        return trimmed
    }

    private static func isLikelyPersonName(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        if normalized == "me" || normalized == "i" {
            return true
        }
        if normalized.count > 24 { return false }
        let blocked = Set([
            "hi", "hello", "there", "yeah", "okay", "ok", "know", "that",
            "just", "please", "want", "with", "for", "thanks",
        ])
        let tokens = normalized.split(separator: " ")
        guard !tokens.isEmpty, tokens.count <= 3 else { return false }
        for token in tokens {
            let part = String(token)
            if blocked.contains(part) { return false }
            let valid = part.allSatisfy { char in
                char.isLetter || char == "'" || char == "-"
            }
            if !valid || part.count < 2 { return false }
        }
        return true
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
