import Foundation

/// Groups screenshots taken moments apart, as when scrolling through one post, so they're read
/// together. The first screenshot often holds the title or venue the later ones need.
///
/// Camera photos are always read alone. Ones taken moments apart are usually separate flyers,
/// such as two posters on the same wall, and reading them together mixed their events up.
public enum PhotoGrouping {
    /// A screenshot joins a group when it was taken within this long of the group's previous one.
    public static let window: TimeInterval = 120
    /// Keeps a long burst from becoming one huge, costly request.
    public static let maxPhotos = 8

    /// Groups candidates in the order they were taken.
    public static func groups(_ candidates: [PhotoCandidate]) -> [[PhotoCandidate]] {
        var output: [[PhotoCandidate]] = []
        for candidate in candidates.sorted(by: { $0.takenAt < $1.takenAt }) {
            if candidate.isScreenshot, let last = output.last?.last, last.isScreenshot,
               output[output.count - 1].count < maxPhotos,
               candidate.takenAt.timeIntervalSince(last.takenAt) <= window {
                output[output.count - 1].append(candidate)
            } else {
                output.append([candidate])
            }
        }
        return output
    }

    /// True while another photo could still join the group, so a scheduled scan should wait for it.
    public static func mayStillGrow(_ group: [PhotoCandidate], now: Date) -> Bool {
        guard let last = group.last, last.isScreenshot, group.count < maxPhotos else { return false }
        return now.timeIntervalSince(last.takenAt) < window
    }
}
