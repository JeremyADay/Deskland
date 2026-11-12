// Deskland Mac host: where the Desktop icons are.
// Copyright (C) 2026 Jeremy Day. Part of the Mac host for Deskland (BLEZZ0102/Deskland).
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See LICENSE at the top of the repository.
//
// Adapted from Desk Critters (wallpaper/Icons.swift). macOS tells an app where Finder's desktop
// icons are only through Accessibility, which the person grants in System Settings > Privacy &
// Security > Accessibility. Only icon geometry and structural/visibility metadata are read:
// never a title, file name or URL, and no action is ever performed on an icon.

import ApplicationServices
import Cocoa

enum Accessibility {
  /// Whether Accessibility has been granted. Never prompts.
  static var trusted: Bool { AXIsProcessTrusted() }

  /// Shows macOS's own Accessibility prompt (only from the menu item that says so).
  static func ask() {
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
  }
}

/// Polls Finder for the icon rects and reports them when they change.
final class DesktopIcons {
  /// The icons on the main screen, from its top left, in physical pixels: [left, top, right,
  /// bottom] as the page's {"t":"icons"} message takes them. Called on the main thread, only when
  /// the list differs from the last one. Without Accessibility: called once with an empty list.
  var onChange: ([[Int]]) -> Void = { _ in }
  /// Whether Accessibility is granted, when that changes (for the menu).
  var onTrust: (Bool) -> Void = { _ in }

  /// A busy Finder gets this long to answer one question.
  private static let patience: Float = 0.25
  private static let most = 600

  private var timer: Timer?
  private var mode = IconPollingMode.stopped
  /// In-flight AX requests cannot be cancelled. A result from an earlier mode must not update
  /// the scene after pausing, stopping, or resuming with a different desktop arrangement.
  private var generation = 0
  private var reading = false
  private var refreshPending = false
  private var lastChange = -Double.infinity
  /// Last visibility state successfully applied. While paused, an unchanged visible desktop
  /// needs no AX reads; a reveal (or a pending refresh after an AX failure) needs one.
  private var lastRefreshedVisibility: Bool?
  private(set) var trusted = false
  private var last: [[Int]]?
  private let queue = DispatchQueue(label: "deskland.icons", qos: .utility)

  func setMode(_ next: IconPollingMode) {
    guard next != mode else { return }
    mode = next
    generation += 1
    refreshPending = false
    timer?.invalidate()
    timer = nil
    lastChange = -Double.infinity
    lastRefreshedVisibility = nil
    // A paused transition checks visibility once, then only refreshes AX after a reveal.
    tick()
  }

  func stop() { setMode(.stopped) }

  /// Forgets the last list, so the next look is sent even if unchanged (after a page reload).
  func resend() {
    last = nil
    lastRefreshedVisibility = nil
    generation += 1
    tick()
  }

  /// A release can finish a drop or change desktop visibility before the next idle poll.
  /// Keep `last`: an unchanged layout must not restart the renderer's animation. If Finder is
  /// already answering, coalesce requests into one fresh read immediately after it finishes.
  func refreshAfterInteraction() {
    guard mode != .stopped, checkTrust() else { return }
    if reading { refreshPending = true; return }
    tick()
  }

  @discardableResult private func checkTrust() -> Bool {
    let current = Accessibility.trusted
    if current != trusted {
      trusted = current
      lastRefreshedVisibility = nil
      onTrust(current)
    }
    if !current { report([]) }
    return current
  }

