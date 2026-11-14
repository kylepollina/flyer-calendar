import Foundation

/// Groups photos taken moments apart, such as screenshots scrolling through one post, so they're
/// read together. The first screenshot often holds the title or venue the later ones need.
public enum PhotoGrouping {
    /// A photo joins a group when it was taken within this long of the group's previous photo.
    public static let window: TimeInterval = 120
    /// Keeps a long burst from becoming one huge, costly request.
    public static let maxPhotos = 8

    /// Groups candidates in the order they were taken.
    public static func groups(_ candidates: [PhotoCandidate]) -> [[PhotoCandidate]] {
        var output: [[PhotoCandidate]] = []
        for candidate in candidates.sorted(by: { $0.takenAt < $1.takenAt }) {
            if let last = output.last?.last, output[output.count - 1].count < maxPhotos,
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
        guard let last = group.last, group.count < maxPhotos else { return false }
        return now.timeIntervalSince(last.takenAt) < window
    }
}
