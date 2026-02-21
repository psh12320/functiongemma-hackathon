import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LedgerSummaryView()
                .tabItem {
                    Label("Summary", systemImage: "list.bullet.rectangle")
                }

            AddEntryView()
                .tabItem {
                    Label("Add", systemImage: "plus.circle")
                }

            VoiceCaptureView()
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }
        }
    }
}
