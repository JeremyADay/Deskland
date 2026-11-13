// Deskland Mac host: the menu's words, in Simplified Chinese or English.
// Copyright (C) 2026 Jeremy Day. Part of the Mac host for Deskland (BLEZZ0102/Deskland).
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See LICENSE at the top of the repository.
//
// Chinese when the Mac's first preferred language is Chinese, English otherwise (the only two
// languages Deskland has). Words the Windows tray already has come from prototype/i18n/*.json and,
// for the theme names, themes.json; the few Mac-only ones are in the table below.

import Foundation

enum Strings {
  static let chinese: Bool = (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")

  /// Mac-only words: [English, Chinese].
  private static let own: [String: (en: String, zh: String)] = [
    "grant": ("Grant Accessibility…", "授予辅助功能权限…"),
    "desktopPreview": ("Match new desktop preview", "同步新建桌面预览"),
    "about": ("About Deskland Preview", "关于 Deskland Preview"),
    "aboutText": (
      "Deskland Preview for macOS. Mac host by Jeremy Day (github.com/JeremyADay). GPL-3.0.",
      "Deskland Preview macOS 版。Mac 宿主由 Jeremy Day 编写（github.com/JeremyADay）。GPL-3.0。"
    ),
    // Fallbacks, should the bundle's i18n files be unreadable.
    "theme": ("Themes", "主题"),
    "pause": ("Pause animation", "暂停动画"),
    "reload": ("Reload", "重新载入"),
    "quit": ("Exit (restore wallpaper)", "退出（恢复原壁纸）"),
  ]

  static func own(_ key: String) -> String {
    guard let pair = own[key] else { return key }
    return chinese ? pair.zh : pair.en
  }

  /// The menu entries the Windows tray has too.
  static var theme: String { shared(["ui", "themes"]) ?? own("theme") }
  static var pause: String { shared(["host", "trayPause"]) ?? own("pause") }
  static var reload: String { shared(["host", "trayReload"]) ?? own("reload") }
  static var quit: String { shared(["host", "trayExit"]) ?? own("quit") }

  /// A theme's name: themes.json has the Chinese names, en.json the English ones.
  static func title(_ theme: Theme) -> String {
    if chinese, let name = Theme.name(theme) { return name }
    if !chinese, let name = shared(["themes", theme.rawValue, "name"]) { return name }
    return theme == .meadow ? (chinese ? "草地" : "Meadow") : (chinese ? "沙滩" : "Beach")
  }

  private static let table: [String: Any] = {
    let file = Scene.root.appendingPathComponent("i18n/\(chinese ? "zh-CN" : "en").json")
    guard let data = try? Data(contentsOf: file),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
  }()

  private static func shared(_ path: [String]) -> String? {
    var node: Any = table
    for key in path {
      guard let next = (node as? [String: Any])?[key] else { return nil }
      node = next
    }
    return node as? String
  }
}
