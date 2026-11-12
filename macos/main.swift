// Deskland Mac host: a native macOS host for Deskland's theme pages.
// Copyright (C) 2026 Jeremy Day. Part of the Mac host for Deskland (BLEZZ0102/Deskland).
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See LICENSE at the top of the repository.

import Cocoa

let arguments = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared
// Kept here: NSApplication holds its delegate weakly.
let delegate: NSApplicationDelegate
var signalSources: [DispatchSourceSignal] = []

func installTerminationSignalHandlers() {
  var requested = false
  for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
      guard !requested else { return }
      requested = true
      // AppKit may enter a nested event loop for terminateLater. Return from this dispatch
      // callback first, so the main queue can deliver asynchronous restoration callbacks.
      let timer = Timer(timeInterval: 0, repeats: false) { _ in NSApp.terminate(nil) }
      RunLoop.main.add(timer, forMode: .common)
    }
    source.resume()
    signalSources.append(source)
  }
}

func usage() -> Never {
  FileHandle.standardError.write(Data("""
    usage: Deskland                        the wallpaper, with a menu bar item
    developer commands (selftest/profile offscreen; demo commands visible; see macos/README.md):
           Deskland --selftest <meadow|beach> <out.png> [--no-icons]
           Deskland --selftest-shim
           Deskland --profile <meadow|beach> <out.json> [--no-icons]
           Deskland --demo <meadow|beach>
           Deskland --selftest-demo <output-directory>

    """.utf8))
  exit(2)
}

switch arguments.first {
case "--selftest":
  guard arguments.count >= 3, let theme = Theme(rawValue: arguments[1]) else { usage() }
  let output = URL(fileURLWithPath: arguments[2])
  delegate = SceneTest(theme: theme, output: output, withIcons: !arguments.contains("--no-icons"))
  app.setActivationPolicy(.accessory)
case "--selftest-shim":
  delegate = ShimTest()
  app.setActivationPolicy(.accessory)
case "--profile":
  guard arguments.count >= 3, let theme = Theme(rawValue: arguments[1]) else { usage() }
  delegate = SceneProfile(theme: theme, output: URL(fileURLWithPath: arguments[2]),
                          withIcons: !arguments.contains("--no-icons"))
  app.setActivationPolicy(.accessory)
case "--demo":
  guard arguments.count == 2, let theme = Theme(rawValue: arguments[1]) else { usage() }
  delegate = SceneDemo(theme: theme)
  app.setActivationPolicy(.regular)
case "--selftest-demo":
  guard arguments.count == 2 else { usage() }
  delegate = SceneDemo(theme: .meadow, testOutput: URL(fileURLWithPath: arguments[1], isDirectory: true))
  app.setActivationPolicy(.regular)
case nil:
  // A second launch while the wallpaper runs leaves quietly. (The self-tests do not take the lock.)
  guard App.claimInstance() else {
    Log.line("already running; this copy exits")
    exit(0)
  }
  // `kill` / Ctrl-C quit like the menu does, so the window is taken away the same way.
  installTerminationSignalHandlers()
  delegate = Controller()
  app.setActivationPolicy(.accessory)
default:
  usage()
}
app.delegate = delegate
app.run()
