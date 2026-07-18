import Foundation

/// Pure layout decisions for the message timeline: where day separators go
/// and what they say.
enum MessageTimeline {
    /// A separator renders before `current` when it starts a new day
    /// (or is the first message).
    static func showsDateSeparator(
        before current: Date,
        previous: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(current, inSameDayAs: previous)
    }

    /// "Today" / "Yesterday" / full date, in the viewer's locale.
    static func dayLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
        return formatter.string(from: date)
    }
}
