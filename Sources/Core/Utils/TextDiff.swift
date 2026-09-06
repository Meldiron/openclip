// TextDiff.swift
// OpenClip
//
// Character-level diff between an action's input text and the text it produced, used by the
// result card's change view. Pure domain code: it returns ordered segments (equal / inserted /
// deleted) and leaves colours, strikethrough and typography to the card.
//
// The comparison is a Myers greedy diff over `Character`s (grapheme clusters, so emoji and
// composed characters are never split), preceded by common prefix/suffix trimming so the usual
// proofread case — a long text with a couple of edits — only diffs the changed middle. Two
// budgets keep a pathological input cheap: `maxComparableLength` on the trimmed middle and
// `maxEditDistance` on the diff's D. Exceeding either yields the honest fallback of "the middle
// was replaced" (one delete + one insert), which is also the only sensible rendering when the
// result is a rewrite rather than an edit.
import Foundation

/// One run of the diff: a stretch of text that survived, was added, or was removed.
public struct TextDiffSegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case equal
        case insert
        case delete
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum TextDiff {
    /// Combined character budget for the *trimmed* middle. Beyond it the middle is reported as a
    /// wholesale replacement instead of being diffed.
    public static let maxComparableLength = 6_000
    /// Maximum edit distance the Myers search explores before giving up (its cost — and the
    /// trace it keeps — grow with D², so an unrelated pair of texts must not run unbounded).
    public static let maxEditDistance = 600

    /// Diffs `old` into `new`, coalescing consecutive characters of the same kind into one segment.
    public static func segments(from old: String, to new: String) -> [TextDiffSegment] {
        if old == new {
            return old.isEmpty ? [] : [TextDiffSegment(kind: .equal, text: old)]
        }

        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix,
              suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldChars[prefix..<(oldChars.count - suffix)])
        let newMiddle = Array(newChars[prefix..<(newChars.count - suffix)])

        let middle: [TextDiffSegment]
        if oldMiddle.count + newMiddle.count > maxComparableLength {
            middle = replacement(oldMiddle, newMiddle)
        } else {
            middle = myers(oldMiddle, newMiddle) ?? replacement(oldMiddle, newMiddle)
        }

        var result: [TextDiffSegment] = []
        if prefix > 0 {
            result.append(TextDiffSegment(kind: .equal, text: String(oldChars[0..<prefix])))
        }
        result.append(contentsOf: middle)
        if suffix > 0 {
            result.append(TextDiffSegment(kind: .equal, text: String(oldChars[(oldChars.count - suffix)...])))
        }
        return coalesced(result)
    }

    /// Share of the diffed material that survived unchanged, 0...1 — 1.0 for identical texts and
    /// near 0 for a full rewrite. The card uses it to decide whether the change view is worth
    /// showing by default (a rewrite diffs into noise; an edit reads perfectly).
    public static func equalRatio(of segments: [TextDiffSegment]) -> Double {
        var equal = 0
        var total = 0
        for segment in segments {
            let count = segment.text.count
            total += count
            if segment.kind == .equal { equal += count }
        }
        guard total > 0 else { return 1.0 }
        return Double(equal) / Double(total)
    }

    // MARK: - Internals

    private static func replacement(_ old: [Character], _ new: [Character]) -> [TextDiffSegment] {
        var segments: [TextDiffSegment] = []
        if !old.isEmpty { segments.append(TextDiffSegment(kind: .delete, text: String(old))) }
        if !new.isEmpty { segments.append(TextDiffSegment(kind: .insert, text: String(new))) }
        return segments
    }

    /// Myers greedy diff with a D budget. Returns nil when the texts are further apart than
    /// `maxEditDistance`, leaving the caller to fall back to a wholesale replacement.
    private static func myers(_ a: [Character], _ b: [Character]) -> [TextDiffSegment]? {
        let n = a.count
        let m = b.count
        if n == 0 && m == 0 { return [] }
        if n == 0 { return [TextDiffSegment(kind: .insert, text: String(b))] }
        if m == 0 { return [TextDiffSegment(kind: .delete, text: String(a))] }

        let bound = min(n + m, maxEditDistance)
        let offset = bound + 1
        var v = [Int](repeating: 0, count: 2 * bound + 3)
        var trace: [[Int]] = []
        trace.reserveCapacity(bound + 1)

        for d in 0...bound {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    return backtrack(a, b, trace: trace, offset: offset)
                }
                k += 2
            }
        }
        return nil
    }

    /// Walks the recorded end points backwards, emitting one character per step, then coalesces.
    private static func backtrack(_ a: [Character], _ b: [Character], trace: [[Int]], offset: Int) -> [TextDiffSegment] {
        var x = a.count
        var y = b.count
        var reversed: [(kind: TextDiffSegment.Kind, character: Character)] = []

        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = v[offset + previousK]
            let previousY = previousX - previousK

            while x > previousX && y > previousY {
                x -= 1
                y -= 1
                reversed.append((.equal, a[x]))
            }
            guard d > 0 else { break }
            if x == previousX {
                y -= 1
                reversed.append((.insert, b[y]))
            } else {
                x -= 1
                reversed.append((.delete, a[x]))
            }
        }

        var segments: [TextDiffSegment] = []
        var currentKind: TextDiffSegment.Kind?
        var currentText = ""
        for step in reversed.reversed() {
            if step.kind == currentKind {
                currentText.append(step.character)
            } else {
                if let currentKind, !currentText.isEmpty {
                    segments.append(TextDiffSegment(kind: currentKind, text: currentText))
                }
                currentKind = step.kind
                currentText = String(step.character)
            }
        }
        if let currentKind, !currentText.isEmpty {
            segments.append(TextDiffSegment(kind: currentKind, text: currentText))
        }
        return segments
    }

    /// Merges neighbouring segments of the same kind (the prefix/suffix joints produce them).
    private static func coalesced(_ segments: [TextDiffSegment]) -> [TextDiffSegment] {
        var merged: [TextDiffSegment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = merged.last, last.kind == segment.kind {
                merged[merged.count - 1] = TextDiffSegment(kind: last.kind, text: last.text + segment.text)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}
