import Foundation

/// Groups map pins that would sit on top of each other at the current zoom, so each group can
/// show as one pin. Zooming in spreads them apart again.
public enum MapGrouping {
    public struct Point: Equatable, Sendable {
        public var id: String
        public var latitude: Double
        public var longitude: Double

        public init(id: String, latitude: Double, longitude: Double) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// The part of the map on screen and how big it's drawn.
    public struct Viewport: Equatable, Sendable {
        public var centerLatitude: Double
        public var centerLongitude: Double
        public var latitudeSpan: Double
        public var longitudeSpan: Double
        public var width: Double
        public var height: Double

        public init(centerLatitude: Double, centerLongitude: Double, latitudeSpan: Double, longitudeSpan: Double, width: Double, height: Double) {
            self.centerLatitude = centerLatitude
            self.centerLongitude = centerLongitude
            self.latitudeSpan = latitudeSpan
            self.longitudeSpan = longitudeSpan
            self.width = width
            self.height = height
        }

        /// Where a point lands on screen, in points. Close enough for a city, which is as far as
        /// grouping matters.
        func screen(_ point: Point) -> (x: Double, y: Double) {
            (
                x: (point.longitude - centerLongitude) / longitudeSpan * width,
                y: (centerLatitude - point.latitude) / latitudeSpan * height
            )
        }
    }

    /// Groups of point IDs, each in the order given. Points closer on screen than `distance`
    /// share a group. Without a viewport, nothing is grouped.
    public static func group(_ points: [Point], in viewport: Viewport?, distance: Double) -> [[String]] {
        guard let viewport, viewport.latitudeSpan > 0, viewport.longitudeSpan > 0, viewport.width > 0, viewport.height > 0 else {
            return points.map { [$0.id] }
        }
        // Each group is measured from its first point, so groups don't creep across the map.
        var groups: [(x: Double, y: Double, ids: [String])] = []
        for point in points {
            let spot = viewport.screen(point)
            if let index = groups.firstIndex(where: { hypot($0.x - spot.x, $0.y - spot.y) < distance }) {
                groups[index].ids.append(point.id)
            } else {
                groups.append((spot.x, spot.y, [point.id]))
            }
        }
        return groups.map(\.ids)
    }
}
