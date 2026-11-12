// Run with tools/test-mac-interaction.sh. Uses only Foundation and the local run loop.
import Foundation
import CoreFoundation

@main
struct InteractionRefreshTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }

  static func run(for duration: TimeInterval, mode: RunLoop.Mode = .default) {
    let deadline = Date().addingTimeInterval(duration)
    let keeper = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
    RunLoop.main.add(keeper, forMode: mode)
    defer { keeper.invalidate() }
    while Date() < deadline { _ = RunLoop.main.run(mode: mode, before: deadline) }
  }

  static func main() {
    do {
      let start = ProcessInfo.processInfo.systemUptime
      var calls: [TimeInterval] = []
      let scheduler = InteractionRefresh { calls.append(ProcessInfo.processInfo.systemUptime - start) }
      scheduler.trigger()
      expect(calls.count == 1, "The first refresh must be synchronous")
      run(for: 0.4)
      expect(calls.count == 4, "A burst must have exactly three follow-ups")
      for (actual, expected) in zip(calls.dropFirst(), [0.05, 0.15, 0.3]) {
        expect(actual >= expected - 0.01, "Follow-ups must not fire before their intended deadlines")
        expect(actual < expected + 0.1, "Follow-ups must run near 50, 150 and 300ms")
      }
      run(for: 0.1)
      expect(calls.count == 4, "The burst must stop without permanent polling")
      scheduler.cancel()
    }
    do {
      var calls = 0
      let scheduler = InteractionRefresh { calls += 1 }
      scheduler.trigger()
      run(for: 0.02)
      scheduler.trigger()
      expect(calls == 2, "Every interaction needs an immediate refresh")
      run(for: 0.4)
      expect(calls == 5, "A replacement must cancel all previous follow-ups")
    }
    do {
      var calls = 0
      let scheduler = InteractionRefresh { calls += 1 }
      scheduler.trigger()
      scheduler.cancel()
      run(for: 0.35)
      expect(calls == 1, "Cancel must suppress all outstanding follow-ups")
      scheduler.trigger()
      run(for: 0.35)
      expect(calls == 5, "A cancelled scheduler must accept a later interaction")
    }
    do {
      var calls = 0
      var scheduler: InteractionRefresh? = InteractionRefresh { calls += 1 }
      weak var released = scheduler
      scheduler?.trigger()
      scheduler?.cancel()
      scheduler = nil
      expect(released == nil, "Cancelled timers must not keep the scheduler alive")
      run(for: 0.35)
      expect(calls == 1, "Releasing a cancelled scheduler must not allow callbacks")
    }
    do {
      var calls = 0
      var scheduler: InteractionRefresh? = InteractionRefresh { calls += 1 }
      weak var released = scheduler
      scheduler?.trigger()
      scheduler = nil
      expect(released == nil, "Pending timers must capture the scheduler weakly")
      run(for: 0.35)
      expect(calls == 1, "Deinitialization must cancel the remaining burst")
    }
    do {
      var calls = 0
      var scheduler: InteractionRefresh!
      scheduler = InteractionRefresh { calls += 1; scheduler.cancel() }
      scheduler.trigger()
      run(for: 0.35)
      expect(calls == 1, "Cancellation inside the immediate callback must prevent scheduling")
      scheduler = nil
    }
    do {
      var calls = 0
      var scheduler: InteractionRefresh!
      scheduler = InteractionRefresh {
        calls += 1
        if calls == 2 { scheduler.cancel() }
      }
      scheduler.trigger()
      run(for: 0.35)
      expect(calls == 2, "Cancellation inside a follow-up must suppress later follow-ups")
      scheduler = nil
    }
    do {
      var calls = 0
      var scheduler: InteractionRefresh!
      scheduler = InteractionRefresh {
        calls += 1
        if calls == 1 { scheduler.trigger() }
      }
      scheduler.trigger()
      run(for: 0.35)
      expect(calls == 5, "A reentrant trigger must retain only the replacement burst")
      scheduler = nil
    }
    do {
      let mode = RunLoop.Mode("InteractionRefreshTestMode")
      CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
      var calls = 0
      let scheduler = InteractionRefresh { calls += 1 }
      scheduler.trigger()
      run(for: 0.35, mode: mode)
      expect(calls == 4, "Follow-ups must also run in common tracking modes")
    }
    print("InteractionRefresh: 9 scenarios passed (timing, replacement, cancellation, lifetime, reentrancy and common modes)")
  }
}
