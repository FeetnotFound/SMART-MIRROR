import SwiftUI
import EventKit

@MainActor
final class CalendarInterface: ObservableObject {
    static let shared = CalendarInterface()
    @Published var events: [EKEvent] = []
    @Published var eventsByDate: [Date: [[String: String]]] = [:]
    @Published var showAccessError: Bool = false
    @Published var accessErrorMessage: String = ""
    @Published var showSettingsButton: Bool = false

    private let eventStore = EKEventStore()

    func reload() async {
        print("[CalendarInterface] reload() started at \(Date())")
        do {
            try await ensureCalendarAccess()
            let now = Date()
            let todayStart = Calendar.current.startOfDay(for: now)
            let startDate = Calendar.current.date(byAdding: .day, value: -3, to: todayStart)!
            let endDateExclusive = Calendar.current.date(byAdding: .day, value: 4, to: todayStart)!
            let fetched = try await fetchEvents(from: startDate, to: endDateExclusive)

            // Filter to events intersecting the window
            let filtered = fetched.compactMap { event -> EKEvent? in
                guard let s = event.startDate, let e = event.endDate else { return nil }
                guard (s < endDateExclusive) && (e >= startDate) else { return nil }
                return event
            }

            // Build dictionary keyed by day start with stringified fields
            var dict: [Date: [[String: String]]] = [:]
            for ev in filtered {
                guard let s = ev.startDate, let e = ev.endDate else { continue }
                let key = dayKey(for: s)
                var arr = dict[key, default: []]
                let entry: [String: String] = [
                    "calendar": (ev.calendar.title.isEmpty ? "Calendar" : ev.calendar.title),
                    "event": ((ev.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) ? "Untitled" : (ev.title ?? "Untitled")),
                    "time": timeString(start: s, end: e, allDay: ev.isAllDay),
                    "location": (ev.location?.isEmpty == false ? ev.location! : "")
                ]
                arr.append(entry)
                dict[key] = arr
            }
            for key in dict.keys {
                dict[key]?.sort { (lhs, rhs) in
                    (lhs["time"] ?? "") < (rhs["time"] ?? "")
                }
            }

            self.eventsByDate = dict
            self.events = filtered.sorted { (l, r) in
                guard let ls = l.startDate, let rs = r.startDate else { return false }
                return ls < rs
            }

            // Send to mirror after successful reload
            let rangeStart = startDate
            let rangeEnd = endDateExclusive
            Task { @MainActor in
                await MirrorManager.shared.sendCalendar(rangeStart: rangeStart, rangeEnd: rangeEnd, events: filtered)
            }

            print("[CalendarInterface] reload() finished at \(Date()) — events: \(self.events.count))")
        } catch {
            self.showAccessError = true
            self.accessErrorMessage = userFacingErrorMessage(for: error)
            print("[CalendarInterface] reload() failed: \(error)")
            print("Calendar access/fetch error: \(error)")
            // Even on failure, send an empty 7-day window to the mirror so it can clear UI.
            let now = Date()
            let todayStart = Calendar.current.startOfDay(for: now)
            let startDate = Calendar.current.date(byAdding: .day, value: -3, to: todayStart)!
            let endDateExclusive = Calendar.current.date(byAdding: .day, value: 4, to: todayStart)!
            Task { @MainActor in
                await MirrorManager.shared.sendCalendar(rangeStart: startDate, rangeEnd: endDateExclusive, events: [])
            }
        }
    }

    // MARK: - Helpers

