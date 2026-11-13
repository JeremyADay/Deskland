// Run with tools/test-mac-policy.sh. No AppKit, WebKit, GUI, or Accessibility access.

@main
struct HostPolicyTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }

  static func main() {
    var policy = HostPolicy()
    expect(!policy.paused && policy.pollWindows && policy.iconMode == .active,
      "An uncovered active desktop must animate and poll")

    policy.covered = true
    expect(policy.paused && policy.pollWindows && policy.iconMode == .permissionOnly,
      "Coverage must stop icon reads but keep watching for uncovering")
    policy.manualPause = true
    expect(policy.paused && !policy.pollWindows && policy.iconMode == .permissionOnly,
      "Manual pause must stop window and icon reads")
    policy.covered = false
    expect(policy.paused, "Uncovering must not cancel a manual pause")
    policy.manualPause = false
    expect(!policy.paused && policy.iconMode == .active, "Manual resume must enable immediate icon refresh")

    // Exercise every ordering of overlapping OS reasons: waking the display must not clear a
    // lock, stopping the saver must not activate a switched-out session, and so on.
    for first in HostPolicy.Suspension.allCases {
      for second in HostPolicy.Suspension.allCases where first != second {
        var overlapping = HostPolicy()
        overlapping.setSuspended(first, true)
        overlapping.setSuspended(second, true)
        overlapping.setSuspended(first, false)
        expect(overlapping.paused && !overlapping.pollWindows && overlapping.iconMode == .stopped,
          "Clearing \(first) must leave \(second) suspended, with no polling timers")
        overlapping.setSuspended(second, false)
        expect(!overlapping.paused && overlapping.pollWindows && overlapping.iconMode == .active,
          "Clearing the final reason must restore active polling")
      }
    }

    policy.manualPause = true
    policy.setSuspended(.locked, true)
    policy.setSuspended(.displaySleep, true)
    policy.setSuspended(.displaySleep, false)
    policy.setSuspended(.locked, false)
    expect(policy.paused && !policy.pollWindows && policy.iconMode == .permissionOnly,
      "Wake and unlock must preserve the user's manual pause")
    policy.manualPause = false
    policy.covered = true
    expect(policy.paused && policy.pollWindows, "A still-covered desktop must wait for uncovering")
    policy.covered = false
    expect(!policy.paused && policy.iconMode == .active, "Uncovering must restore icon reads")

    expect(IconPollingMode.stopped.interval(trusted: true, sinceChange: 0) == nil,
      "Sleeping or locked hosts must have no icon timer")
    expect(IconPollingMode.permissionOnly.interval(trusted: true, sinceChange: 0) == 2,
      "Paused hosts must only check permission every two seconds")
    expect(IconPollingMode.active.interval(trusted: false, sinceChange: 0) == 2,
      "Missing permission must not leave a 10 Hz timer")
    expect(IconPollingMode.active.interval(trusted: true, sinceChange: 1.99) == 0.1,
      "Recently moved icons must be followed at the fast interval")
    expect(IconPollingMode.active.interval(trusted: true, sinceChange: 2) == 0.4,
      "The fast interval must end after two seconds")
    expect(IconPollingMode.active.interval(trusted: true, sinceChange: .infinity) == 0.4,
      "An idle desktop must use the slow interval")
    print("HostPolicy: overlapping pause reasons and polling intervals passed")
  }
}
