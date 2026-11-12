// Pause and polling decisions, kept independent of AppKit so lifecycle overlaps can be tested.
// Part of the Mac host for Deskland. GPL-3.0-or-later, see LICENSE.

enum IconPollingMode {
  case stopped, permissionOnly, active

  /// Actual time until the next timer fires, rather than a fast timer that mostly does nothing.
  func interval(trusted: Bool, sinceChange: Double) -> Double? {
    switch self {
    case .stopped: return nil
    case .permissionOnly: return 2
    case .active:
      guard trusted else { return 2 }
      return sinceChange < 2 ? 0.1 : 0.4
    }
  }
}

struct HostPolicy {
  enum Suspension: CaseIterable {
    case displaySleep, inactiveSession, locked, screenSaver
  }

  var manualPause = false
  var covered = false
  private(set) var suspensions: Set<Suspension> = []

  mutating func setSuspended(_ reason: Suspension, _ suspended: Bool) {
    if suspended { suspensions.insert(reason) } else { suspensions.remove(reason) }
  }

  var paused: Bool { manualPause || covered || !suspensions.isEmpty }
  // Coverage must still be watched while covered, to discover when the desktop becomes visible.
  var pollWindows: Bool { !manualPause && suspensions.isEmpty }
  var iconMode: IconPollingMode {
    if !suspensions.isEmpty { return .stopped }
    return paused ? .permissionOnly : .active
  }
}
