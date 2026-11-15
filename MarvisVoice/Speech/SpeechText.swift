import Foundation

enum SpeechText {
    /// Cuts text into pieces of at most `limit` characters: after a sentence where one
    /// fits, else after a comma or similar, else between words. The default keeps each
    /// Marvis prompt well below its hard 1,298-token context precondition, and bounds
    /// the amount of audio buffered ahead of playback.
    static func chunks(_ text: String, limit: Int = 180) -> [String] {
        precondition(limit > 0)
        var chunks: [String] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while remaining.count > limit {
            let end = remaining.index(remaining.startIndex, offsetBy: limit)
            let prefix = remaining[..<end]
            // A comma inside a number such as 1,998 is not a place to pause.
            let clauseEnd = prefix.indices.last { index in
                ",;:—".contains(prefix[index]) && remaining[remaining.index(after: index)].isWhitespace
            }
            let boundary = (prefix.lastIndex(where: { ".!?\n".contains($0) }) ?? clauseEnd)
                .map { remaining.index(after: $0) }
                ?? prefix.lastIndex(where: { $0.isWhitespace })
                ?? end
            let piece = remaining[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remaining = remaining[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !remaining.isEmpty { chunks.append(remaining) }
        return chunks
    }

    /// Cuts one sentence into pieces of at most `limit` characters that are close to
    /// equal in length: after a comma or similar where one fits, else before a joining
    /// word such as "and" or "which", else between words. For a model that takes so
    /// little text at a time that most long sentences have to be cut somewhere.
    static func clauses(_ sentence: String, limit: Int) -> [String] {
        precondition(limit > 0)
        let joiningWords: Set<String> = [
            "and", "but", "or", "so", "because", "which", "that", "who", "when", "where",
            "while", "although", "though", "if", "than", "as", "since", "until", "before", "after",
        ]
        var pieces: [String] = []
        var remaining = Array(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
        while remaining.count > limit {
            let needed = (remaining.count + limit - 1) / limit
            let ideal = remaining.count / needed
            // A shorter piece would leave more text than the other pieces can hold.
            let shortest = remaining.count - (needed - 1) * limit
            func rank(_ cut: Int) -> Int {
                if ",;:—".contains(remaining[cut - 1]) { return 0 }
                let next = remaining[cut...].drop(while: \.isWhitespace).prefix(while: \.isLetter)
                return joiningWords.contains(String(next).lowercased()) ? 1 : 2
            }
            let cuts = (1...limit).filter { remaining[$0].isWhitespace && !remaining[$0 - 1].isWhitespace }
            let fitting = cuts.filter { $0 >= shortest }
            let cut = (fitting.isEmpty ? cuts : fitting)
                .min { (rank($0), abs($0 - ideal)) < (rank($1), abs($1 - ideal)) } ?? limit
            pieces.append(String(remaining[..<cut]))
            remaining = Array(remaining[cut...].drop(while: \.isWhitespace))
        }
        if !remaining.isEmpty { pieces.append(String(remaining)) }
        return pieces
    }

    /// Replaces the hyphen inside a compound such as "1000-word" or "well-known" with a
    /// space. Kokoro reads that hyphen as a dash and pauses in the middle of the word.
    /// Ranges such as "1990-2000" and spaced dashes are left alone.
    static func joiningHyphenatedWords(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=[\p{L}\p{N}])-(?=\p{L})"#, with: " ", options: .regularExpression)
    }
}

/// Turns cumulative model snapshots into phrases that can be queued for speech immediately.
/// The cursor includes whitespace after spoken phrases, so the next snapshot never repeats it.
struct StreamingSpeechText {
    enum Style: Sendable {
        /// Starts with the first few words, for a voice that can begin on any word.
        case immediate
        /// Starts once a phrase has enough words to set its rhythm.
        case natural
        /// Whole sentences only, for a model that speaks each piece as a separate
        /// utterance: it pauses wherever a sentence is cut.
        case sentences
    }

    private var snapshot: [Character] = []
    private var consumed = 0
    private var hasEmittedPhrase = false
    private let style: Style
    private let firstPhraseLength = 24
    private let firstPhraseWords = 4
    private let phraseLength = 90
    private let maximumLength = 180

    init(style: Style = .immediate) {
        self.style = style
    }

    /// Splits a complete text into its sentences in one step.
    static func sentences(in text: String) -> [String] {
        var speech = StreamingSpeechText(style: .sentences)
        speech.snapshot = Array(text)
        return speech.finish()
    }

    mutating func append(_ text: String) -> [String] {
        let updated = Array(text)
        guard updated != snapshot else { return [] }
        consumed = reconciledCursor(in: updated)
        snapshot = updated
        return drain(finishing: false)
    }

    mutating func finish() -> [String] {
        drain(finishing: true)
    }

    /// A latency timer can release a short phrase when the next model token is slow.
    /// Keep the unfinished final word (and any trailing abbreviation) for the next snapshot.
    mutating func flushReadyWords() -> [String] {
        while consumed < snapshot.count, snapshot[consumed].isWhitespace { consumed += 1 }
        let end = min(consumed + maximumLength, snapshot.count)
        guard consumed < end,
              let space = (consumed..<end).last(where: { isSafeWordBoundary(at: $0) }) else {
            return []
        }
        let phrase = String(snapshot[consumed..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard style == .immediate || (style == .natural && hasNaturalPhraseContext(phrase)) else { return [] }
        consumed = space + 1
        hasEmittedPhrase = true
        return [phrase]
    }

    private func reconciledCursor(in updated: [Character]) -> Int {
        let sharedPrefix = zip(snapshot, updated).prefix(while: { $0 == $1 }).count
        guard sharedPrefix < consumed else { return consumed }

        // A model may revise its cumulative response. Preserve an unchanged suffix after
        // a corrected spoken prefix, instead of replaying that prefix or using stale offsets.
        var sharedSuffix = 0
        while sharedSuffix < min(snapshot.count, updated.count) - sharedPrefix,
              snapshot[snapshot.count - sharedSuffix - 1] == updated[updated.count - sharedSuffix - 1] {
            sharedSuffix += 1
        }
        let oldChangeEnd = snapshot.count - sharedSuffix
        let newChangeEnd = updated.count - sharedSuffix
        if oldChangeEnd <= consumed {
            return consumed + newChangeEnd - oldChangeEnd
        }
        // Speech already played cannot be retracted. If a rewrite crosses that boundary,
        // skip its ambiguous changed region rather than speaking revised text twice.
        return newChangeEnd
    }

    private mutating func drain(finishing: Bool) -> [String] {
        var phrases: [String] = []
        while consumed < snapshot.count {
            while consumed < snapshot.count, snapshot[consumed].isWhitespace { consumed += 1 }
            guard consumed < snapshot.count,
                  let boundary = nextBoundary(finishing: finishing) else { break }
            let phrase = String(snapshot[consumed..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            consumed = boundary
            if !phrase.isEmpty {
                phrases.append(phrase)
                hasEmittedPhrase = true
            }
        }
        return phrases
    }

    private func nextBoundary(finishing: Bool) -> Int? {
        let end = min(consumed + maximumLength, snapshot.count)
        var completedWords = 0
        for index in consumed..<end {
            let character = snapshot[index]
            if character == "\n" { return index + 1 }
            if !finishing, !hasEmittedPhrase, character.isWhitespace,
               index > consumed, !snapshot[index - 1].isWhitespace {
                completedWords += 1
                let ready = switch style {
                case .immediate:
                    completedWords >= firstPhraseWords || index - consumed >= firstPhraseLength
                case .natural:
                    completedWords >= 6 && index - consumed >= 32
                case .sentences:
                    false
                }
                if ready,
                   isSafeWordBoundary(at: index) {
                    return index + 1
                }
            }
            let sentenceEnd = ".!?。！？".contains(character)
            let clauseEnd = style != .sentences && ",;:，；：—".contains(character) && index - consumed >= 45
            guard sentenceEnd || clauseEnd else { continue }
            if character == ".", isAbbreviation(at: index) { continue }

            var boundary = index + 1
            // Keep a punctuation run and closing quote together if they arrive in separate tokens.
            while boundary < snapshot.count, "\"'”’)]}!?。！？".contains(snapshot[boundary]) {
                boundary += 1
            }
            let nonLatinEnd = "。！？，；：".contains(character)
            if boundary < snapshot.count,
               snapshot[boundary].isWhitespace || nonLatinEnd {
                return boundary
            }
            if finishing, boundary == snapshot.count { return boundary }
        }

        let remaining = snapshot.count - consumed
        if style != .sentences, remaining >= phraseLength {
            let preferredEnd = min(consumed + phraseLength, snapshot.count - 1)
            if let space = (consumed...preferredEnd).last(where: { snapshot[$0].isWhitespace }),
               space - consumed >= 60,
               style == .immediate || hasEmittedPhrase || finishing ||
                hasNaturalPhraseContext(String(snapshot[consumed..<space])) {
                return space + 1
            }
        }
        if remaining > maximumLength {
            if let space = (consumed..<end).last(where: { snapshot[$0].isWhitespace }) {
                return space + 1
            }
            // Scripts without spaces and exceptional oversized tokens still respect the TTS limit.
            return end
        }
        return finishing ? snapshot.count : nil
    }

    /// Neural speech needs enough context to establish a phrase's rhythm.
    /// Native speech can start with the first complete word instead.
    private func hasNaturalPhraseContext(_ phrase: String) -> Bool {
        phrase.count >= 32 && phrase.split(whereSeparator: \.isWhitespace).count >= 6
    }

    private func isSafeWordBoundary(at index: Int) -> Bool {
        guard snapshot[index].isWhitespace, index > consumed,
              !snapshot[index - 1].isWhitespace else { return false }
        if snapshot[index - 1] == ".", isAbbreviation(at: index - 1) { return false }
        return true
    }

    private func isAbbreviation(at period: Int) -> Bool {
        var wordStart = period
        while wordStart > consumed,
              snapshot[wordStart - 1].isLetter || snapshot[wordStart - 1] == "." {
            wordStart -= 1
        }
        let word = String(snapshot[wordStart..<period]).lowercased()
        let abbreviations: Set<String> = [
            "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
            "e.g", "i.e", "a.m", "p.m", "u.s", "u.k"
        ]
        return abbreviations.contains(word) || (word.count == 1 && word.first?.isLetter == true)
    }
}
