import Foundation

enum ConversationResponse {
    case added(ParsedBillCommand, String)
    case ask(String)
    case info(String)
    case settle(targetName: String?)
}

struct AudioConversationResult {
    let transcript: String?
    let response: ConversationResponse
}

private enum MissingSlot {
    case amount
    case debtor
    case creditor
}

private enum DisambiguationSlot {
    case debtor
    case creditor
    case settleTarget
}

private enum NameResolution {
    case resolved(String)
    case ambiguous([String])
    case notFound
}

private struct BillDraft {
    var creditorName: String?
    var debtorName: String?
    var amount: Decimal?
    var note: String?

    var isComplete: Bool {
        creditorName != nil && debtorName != nil && amount != nil
    }
}

private struct PendingNameDisambiguation {
    var draft: BillDraft?
    let slot: DisambiguationSlot
    let rawName: String
    let options: [String]
}

private struct BalanceCommand {
    let creditorName: String
    let debtorName: String
    let amount: Decimal
}

@MainActor
final class BillConversationAgent: ObservableObject {
    private let pipeline: VoiceCommandPipeline
    private var pendingDraft: BillDraft?
    private var pendingDisambiguation: PendingNameDisambiguation?
    private var lastMentionedPerson: String?
    private var clarificationTurns = 0
    private let maxClarificationTurns = 3

    init(pipeline: VoiceCommandPipeline? = nil) {
        self.pipeline = pipeline ?? VoiceCommandPipeline()
    }

    func handleAudio(url: URL, knownContacts: [String]) async -> AudioConversationResult {
        do {
            let transcript = try await pipeline.transcribe(audioURL: url)
            let response = await handleUtterance(transcript, knownContacts: knownContacts)
            return AudioConversationResult(transcript: transcript, response: response)
        } catch {
            return AudioConversationResult(
                transcript: nil,
                response: .ask("I couldn't transcribe that clearly. Please say it again.")
            )
        }
    }

