import Foundation

// MARK: - What the model returns

public struct ExtractedEvent: Codable, Equatable, Sendable {
    public var name: String
    public var dateAsPrinted: String?
    public var startDate: String?
    public var startTime: String?
    public var endDate: String?
    public var endTime: String?
    public var yearInferred: Bool
    public var rrule: String?
    public var startUncertain: Bool
    public var location: String?
    public var locationInferred: Bool
    public var url: String?
    public var description: String?

    public init(
        name: String, dateAsPrinted: String? = nil, startDate: String? = nil, startTime: String? = nil,
        endDate: String? = nil, endTime: String? = nil, yearInferred: Bool = false, rrule: String? = nil,
        startUncertain: Bool = false, location: String? = nil, locationInferred: Bool = false,
        url: String? = nil, description: String? = nil
    ) {
        self.name = name
        self.dateAsPrinted = dateAsPrinted
        self.startDate = startDate
        self.startTime = startTime
        self.endDate = endDate
        self.endTime = endTime
        self.yearInferred = yearInferred
        self.rrule = rrule
        self.startUncertain = startUncertain
        self.location = location
        self.locationInferred = locationInferred
        self.url = url
        self.description = description
    }
}

public enum Confidence: String, Codable, Sendable { case high, medium, low }

public struct ExtractionResult: Codable, Equatable, Sendable {
    public var isEventFlyer: Bool
    public var confidence: Confidence
    public var reason: String
    public var flyerTitle: String?
    public var events: [ExtractedEvent]

    public init(
        isEventFlyer: Bool, confidence: Confidence = .high, reason: String = "",
        flyerTitle: String? = nil, events: [ExtractedEvent] = []
    ) {
        self.isEventFlyer = isEventFlyer
        self.confidence = confidence
        self.reason = reason
        self.flyerTitle = flyerTitle
        self.events = events
    }
}

public struct TokenUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    /// USD at Haiku 5.5 rates, for prompts of 100K tokens or fewer.
    public var cost: Double { (Double(input) * 0.10 + Double(output) * 0.50) / 1_000_000 }
}

// MARK: - What the app stores

public enum EventState: String, Codable, Sendable {
    /// Waiting to be added to the calendar.
    case queued
    case onCalendar
    /// Held back for you to check.
    case needsReview
    /// Kept in the app but not on the calendar, such as weekly items on a schedule flyer.
    case available
    /// Deleted here. The record stays so a rescan can't bring the event back.
    case deleted
    /// You deleted it in Calendar. Treated like a delete here.
    case removedInCalendar
}

public struct FlyerEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var flyerID: UUID
    public var name: String
    public var datePrinted: String?
    public var startDay: Day?
    public var startTime: String?
    public var endDay: Day?
    public var endTime: String?
    public var rrule: String?
    public var yearInferred: Bool
    public var startUncertain: Bool
    public var location: String?
    public var locationInferred: Bool
    public var url: String?
    public var details: String?
    public var state: EventState
    /// What to go back to on Undo.
    public var stateBeforeDelete: EventState?
    public var calendarItemID: String?
    /// Stays the same after edits, so an edited or deleted event still blocks its duplicates.
    public var fingerprint: String
    public var problems: [String]

    public init(
        id: UUID, flyerID: UUID, name: String, datePrinted: String?, startDay: Day?, startTime: String?,
        endDay: Day?, endTime: String?, rrule: String?, yearInferred: Bool, startUncertain: Bool,
        location: String?, locationInferred: Bool, url: String?, details: String?, state: EventState,
        stateBeforeDelete: EventState?, calendarItemID: String?, fingerprint: String, problems: [String]
    ) {
        self.id = id
        self.flyerID = flyerID
        self.name = name
        self.datePrinted = datePrinted
        self.startDay = startDay
        self.startTime = startTime
        self.endDay = endDay
        self.endTime = endTime
        self.rrule = rrule
        self.yearInferred = yearInferred
        self.startUncertain = startUncertain
        self.location = location
        self.locationInferred = locationInferred
        self.url = url
        self.details = details
        self.state = state
        self.stateBeforeDelete = stateBeforeDelete
        self.calendarItemID = calendarItemID
        self.fingerprint = fingerprint
        self.problems = problems
    }

    public var recurrence: Recurrence? { rrule.flatMap { try? Recurrence(rrule: $0) } }

    public func nextDay(onOrAfter day: Day) -> Day? {
        guard let startDay else { return nil }
        if let recurrence { return recurrence.nextOccurrence(start: startDay, onOrAfter: day) }
        return (endDay ?? startDay) >= day ? max(startDay, day) : nil
    }

    public func isOver(today: Day) -> Bool {
        guard startDay != nil else { return false }
        return nextDay(onOrAfter: today) == nil
    }

    public var isHidden: Bool { state == .deleted || state == .removedInCalendar }

    public static func makeFingerprint(name: String, startDay: Day?) -> String {
        let letters = name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        return "\(String(String.UnicodeScalarView(letters)))|\(startDay?.iso ?? "undated")"
    }
}

public struct Flyer: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var assetID: String
    public var takenAt: Date
    public var title: String?
    public var reason: String
    public var confidence: Confidence
    public var thumbnailFile: String?

    public init(
        id: UUID, assetID: String, takenAt: Date, title: String?, reason: String,
        confidence: Confidence, thumbnailFile: String?
    ) {
        self.id = id
        self.assetID = assetID
        self.takenAt = takenAt
        self.title = title
        self.reason = reason
        self.confidence = confidence
        self.thumbnailFile = thumbnailFile
    }
}

public enum PhotoStatus: String, Codable, Sendable {
    /// The on-device filter found no event text, so it never left this Mac.
    case skippedByFilter
    case notAFlyer
    case extracted
    case failed
}

public struct PhotoRecord: Codable, Equatable, Sendable {
    public var status: PhotoStatus
    public var attempts: Int
    public var lastError: String?
    public var processedAt: Date
}

public enum AddMode: String, Codable, CaseIterable, Sendable { case automatic, review }

public struct AppSettings: Codable, Equatable, Sendable {
    public var calendarID: String?
    public var addMode: AddMode = .automatic
    /// Minutes before the event. Zero means no alert.
    public var alertMinutesBefore = 1440
    public var scanIntervalMinutes = 60
    /// Starts at midnight, so a flyer photographed earlier on install day still counts.
    public var scanStartDate = Calendar.current.startOfDay(for: Date())
    public var includeScreenshots = false
    public var monthlySpendLimit = 1.0
    public var launchAtLoginSet = false

    public init() {}
}

public struct AppDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var settings = AppSettings()
    public var photos: [String: PhotoRecord] = [:]
    public var flyers: [Flyer] = []
    public var events: [FlyerEvent] = []
    /// USD by `YYYY-MM`.
    public var spend: [String: Double] = [:]
    public var lastScanAt: Date?
    public var lastScanSummary: String?
    /// True after you stop a scan, so scheduled scans don't restart it. Optional so that
    /// library files saved before this existed still load.
    public var scanPaused: Bool?
    /// True once events added before Open in Flyers links existed have been given one.
    public var appLinksAdded: Bool?

    public init() {}
}
