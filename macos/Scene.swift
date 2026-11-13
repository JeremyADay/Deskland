// Deskland Mac host: the themes and the web view that shows one.
// Copyright (C) 2026 Jeremy Day. Part of the Mac host for Deskland (BLEZZ0102/Deskland).
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See LICENSE at the top of the repository.
//
// The pages come from the app bundle's copy of prototype/ (Contents/Resources/prototype), served
// over a private URL scheme, deskland://app/. macos/README.md says why not file URLs.

import Cocoa
import WebKit

/// The two open-source themes. The others in themes.json are locked and have no page.
enum Theme: String, CaseIterable {
  case meadow, beach

  /// The name shown in the menu, in the menu's language.
  var title: String { Strings.title(self) }

  /// The page in prototype/, as themes.json has it.
  var page: String { Theme.catalog(self)?.page ?? (self == .meadow ? "meadow.html" : "flat.html") }

  /// The theme's parameter defaults from themes.json, as the {"t":"settings"} message takes them.
  var defaults: [String: Any] { Theme.catalog(self)?.defaults ?? [:] }

  /// The theme's name in themes.json (Simplified Chinese).
  static func name(_ theme: Theme) -> String? { catalog(theme)?.name }

  private static var cache: [Theme: (page: String, name: String?, defaults: [String: Any])] = [:]

  private static func catalog(_ theme: Theme) -> (page: String, name: String?, defaults: [String: Any])? {
    if let hit = cache[theme] { return hit }
    let file = Scene.root.appendingPathComponent("themes.json")
    guard let data = try? Data(contentsOf: file),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let themes = json["themes"] as? [[String: Any]],
      let entry = themes.first(where: { $0["id"] as? String == theme.rawValue }),
      let page = entry["page"] as? String
    else { return nil }
    var defaults: [String: Any] = [:]
    for group in entry["groups"] as? [[String: Any]] ?? [] {
      for param in group["params"] as? [[String: Any]] ?? [] {
        if let key = param["key"] as? String, let value = param["default"] { defaults[key] = value }
      }
    }
    cache[theme] = (page, entry["name"] as? String, defaults)
    return cache[theme]
  }
}

enum Scene {
  static let scheme = "deskland"
  static let host = "app"

  /// The bundle's copy of prototype/. DESKLAND_PAGES overrides it (for trying a working tree).
  static var root: URL {
    if let path = ProcessInfo.processInfo.environment["DESKLAND_PAGES"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return Bundle.main.resourceURL!.appendingPathComponent("prototype", isDirectory: true)
  }

  /// JSON text for a message to the page.
  static func json(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

/// Serves prototype/ to the web view under deskland://app/, read only and never outside it.
final class SceneHandler: NSObject, WKURLSchemeHandler {
  private let root: URL
  private static let types = [
    "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
    "json": "application/json", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "webp": "image/webp", "svg": "image/svg+xml", "woff2": "font/woff2",
  ]

  init(root: URL) { self.root = root.standardizedFileURL }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let file = root.appendingPathComponent(url.path).standardizedFileURL
    guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
      task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
      return
    }
    let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
    let text = type.hasPrefix("text/") || type == "application/json" ? "utf-8" : nil
    task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: text))
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// One theme page in a web view, and the conversation with it.
final class ScenePage: NSObject, WKNavigationDelegate {
  let view: WKWebView
  let theme: Theme
  /// Whether the page has said 'ready'. Nothing is sent before that: the page would not hear it.
  private(set) var ready = false
  /// Called when the page says 'ready' (again after every reload).
  var onReady: () -> Void = {}
  /// Every other message the page posts (for example the share snapshot), as text.
  var onMessage: (String) -> Void = { _ in }
  var onError: (String) -> Void = { _ in }
  /// Number of messages submitted to the page, for diagnostics and the self-test. Keeping only
  /// a count avoids retaining historical icon positions for the lifetime of the wallpaper.
  private(set) var sentCount = 0
  private let shim = ShimHandler()

  init(frame: NSRect, theme: Theme) {
    self.theme = theme
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(SceneHandler(root: Scene.root), forURLScheme: Scene.scheme)
    config.suppressesIncrementalRendering = true
    config.preferences.isFraudulentWebsiteWarningEnabled = false
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .nonPersistent()
    config.userContentController.addUserScript(Shim.userScript)
    config.userContentController.add(shim, name: Shim.handler)
    view = WKWebView(frame: frame, configuration: config)
    super.init()
    // A background agent's window is never reported as visible, and WebKit stops pages it thinks
    // are covered; this app works out what is covered itself (private key, as in Desk Critters).
    if Self.has(view, "windowOcclusionDetectionEnabled") { view.setValue(false, forKey: "windowOcclusionDetectionEnabled") }
    // No white flash before the first frame.
    if Self.has(view, "drawsBackground") { view.setValue(false, forKey: "drawsBackground") }
    view.navigationDelegate = self
    shim.onMessage = { [weak self] text in self?.received(text) }
    shim.onError = { [weak self] text in self?.onError(text) }
    view.load(URLRequest(url: URL(string: "\(Scene.scheme)://\(Scene.host)/\(theme.page)?wallpaper=1")!))
  }

  private static func has(_ view: WKWebView, _ key: String) -> Bool {
    let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
    return view.responds(to: NSSelectorFromString(setter)) || view.responds(to: NSSelectorFromString("_" + setter))
  }

  func reload() {
    ready = false
    view.reload()
  }

  /// Sends one message (JSON text) to the page's listeners, once the page is ready.
  func send(_ json: String) {
    guard ready else { return }
    sentCount += 1
    view.evaluateJavaScript(Shim.deliver(json)) { [weak self] _, error in
      if let error { self?.onError("delivering a message: \(error.localizedDescription)") }
    }
  }

  func send(_ object: [String: Any]) { send(Scene.json(object)) }

  private func received(_ text: String) {
    if text == "ready" {
      ready = true
      onReady()
    } else {
      onMessage(text)
    }
  }

  func close() {
    view.navigationDelegate = nil
    view.configuration.userContentController.removeAllUserScripts()
    view.configuration.userContentController.removeScriptMessageHandler(forName: Shim.handler)
    view.removeFromSuperview()
  }

  // MARK: - Navigation

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { ready = false }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    onError("the page did not load: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    onError("the page failed: \(error.localizedDescription)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ready = false
    onError("the web content process ended; reloading")
    webView.reload()
  }
}