    func handleUtterance(_ text: String, knownContacts: [String]) async -> ConversationResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .ask("Tell me who owes whom and how much.")
        }

        if pendingDisambiguation != nil {
            return await resolvePendingDisambiguation(with: trimmed, knownContacts: knownContacts)
        }

        if let composite = handleCompositeBalanceUtterance(trimmed, knownContacts: knownContacts) {
            return composite
        }

        if isAcknowledgement(trimmed) {
            if let pendingDraft {
                let missing = missingSlots(for: pendingDraft)
                if missing.contains(.amount) {
                    return .ask("Got it. How much is it?")
                }
                if missing.contains(.debtor) {
                    return .ask("Got it. Who owes the money?")
                }
                if missing.contains(.creditor) {
                    return .ask("Got it. Who should receive the money?")
                }
            }
            return .ask("Tell me who owes whom and how much.")
        }

        if let settleIntent = parseSettleIntent(from: trimmed) {
            return handleSettleIntent(settleIntent, knownContacts: knownContacts)
        }

        if let direct = try? await pipeline.parse(transcript: trimmed), isValidParsedCommand(direct) {
            var draft = BillDraft(
                creditorName: direct.creditorName,
                debtorName: direct.debtorName,
                amount: direct.amount,
                note: direct.note
            )

            if let question = resolveNamesIfNeeded(draft: &draft, knownContacts: knownContacts) {
                pendingDraft = draft
                return .ask(question)
            }

            let resolved = ParsedBillCommand(
                creditorName: draft.creditorName ?? direct.creditorName,
                debtorName: draft.debtorName ?? direct.debtorName,
                amount: draft.amount ?? direct.amount,
                note: draft.note ?? direct.note,
                decision: direct.decision,
                transcript: direct.transcript
            )
            resetConversationState()
            return finalize(resolved)
        }

        var draft = pendingDraft ?? BillDraft()
        merge(into: &draft, from: extractDraft(from: trimmed))

        if draft.isComplete {
            return await finalizeDraft(draft, knownContacts: knownContacts)
        }

        if let amount = parseAmount(from: trimmed), draft.amount == nil {
            draft.amount = amount
        } else if let person = parseSinglePerson(from: trimmed) {
            if draft.debtorName == nil {
                draft.debtorName = person
            } else if draft.creditorName == nil {
                draft.creditorName = person
            }
        }

        if draft.isComplete {
            return await finalizeDraft(draft, knownContacts: knownContacts)
        }

        pendingDraft = draft
        let missing = missingSlots(for: draft)
        return nextClarification(for: missing)
    }

    private func handleSettleIntent(_ rawTarget: String?, knownContacts: [String]) -> ConversationResponse {
        resetConversationState()

        guard let rawTarget, !rawTarget.isEmpty else {
            return .settle(targetName: nil)
        }

        switch resolveName(rawTarget, knownContacts: knownContacts) {
        case .resolved(let name):
            return .settle(targetName: name)
        case .ambiguous(let options):
            pendingDisambiguation = PendingNameDisambiguation(
                draft: nil,
                slot: .settleTarget,
                rawName: rawTarget,
                options: options
            )
            return .ask(disambiguationQuestion(for: .settleTarget, rawName: rawTarget, options: options))
        case .notFound:
            return .ask(notFoundQuestion(for: .settleTarget, rawName: rawTarget))
        }
    }

    private func resolvePendingDisambiguation(with text: String, knownContacts: [String]) async -> ConversationResponse {
        guard let pendingDisambiguation else {
            return .ask("Please repeat that.")
        }

        if isRejection(text), pendingDisambiguation.options.count == 1 {
            return .ask("Okay, please say the contact name you want instead.")
        }

        let selected = selectOption(from: text, options: pendingDisambiguation.options)
        let customName = parseSinglePerson(from: text)
        let chosen = selected ?? customName

        guard let chosen else {
            return .ask(disambiguationQuestion(
                for: pendingDisambiguation.slot,
                rawName: pendingDisambiguation.rawName,
                options: pendingDisambiguation.options
            ))
        }

        self.pendingDisambiguation = nil

        switch pendingDisambiguation.slot {
        case .settleTarget:
            return .settle(targetName: chosen)
        case .debtor, .creditor:
            guard var draft = pendingDisambiguation.draft else {
                return .ask("Tell me who owes whom and how much.")
            }
            switch pendingDisambiguation.slot {
            case .debtor:
                draft.debtorName = chosen
            case .creditor:
                draft.creditorName = chosen
            case .settleTarget:
                break
            }
            pendingDraft = draft
            if draft.isComplete {
                return await finalizeDraft(draft, knownContacts: knownContacts)
            }
            return nextClarification(for: missingSlots(for: draft), incrementTurn: false)
        }
    }

    private func finalize(_ parsed: ParsedBillCommand) -> ConversationResponse {
        rememberPrimaryCounterparty(creditor: parsed.creditorName, debtor: parsed.debtorName)
        let message = "Added \(parsed.debtorName) owes \(parsed.creditorName) \(parsed.amount.formatted(.currency(code: "USD")))."
        return .added(parsed, message)
    }

    private func finalizeDraft(_ draft: BillDraft, knownContacts: [String]) async -> ConversationResponse {
        guard let creditor = draft.creditorName,
              let debtor = draft.debtorName,
              let amount = draft.amount else {
            return .ask("I still need more details.")
        }

        var resolvedDraft = BillDraft(
            creditorName: creditor,
            debtorName: debtor,
            amount: amount,
            note: draft.note
        )
        if let question = resolveNamesIfNeeded(draft: &resolvedDraft, knownContacts: knownContacts) {
            pendingDraft = resolvedDraft
            return .ask(question)
        }

        guard let resolvedCreditor = resolvedDraft.creditorName,
              let resolvedDebtor = resolvedDraft.debtorName,
              let resolvedAmount = resolvedDraft.amount else {
            return .ask("I still need more details.")
        }

        let canonical = "\(resolvedDebtor) owes \(resolvedCreditor) \(resolvedAmount)" + (resolvedDraft.note.map { " for \($0)" } ?? "")

        if let parsed = try? await pipeline.parse(transcript: canonical), isValidParsedCommand(parsed) {
            let withResolvedNames = ParsedBillCommand(
                creditorName: resolvedCreditor,
                debtorName: resolvedDebtor,
                amount: parsed.amount,
                note: parsed.note,
                decision: parsed.decision,
                transcript: parsed.transcript
            )
            resetConversationState()
            return finalize(withResolvedNames)
        }

        let fallback = ParsedBillCommand(
            creditorName: resolvedCreditor,
            debtorName: resolvedDebtor,
            amount: resolvedAmount,
            note: resolvedDraft.note ?? "",
            decision: RouteDecision(
                route: .onDevice,
                reasonTags: ["slot_fill_local_validation", "cloud_fallback_avoided"],
                complexityScore: pipeline.lastComplexityScore
            ),
            transcript: canonical
        )
        resetConversationState()
        return finalize(fallback)
    }

    private func resolveNamesIfNeeded(draft: inout BillDraft, knownContacts: [String]) -> String? {
        if let debtor = draft.debtorName {
            switch resolveName(debtor, knownContacts: knownContacts) {
            case .resolved(let value):
                draft.debtorName = value
            case .ambiguous(let options):
                pendingDisambiguation = PendingNameDisambiguation(
                    draft: draft,
                    slot: .debtor,
                    rawName: debtor,
                    options: options
                )
                return disambiguationQuestion(for: .debtor, rawName: debtor, options: options)
            case .notFound:
                return notFoundQuestion(for: .debtor, rawName: debtor)
            }
        }

        if let creditor = draft.creditorName {
            switch resolveName(creditor, knownContacts: knownContacts) {
            case .resolved(let value):
                draft.creditorName = value
            case .ambiguous(let options):
                pendingDisambiguation = PendingNameDisambiguation(
                    draft: draft,
                    slot: .creditor,
                    rawName: creditor,
                    options: options
                )
                return disambiguationQuestion(for: .creditor, rawName: creditor, options: options)
            case .notFound:
                return notFoundQuestion(for: .creditor, rawName: creditor)
            }
        }

        return nil
    }

    private func resolveName(_ rawName: String, knownContacts: [String]) -> NameResolution {
        let normalized = normalizePerson(rawName)
        let lower = normalized.lowercased()
        if lower == "me" {
            return .resolved("me")
        }

        let contacts = knownContacts
            .map(normalizePerson)
            .filter { !$0.isEmpty && $0.lowercased() != "me" }

        if contacts.isEmpty {
            // If contact access is unavailable, still allow free-form names.
            return .resolved(normalized)
        }

        if let exact = contacts.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return .resolved(exact)
        }

        let ranked = rankedCandidates(for: normalized, in: contacts)
        if !ranked.isEmpty {
            return .ambiguous(ranked)
        }
        return .notFound
    }

    private func disambiguationQuestion(for slot: DisambiguationSlot, rawName: String, options: [String]) -> String {
        let role: String
        switch slot {
        case .debtor:
            role = "debtor"
        case .creditor:
            role = "creditor"
        case .settleTarget:
            role = "person to settle with"
        }

        if options.count == 1, let only = options.first {
            return "I couldn't find an exact contact match for '\(rawName)'. Best match is \(only). Say yes to confirm or say another name."
        }

        let list = options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")
        return "I couldn't find an exact contact match for '\(rawName)' as the \(role). Best matches: \(list). Say the name or number."
    }

    private func notFoundQuestion(for slot: DisambiguationSlot, rawName: String) -> String {
        let role: String
        switch slot {
        case .debtor:
            role = "debtor"
        case .creditor:
            role = "creditor"
        case .settleTarget:
            role = "person to settle with"
        }
        return "I couldn't find a contact named '\(rawName)' for the \(role). Please say the exact contact name."
    }

    private func selectOption(from text: String, options: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if options.count == 1, isConfirmation(trimmed), let only = options.first {
            return only
        }

        if let number = Int(trimmed), number >= 1, number <= options.count {
            return options[number - 1]
        }

        let lower = trimmed.lowercased()
        if let exact = options.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }

        let candidates = options.filter { option in
            let optionLower = option.lowercased()
            return optionLower.contains(lower) || lower.contains(optionLower)
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        return nil
    }

    private func rankedCandidates(for rawName: String, in contacts: [String]) -> [String] {
        let query = rawName.lowercased()
        let scored = contacts.compactMap { name -> (String, Int)? in
            let candidate = name.lowercased()
            let first = candidate.split(separator: " ").first.map(String.init) ?? candidate
            let score: Int
            if candidate == query {
                score = 100
            } else if first == query {
                score = 90
            } else if candidate.hasPrefix(query + " ") {
                score = 85
            } else if candidate.contains(query) {
                score = 70
            } else if query.contains(first) {
                score = 55
            } else {
                score = 0
            }

            guard score > 0 else { return nil }
            return (name, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                return lhs.1 > rhs.1
            }
            .map(\.0)
            .uniquedCaseInsensitive()
            .prefix(3)
            .map { $0 }
    }

    private func parseSettleIntent(from text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let simple = Set(["paid", "mark paid", "settle", "settle up", "done settling"])
        if simple.contains(lower) {
            return ""
        }

        if let m = match(lower, pattern: #"^(?:paid|settle|settle up|mark paid)(?:\s+(?:with|to|for))?\s+([a-z][a-z '\-]+)$"#) {
            return normalizePerson(m[1])
        }
        if let m = match(lower, pattern: #"^(?:pay)\s+([a-z][a-z '\-]+)$"#) {
            return normalizePerson(m[1])
        }
        return nil
    }

    private func handleCompositeBalanceUtterance(_ text: String, knownContacts: [String]) -> ConversationResponse? {
        let commands = parseBalanceCommands(from: text)
        let lower = text.lowercased()
        let asksConsensus = lower.contains("consensus") || lower.contains("net") || lower.contains("settle up")
        let mentionsBalances = lower.contains("owe") || lower.contains("owes")

        if asksConsensus, commands.count < 2, mentionsBalances {
            if commands.count == 1 {
                return .ask("I only caught one side of that. Tell me the other amount too.")
            }
            return .ask("I heard a consensus question but missed the amounts. Please repeat both sides.")
        }
        guard !commands.isEmpty else { return nil }
        let compositeResolution = resolveCompositeNames(commands, knownContacts: knownContacts)
        if let question = compositeResolution.question {
            return .ask(question)
        }
        guard let resolvedCommands = compositeResolution.commands else { return nil }

        if asksConsensus || resolvedCommands.count > 1 {
            let summary = consensusSummary(commands: resolvedCommands)
            if asksConsensus {
                return .info(summary)
            }
            return .info("I heard multiple balances. \(summary)")
        }

        guard let only = resolvedCommands.first else { return nil }
        var draft = BillDraft(
            creditorName: only.creditorName,
            debtorName: only.debtorName,
            amount: only.amount,
            note: nil
        )
        if let question = resolveNamesIfNeeded(draft: &draft, knownContacts: knownContacts) {
            pendingDraft = draft
            return .ask(question)
        }
        guard let creditor = draft.creditorName, let debtor = draft.debtorName, let amount = draft.amount else {
            return nil
        }

        let parsed = ParsedBillCommand(
            creditorName: creditor,
            debtorName: debtor,
            amount: amount,
            note: "",
            decision: RouteDecision(
                route: .onDevice,
                reasonTags: ["local_multi_clause_parse"],
                complexityScore: pipeline.lastComplexityScore
            ),
            transcript: text
        )
        resetConversationState()
        return finalize(parsed)
    }

    private func resolveCompositeNames(
        _ commands: [BalanceCommand],
        knownContacts: [String]
    ) -> (commands: [BalanceCommand]?, question: String?) {
        var output: [BalanceCommand] = []

        for command in commands {
            var creditor = command.creditorName
            var debtor = command.debtorName

            if creditor.caseInsensitiveCompare("me") != .orderedSame {
                switch resolveName(creditor, knownContacts: knownContacts) {
                case .resolved(let value):
                    creditor = value
                case .ambiguous(let options):
                    let list = options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")
                    return (nil, "I couldn't find an exact contact match for '\(creditor)'. Best matches: \(list). Please repeat with one of these names.")
                case .notFound:
                    return (nil, "I couldn't find a contact named '\(creditor)'. Please repeat with the exact contact name.")
                }
            }

            if debtor.caseInsensitiveCompare("me") != .orderedSame {
                switch resolveName(debtor, knownContacts: knownContacts) {
                case .resolved(let value):
                    debtor = value
                case .ambiguous(let options):
                    let list = options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")
                    return (nil, "I couldn't find an exact contact match for '\(debtor)'. Best matches: \(list). Please repeat with one of these names.")
                case .notFound:
                    return (nil, "I couldn't find a contact named '\(debtor)'. Please repeat with the exact contact name.")
                }
            }

            output.append(BalanceCommand(creditorName: creditor, debtorName: debtor, amount: command.amount))
        }

        return (output, nil)
    }

    private func parseBalanceCommands(from text: String) -> [BalanceCommand] {
        let lower = sanitizeForBalanceParsing(text.lowercased())
        var results: [BalanceCommand] = []
        var recentPerson = lastMentionedPerson

        for clause in splitBalanceClauses(lower) {
            guard let amount = parseFlexibleAmount(from: clause) else { continue }

            if let owesMe = match(clause, pattern: #"^([a-z][a-z '\-]{1,40}?)\s+owes\s+me\b"#),
               let debtorRaw = owesMe[safe: 1],
               let debtor = resolveReferenceName(debtorRaw, recentPerson: recentPerson), !debtor.isEmpty {
                recentPerson = debtor
                results.append(BalanceCommand(creditorName: "me", debtorName: debtor, amount: amount))
                continue
            }

            if let iOwe = match(clause, pattern: #"\b(?:i|me)(?:\s+(?:also|still|just))?\s+owe\s+(him|her|them|[a-z][a-z '\-]{1,40})\b"#),
               let creditorRaw = iOwe[safe: 1],
               let creditor = resolveReferenceName(creditorRaw, recentPerson: recentPerson), !creditor.isEmpty {
                recentPerson = creditor
                results.append(BalanceCommand(creditorName: creditor, debtorName: "me", amount: amount))
                continue
            }
        }

        if let recentPerson {
            lastMentionedPerson = recentPerson
        }
        return results
    }

    private func sanitizeForBalanceParsing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitBalanceClauses(_ text: String) -> [String] {
        let withBreaks = text
            .replacingOccurrences(of: #"[;,]"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(and|but|then|while|so)\b"#, with: " | ", options: .regularExpression)
        return withBreaks
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: #"^(?:uh|um|well|okay|ok|like)\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    private func resolveReferenceName(_ raw: String, recentPerson: String?) -> String? {
        let normalized = normalizePerson(raw)
        let lower = normalized.lowercased()
        if ["him", "her", "them"].contains(lower) {
            return recentPerson ?? lastMentionedPerson
        }
        return normalized
    }

    private func consensusSummary(commands: [BalanceCommand]) -> String {
        var balances: [String: Decimal] = [:]
        for command in commands {
            if command.creditorName.caseInsensitiveCompare("me") == .orderedSame {
                balances[command.debtorName, default: .zero] += command.amount
            } else if command.debtorName.caseInsensitiveCompare("me") == .orderedSame {
                balances[command.creditorName, default: .zero] -= command.amount
            }
        }

        guard !balances.isEmpty else {
            return "I couldn't compute a net balance from that."
        }

        let lines = balances
            .map { key, value -> String in
                if value > .zero {
                    return "\(key) owes you \(value.formatted(.currency(code: "USD")))"
                }
                if value < .zero {
                    return "You owe \(key) \((-value).formatted(.currency(code: "USD")))"
                }
                return "You and \(key) are settled up"
            }
            .sorted()

        return "Consensus: " + lines.joined(separator: ". ") + "."
    }

    private func extractDraft(from text: String) -> BillDraft {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let m = match(lower, pattern: #"^([a-z ]+?)\s+owes\s+(me|[a-z ]+?)(?:\s+\$?([0-9]+(?:\.[0-9]{1,2})?))?(?:\s+for\s+(.+))?$"#) {
            return BillDraft(
                creditorName: normalizePerson(m[2]),
                debtorName: normalizePerson(m[1]),
                amount: m[safe: 3].flatMap { Decimal(string: $0) },
                note: m[safe: 4]
            )
        }

        if let m = match(lower, pattern: #"^(?:i|me)\s+owe\s+([a-z ]+?)(?:\s+\$?([0-9]+(?:\.[0-9]{1,2})?))?(?:\s+for\s+(.+))?$"#) {
            return BillDraft(
                creditorName: normalizePerson(m[1]),
                debtorName: "me",
                amount: m[safe: 2].flatMap { Decimal(string: $0) },
                note: m[safe: 3]
            )
        }

        if let m = match(lower, pattern: #"^([a-z ]+?)\s+paid(?:\s+\$?([0-9]+(?:\.[0-9]{1,2})?))?(?:\s+for\s+([a-z ]+?))?(?:\s+for\s+(.+))?$"#) {
            return BillDraft(
                creditorName: normalizePerson(m[1]),
                debtorName: m[safe: 3].map(normalizePerson),
                amount: m[safe: 2].flatMap { Decimal(string: $0) },
                note: m[safe: 4]
            )
        }

        return BillDraft(amount: parseAmount(from: lower), note: nil)
    }

    private func merge(into base: inout BillDraft, from update: BillDraft) {
        if base.creditorName == nil, let name = update.creditorName {
            base.creditorName = name
        }
        if base.debtorName == nil, let name = update.debtorName {
            base.debtorName = name
        }
        if base.amount == nil, let amount = update.amount {
            base.amount = amount
        }
        if base.note == nil, let note = update.note, !note.isEmpty {
            base.note = note
        }
    }

    private func missingSlots(for draft: BillDraft) -> [MissingSlot] {
        var missing: [MissingSlot] = []
        if draft.amount == nil { missing.append(.amount) }
        if draft.debtorName == nil { missing.append(.debtor) }
        if draft.creditorName == nil { missing.append(.creditor) }
        return missing
    }

    private func nextClarification(for missing: [MissingSlot], incrementTurn: Bool = true) -> ConversationResponse {
        if incrementTurn {
            clarificationTurns += 1
        }

        guard clarificationTurns <= maxClarificationTurns else {
            let reminder = "I still need missing details. Let's restart. Say: Alice owes me 12.50 for lunch."
            resetConversationState()
            return .info(reminder)
        }

        if missing.contains(.amount) {
            return .ask("How much is it?")
        }
        if missing.contains(.debtor) {
            return .ask("Who owes the money?")
        }
        if missing.contains(.creditor) {
            return .ask("Who should receive the money?")
        }
        return .ask("Anything else to add?")
    }

    private func parseAmount(from text: String) -> Decimal? {
        if let numeric = parseFlexibleAmount(from: text) {
            return numeric
        }

        guard let regex = try? NSRegularExpression(pattern: #"(?:(?:us)?\$|usd\s*)?([0-9]+(?:\.[0-9]{1,2})?)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Decimal(string: String(text[valueRange]))
    }

    private func parseFlexibleAmount(from text: String) -> Decimal? {
        if let direct = parseNumericAmount(from: text) {
            return direct
        }
        return parseWordAmount(from: text)
    }

    private func parseNumericAmount(from text: String) -> Decimal? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:(?:us)?\$|usd\s*)?([0-9]+(?:\.[0-9]{1,2})?)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Decimal(string: String(text[valueRange]))
    }

    private func parseWordAmount(from text: String) -> Decimal? {
        let words = text
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        let units: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
            "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ]
        let tens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]

        var found = false
        var total = 0
        var current = 0

        for word in words {
            if let unit = units[word] {
                current += unit
                found = true
                continue
            }
            if let ten = tens[word] {
                current += ten
                found = true
                continue
            }
            if word == "hundred", current > 0 {
                current *= 100
                found = true
                continue
            }
            if word == "thousand", current > 0 {
                total += current * 1000
                current = 0
                found = true
                continue
            }
            if found {
                break
            }
        }

        let value = total + current
        return found && value > 0 ? Decimal(value) : nil
    }

    private func parseSinglePerson(from text: String) -> String? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered == "me" || lowered == "i" {
            return "me"
        }
        if ["him", "her", "them"].contains(lowered), let lastMentionedPerson {
            return lastMentionedPerson
        }
        if isAcknowledgement(lowered) || isRejection(lowered) {
            return nil
        }
        let tokens = lowered.split(separator: " ")
        guard tokens.count <= 3, tokens.allSatisfy({ token in token.allSatisfy({ $0.isLetter }) }) else {
            return nil
        }
        return normalizePerson(lowered)
    }

    private func normalizePerson(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        if cleaned.isEmpty { return "" }
        let lower = cleaned.lowercased()
        if lower == "i" || lower == "me" {
            return "me"
        }
        if ["him", "her", "them"].contains(lower), let lastMentionedPerson {
            return lastMentionedPerson
        }
        return cleaned.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }

    private func isValidParsedCommand(_ parsed: ParsedBillCommand) -> Bool {
        guard parsed.amount > .zero else { return false }
        guard isLikelyPersonName(parsed.creditorName), isLikelyPersonName(parsed.debtorName) else {
            return false
        }
        return parsed.creditorName.lowercased() != parsed.debtorName.lowercased()
    }

    private func rememberPrimaryCounterparty(creditor: String, debtor: String) {
        if creditor.caseInsensitiveCompare("me") == .orderedSame {
            lastMentionedPerson = debtor
        } else if debtor.caseInsensitiveCompare("me") == .orderedSame {
            lastMentionedPerson = creditor
        } else {
            lastMentionedPerson = debtor
        }
    }

    private func isLikelyPersonName(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)

        if normalized == "me" || normalized == "i" {
            return true
        }

        let blocked = Set([
            "hi", "hello", "there", "yeah", "okay", "ok", "know", "that",
            "just", "please", "want", "with", "for", "thanks", "thank you",
        ])
        let tokens = normalized.split(separator: " ")
        guard !tokens.isEmpty, tokens.count <= 3 else { return false }
        if normalized.count > 24 { return false }

        for token in tokens {
            let part = String(token)
            if blocked.contains(part) { return false }
            let validCharacters = part.allSatisfy { char in
                char.isLetter || char == "'" || char == "-"
            }
            if !validCharacters || part.count < 2 {
                return false
            }
        }
        return true
    }

    private func isAcknowledgement(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "ok", "okay", "k", "sure", "yes", "yep", "yeah", "alright", "got it",
        ].contains(normalized)
    }

    private func isConfirmation(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["yes", "y", "yeah", "yep", "ok", "okay", "correct"].contains(normalized)
    }

    private func isRejection(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["no", "nope", "nah", "wrong"].contains(normalized)
    }

    private func resetConversationState() {
        pendingDraft = nil
        pendingDisambiguation = nil
        clarificationTurns = 0
    }

    private func match(_ input: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let result = regex.firstMatch(in: input, options: [], range: range) else {
            return nil
        }
        return (0..<result.numberOfRanges).compactMap { idx in
            let capture = result.range(at: idx)
            guard let r = Range(capture, in: input) else { return nil }
            return String(input[r])
        }
    }

    private func matches(_ input: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let all = regex.matches(in: input, options: [], range: range)
        return all.map { result in
            (0..<result.numberOfRanges).compactMap { idx in
                let capture = result.range(at: idx)
                guard let r = Range(capture, in: input) else { return nil }
                return String(input[r])
            }
        }
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }

    func uniquedCaseInsensitive() -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in self {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                output.append(value)
            }
        }
        return output
    }
}
