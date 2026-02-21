import SwiftUI

private enum ChatSpeaker {
    case user
    case assistant
}

private struct ChatLine: Identifiable {
    let id = UUID()
    let speaker: ChatSpeaker
    let text: String
}

private struct ChatBubble: View {
    let line: ChatLine

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if line.speaker == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }

            Text(line.text)
                .font(.body)
                .foregroundColor(line.speaker == .assistant ? Color.primary : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 280, alignment: .leading)
                .background(line.speaker == .assistant ? Color(.secondarySystemBackground) : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if line.speaker == .user {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: line.speaker == .assistant ? .leading : .trailing)
    }
}

struct VoiceCaptureView: View {
    @EnvironmentObject private var store: LedgerStore
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var agent = BillConversationAgent()
    @StateObject private var speechOutput = SpeechOutput()
    @StateObject private var contactsProvider = DeviceContactsProvider()

    @State private var typedInput = ""
    @State private var statusMessage = "Ready"
    @State private var working = false
    @State private var paidPopup = false
    @State private var paidPopupMessage = ""
    @State private var chat: [ChatLine] = [
        ChatLine(
            speaker: .assistant,
            text: "Tell me a bill command. Example: Alice owes me 12.50 for lunch."
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    voiceControlCard
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    Divider()
                        .padding(.top, 12)

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(chat) { line in
                                ChatBubble(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 18)
                    }
                }
                .background(Color(.systemBackground))
                .safeAreaInset(edge: .bottom) {
                    composer
                }
                .navigationTitle("Voice")
                .alert("Paid", isPresented: $paidPopup) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(paidPopupMessage)
                }
                .task {
                    await contactsProvider.refreshIfNeeded()
                }
                .onChange(of: chat.count) { _, _ in
                    if let last = chat.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var voiceControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task { await handleVoiceButtonTap() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        Text(recorder.isRecording ? "Stop & Process" : "Tap to Speak")
                    }
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .blue)
                .disabled(working)

                Spacer()
            }

            Text(recorder.isRecording ? "Listening..." : statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type your reply", text: $typedInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task { await sendTypedReply() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    private func handleVoiceButtonTap() async {
        if recorder.isRecording {
            recorder.stop()
            guard let url = recorder.lastRecordingURL else {
                statusMessage = "No recording found."
                return
            }

            working = true
            defer { working = false }
            await contactsProvider.refreshIfNeeded()
            let turn = await agent.handleAudio(url: url, knownContacts: knownContactNames)

            if let transcript = turn.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                chat.append(ChatLine(speaker: .user, text: transcript))
            }

            apply(turn.response)
            return
        }

        let granted = await recorder.requestPermission()
        guard granted else {
            statusMessage = "Microphone permission is required."
            return
        }

        do {
            speechOutput.stop()
            try recorder.start()
            statusMessage = "Listening... tap again to stop and process."
        } catch {
            statusMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func sendTypedReply() async {
        let userText = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        typedInput = ""
        chat.append(ChatLine(speaker: .user, text: userText))

        working = true
        defer { working = false }

        await contactsProvider.refreshIfNeeded()
        let response = await agent.handleUtterance(userText, knownContacts: knownContactNames)
        apply(response)
    }

    private func apply(_ response: ConversationResponse) {
        switch response {
        case .added(let parsed, let message):
            store.addParsedEntry(
                creditorName: parsed.creditorName,
                debtorName: parsed.debtorName,
                amount: parsed.amount,
                note: parsed.note
            )
            statusMessage = message
            print("[HybridRouting] route=\(parsed.decision.route.rawValue) tags=\(parsed.decision.reasonTags.joined(separator: ",")) complexity=\(parsed.decision.complexityScore)")
            chat.append(ChatLine(speaker: .assistant, text: message))
            speechOutput.speak(message)

        case .ask(let question):
            statusMessage = question
            chat.append(ChatLine(speaker: .assistant, text: question))
            speechOutput.speak(question)

        case .info(let message):
            statusMessage = message
            chat.append(ChatLine(speaker: .assistant, text: message))
            speechOutput.speak(message)

        case .settle(let targetName):
            let message = store.settle(targetName: targetName)
            statusMessage = message
            paidPopupMessage = message
            paidPopup = true
            print("[HybridRouting] route=on-device tags=settle_ledger_mutation complexity=0")
            chat.append(ChatLine(speaker: .assistant, text: message))
            speechOutput.speak(message)
        }
    }

    private var knownContactNames: [String] {
        (store.people.map(\.name) + contactsProvider.names)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .uniquedCaseInsensitive()
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
