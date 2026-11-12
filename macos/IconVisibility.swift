// Finder can expose icon geometry even while WindowManager hides the icons.
// Part of the Mac host for Deskland. GPL-3.0-or-later, see LICENSE.

import CoreGraphics

/// A geometry-only view of relevant WindowServer entries, ordered front to back.
/// Kept separate from AX/CoreGraphics collection so hidden/revealed transitions can be tested.
enum DesktopIconVisibility {
  enum Owner { case finder, windowManager }
  enum ReadAction { case clear, read, keep }

  struct Window {
    let owner: Owner
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    let onScreen: Bool
  }

  /// Pausing stops routine AX geometry polling, but visibility changes still need a static
  /// update. A successful visible refresh is remembered; a failed AX refresh can retry later.
  static func readAction(paused: Bool, visible: Bool?, lastRefreshedVisibility: Bool?) -> ReadAction {
    if visible == false { return .clear }
    if !paused { return .read }
    if visible == true && lastRefreshedVisibility != true { return .read }
    return .keep
  }

  /// nil means there is no reliable full-screen desktop-layer signal; use Finder's AX result.
  /// Ordinary app windows are deliberately ignored: covering the desktop is handled by pausing,
  /// and must not destroy its icon layout.
  static func visible(windows: [Window], screen: CGRect, iconLayer: Int) -> Bool? {
    guard screen.width > 0, screen.height > 0 else { return nil }
    for window in windows where window.onScreen && window.layer == iconLayer && window.alpha > 0.01 {
      let overlap = window.bounds.intersection(screen)
      guard !overlap.isNull,
        overlap.width * overlap.height >= screen.width * screen.height * 0.98
      else { continue }
      // On current macOS, hiding desktop items leaves Finder's icon window and AX tree intact.
      // WindowManager inserts a full-screen window ahead of Finder at the same icon level.
      return window.owner == .finder
    }
    return nil
  }
}
