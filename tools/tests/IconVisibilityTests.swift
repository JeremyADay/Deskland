// Run with tools/test-mac-icon-visibility.sh. No desktop or preference changes.
import CoreGraphics

@main
struct IconVisibilityTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }

  static func main() {
    let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let other = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
    let layer = -2147483603
    func window(_ owner: DesktopIconVisibility.Owner, _ bounds: CGRect = main,
                layer value: Int = layer, alpha: Double = 1, onScreen: Bool = true) -> DesktopIconVisibility.Window {
      .init(owner: owner, bounds: bounds, layer: value, alpha: alpha, onScreen: onScreen)
    }
    func visible(_ windows: [DesktopIconVisibility.Window]) -> Bool? {
      DesktopIconVisibility.visible(windows: windows, screen: main, iconLayer: layer)
    }
    let finder = window(.finder)
    let shield = window(.windowManager)
    expect(visible([finder]) == true, "Finder alone must preserve icon geometry")
    expect(visible([shield, finder]) == false, "A frontmost WindowManager shield must clear hidden icons")
    expect(visible([finder, shield]) == true, "A shield behind Finder must not hide revealed icons")
    // Actual hide → reveal → hide ordering, even though Finder's AX list never changes.
    let sequence = [[shield, finder], [finder, shield], [shield, finder]].map { visible($0) }
    expect(sequence == [false, true, false], "Click-to-reveal transitions must restore and clear the same icons")
    expect(visible([window(.windowManager, alpha: 0), finder]) == true, "A transparent shield must be ignored")
    expect(visible([window(.windowManager, onScreen: false), finder]) == true, "An offscreen shield must be ignored")
    expect(visible([window(.windowManager, other), finder]) == true, "Another display's shield must not clear the main display")
    expect(visible([window(.windowManager, layer: 0), finder]) == true, "Normal windows must not count as hidden desktop icons")
    expect(visible([window(.windowManager, CGRect(x: 0, y: 0, width: 1470, height: 33)), finder]) == true,
      "Menu-bar strips must not clear desktop icons")
    expect(visible([]) == nil, "Missing window metadata must fall back to AX instead of clearing icons")
    expect(DesktopIconVisibility.visible(windows: [shield], screen: .zero, iconLayer: layer) == nil,
      "An unknown display frame must not manufacture a hidden result")

    // The native paused polling path must clear/reveal without continuously querying Finder.
    func action(_ visible: Bool?, _ previous: Bool?, paused: Bool = true) -> DesktopIconVisibility.ReadAction {
      DesktopIconVisibility.readAction(paused: paused, visible: visible, lastRefreshedVisibility: previous)
    }
    expect(action(true, nil) == .read, "Initial known-visible paused state needs one geometry refresh")
    expect(action(true, true) == .keep, "Stable visible paused state must not keep polling Finder")
    expect(action(false, true) == .clear, "Hiding icons while paused must clear cached geometry")
    expect(action(false, false) == .clear, "A stable hidden state needs no Finder reads")
    expect(action(true, false) == .read, "Revealing icons while paused needs one geometry refresh")
    expect(action(nil, true) == .keep, "Unknown paused visibility must preserve a previous visible layout")
    expect(action(nil, false) == .keep, "Unknown paused visibility must preserve a previous hidden layout")
    expect(action(nil, nil) == .keep, "Unknown initial paused visibility must not start AX polling")
    expect(action(true, false) == .read, "A failed reveal refresh, not yet remembered, must be retryable")
    expect(action(true, true, paused: false) == .read, "Active mode must still detect ordinary icon moves")
    expect(action(nil, true, paused: false) == .read, "Active unknown visibility must fall back to AX")
    expect(action(false, true, paused: false) == .clear, "Active hidden state must skip Finder reads too")
    print("DesktopIconVisibility: hidden/revealed ordering, display filtering and paused refresh decisions passed")
  }
}
