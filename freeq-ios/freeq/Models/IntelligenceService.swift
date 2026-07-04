import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence — private by design, which is exactly freeq's
/// ethos. Summaries and suggested replies run through the system model *on the
/// device*; no message ever leaves the phone for inference. Everything is gated
/// on iOS 26 + live model availability and degrades silently to nil / [] when
/// unavailable (older OS, unsupported device, model still downloading, or the
/// user has Apple Intelligence off), so callers can always ask.
@MainActor
final class IntelligenceService {
    static let shared = IntelligenceService()
    private init() {}

    /// Whether on-device generation is usable right now. Drives whether the UI
    /// even offers the affordance.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// A one-line "catch me up" over recent messages. nil when unavailable or
    /// there's nothing worth summarizing.
    func summarize(_ messages: [ChatMessage], in channel: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let transcript = Self.transcript(messages.suffix(40))
            guard transcript.count > 1 else { return nil }
            let session = LanguageModelSession(instructions: """
                You summarize a group chat for someone catching up after being away. \
                Reply with ONE short, plain sentence naming who did or asked what. \
                No preamble, no markdown, no quotes.
                """)
            do {
                let reply = try await session.respond(to: "Channel \(channel):\n" + transcript.joined(separator: "\n"))
                let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Up to three short, natural suggested replies to the latest messages.
    /// Empty when unavailable or the last message is the user's own.
    func smartReplies(_ messages: [ChatMessage], myNick: String) async -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return [] }
            let recent = Self.transcript(messages.suffix(8))
            guard let last = messages.last(where: { !$0.isDeleted && !$0.from.isEmpty }),
                  last.from.lowercased() != myNick.lowercased(),
                  recent.count > 0 else { return [] }
            let session = LanguageModelSession(instructions: """
                Suggest exactly three very short, natural replies (max ~6 words each) that \
                \(myNick) could send next in this chat. One reply per line. No numbering, \
                no bullets, no quotes, no emoji unless natural.
                """)
            do {
                let reply = try await session.respond(to: recent.joined(separator: "\n"))
                let lines = reply.content
                    .split(whereSeparator: \.isNewline)
                    .map(Self.clean)
                    .filter { !$0.isEmpty && $0.count <= 60 }
                return Array(lines.prefix(3))
            } catch {
                return []
            }
        }
        #endif
        return []
    }

    // MARK: - Pure helpers

    private static func transcript<S: Sequence>(_ messages: S) -> [String] where S.Element == ChatMessage {
        messages
            .filter { !$0.isDeleted && !$0.from.isEmpty && !$0.isAction }
            .map { "\($0.from): \($0.text)" }
    }

    /// Strip model formatting noise (leading bullets / numbering / quotes) a
    /// suggestion sometimes carries despite instructions.
    static func clean(_ line: Substring) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while let f = s.first, "-*•·\"'".contains(f) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        if let r = s.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
