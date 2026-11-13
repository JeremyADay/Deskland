// Deskland Mac host: self-tests that never show the wallpaper.
// Copyright (C) 2026 Jeremy Day. Part of the Mac host for Deskland (BLEZZ0102/Deskland).
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See LICENSE at the top of the repository.
//
//   Deskland --selftest <meadow|beach> <out.png> [--no-icons]
//     Loads the theme page in a web view in a window placed off every screen (1728 x 1117 points),
//     sends the theme's settings and a fixed set of fake icons once the page says 'ready', waits
//     for the scene to settle, writes a snapshot and exits 0. Any JavaScript error: exit 1.
//   Deskland --selftest-shim
//     Checks the shim's message flow against a tiny stand-in page: 'ready' arrives before anything
//     is sent, and the page's listener gets every message in order, byte for byte.
// No menu bar item, no wallpaper window, nothing on screen.

import Cocoa
import WebKit

/// Fake desktop icons in points from the top left of a 1728 x 1117 screen: a grouped column of
/// six at the top right, as Finder arranges new icons, and three scattered ones.
enum FakeIcons {
  static let size = CGSize(width: 1728, height: 1117)
  static let scale = 2.0
  static let points: [CGRect] = {
    var list: [CGRect] = []
    for row in 0..<6 { list.append(CGRect(x: 1628, y: 40 + Double(row) * 100, width: 80, height: 90)) }
    list.append(CGRect(x: 380, y: 300, width: 80, height: 90))
    list.append(CGRect(x: 900, y: 640, width: 80, height: 90))
    list.append(CGRect(x: 180, y: 860, width: 80, height: 90))
    return list
  }()

  static func physical(scale: Double) -> [[Int]] {
    points.map { [Int($0.minX * scale), Int($0.minY * scale), Int($0.maxX * scale), Int($0.maxY * scale)] }
  }
}

/// A window off every screen: it renders like any window, but nobody sees it.
private func offscreenWindow(_ size: CGSize) -> NSWindow {
  let far = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxX) } + 4000
  let window = NSWindow(
    contentRect: NSRect(x: far, y: -6000, width: size.width, height: size.height), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.ignoresMouseEvents = true
  window.collectionBehavior = [.transient, .ignoresCycle]
  return window
}

private func fail(_ text: String) -> Never {
  FileHandle.standardError.write(Data("selftest FAILED: \(text)\n".utf8))
  exit(1)
}

private func say(_ text: String) { print("selftest: \(text)"); fflush(stdout) }

/// Exits 1 after a while whatever happens, even if WebKit never answers a call: off the main
/// thread, so a stuck main thread cannot hold it up either.
private func watchdog(_ seconds: Double) {
  DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
    fail("no result after \(Int(seconds)) s (a WebKit callback never came back)")
  }
}

final class SceneTest: NSObject, NSApplicationDelegate {
  private let theme: Theme
  private let output: URL
  private let withIcons: Bool
  private var window: NSWindow?
  private var page: ScenePage?
  private var errors: [String] = []
  private var log: [String] = []
  private let started = Date()

  init(theme: Theme, output: URL, withIcons: Bool) {
    self.theme = theme
    self.output = output
    self.withIcons = withIcons
  }

