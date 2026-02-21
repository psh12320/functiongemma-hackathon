import Foundation

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var people: [Person]
    @Published private(set) var entries: [BillEntry]

    let me: Person

    init() {
        self.me = Person(id: UUID(uuidString: "C0C7B3E2-2A6A-4C7A-A653-E8A2A92D52B0")!, name: "Me")
        self.people = [me]
        self.entries = []
        load()
    }

    func addPersonIfMissing(name: String, phoneNumber: String?) -> Person {
        if let existing = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let person = Person(name: name, phoneNumber: phoneNumber)
        people.append(person)
        persist()
        return person
    }

    func person(for id: UUID) -> Person? {
        people.first(where: { $0.id == id })
    }

    func addEntry(
        creditorID: UUID?,
        debtorID: UUID?,
        amountString: String,
        note: String
    ) throws {
        guard let creditorID, let debtorID else {
            throw BillValidationError.missingPerson
        }
        guard creditorID != debtorID else {
            throw BillValidationError.samePerson
        }
        guard let amount = Decimal(string: amountString), amount > .zero else {
            throw BillValidationError.invalidAmount
        }

        entries.insert(
            BillEntry(
                creditorID: creditorID,
                debtorID: debtorID,
                amount: amount,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            at: 0
        )
        persist()
    }

    func addParsedEntry(creditorName: String, debtorName: String, amount: Decimal, note: String) {
        let creditor = creditorName.caseInsensitiveCompare("me") == .orderedSame
            ? me
            : addPersonIfMissing(name: creditorName, phoneNumber: nil)
        let debtor = debtorName.caseInsensitiveCompare("me") == .orderedSame
            ? me
            : addPersonIfMissing(name: debtorName, phoneNumber: nil)

        guard creditor.id != debtor.id else { return }

        entries.insert(
            BillEntry(creditorID: creditor.id, debtorID: debtor.id, amount: amount, note: note),
            at: 0
        )
        persist()
    }

    var owesMe: [(person: Person, amount: Decimal)] {
        let grouped = entries.reduce(into: [UUID: Decimal]()) { partial, entry in
            if entry.creditorID == me.id {
                partial[entry.debtorID, default: .zero] += entry.amount
            }
        }
        return grouped.compactMap { key, value in
            guard let person = person(for: key) else { return nil }
            return (person: person, amount: value)
        }
        .sorted { $0.amount > $1.amount }
    }

    var iOwe: [(person: Person, amount: Decimal)] {
        let grouped = entries.reduce(into: [UUID: Decimal]()) { partial, entry in
            if entry.debtorID == me.id {
                partial[entry.creditorID, default: .zero] += entry.amount
            }
        }
        return grouped.compactMap { key, value in
            guard let person = person(for: key) else { return nil }
            return (person: person, amount: value)
        }
        .sorted { $0.amount > $1.amount }
    }

    func settle(targetName: String?) -> String {
        if let targetName = targetName?.trimmingCharacters(in: .whitespacesAndNewlines), !targetName.isEmpty {
            if let person = people.first(where: { $0.name.caseInsensitiveCompare(targetName) == .orderedSame }) {
                return settle(personID: person.id)
            }
            return "No open balance found for \(targetName)."
        }

        if let outgoing = iOwe.first {
            return settle(personID: outgoing.person.id)
        }
        if let incoming = owesMe.first {
            return settle(personID: incoming.person.id)
        }
        return "No balances to settle right now."
    }

    func settle(personID: UUID) -> String {
        guard let person = person(for: personID) else {
            return "No open balance found."
        }

        let related = entries.filter {
            ($0.creditorID == me.id && $0.debtorID == personID) ||
            ($0.debtorID == me.id && $0.creditorID == personID)
        }
        guard !related.isEmpty else {
            return "No open balance found for \(person.name)."
        }

        let youAreOwed = related.reduce(Decimal.zero) { total, entry in
            entry.creditorID == me.id ? total + entry.amount : total
        }
        let youOwe = related.reduce(Decimal.zero) { total, entry in
            entry.debtorID == me.id ? total + entry.amount : total
        }

        entries.removeAll {
            ($0.creditorID == me.id && $0.debtorID == personID) ||
            ($0.debtorID == me.id && $0.creditorID == personID)
        }
        persist()

        if youOwe > youAreOwed {
            let net = youOwe - youAreOwed
            return "Paid: settled with \(person.name). Net paid \(net.formatted(.currency(code: "USD")))."
        }
        if youAreOwed > youOwe {
            let net = youAreOwed - youOwe
            return "Paid: settled with \(person.name). Net received \(net.formatted(.currency(code: "USD")))."
        }
        return "Paid: settled all balances with \(person.name)."
    }

    func removeEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        let snapshot = LedgerSnapshot(people: people, entries: entries)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to persist ledger: \(error)")
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
            var loadedPeople = snapshot.people
            if !loadedPeople.contains(where: { $0.id == me.id }) {
                loadedPeople.insert(me, at: 0)
            }
            self.people = loadedPeople
            self.entries = snapshot.entries
        } catch {
            self.people = [me]
            self.entries = []
        }
    }

    private var fileURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("bill_split_ledger.json")
    }
}
