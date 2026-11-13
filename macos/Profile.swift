// Developer profiling and a windowed demonstration of the native Mac renderer.
// GPL-3.0-or-later; see LICENSE at the repository root.

import Cocoa
import WebKit

private func profileLog(_ text: String) {
  print("profile: \(text)")
  fflush(stdout)
}

private func profileFail(_ text: String) -> Never {
  FileHandle.standardError.write(Data("profile FAILED: \(text)\n".utf8))
  exit(1)
}

/// Fixed terrain seed and icon layout reduce variation; actors and noise still use Math.random.
private enum DemoLayout {
  static let seed = 12345

  static func settings(_ theme: Theme) -> [String: Any] {
    var settings = theme.defaults
    settings["seed"] = seed
    return settings
  }

  static func icons(size: CGSize, scale: Double, moved: Bool = false) -> [[Double]] {
    FakeIcons.points.enumerated().map { index, rect in
      let shift = moved && index >= 6 ? 140.0 : 0
      let x = (rect.minX + shift) * size.width / FakeIcons.size.width
      let y = rect.minY * size.height / FakeIcons.size.height
      let w = rect.width * size.width / FakeIcons.size.width
      let h = rect.height * size.height / FakeIcons.size.height
      return [x * scale, y * scale, (x + w) * scale, (y + h) * scale]
    }
  }
}

/// Uses the actual main screen's logical size and DPR, but keeps the test window offscreen.
/// This tests the renderer; it deliberately does not simulate Finder polling or window coverage.
final class SceneProfile: NSObject, NSApplicationDelegate {
  private let theme: Theme
  private let output: URL
  private let withIcons: Bool
  private var window: NSWindow?
  private var page: ScenePage?
  private var size = CGSize.zero
  private var scale = 1.0
  private var errors: [String] = []
  private var phases: [[String: Any]] = []
  private var begun = false
  private let started = ProcessInfo.processInfo.systemUptime
  private let phasesToRun: [(name: String, paused: Bool, seconds: Double)] = [
    ("active", false, 12), ("paused", true, 8), ("resumed", false, 8),
  ]

