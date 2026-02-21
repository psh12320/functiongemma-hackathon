import Foundation

enum ParseRoute: String {
    case onDevice = "on-device"
    case cloud = "cloud-fallback"
}

struct RouteDecision {
    let route: ParseRoute
    let reasonTags: [String]
    let complexityScore: Int
}

struct ParsedBillCommand {
    let creditorName: String
    let debtorName: String
    let amount: Decimal
    let note: String
    let decision: RouteDecision
    let transcript: String
}

enum VoicePipelineError: LocalizedError {
    case transcriptionFailed
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed:
            return "Could not transcribe audio with Cactus."
        case .parseFailed:
            return "Could not parse the sentence into a bill command."
        }
    }
}
