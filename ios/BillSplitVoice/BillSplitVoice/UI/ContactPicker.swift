import Contacts
import ContactsUI
import SwiftUI

@MainActor
final class DeviceContactsProvider: ObservableObject {
    @Published private(set) var names: [String] = []
    @Published private(set) var authorizationStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    private let store = CNContactStore()
    private var loaded = false

    func refreshIfNeeded() async {
        if loaded { return }
        await refresh()
    }

    func refresh() async {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

        if authorizationStatus == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                store.requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            authorizationStatus = granted ? .authorized : .denied
        }

        guard authorizationStatus == .authorized else {
            names = []
            loaded = true
            return
        }
        names = await Self.fetchContactNames()

        loaded = true
    }

    nonisolated private static func fetchContactNames() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactMiddleNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
            ]

            var collected: [String] = []
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .givenName

            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let parts = [
                        contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines),
                        contact.middleName.trimmingCharacters(in: .whitespacesAndNewlines),
                        contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines),
                    ].filter { !$0.isEmpty }

                    let fullName = parts.joined(separator: " ")
                    if !fullName.isEmpty {
                        collected.append(fullName)
                    } else {
                        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !nickname.isEmpty {
                            collected.append(nickname)
                        }
                    }
                }
                return collected.uniquedCaseInsensitive().sorted()
            } catch {
                return []
            }
        }.value
    }
}

struct ContactPicker: UIViewControllerRepresentable {
    var onPick: (String, String?) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPick: (String, String?) -> Void

        init(onPick: @escaping (String, String?) -> Void) {
            self.onPick = onPick
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Unknown"
            let phone = contact.phoneNumbers.first?.value.stringValue
            onPick(name, phone)
        }
    }
}

private extension Array where Element == String {
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
