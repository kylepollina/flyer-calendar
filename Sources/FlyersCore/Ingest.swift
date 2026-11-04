import Foundation

/// Turns the model's answer into stored events. No I/O, so every placement rule is testable.
public enum Ingest {
    /// With this many repeating events, a flyer is a schedule. Its repeating events stay in the app
    /// until you pick them, so one flyer can't flood the calendar.
    public static let scheduleThreshold = 3

    public static func events(
        from result: ExtractionResult,
        flyerID: UUID,
        takenOn: Day,
        today: Day,
        settings: AppSettings,
        existingFingerprints: Set<String>
    ) -> [FlyerEvent] {
        guard result.isEventFlyer else { return [] }
        let repeating = result.events.filter { $0.rrule != nil }.count
        var seen = existingFingerprints
        var output: [FlyerEvent] = []

        for extracted in result.events {
            let startDay = extracted.startDate.flatMap(Day.init(iso:))
            let endDay = extracted.endDate.flatMap(Day.init(iso:))
            // A flyer's earlier dates had passed before you photographed it.
            if extracted.rrule == nil, let startDay, (endDay ?? startDay) < takenOn { continue }

            let fingerprint = FlyerEvent.makeFingerprint(name: extracted.name, startDay: startDay)
            guard seen.insert(fingerprint).inserted else { continue }

            var event = FlyerEvent(
                id: UUID(),
                flyerID: flyerID,
                name: extracted.name,
                datePrinted: extracted.dateAsPrinted,
                startDay: startDay,
                startTime: validTime(extracted.startTime),
                endDay: endDay == startDay ? nil : endDay,
                endTime: validTime(extracted.endTime),
                rrule: extracted.rrule,
                yearInferred: extracted.yearInferred,
                startUncertain: extracted.startUncertain,
                location: extracted.location,
                locationInferred: extracted.locationInferred,
                url: normalizedURL(extracted.url),
                details: extracted.description,
                state: .queued,
                stateBeforeDelete: nil,
                calendarItemID: nil,
                fingerprint: fingerprint,
                problems: []
            )
            event.problems = problems(in: extracted, startDay: startDay)

            if event.isOver(today: today) {
                event.state = .available
            } else if result.confidence == .low || !event.problems.isEmpty {
                event.state = .needsReview
            } else if extracted.rrule != nil && repeating >= scheduleThreshold {
                event.state = .available
            } else if settings.addMode == .review {
                event.state = .needsReview
            }
            output.append(event)
        }
        return output
    }

    /// Checks that don't depend on the model grading itself.
    public static func problems(in event: ExtractedEvent, startDay: Day?) -> [String] {
        guard let startDay else {
            return [event.startDate == nil ? "No start date on the flyer" : "Couldn't read the date \(event.startDate!)"]
        }
        var problems: [String] = []
        if let printed = printedWeekday(event.dateAsPrinted), printed != startDay.weekday {
            problems.append("The flyer says \(Day.weekdayNames[printed - 1]), but \(startDay.iso) is a \(startDay.weekdayName)")
        }
        if let rule = event.rrule {
            do {
                let recurrence = try Recurrence(rrule: rule)
                if recurrence.nextOccurrence(start: startDay, onOrAfter: startDay) != startDay {
                    problems.append("The repeat rule doesn't land on the start date")
                }
            } catch {
                problems.append("Calendar can't represent this repeat: \(error)")
            }
        }
        if event.startUncertain {
            problems.append("The flyer doesn't say which date comes first")
        }
        return problems
    }

    private static let weekdayWords: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// The weekday printed in `text`, if it names exactly one.
    public static func printedWeekday(_ text: String?) -> Int? {
        guard let text else { return nil }
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        // Plurals count too, as in "Sundays 4-6pm".
        let days = Set(words.compactMap { weekdayWords[$0] ?? ($0.hasSuffix("s") ? weekdayWords[String($0.dropLast())] : nil) })
        return days.count == 1 ? days.first : nil
    }

    private static func validTime(_ text: String?) -> String? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Only http and https links are kept, so a flyer can't plant another URL scheme.
    public static func normalizedURL(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains(" ") else { return nil }
        if !text.contains("://") {
            guard !text.contains(":") else { return nil }
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return text
    }
}