  private func note(_ text: String) {
    let line = String(format: "%5.2fs %@", Date().timeIntervalSince(started), text)
    log.append(line)
    say(line)
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    let window = offscreenWindow(FakeIcons.size)
    let page = ScenePage(frame: NSRect(origin: .zero, size: FakeIcons.size), theme: theme)
    // A window off every screen has no screen to take a scale from (it comes out 1x); WebKit's
    // own override (private, as the other keys in Scene.swift) makes the page a Retina screen.
    let scaleKey = "overrideDeviceScaleFactor"
    if page.view.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")) {
      page.view.setValue(FakeIcons.scale, forKey: scaleKey)
    }
    page.onError = { [weak self] text in
      self?.errors.append(text)
      self?.note("JS error: \(text)")
    }
    page.onMessage = { [weak self] text in self?.note("page says: \(text.prefix(80))") }
    page.onReady = { [weak self] in self?.ready() }
    window.contentView = page.view
    window.orderFrontRegardless()
    self.window = window
    self.page = page
    self.note("loading \(theme.page) over \(Scene.scheme)://, window scale \(window.backingScaleFactor)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
      guard let self, self.page?.ready != true else { return }
      fail("the page never said 'ready' (\(self.errors.joined(separator: "; ")))")
    }
    watchdog(45)
  }

  private func ready() {
    guard let page else { return }
    let sentBefore = page.sentCount
    note("received 'ready' (messages sent before it: \(sentBefore))")
    if sentBefore != 0 { fail("messages were sent before 'ready'") }
    page.send(["t": "settings", "v": theme.defaults])
    note("sent settings \(Scene.json(theme.defaults))")
    let scale = FakeIcons.scale
    let rects = withIcons ? FakeIcons.physical(scale: scale) : []
    page.send(["t": "icons", "vis": true, "r": rects])
    note("sent icons: \(rects.count) rects at scale \(scale)")
    page.send(["t": "pause", "v": false])
    note("sent pause false")
    // The page draws the land / clouds growing from the first icons over a couple of seconds.
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in self?.finish() }
  }

  private func finish() {
    guard let page else { return }
    let probe = """
      (() => { const c = document.querySelector('canvas');
        return JSON.stringify({ dpr: devicePixelRatio, w: innerWidth, h: innerHeight, hidden: document.hidden,
          canvas: c && [c.width, c.height], webgl2: !!(c && c.getContext('webgl2')), href: location.href,
          cap30: typeof P === 'object' ? P.cap30 : null, fps: typeof fpsEMA === 'number' ? Math.round(fpsEMA) : null,
          frames: typeof frameN === 'number' ? frameN : null }); })()
      """
    note("asking the page for its state")
    page.view.evaluateJavaScript(probe) { [weak self] value, error in
      guard let self else { return }
      if let error { fail("could not read page state: \(error.localizedDescription)") }
      guard let text = value as? String, let data = text.data(using: .utf8),
        let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { fail("the page returned invalid state: \(value ?? "nil")") }
      self.note("page state: \(text)")
      guard state["webgl2"] as? Bool == true else { fail("WebGL2 is unavailable") }
      guard let width = state["w"] as? Double, let height = state["h"] as? Double,
        let scale = state["dpr"] as? Double, width > 0, height > 0, scale > 0,
        let canvas = state["canvas"] as? [Int], canvas.count == 2,
        canvas[0] == Int((width * scale).rounded()), canvas[1] == Int((height * scale).rounded())
      else { fail("canvas dimensions do not match the page's physical pixel size") }
      guard let frames = state["frames"] as? Int, frames > 0 else { fail("the scene did not render any frames") }
      guard page.sentCount == 3 else { fail("expected settings, icons and pause to be sent exactly once") }
      self.note("taking the snapshot")
      self.snapshot()
    }
  }

  private func snapshot() {
    guard let page else { return }
    page.view.takeSnapshot(with: nil) { [weak self] image, error in
      guard let self else { return }
      guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("no snapshot: \(error?.localizedDescription ?? "?")")
      }
      let rep = NSBitmapImageRep(cgImage: cg)
      guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode the PNG") }
      do { try png.write(to: self.output) } catch { fail("could not write \(self.output.path): \(error)") }
      self.note("wrote \(self.output.path) (\(cg.width) x \(cg.height) pixels)")
      if !self.errors.isEmpty { fail("\(self.errors.count) JavaScript error(s): \(self.errors.joined(separator: " | "))") }
      say("OK")
      exit(0)
    }
  }
}

/// The shim's message flow against a stand-in page that behaves as the theme pages do: it
/// registers a listener, says 'ready', and echoes every message it gets back as "echo|<data>".
final class ShimTest: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var page: WKWebView?
  private let shim = ShimHandler()
  private var events: [String] = []
  private let messages = [
    #"{"t":"settings","v":{"sigma":72}}"#,
    #"{"r":[[3256,80,3416,260],[10,20,30,40]],"t":"icons","vis":true}"#,
    #"{"t":"pause","v":true}"#,
    #"{"t":"note","v":"quotes \" and \\ and </script> and 草地"}"#,
  ]

  private static let stand = """
    <!doctype html><html><body><script>
    const host = window.chrome && window.chrome.webview;
    if (!host) throw new Error('no window.chrome.webview');
    const fn = ev => host.postMessage('echo|' + ev.data + '|' + typeof ev.data);
    host.addEventListener('message', fn);
    host.addEventListener('message', ev => { if (ev.data === 'unhook') host.removeEventListener('message', fn); });
    host.postMessage('ready');
    </script></body></html>
    """

  func applicationDidFinishLaunching(_ note: Notification) {
    let config = WKWebViewConfiguration()
    config.userContentController.addUserScript(Shim.userScript)
    config.userContentController.add(shim, name: Shim.handler)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
    let window = offscreenWindow(CGSize(width: 200, height: 200))
    window.contentView = view
    window.orderFrontRegardless()
    self.window = window
    page = view
    shim.onError = { text in fail("JS error: \(text)") }
    shim.onMessage = { [weak self] text in self?.got(text) }
    view.loadHTMLString(Self.stand, baseURL: nil)
    watchdog(20)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      fail("timed out; events so far: \(self?.events ?? [])")
    }
  }

  private func got(_ text: String) {
    events.append(text)
    say("page -> host: \(text)")
    if text == "ready" {
      if events.count != 1 { fail("'ready' was not the first message") }
      for message in messages + ["unhook", "after unhook"] {
        say("host -> page: \(message)")
        page?.evaluateJavaScript(Shim.deliver(message))
      }
      // Everything echoed, in order, then nothing after the listener was removed.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.check() }
    }
  }

  private func check() {
    let expected = ["ready"] + (messages + ["unhook"]).map { "echo|\($0)|string" }
    guard events == expected else { fail("wrong flow.\nexpected \(expected)\n     got \(events)") }
    say("flow OK: 'ready' first, \(messages.count) messages echoed in order as strings, removeEventListener works")
    say("OK")
    exit(0)
  }
}
