import Foundation

struct ComplexityScorer {
    private let threshold = 26

    func score(for sentence: String) -> Int {
        let lower = sentence.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let conjunctions = ["and", "then", "after", "also", "while"].reduce(into: 0) { count, token in
            count += lower.components(separatedBy: token).count - 1
        }
        let punctuation = lower.filter { ",;:".contains($0) }.count
        return words.count + conjunctions * 4 + punctuation * 2
    }

    func shouldUseCloud(for sentence: String) -> Bool {
        score(for: sentence) >= threshold
    }
}