  init(theme: Theme, output: URL, withIcons: Bool) {
    self.theme = theme
    self.output = output
    self.withIcons = withIcons
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let screen = NSScreen.screens.first else { profileFail("no main screen") }
    size = screen.frame.size
    scale = screen.backingScaleFactor
    let far = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxX) } + 4000
    let window = NSWindow(contentRect: NSRect(x: far, y: -6000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.transient, .ignoresCycle]
    let page = ScenePage(frame: NSRect(origin: .zero, size: size), theme: theme)
    if page.view.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")) {
      page.view.setValue(scale, forKey: "overrideDeviceScaleFactor")
    } else if scale != 1 {
      profileFail("WebKit cannot set the offscreen device scale to the main screen's scale")
    }
    page.onError = { [weak self] text in
      self?.errors.append(text)
      profileLog("JS error: \(text)")
    }
    page.onReady = { [weak self] in self?.ready() }
    window.contentView = page.view
    window.orderFrontRegardless()
    self.window = window
    self.page = page
    profileLog("loading \(theme.rawValue), \(size.width)×\(size.height) points, DPR \(scale), pid \(getpid())")
    DispatchQueue.global().asyncAfter(deadline: .now() + 75) {
      profileFail("watchdog: profile did not finish within 75 s")
    }
  }

  private func ready() {
    guard let page else { return }
    guard !begun else { profileFail("page reloaded during profiling") }
    begun = true
    page.send(["t": "settings", "v": DemoLayout.settings(theme)])
    page.send(["t": "icons", "vis": true,
               "r": withIcons ? DemoLayout.icons(size: size, scale: scale) : []])
    page.send(["t": "pause", "v": false])
    evaluate(Self.instrument) { [weak self] _ in
      profileLog("phase warmup 5 s")
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.beginPhase(0) }
    }
  }

  private func evaluate(_ source: String, then completion: @escaping (Any?) -> Void) {
    page?.view.evaluateJavaScript(source) { value, error in
      if let error { profileFail("JavaScript probe: \(error.localizedDescription)") }
      completion(value)
    }
  }

  private func beginPhase(_ index: Int) {
    guard index < phasesToRun.count else { finish(); return }
    let phase = phasesToRun[index]
    page?.send(["t": "pause", "v": phase.paused])
    // Exclude state-transition work, including Beach's one-off paused terrain draw.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      self.evaluate("window.__nativeProfile.begin();") { [self] _ in
        let start = ProcessInfo.processInfo.systemUptime - self.started
        profileLog("phase \(phase.name) \(phase.seconds) s; elapsed \(String(format: "%.3f", start)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + phase.seconds) { [weak self] in
          self?.endPhase(index, start: start)
        }
      }
    }
  }

  private func endPhase(_ index: Int, start: Double) {
    evaluate("JSON.stringify(window.__nativeProfile.end());") { [weak self] value in
      guard let self, let text = value as? String, let data = text.data(using: .utf8),
        var result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { profileFail("invalid profile result") }
      let phase = self.phasesToRun[index]
      result["name"] = phase.name
      result["hostStartSeconds"] = start
      result["hostEndSeconds"] = ProcessInfo.processInfo.systemUptime - self.started
      self.phases.append(result)
      profileLog("result \(phase.name) \(text)")
      self.beginPhase(index + 1)
    }
  }

  private func finish() {
    var failures = errors
    for phase in phases {
      let name = phase["name"] as? String ?? "?"
      let frames = (phase["renderedFrames"] as? NSNumber)?.intValue ?? 0
      let measuredScale = (phase["dpr"] as? NSNumber)?.doubleValue ?? 0
      if name == "paused" && frames != 0 { failures.append("paused phase rendered \(frames) frames") }
      if name != "paused" && frames <= 0 { failures.append("\(name) phase rendered no frames") }
      if measuredScale != scale { failures.append("\(name) DPR \(measuredScale), expected \(scale)") }
      if phase["webgl2"] as? Bool != true { failures.append("\(name) did not use WebGL2") }
    }
    let result: [String: Any] = [
      "schemaVersion": 1, "theme": theme.rawValue, "mode": "offscreen-renderer",
      "screenPoints": [size.width, size.height], "requestedDPR": scale,
      "fakeIconCount": withIcons ? FakeIcons.points.count : 0,
      "settings": DemoLayout.settings(theme), "warmupSeconds": 5,
      "transitionSettleSeconds": 0.5, "phases": phases,
      "accessibilityTrusted": Accessibility.trusted,
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "errors": failures, "passed": failures.isEmpty,
      "timingNote": "Frame callback wall times measure JavaScript plus synchronous API waits, not asynchronous GPU completion. Offscreen renderer only; Finder polling and wallpaper coverage are not exercised. rAF counts include capped or paused callbacks, renderedFrames counts completed theme frames.",
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch { profileFail("could not write JSON: \(error.localizedDescription)") }
    page?.close()
    window?.orderOut(nil)
    profileLog("\(failures.isEmpty ? "OK" : "FAILED") wrote \(output.path)")
    exit(failures.isEmpty ? 0 : 1)
  }

  private static let instrument = """
    (() => {
      if (typeof frame !== 'function' || typeof frameN !== 'number') throw new Error('missing theme frame counters');
      const nativeRAF = window.requestAnimationFrame.bind(window);
      let measuring = false, callbacks = 0, readbacks = 0, durations = [], intervals = [], previousRender = null;
      let startFrame = 0, startTime = 0;
      const nativeReadPixels = gl.readPixels.bind(gl);
      gl.readPixels = (...args) => { if (measuring) readbacks++; return nativeReadPixels(...args); };
      window.requestAnimationFrame = callback => nativeRAF(now => {
        if (callback !== frame) { callback(now); return; }
        const before = frameN, begin = performance.now();
        callback(now);
        if (!measuring) return;
        callbacks++;
        if (frameN !== before) {
          durations.push(performance.now() - begin);
          if (previousRender !== null) intervals.push(now - previousRender);
          previousRender = now;
        }
      });
      const summary = values => {
        const sorted = values.slice().sort((a, b) => a - b);
        const at = q => sorted.length ? sorted[Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1)] : null;
        return { count: sorted.length, median: at(.5), p95: at(.95), max: sorted.length ? sorted[sorted.length - 1] : null,
          mean: sorted.length ? sorted.reduce((a,b) => a+b, 0) / sorted.length : null };
      };
      window.__nativeProfile = {
        begin() {
          callbacks = 0; readbacks = 0; durations = []; intervals = []; previousRender = null;
          startFrame = frameN; startTime = performance.now(); measuring = true;
        },
        end() {
          measuring = false;
          const endTime = performance.now(), endFrame = frameN, seconds = (endTime - startTime) / 1000;
          const canvas = document.querySelector('canvas');
          return { startFrame, endFrame, renderedFrames: endFrame - startFrame, elapsedSeconds: seconds,
            renderedFPS: (endFrame - startFrame) / seconds, rafCallbacks: callbacks, rafCallbacksPerSecond: callbacks / seconds,
            readPixelsCalls: readbacks,
            callbackMilliseconds: summary(durations), renderIntervalMilliseconds: summary(intervals),
            dpr: devicePixelRatio, viewport: [innerWidth, innerHeight], canvas: canvas && [canvas.width, canvas.height],
            webgl2: !!(canvas && canvas.getContext('webgl2')), cap30: P.cap30, paused, hidden: document.hidden };
        }
      };
      return true;
    })()
    """
}

