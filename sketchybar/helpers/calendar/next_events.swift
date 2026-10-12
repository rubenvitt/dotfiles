// Nächste Termine für den Countdown neben der Uhr (items/calendar.lua).
//
// Läuft als eigener LaunchAgent und nicht über sbar.exec: macOS rechnet den
// Kalenderzugriff dem "verantwortlichen" Prozess zu. Unter mbar wäre das
// mbar.app, und die hat keine NSCalendarsFullAccessUsageDescription — der
// Zugriff wird dann ohne Dialog verweigert. Unter launchd ist dieses Programm
// selbst verantwortlich; den Text für den Dialog trägt es als eingebettete
// Info.plist (siehe makefile).
//
// Schreibt nach jeder Kalenderänderung und alle fünf Minuten die Datei
// ~/.cache/sketchybar/next_events, atomar per rename:
//
//   T|<geschrieben, epoch>|<ok|denied>
//   E|<beginn, epoch>|<ende, epoch>|<titel>     -- bis zu MAX_EVENTS Zeilen
//
// Die Bar rechnet den Countdown selbst aus und liest die Datei nur.

import EventKit
import Foundation

// Kalender, die keine Termine im Sinne von "da muss ich hin" tragen.
let ignoredCalendars: Set<String> = [
  "Birthdays", "Geburtstage",
  "Deutsche Feiertage", "Feiertage in Deutschland",
  "Parqet Dividendenkalender",
  "Clickup / Rubeen", "Clickup / Phönix Progression",
  "Timewarp", "Urlaub",
]
// Selbst gesetzte Blocker im Arbeitskalender, kein Termin.
let ignoredTitles: Set<String> = ["Blockiert"]

let horizon: TimeInterval = 12 * 3600
// Bereits begonnene Termine bleiben so lange drin, wie die Bar "jetzt" zeigt.
let lookBack: TimeInterval = 5 * 60
let refreshInterval: TimeInterval = 5 * 60
let maxEvents = 5

let outDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".cache/sketchybar")
let outFile = outDir.appendingPathComponent("next_events")

let store = EKEventStore()

func log(_ message: String) {
  FileHandle.standardError.write("\(Date()) \(message)\n".data(using: .utf8)!)
}

func declinedByMe(_ event: EKEvent) -> Bool {
  event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
}

func relevant(_ event: EKEvent, after: Date) -> Bool {
  !event.isAllDay
    && event.startDate >= after
    && event.status != .canceled
    // .notSupported ist kein "frei": abonnierte Kalender melden schlicht keine
    // Verfügbarkeit.
    && event.availability != .free
    && !ignoredCalendars.contains(event.calendar.title)
    && !ignoredTitles.contains(event.title ?? "")
    && !declinedByMe(event)
}

func clean(_ title: String?) -> String {
  let t = (title ?? "").replacingOccurrences(of: "|", with: "/")
    .components(separatedBy: .newlines).joined(separator: " ")
    .trimmingCharacters(in: .whitespaces)
  return t.isEmpty ? "Termin" : t
}

func write(_ lines: [String]) {
  do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let tmp = outDir.appendingPathComponent(".next_events.tmp")
    try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: false, encoding: .utf8)
    _ = try FileManager.default.replaceItemAt(outFile, withItemAt: tmp)
  } catch {
    log("schreiben fehlgeschlagen: \(error)")
  }
}

func refresh() {
  let now = Date()
  let stamp = Int(now.timeIntervalSince1970)
  guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
    write(["T|\(stamp)|denied"])
    return
  }
  let from = now.addingTimeInterval(-lookBack)
  let predicate = store.predicateForEvents(withStart: from, end: now.addingTimeInterval(horizon), calendars: nil)
  var seen = Set<String>()
  var lines = ["T|\(stamp)|ok"]
  for event in store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate }) {
    guard relevant(event, after: from) else { continue }
    let start = Int(event.startDate.timeIntervalSince1970)
    let title = clean(event.title)
    // Derselbe Termin in zwei Kalendern (z. B. abonniert und eingeladen).
    guard seen.insert("\(start)|\(title)").inserted else { continue }
    lines.append("E|\(start)|\(Int(event.endDate.timeIntervalSince1970))|\(title)")
    if lines.count > maxEvents { break }
  }
  write(lines)
}

store.requestFullAccessToEvents { granted, error in
  if !granted { log("Kalenderzugriff verweigert \(error.map { "\($0)" } ?? "")") }
  DispatchQueue.main.async { refresh() }
}

NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
  refresh()
}
Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in refresh() }
RunLoop.main.run()