    func sectionTitle(for dayStart: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(dayStart) { return "Today" }
        if calendar.isDateInYesterday(dayStart) { return "Yesterday" }
        if calendar.isDateInTomorrow(dayStart) { return "Tomorrow" }
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: dayStart) - 1]
        return weekday
    }

    func dateRangeString(start: Date, end: Date, allDay: Bool) -> String {
        if allDay { return "All-day" }
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.timeStyle = .short
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }

    func eventsDictionaryText() -> String {
        let dict = self.eventsByDate
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateStyle = .medium
        var lines: [String] = []
        lines.append("==== Events Dictionary ====")
        for key in dict.keys.sorted() {
            let label: String
            if calendar.isDateInToday(key) { label = "Today" }
            else if calendar.isDateInYesterday(key) { label = "Yesterday" }
            else if calendar.isDateInTomorrow(key) { label = "Tomorrow" }
            else { label = dateFormatter.string(from: key) }
            lines.append("\n\(label) (")
            if let items = dict[key] {
                for item in items {
                    let cal = item["calendar"] ?? ""
                    let name = item["event"] ?? ""
                    let time = item["time"] ?? ""
                    let rawLoc = item["location"] ?? ""
                    let loc = rawLoc.trimmingCharacters(in: .whitespacesAndNewlines)
                    if loc.isEmpty {
                        lines.append("  - [\(cal)] \(name) — \(time)")
                    } else {
                        lines.append("  - [\(cal)] \(name) — \(time) @ \(loc)")
                    }
                }
            }
            lines.append(")")
        }
        lines.append("==== End ====")
        return lines.joined(separator: "\n")
    }

    func printEventsDictionary() {
        let dict = self.eventsByDate
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateStyle = .medium
        print("==== Events Dictionary Dump ====")
        for key in dict.keys.sorted() {
            let label: String
            if calendar.isDateInToday(key) { label = "Today" }
            else if calendar.isDateInYesterday(key) { label = "Yesterday" }
            else if calendar.isDateInTomorrow(key) { label = "Tomorrow" }
            else { label = dateFormatter.string(from: key) }
            print("\n\(label) (")
            if let items = dict[key] {
                for item in items {
                    let cal = item["calendar"] ?? ""
                    let name = item["event"] ?? ""
                    let time = item["time"] ?? ""
                    let loc = (item["location"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if loc.isEmpty {
                        print("  - [\(cal)] \(name) — \(time)")
                    } else {
                        print("  - [\(cal)] \(name) — \(time) @ \(loc)")
                    }
                }
            }
            print(")")
        }
        print("==== End Dictionary Dump ====")
    }

    // MARK: - Private

    private func dayKey(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func timeString(start: Date, end: Date, allDay: Bool) -> String {
        if allDay { return "All-day" }
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.timeStyle = .short
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }

    private func ensureCalendarAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:
            return
        case .fullAccess:
            // Treat full access the same as authorized
            return
        case .notDetermined:
            let granted = try await eventStore.requestAccess(to: .event)
            if !granted {
                showSettingsButton = true
                throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied. You can enable access in Settings."])
            }
        case .writeOnly:
            showSettingsButton = true
            throw NSError(domain: "Calendar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Calendar access not granted. Enable access in Settings."])
        case .denied, .restricted:
            showSettingsButton = true
            throw NSError(domain: "Calendar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Calendar access not granted. Enable access in Settings."])
        @unknown default:
            throw NSError(domain: "Calendar", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown calendar authorization status."])
        }
    }

    private func fetchEvents(from start: Date, to end: Date) async throws -> [EKEvent] {
        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return eventStore.events(matching: predicate)
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "Calendar" {
            return nsError.localizedDescription
        }
        return "Something went wrong. Please try again. (\(nsError.localizedDescription))"
    }

    // MARK: - View Convenience

    func sevenDayWindow(centeredOn reference: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let todayStart = calendar.startOfDay(for: reference)
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - 3, to: todayStart)
        }
    }

    func eventsIntersecting(dayStart: Date, calendar: Calendar = .current) -> [EKEvent] {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return events.filter { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return false }
            return (s < nextDay) && (e >= dayStart)
        }
    }

    func calendarColor(for event: EKEvent) -> Color {
        if let cg = event.calendar.cgColor {
            return Color(cgColor: cg)
        }
        return Color.accentColor
    }

    func eventTitle(_ event: EKEvent) -> String {
        let trimmed = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

