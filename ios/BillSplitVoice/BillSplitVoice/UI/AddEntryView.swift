import SwiftUI

struct AddEntryView: View {
    @EnvironmentObject private var store: LedgerStore

    @State private var selectedCreditorID: UUID?
    @State private var selectedDebtorID: UUID?
    @State private var amount = ""
    @State private var note = ""
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showingContactPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("People") {
                    Picker("Who paid?", selection: $selectedCreditorID) {
                        Text("Select").tag(nil as UUID?)
                        ForEach(store.people) { person in
                            Text(person.name).tag(Optional(person.id))
                        }
                    }

                    Picker("Who owes?", selection: $selectedDebtorID) {
                        Text("Select").tag(nil as UUID?)
                        ForEach(store.people) { person in
                            Text(person.name).tag(Optional(person.id))
                        }
                    }

                    Button("Choose Contact") {
                        showingContactPicker = true
                    }
                }

                Section("Amount") {
                    TextField("Amount in USD", text: $amount)
                        .keyboardType(.decimalPad)
                    TextField("Note (optional)", text: $note)
                }

                Section {
                    Button("Save Entry") {
                        save()
                    }
                }
            }
            .navigationTitle("Add Bill")
            .sheet(isPresented: $showingContactPicker) {
                ContactPicker { name, phone in
                    _ = store.addPersonIfMissing(name: name, phoneNumber: phone)
                }
            }
            .alert("Could not save", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                selectedCreditorID = store.me.id
            }
        }
    }

    private func save() {
        do {
            try store.addEntry(
                creditorID: selectedCreditorID,
                debtorID: selectedDebtorID,
                amountString: amount,
                note: note
            )
            amount = ""
            note = ""
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
