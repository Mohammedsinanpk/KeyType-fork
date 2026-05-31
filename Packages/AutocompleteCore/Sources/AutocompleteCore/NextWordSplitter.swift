import Foundation

/// Splits a completion string into the "next word" to accept (Tab) and the remainder, using ICU
/// word boundaries so it works across scripts — space-delimited (Latin/Cyrillic/…) *and*
/// space-less ones the system segments (CJK, Thai). See ADR-016.
///
/// "Next word" is everything from the start of the string up to the next accept boundary, so leading
/// whitespace and the word's own trailing whitespace travel with it (accepting `" world today"`
/// inserts `" world "` and leaves `"today"`; accepting `"orrow to talk"` inserts `"orrow "` and
/// leaves `"to talk"`). A string with one or zero words accepts wholesale.
///
/// Sentence/clause punctuation (`. , ; : ! ?` and the common full-width CJK forms) is *not* swallowed
/// with the word it follows — it becomes its own accept unit, so completing `"esses."` inserts
/// `"esses"` on the first Tab and `"."` on the next. A run of such punctuation (e.g. `"?!"`, `"…"`,
/// `", "`) is one unit, and any whitespace after it travels with it. See ADR-038.
public enum NextWordSplitter {
    /// Punctuation that is confirmed as a separate Tab press rather than bundled into the preceding
    /// word. Covers ASCII sentence/clause marks plus their full-width CJK counterparts.
    private static let separablePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?",
        "。", "，", "、", "；", "：", "！", "？",
    ]

    /// `head` is the slice to insert on a single Tab; `rest` is what remains for the next Tab.
    public static func split(_ text: String) -> (head: String, rest: String) {
        guard !text.isEmpty else { return ("", "") }

        // Leading-punctuation unit: when the remainder begins (after any whitespace) with separable
        // punctuation — e.g. the `"."` left over once `"esses"` was accepted, or `", today"` — that
        // punctuation run plus the whitespace trailing it is the whole unit, kept apart from the next
        // word.
        if let firstNonSpace = text.firstIndex(where: { !$0.isWhitespace }),
           separablePunctuation.contains(text[firstNonSpace]) {
            var index = firstNonSpace
            while index < text.endIndex, separablePunctuation.contains(text[index]) {
                index = text.index(after: index)
            }
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            return (String(text[..<index]), String(text[index...]))
        }

        // Word unit: find where the first ICU word ends. ICU skips whitespace and punctuation, so this
        // segments space-less scripts (CJK/Thai) too.
        var firstWordEnd: String.Index?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) { _, range, _, stop in
            firstWordEnd = range.upperBound
            stop = true
        }

        // No words at all (e.g. only whitespace/symbols) → nothing to sub-divide; accept wholesale.
        guard let firstWordEnd else { return (text, "") }

        // Extend past the word's trailing whitespace (the separator before whatever comes next) so it
        // travels with the word — but stop at punctuation, leaving it for the next Tab. Whether the
        // next unit is a word or punctuation, the boundary is the same: the first non-whitespace
        // character after the word.
        var index = firstWordEnd
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return (String(text[..<index]), String(text[index...]))
    }
}
