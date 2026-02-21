# BillSplitVoice (iPhone)

This is a native SwiftUI iOS app for bill splitting with:
- contact selection
- local ledger of who owes whom
- summary views for `who owes me` and `who I owe`
- voice command flow with on-device-first parsing and cloud fallback for complex sentences

## Cactus integration note

`VoiceCommandPipeline` is wired for Cactus-style routing:
- `transcribeAndParse(audioURL:)` expects `cactus_transcribe` via `CactusTranscribing`
- routing is controlled by `ComplexityScorer`
- if transcript complexity is high, parser routes to cloud fallback (`CloudBillParser`)

To connect production Cactus runtime, replace `PlaceholderCactusTranscriber` in:
- `BillSplitVoice/Voice/CactusVoicePipeline.swift`

## Build on iPhone

1. Open `/Users/shricharan/projects/testing_hackathon/functiongemma-hackathon/ios/BillSplitVoice/BillSplitVoice.xcodeproj`
2. Select the `BillSplitVoice` scheme.
3. Choose an iPhone simulator or a physical iPhone destination.
4. Build and run.

## README.md alignment

This app follows the repository README goals by implementing:
- on-device first strategy
- cloud fallback strategy for complex requests
- voice-to-action workflow design

If you also want leaderboard submission for this repo, keep `main.py` interface compatible and submit via `python submit.py`.
