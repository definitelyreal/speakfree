import Foundation

/// Utility for computing Levenshtein (edit) distance between strings.
enum LevenshteinDistance {
    /// Compute the edit distance between two strings.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : min(prev, dp[j], dp[j - 1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    /// Whether two words are similar enough to be a plausible typo correction.
    /// Returns true if edit distance < 40 % of the longer word's length.
    static func isSimilar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let maxLen = max(a.count, b.count)
        return Double(distance(a.lowercased(), b.lowercased())) / Double(maxLen) < 0.4
    }
}