  private func schedule() {
    timer?.invalidate()
    timer = nil
    let elapsed = ProcessInfo.processInfo.systemUptime - lastChange
    guard let interval = mode.interval(trusted: trusted, sinceChange: elapsed) else { return }
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.tick() }
    timer.tolerance = min(interval * 0.2, 0.1)
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    timer?.invalidate()
    timer = nil
    guard mode != .stopped else { return }
    guard checkTrust() else {
      schedule()
      return
    }
    // The outstanding request's callback will restart polling if its generation became stale.
    guard !reading else { return }
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    else { schedule(); return }
    let pid = finder.processIdentifier
    let windowManagerPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager")
      .first?.processIdentifier
    guard let screen = NSScreen.screens.first else { schedule(); return }
    let screenArea = CGRect(origin: .zero, size: screen.frame.size)
    let requestGeneration = generation
    let paused = mode == .permissionOnly
    let previousVisibility = lastRefreshedVisibility
    refreshPending = false
    reading = true
    queue.async { [weak self] in
      let visible = Self.desktopVisible(finder: pid, windowManager: windowManagerPID, screen: screenArea)
      let action = DesktopIconVisibility.readAction(paused: paused, visible: visible,
        lastRefreshedVisibility: previousVisibility)
      let rects: [CGRect]?
      switch action {
      case .clear: rects = []
      case .read: rects = Self.read(pid)
      case .keep: rects = nil
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.reading = false
        guard requestGeneration == self.generation else {
          if self.mode != .stopped { self.tick() }
          return
        }
        guard self.mode != .stopped else { return }
        // Permission can be revoked while Finder is answering.
        if self.checkTrust(), let rects {
          self.report(Self.physical(rects))
          if let visible { self.lastRefreshedVisibility = visible }
        }
        if self.refreshPending { self.tick() }
        else { self.schedule() }
      }
    }
  }

  private func report(_ rects: [[Int]]) {
    guard rects != last else { return }
    if last != nil { lastChange = ProcessInfo.processInfo.systemUptime }
    last = rects
    onChange(rects)
  }

  /// Global top-left point rects to the main screen's physical pixels; icons on other screens are
  /// left out (main screen only, like the Windows host).
  static func physical(_ rects: [CGRect]) -> [[Int]] {
    guard let main = NSScreen.screens.first else { return [] }
    let scale = main.backingScaleFactor
    let area = CGRect(origin: .zero, size: main.frame.size)  // the main screen, top left at 0,0
    return rects.filter { area.contains(CGPoint(x: $0.midX, y: $0.midY)) }
      .map { [Int(($0.minX * scale).rounded()), Int(($0.minY * scale).rounded()),
              Int(($0.maxX * scale).rounded()), Int(($0.maxY * scale).rounded())] }
      .sorted { $0[1] != $1[1] ? $0[1] < $1[1] : $0[0] < $1[0] }
  }

  // MARK: - Reading Finder, off the main thread

  /// Finder's AX tree survives macOS's click-to-reveal/hide transition. Read window metadata,
  /// not pixels or titles, to notice the WindowManager layer that actually hides those icons.
  private static func desktopVisible(finder: pid_t, windowManager: pid_t?, screen: CGRect) -> Bool? {
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let windows = list.compactMap { info -> DesktopIconVisibility.Window? in
      guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
        pid == finder || (windowManager != nil && pid == windowManager),
        let layer = info[kCGWindowLayer as String] as? Int,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        let alpha = info[kCGWindowAlpha as String] as? Double
      else { return nil }
      return DesktopIconVisibility.Window(owner: pid == finder ? .finder : .windowManager,
        bounds: rect, layer: layer, alpha: alpha, onScreen: true)
    }
    return DesktopIconVisibility.visible(windows: windows, screen: screen,
      iconLayer: Int(CGWindowLevelForKey(.desktopIconWindow)))
  }

  /// The rects of the icons on Finder's desktop (global, top left of the main screen, points), or
  /// nil when they cannot be read just now.
  private static func read(_ pid: pid_t) -> [CGRect]? {
    let finder = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(finder, patience)
    // The desktop is the scroll area among Finder's top elements; its windows are passed over.
    guard let top = children(of: finder) else { return nil }
    var rects: [CGRect] = []
    var found = false
    for area in top where role(of: area) == kAXScrollAreaRole as String {
      guard let inside = children(of: area) else { return nil }
      for group in inside where role(of: group) == kAXGroupRole as String {
        guard let icons = children(of: group), icons.count <= most else { return nil }
        found = true
        for icon in icons {
          guard let rect = frame(of: icon) else { return nil }
          if rect.width >= 8 && rect.height >= 8 && rect.width <= 600 && rect.height <= 600 { rects.append(rect) }
        }
      }
    }
    // Desktop icons hidden (Finder's "Show these items on the desktop" off, or Stage Manager
    // hiding them) or no desktop at all: no icons.
    return found ? rects : []
  }

  private static func children(of element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
    return value as? [AXUIElement]
  }

  private static func role(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  /// Position and size, in one message to Finder.
  private static func frame(of element: AXUIElement) -> CGRect? {
    let names = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values) == .success,
      let pair = values as? [AnyObject], pair.count == 2,
      CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin), AXValueGetValue(pair[1] as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }
}
