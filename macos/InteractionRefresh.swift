// A short refresh burst after an interaction, without another permanent polling timer.
import Foundation

/// Main-run-loop helper. A new interaction replaces the preceding burst's follow-ups.
final class InteractionRefresh {
  private let refresh: () -> Void
  private var timers: [Timer] = []
  private var generation: UInt64 = 0

  init(refresh: @escaping () -> Void) { self.refresh = refresh }

  func trigger() {
    cancel()
    let current = generation
    let start = Date()
    refresh()
    // The callback may cancel this burst or start a replacement synchronously.
    guard generation == current else { return }
    for delay in [0.05, 0.15, 0.3] {
      let timer = Timer(fire: start.addingTimeInterval(delay), interval: 0, repeats: false) { [weak self] timer in
        guard let self, self.generation == current else { return }
        self.timers.removeAll { $0 === timer }
        self.refresh()
      }
      timers.append(timer)
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func cancel() {
    generation &+= 1
    timers.forEach { $0.invalidate() }
    timers.removeAll()
  }

  deinit { timers.forEach { $0.invalidate() } }
}
