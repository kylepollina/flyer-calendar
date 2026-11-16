@testable import FlyersCore
import Testing

@Suite struct MapGroupingTests {
    // A gym listed by its name and by its street address lands about 40 m apart.
    private let gym = MapGrouping.Point(id: "gym", latitude: 41.9400, longitude: -87.6600)
    private let address = MapGrouping.Point(id: "address", latitude: 41.9403, longitude: -87.6603)
    private let farAway = MapGrouping.Point(id: "far", latitude: 41.8800, longitude: -87.6300)

    private func viewport(span: Double) -> MapGrouping.Viewport {
        MapGrouping.Viewport(
            centerLatitude: 41.92, centerLongitude: -87.65, latitudeSpan: span, longitudeSpan: span, width: 400, height: 800
        )
    }

    @Test func nearbyPinsShareOneWhenZoomedOut() {
        let groups = MapGrouping.group([gym, address, farAway], in: viewport(span: 0.2), distance: 60)
        #expect(groups == [["gym", "address"], ["far"]])
    }

    @Test func zoomingInSplitsThemApart() {
        let groups = MapGrouping.group([gym, address], in: viewport(span: 0.002), distance: 60)
        #expect(groups == [["gym"], ["address"]])
    }

    @Test func withoutAViewportNothingIsGrouped() {
        #expect(MapGrouping.group([gym, address], in: nil, distance: 60) == [["gym"], ["address"]])
    }
}
