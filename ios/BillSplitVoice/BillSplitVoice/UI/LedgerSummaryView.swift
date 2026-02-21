import SwiftUI

struct LedgerSummaryView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var paidPopup = false
    @State private var paidPopupMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section("People Who Owe Me") {
                    if store.owesMe.isEmpty {
                        Text("No one owes you right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.owesMe, id: \.person.id) { row in
                            HStack {
                                Text(row.person.name)
                                Spacer()
                                Text(row.amount, format: .currency(code: "USD"))
                                    .fontWeight(.semibold)
                                Button("Paid") {
                                    markPaid(personID: row.person.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section("People I Owe") {
                    if store.iOwe.isEmpty {
                        Text("You owe no one right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.iOwe, id: \.person.id) { row in
                            HStack {
                                Text(row.person.name)
                                Spacer()
                                Text(row.amount, format: .currency(code: "USD"))
                                    .fontWeight(.semibold)
                                Button("Paid") {
                                    markPaid(personID: row.person.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section("All Entries") {
                    if store.entries.isEmpty {
                        Text("No bill entries yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary(for: entry))
                                if !entry.note.isEmpty {
                                    Text(entry.note)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: store.removeEntries)
                    }
                }
            }
            .navigationTitle("BillSplit")
            .alert("Paid", isPresented: $paidPopup) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(paidPopupMessage)
            }
        }
    }

    private func summary(for entry: BillEntry) -> String {
        let creditor = store.person(for: entry.creditorID)?.name ?? "Unknown"
        let debtor = store.person(for: entry.debtorID)?.name ?? "Unknown"
        return "\(debtor) owes \(creditor) \(entry.amount.formatted(.currency(code: "USD")))"
    }

    private func markPaid(personID: UUID) {
        paidPopupMessage = store.settle(personID: personID)
        paidPopup = true
    }
}
