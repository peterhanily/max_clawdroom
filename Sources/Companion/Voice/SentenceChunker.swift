import Foundation

/// Splits a growing streamed text into complete sentences on demand.
/// Tracks how much of the running text has already been emitted as
/// sentences so each call returns only the newly-completed ones.
///
/// Sentence boundaries: `.` `?` `!` `\n`. A trailing partial phrase
/// without a boundary is held until the next call. Sentences shorter
/// than `minLength` characters are buffered until they grow — prevents
/// "M." / "#" / "OK." single-punctuation tokens from getting spoken
/// individually during tool-heavy replies.
@MainActor
final class SentenceChunker {
    private var consumedLength: Int = 0
    private let minLength: Int

    init(minLength: Int = 3) {
        self.minLength = minLength
    }

    func reset() {
        consumedLength = 0
    }

    /// Return all newly-completed sentences since the last call.
    func extractNew(fullText: String) -> [String] {
        guard fullText.count > consumedLength else { return [] }
        let startIdx = fullText.index(fullText.startIndex, offsetBy: consumedLength)
        let remaining = fullText[startIdx...]

        var sentences: [String] = []
        var chunkStart = remaining.startIndex
        var i = remaining.startIndex
        while i < remaining.endIndex {
            let c = remaining[i]
            if c == "." || c == "?" || c == "!" || c == "\n" {
                let next = remaining.index(after: i)
                let chunk = String(remaining[chunkStart..<next])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if chunk.count >= minLength {
                    sentences.append(chunk)
                    chunkStart = next
                }
                // If below minLength, fold into the next sentence.
            }
            i = remaining.index(after: i)
        }

        // Advance consumedLength up to the end of the last emitted
        // sentence. Any tail past chunkStart remains buffered.
        let consumedInRemaining = remaining.distance(
            from: remaining.startIndex,
            to: chunkStart
        )
        consumedLength += consumedInRemaining
        return sentences
    }
}