/// An ordinary window for showing both themes without changing the desktop or granting access.
final class SceneDemo: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var theme: Theme
  private var window: NSWindow?
  private var page: ScenePage?
  private var paused = false
  private var moved = false
  private var pauseItem: NSMenuItem?
  private var themeItems: [Theme: NSMenuItem] = [:]
  private let testOutput: URL?
  private var checks: [[String: Any]] = []
  private var errors: [String] = []
  private var testsStarted = false
  private var finishing = false
  private var readyCount = 0
  private var afterReady: (() -> Void)?
  private var afterShare: ((String) -> Void)?
  private var shareGeneration = 0

  init(theme: Theme, testOutput: URL? = nil) {
    self.theme = theme
    self.testOutput = testOutput
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let testOutput {
      do { try FileManager.default.createDirectory(at: testOutput, withIntermediateDirectories: true) }
      catch { profileFail("could not create demo test output: \(error.localizedDescription)") }
      DispatchQueue.global().asyncAfter(deadline: .now() + 65) {
        profileFail("demo watchdog: integration tests did not finish within 65 s")
      }
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.minSize = NSSize(width: 640, height: 420)
    window.isReleasedWhenClosed = false
    window.delegate = self
    self.window = window
    addMenu()
    loadPage()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func addMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: Strings.chinese ? "退出演示" : "Quit Demo",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let controlsItem = NSMenuItem(title: Strings.chinese ? "演示" : "Demo", action: nil, keyEquivalent: "")
    let controls = NSMenu()
    for (index, choice) in Theme.allCases.enumerated() {
      let item = NSMenuItem(title: choice.title, action: #selector(chooseTheme(_:)), keyEquivalent: String(index + 1))
      item.target = self
      item.representedObject = choice.rawValue
      themeItems[choice] = item
      controls.addItem(item)
    }
    controls.addItem(.separator())
    let pause = NSMenuItem(title: Strings.pause, action: #selector(togglePause), keyEquivalent: "p")
    pause.target = self
    pauseItem = pause
    controls.addItem(pause)
    let move = NSMenuItem(title: Strings.chinese ? "移动示例图标" : "Move Sample Icons",
                          action: #selector(moveIcons), keyEquivalent: "m")
    move.target = self
    controls.addItem(move)
    let reload = NSMenuItem(title: Strings.reload, action: #selector(reload), keyEquivalent: "r")
    reload.target = self
    controls.addItem(reload)
    controlsItem.submenu = controls
    menu.addItem(controlsItem)
    NSApp.mainMenu = menu
  }

  private func loadPage() {
    guard let window else { return }
    page?.close()
    let page = ScenePage(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size), theme: theme)
    page.view.autoresizingMask = [.width, .height]
    page.onReady = { [weak self, weak page] in
      guard let self, let page else { return }
      if self.testOutput != nil {
        page.view.evaluateJavaScript("""
          (() => {
            window.__demoDiagnostics = {readbacks: 0};
            const original = gl.readPixels.bind(gl);
            gl.readPixels = (...args) => { window.__demoDiagnostics.readbacks++; return original(...args); };
          })()
          """) { [weak self] _, error in
            if let error { self?.errors.append("demo diagnostics: \(error.localizedDescription)") }
          }
      }
      page.send(["t": "settings", "v": DemoLayout.settings(self.theme)])
      self.sendIcons { [weak self] in self?.initialized() }
    }
    page.onError = { [weak self] text in
      self?.errors.append(text)
      Log.line("demo: \(text)")
    }
    page.onMessage = { [weak self] text in
      guard let self, text.hasPrefix("snapshot|"), let completion = self.afterShare else { return }
      self.afterShare = nil
      completion(text)
    }
    self.page = page
    window.contentView = page.view
    window.title = "\(App.name) — \(theme.title) — \(Strings.chinese ? "演示" : "Demo")"
    for (choice, item) in themeItems { item.state = choice == theme ? .on : .off }
  }

  private func sendIcons(completion: (() -> Void)? = nil) {
    guard let page, page.ready else { return }
    page.view.evaluateJavaScript("[innerWidth, innerHeight, devicePixelRatio]") { [weak self, weak page] value, error in
      guard let self, let page, self.page === page, error == nil, let values = value as? [NSNumber], values.count == 3 else { return }
      let size = CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
      let scale = values[2].doubleValue
      let rects = DemoLayout.icons(size: size, scale: scale, moved: self.moved)
      page.send(["t": "icons", "vis": true, "r": rects])
      page.send(["t": "pause", "v": self.paused])
      // Only the demo adds these translucent placeholders; the renderer still uses host messages.
      page.view.evaluateJavaScript("""
        (() => {
          let ghosts = document.getElementById('ghosts');
          if (!ghosts) { ghosts = document.createElement('div'); ghosts.id = 'ghosts'; document.body.appendChild(ghosts); }
          ghosts.style.display = 'block';
          drawGhosts();
        })()
        """) { [weak self] _, error in
          if let error { self?.errors.append("demo placeholders: \(error.localizedDescription)") }
          completion?()
        }
    }
  }

  private func initialized() {
    readyCount += 1
    if let completion = afterReady {
      afterReady = nil
      completion()
    } else if testOutput != nil && !testsStarted {
      testsStarted = true
      later(2.5) { [weak self] in self?.testTheme() }
    }
  }

  private func later(_ seconds: Double, _ action: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
  }

  private func check(_ name: String, _ passed: Bool, details: [String: Any] = [:]) {
    checks.append(["theme": theme.rawValue, "check": name, "passed": passed, "details": details])
    print("selftest-demo: \(theme.rawValue) \(name): \(passed ? "PASS" : "FAIL")")
    fflush(stdout)
  }

  private func probe(_ completion: @escaping ([String: Any]) -> Void) {
    page?.view.evaluateJavaScript("""
      JSON.stringify({frame:frameN, icons:icons.map(({x,y,w,h})=>[x,y,w,h]),
        canvas:[cv.width,cv.height], box:[cv.getBoundingClientRect().width,cv.getBoundingClientRect().height],
        viewport:[innerWidth,innerHeight], dpr:devicePixelRatio, paused, href:location.href, mix:curMix,
        iconCloudCircles:typeof massList !== 'undefined' && massList ? massList.length/4 : null,
        diagnosticReadbacks:window.__demoDiagnostics ? window.__demoDiagnostics.readbacks : null,
        ghosts:document.querySelectorAll('#ghosts .ghost').length,
        ghostsVisible:!!document.getElementById('ghosts') && getComputedStyle(document.getElementById('ghosts')).display!=='none'})
      """) { [weak self] value, error in
        guard let self else { return }
        guard error == nil, let text = value as? String, let data = text.data(using: .utf8),
          let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
          self.errors.append("demo probe: \(error?.localizedDescription ?? "invalid JSON")")
          self.finishTests()
          return
        }
        completion(result)
      }
  }

  private func testTheme() {
    probe { [weak self] start in
      guard let self else { return }
      self.check("theme loaded", (start["href"] as? String)?.contains(self.theme.page) == true, details: start)
      self.check("sample icons visible", (start["ghosts"] as? Int) == 9 && start["ghostsVisible"] as? Bool == true)
      self.later(0.8) {
        self.probe { end in
          self.check("animation advances", (end["frame"] as? Int ?? 0) > (start["frame"] as? Int ?? 0))
          self.check("wallpaper skips diagnostic readbacks", start["diagnosticReadbacks"] as? Int != nil &&
                     (end["diagnosticReadbacks"] as? Int) == (start["diagnosticReadbacks"] as? Int))
          self.moveIcons()
          self.later(2) {
            self.probe { moved in
              let before = start["icons"] as? [[Double]] ?? []
              let after = moved["icons"] as? [[Double]] ?? []
              self.check("sample icons move", before.count == 9 && after.count == 9 && before != after)
              self.testResize(previous: moved)
            }
          }
        }
      }
    }
  }

  private func testResize(previous: [String: Any]) {
    let size = theme == .meadow ? NSSize(width: 960, height: 620) : NSSize(width: 1050, height: 660)
    window?.setContentSize(size)
    later(0.6) { [weak self] in
      guard let self else { return }
      self.probe { state in
        let box = state["box"] as? [Double] ?? []
        let canvas = state["canvas"] as? [Double] ?? []
        let dpr = state["dpr"] as? Double ?? 0
        let expected = box.map { ($0 * dpr).rounded() }
        let changed = (state["viewport"] as? [Double]) != (previous["viewport"] as? [Double])
        self.check("resize preserves physical pixels", changed && box.count == 2 && canvas == expected,
                   details: ["canvas": canvas, "expected": expected, "dpr": dpr])
        self.togglePause()
        self.later(0.3) {
          self.probe { pausedStart in
            self.later(0.8) {
              self.probe { pausedEnd in
                self.check("pause stops rendered frames", pausedEnd["paused"] as? Bool == true &&
                           (pausedStart["frame"] as? Int) == (pausedEnd["frame"] as? Int))
                self.testHiddenIcons {
                  self.togglePause()
                  self.later(0.8) {
                    self.probe { resumed in
                      self.check("resume restarts rendering", resumed["paused"] as? Bool == false &&
                                 (resumed["frame"] as? Int ?? 0) > (pausedEnd["frame"] as? Int ?? 0))
                      self.testShare(expectedSize: expected)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private func testHiddenIcons(_ completion: @escaping () -> Void) {
    // Mirror the native host when WindowManager hides Finder's icons, including while paused.
    page?.send(["t": "icons", "vis": true, "r": [] as [[Int]]])
    later(0.25) { [weak self] in
      guard let self else { return }
      self.probe { hidden in
        self.check("hidden icons clear paused terrain", (hidden["icons"] as? [[Double]])?.isEmpty == true &&
                   hidden["paused"] as? Bool == true && (hidden["mix"] as? Double) == 1)
        if self.theme == .meadow {
          self.check("hidden icons remove cached cloud shapes", hidden["iconCloudCircles"] as? Int == 0)
        }
        self.sendIcons {
          self.probe { shown in
            self.check("revealed icons restore paused terrain", (shown["icons"] as? [[Double]])?.count == 9 &&
                       (shown["mix"] as? Double) == 1)
            completion()
          }
        }
      }
    }
  }

  private func testShare(expectedSize: [Double]) {
    shareGeneration += 1
    let generation = shareGeneration
    afterShare = { [weak self] message in
      guard let self, let output = self.testOutput else { return }
      let fields = message.components(separatedBy: "|")
      if fields.count == 3, fields[1].hasPrefix("data:image/jpeg"), fields[2].hasPrefix("data:image/png;base64,"),
        let encoded = fields[2].split(separator: ",", maxSplits: 1).last,
        let png = Data(base64Encoded: String(encoded)), let image = NSBitmapImageRep(data: png) {
        let dimensions = [Double(image.pixelsWide), Double(image.pixelsHigh)]
        do {
          try png.write(to: output.appendingPathComponent("\(self.theme.rawValue)-share.png"), options: .atomic)
          self.check("share snapshot bridge", dimensions == expectedSize,
                     details: ["pixels": dimensions, "bytes": png.count])
        } catch {
          self.check("share snapshot bridge", false, details: ["error": error.localizedDescription])
        }
      } else {
        self.check("share snapshot bridge", false, details: ["reply": String(message.prefix(200))])
      }
      self.snapshotAndReload()
    }
    page?.send(["t": "snapshot"])
    later(8) { [weak self] in
      guard let self, self.shareGeneration == generation, self.afterShare != nil else { return }
      self.afterShare = nil
      self.errors.append("share snapshot reply timed out")
      self.finishTests()
    }
  }

  private func snapshotAndReload() {
    page?.view.takeSnapshot(with: nil) { [weak self] image, error in
      guard let self, let output = self.testOutput else { return }
      if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
        do {
          try png.write(to: output.appendingPathComponent("\(self.theme.rawValue)-window.png"), options: .atomic)
          self.check("WKWebView snapshot", true, details: ["pixels": [cg.width, cg.height]])
        } catch { self.check("WKWebView snapshot", false, details: ["error": error.localizedDescription]) }
      } else { self.check("WKWebView snapshot", false, details: ["error": error?.localizedDescription ?? "no image"]) }
      let previousReady = self.readyCount
      self.afterReady = {
        self.probe { start in
          self.later(1.1) {
            self.probe { end in
              self.check("reload renders again", self.readyCount == previousReady + 1 &&
                         (end["frame"] as? Int ?? 0) > (start["frame"] as? Int ?? 0) &&
                         (end["ghosts"] as? Int) == 9)
              if self.theme == .meadow, let item = self.themeItems[.beach] {
                self.afterReady = { self.later(2.5) { self.testTheme() } }
                self.chooseTheme(item)
              } else { self.finishTests() }
            }
          }
        }
      }
      self.reload()
    }
  }

  private func finishTests() {
    guard !finishing, let output = testOutput else { return }
    finishing = true
    let passed = errors.isEmpty && !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }
    let result: [String: Any] = ["schemaVersion": 1, "passed": passed, "checks": checks, "errors": errors,
                               "note": "Windowed native integration test with synthetic icons; no Finder permission or real desktop icon moves."]
    do {
      let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      try json.write(to: output.appendingPathComponent("demo-results.json"), options: .atomic)
    } catch { profileFail("could not write demo test JSON: \(error.localizedDescription)") }
    page?.close()
    window?.orderOut(nil)
    print("selftest-demo: \(passed ? "OK" : "FAILED")")
    fflush(stdout)
    exit(passed ? 0 : 1)
  }

  @objc private func chooseTheme(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String, let choice = Theme(rawValue: id), choice != theme else { return }
    theme = choice
    loadPage()
  }

  @objc private func togglePause() {
    paused.toggle()
    pauseItem?.state = paused ? .on : .off
    page?.send(["t": "pause", "v": paused])
  }

  @objc private func moveIcons() { moved.toggle(); sendIcons() }
  @objc private func reload() { page?.reload() }
  func windowDidResize(_ notification: Notification) { sendIcons() }
  func windowDidChangeBackingProperties(_ notification: Notification) { sendIcons() }
  func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { page?.close() }
}
