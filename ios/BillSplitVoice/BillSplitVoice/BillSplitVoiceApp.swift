import SwiftUI

@main
struct BillSplitVoiceApp: App {
    @StateObject private var store = LedgerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
