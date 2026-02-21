import Foundation

struct Person: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var phoneNumber: String?

    init(id: UUID = UUID(), name: String, phoneNumber: String? = nil) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
    }
}

struct BillEntry: Codable, Hashable, Identifiable {
    let id: UUID
    let creditorID: UUID
    let debtorID: UUID
    let amount: Decimal
    let note: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        creditorID: UUID,
        debtorID: UUID,
        amount: Decimal,
        note: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.creditorID = creditorID
        self.debtorID = debtorID
        self.amount = amount
        self.note = note
        self.createdAt = createdAt
    }
}

struct LedgerSnapshot: Codable {
    var people: [Person]
    var entries: [BillEntry]
}

enum BillValidationError: LocalizedError {
    case missingPerson
    case invalidAmount
    case samePerson

    var errorDescription: String? {
        switch self {
        case .missingPerson:
            return "Choose both payer and debtor."
        case .invalidAmount:
            return "Enter a valid amount greater than 0."
        case .samePerson:
            return "Payer and debtor cannot be the same person."
        }
    }
}
