// Deskland Mac host: the wallpaper window, the menu bar item and when to pause.
// Copyright (C) 2026 Jeremy Day. Part of the Mac host for Deskland (BLEZZ0102/Deskland).
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See LICENSE at the top of the repository.
//
// Adapted from Desk Critters (wallpaper/Wallpaper.swift). One borderless window on the main screen
// at the desktop window level: above the still wallpaper picture, below the desktop icons, on
// every Space. It never takes mouse events, so the desktop keeps working as usual.

import Cocoa
import WebKit

/// A window that keeps the exact frame it is given (AppKit insets ordinary windows from the
/// screen edges; a wallpaper has to reach them) and never becomes key.
final class DesktopWindow: NSWindow {
  override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

enum App {
  /// The product's display name, as on Windows.
  static let name = "Deskland Preview"
  /// Its own identity, apart from any other Deskland build (Info.plist has the same id).
  static let id = "app.deskland.preview.mac"

  /// ~/Library/Application Support/app.deskland.preview.mac
  static var support: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent(id, isDirectory: true)
  }

  private static var lock: Int32 = -1

  /// One wallpaper at a time: true when this process holds the instance lock, false when another
  /// copy is already running. The lock goes with the process, however it ends.
  static func claimInstance() -> Bool {
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let fd = open(support.appendingPathComponent("instance.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return true }  // nothing to lock against; better to run than not at all
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return false
    }
    lock = fd
    return true
  }
}

enum Log {
  static func line(_ text: String) { NSLog("deskland: %@", text) }
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var window: DesktopWindow?
  private var page: ScenePage?
  private let icons = DesktopIcons()
  private var status: NSStatusItem?
  private var themeItems: [Theme: NSMenuItem] = [:]
  private let pauseItem = NSMenuItem(title: Strings.pause, action: #selector(togglePause), keyEquivalent: "")
  private let grantItem = NSMenuItem(title: Strings.own("grant"), action: #selector(grantAccess), keyEquivalent: "")
  private var watchTimer: Timer?
  private var lastIcons: [[Int]] = []
  /// The pause the page was last told, or nil when it has not been told yet.
  private var sentPause: Bool?
  private var policy = HostPolicy()
  private var mainFrame = NSRect.zero

  private var theme: Theme {
    get { Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .meadow }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    addMenu()
    buildWindow()
    icons.onChange = { [weak self] rects in self?.iconsChanged(rects) }
    icons.onTrust = { [weak self] trusted in self?.grantItem.isHidden = trusted }

    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    // Nothing to draw while the display sleeps, the session is switched away, the screen is
    // locked or the screen saver runs.
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, reason, suspended) in [
      (NSWorkspace.screensDidSleepNotification, HostPolicy.Suspension.displaySleep, true),
      (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
      (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
      (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false),
    ] {
      workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.setSuspended(reason, suspended)
      }
    }
    let distributed = DistributedNotificationCenter.default()
    for (name, reason, suspended) in [
      ("com.apple.screenIsLocked", HostPolicy.Suspension.locked, true),
      ("com.apple.screenIsUnlocked", .locked, false),
      ("com.apple.screensaver.didstart", .screenSaver, true),
      ("com.apple.screensaver.didstop", .screenSaver, false),
    ] {
      distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
        self?.setSuspended(reason, suspended)
      }
    }
    updatePause()
  }

  /// Quit (from the menu, a log out or a plain `kill`) takes the wallpaper window away first, so the
  /// normal desktop picture is back at once. macOS would remove it with the process anyway.
  func applicationWillTerminate(_ note: Notification) {
    watchTimer?.invalidate()
    icons.stop()
    page?.close()
    page = nil
    window?.orderOut(nil)
    window = nil
    Log.line("quit")
  }

  // MARK: - The window and the page

  private func buildWindow() {
    guard let screen = NSScreen.screens.first else { return }
    mainFrame = screen.frame
    let window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.hasShadow = false
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    window.canHide = false
    window.setFrame(screen.frame, display: true)
    self.window = window
    loadPage()
    window.orderFrontRegardless()
  }

  private func loadPage() {
    page?.close()
    guard let window else { return }
    let page = ScenePage(frame: NSRect(origin: .zero, size: window.frame.size), theme: theme)
    page.view.autoresizingMask = [.width, .height]
    page.onReady = { [weak self, weak page] in
      guard let self, let page else { return }
      // As the Windows host: settings first (the shore is worked out from them), then the icons
      // and the pause state.
      page.send(["t": "settings", "v": page.theme.defaults])
      self.sendIcons(to: page)
      self.sentPause = nil
      self.updatePause()
      Log.line("\(page.theme.rawValue) ready")
    }
    page.onError = { text in Log.line("page: \(text)") }
    page.onMessage = { text in Log.line("page says \(text.prefix(80))") }
    window.contentView = page.view
    self.page = page
  }

  private func sendIcons(to page: ScenePage) {
    page.send(["t": "icons", "vis": true, "r": lastIcons])
  }

  private func iconsChanged(_ rects: [[Int]]) {
    lastIcons = rects
    if let page { sendIcons(to: page) }
  }

  @objc private func screensChanged() {
    guard let screen = NSScreen.screens.first, screen.frame != mainFrame else { return }
    mainFrame = screen.frame
    window?.setFrame(screen.frame, display: true)
    // The page measures itself on resize; the icons are read again for the new arrangement.
    icons.resend()
  }

  // MARK: - Pause

  private func setSuspended(_ reason: HostPolicy.Suspension, _ suspended: Bool) {
    policy.setSuspended(reason, suspended)
    updatePause()
  }

  private func updatePolling() {
    if policy.pollWindows {
      if watchTimer == nil {
        // The windows may have changed while manually paused, asleep or locked. Sample before
        // deciding whether to resume the page or restart Finder reads.
        policy.covered = Self.screenCovered(mainFrame.size)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.watchWindows() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
      }
    } else {
      watchTimer?.invalidate()
      watchTimer = nil
    }
    icons.setMode(policy.iconMode)
  }

  /// Whether one ordinary window covers essentially the whole main screen (a zoomed or full
  /// screen window). Positions and sizes only; window titles are never read.
  private func watchWindows() {
    guard policy.pollWindows else { return }
    policy.covered = Self.screenCovered(mainFrame.size)
    updatePause()
  }

  static func screenCovered(_ size: CGSize) -> Bool {
    guard size.width > 0,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let me = ProcessInfo.processInfo.processIdentifier
    let screen = CGRect(origin: .zero, size: size)  // the main screen, global top-left coordinates
    for info in list {
      guard info[kCGWindowLayer as String] as? Int == 0,
        info[kCGWindowOwnerPID as String] as? Int32 != me,
        info[kCGWindowAlpha as String] as? Double ?? 0 > 0.95,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { continue }
      let clip = rect.intersection(screen)
      // A zoomed window leaves the menu bar (and perhaps the Dock) showing: 85% of the screen is
      // "essentially all" of the desktop picture.
      if !clip.isNull && clip.width * clip.height >= 0.85 * screen.width * screen.height { return true }
    }
    return false
  }

  private func updatePause() {
    updatePolling()
    guard let page, page.ready else { return }
    let pause = policy.paused
    guard pause != sentPause else { return }
    sentPause = pause
    page.send(["t": "pause", "v": pause])
    Log.line(pause ? "paused" : "playing")
  }

  // MARK: - The menu bar

  private func addMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let image = NSImage(systemSymbolName: "leaf", accessibilityDescription: App.name) {
      image.isTemplate = true
      item.button?.image = image
    } else {
      item.button?.title = "D"
    }
    item.button?.toolTip = App.name
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false

    let themes = NSMenu()
    for choice in Theme.allCases {
      let entry = NSMenuItem(title: choice.title, action: #selector(chooseTheme), keyEquivalent: "")
      entry.target = self
      entry.representedObject = choice.rawValue
      themes.addItem(entry)
      themeItems[choice] = entry
    }
    let themeItem = NSMenuItem(title: Strings.theme, action: nil, keyEquivalent: "")
    themeItem.submenu = themes
    menu.addItem(themeItem)
    pauseItem.target = self
    menu.addItem(pauseItem)
    let reload = NSMenuItem(title: Strings.reload, action: #selector(reloadPage), keyEquivalent: "")
    reload.target = self
    menu.addItem(reload)
    menu.addItem(.separator())
    grantItem.target = self
    grantItem.isHidden = Accessibility.trusted
    menu.addItem(grantItem)
    let about = NSMenuItem(title: Strings.own("about"), action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(about)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: Strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
    item.menu = menu
    status = item
  }

  func menuWillOpen(_ menu: NSMenu) {
    for (choice, entry) in themeItems { entry.state = choice == theme ? .on : .off }
    pauseItem.state = policy.manualPause ? .on : .off
    grantItem.isHidden = Accessibility.trusted
  }

  @objc private func chooseTheme(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let choice = Theme(rawValue: id), choice != theme else { return }
    theme = choice
    loadPage()
  }

  @objc private func togglePause() {
    policy.manualPause.toggle()
    updatePause()
  }

  @objc private func reloadPage() {
    sentPause = nil
    page?.reload()
  }

  @objc private func grantAccess() { Accessibility.ask() }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = App.name
    alert.informativeText = Strings.own("aboutText")
    alert.runModal()
  }
}
