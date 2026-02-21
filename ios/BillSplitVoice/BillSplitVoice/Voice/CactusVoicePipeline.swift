import Foundation
import Speech

protocol CactusTranscribing {
    func transcribe(audioURL: URL) async -> String?
}

final class PlaceholderCactusTranscriber: CactusTranscribing {
    func transcribe(audioURL: URL) async -> String? {
        // Hook point for cactus_transcribe on iPhone. This placeholder keeps the app runnable.
        // Replace with Cactus SDK call when local model integration is available.
        return nil
    }
}

final class AppleSpeechTranscriber: CactusTranscribing {
    func transcribe(audioURL: URL) async -> String? {
        let authorized = await requestSpeechAuthorization()
        guard authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            return nil
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { continuation in
            var completed = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if completed {
                    return
                }
                if let result, result.isFinal {
                    completed = true
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    return
                }
                if error != nil {
                    completed = true
                    task?.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

final class HybridCactusTranscriber: CactusTranscribing {
    private let cactus: CactusTranscribing
    private let fallback: CactusTranscribing

    init(
        cactus: CactusTranscribing = PlaceholderCactusTranscriber(),
        fallback: CactusTranscribing = AppleSpeechTranscriber()
    ) {
        self.cactus = cactus
        self.fallback = fallback
    }

    func transcribe(audioURL: URL) async -> String? {
        if let cactusTranscript = await cactus.transcribe(audioURL: audioURL),
           !cactusTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cactusTranscript
        }
        return await fallback.transcribe(audioURL: audioURL)
    }
}

@MainActor
final class VoiceCommandPipeline: ObservableObject {
    @Published private(set) var lastRoute: ParseRoute = .onDevice
    @Published private(set) var lastReasonTags: [String] = []
    @Published private(set) var lastComplexityScore: Int = 0

    private let transcriber: CactusTranscribing
    private let complexityScorer: ComplexityScorer
    private let onDeviceParser: BillCommandParsing
    private let cloudParser: BillCommandParsing

    init(
        transcriber: CactusTranscribing = HybridCactusTranscriber(),
        complexityScorer: ComplexityScorer = ComplexityScorer(),
        onDeviceParser: BillCommandParsing = OnDeviceBillParser(),
        cloudParser: BillCommandParsing = CloudBillParser()
    ) {
        self.transcriber = transcriber
        self.complexityScorer = complexityScorer
        self.onDeviceParser = onDeviceParser
        self.cloudParser = cloudParser
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let transcript = await transcriber.transcribe(audioURL: audioURL),
              !transcript.isEmpty else {
            throw VoicePipelineError.transcriptionFailed
        }
        return transcript
    }

    func transcribeAndParse(audioURL: URL) async throws -> ParsedBillCommand {
        let transcript = try await transcribe(audioURL: audioURL)
        return try await parse(transcript: transcript)
    }

    func parse(transcript: String) async throws -> ParsedBillCommand {
        let complexity = complexityScorer.score(for: transcript)
        lastComplexityScore = complexity

        if let parsed = await onDeviceParser.parse(sentence: transcript) {
            lastRoute = .onDevice
            let tags = [
                "on_device_success",
                complexityScorer.shouldUseCloud(for: transcript) ? "complex_but_local_success" : "low_complexity",
            ]
            lastReasonTags = tags
            return ParsedBillCommand(
                creditorName: parsed.creditor,
                debtorName: parsed.debtor,
                amount: parsed.amount,
                note: parsed.note,
                decision: RouteDecision(route: .onDevice, reasonTags: tags, complexityScore: complexity),
                transcript: transcript
            )
        }

        if shouldUseCloudFallback(for: transcript),
           let parsed = await cloudParser.parse(sentence: transcript) {
            lastRoute = .cloud
            let tags = ["on_device_parse_failed", "complexity_triggered", "cloud_fallback_success"]
            lastReasonTags = tags
            return ParsedBillCommand(
                creditorName: parsed.creditor,
                debtorName: parsed.debtor,
                amount: parsed.amount,
                note: parsed.note,
                decision: RouteDecision(route: .cloud, reasonTags: tags, complexityScore: complexity),
                transcript: transcript
            )
        }

        lastRoute = .onDevice
        lastReasonTags = ["on_device_parse_failed", "fallback_not_triggered"]
        throw VoicePipelineError.parseFailed
    }

    private func shouldUseCloudFallback(for transcript: String) -> Bool {
        // Keep cloud usage rare: only for highly complex, long utterances.
        let words = transcript.split { !$0.isLetter && !$0.isNumber }.count
        let complex = complexityScorer.shouldUseCloud(for: transcript)
        let hasMultiClauseSignals = transcript.contains(",") || transcript.contains(";")
        return complex && words >= 20 && hasMultiClauseSignals
    }
}
