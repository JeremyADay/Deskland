// Event-driven native wallpaper snapshots for Mission Control's new-desktop preview.
// Only WKWebView content is captured. No Finder content or screen pixels are read.
// GPL-3.0-or-later; see LICENSE at the repository root.

import Cocoa
import WebKit

final class DesktopPreview {
  static let preferenceKey = "matchNewDesktopPreview"
  private let store = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
  private let folder = App.support.appendingPathComponent("desktop-preview", isDirectory: true)
  private let journal = WallpaperRestoreJournal(url: App.support.appendingPathComponent("preview-restore.plist"))
  private weak var page: ScenePage?
  private weak var screen: NSScreen?
  private var pending: DispatchWorkItem?
  private var busy = false
  private var recovering = true
  private var stopping = false
  private var disabledForSession = false
  private var needsRefresh = false
  private var uncertainApplication = false
  private var allowDifferentDesktop = false
  private var suspended = false
  private var captureGeneration = 0
  private var snapshotPending: Int?
  private var finishStop: (() -> Void)?

  var enabled: Bool { UserDefaults.standard.bool(forKey: Self.preferenceKey) && !disabledForSession }

  /// Recover before allowing a new snapshot, even when the preference was disabled meanwhile.
  func start() {
    guard !busy else { return }
    recovering = true
    busy = true
    restore { [weak self] succeeded in
      guard let self else { return }
      self.recovering = false
      self.busy = false
      if !succeeded { self.disabledForSession = true }
      self.continueWork()
    }
  }

  func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
    if enabled {
      disabledForSession = false
      stopping = false
      finishStop = nil
      needsRefresh = true
      guard !busy else { return }
      start()
    } else {
      stop {}
    }
  }

  /// Repeated icon changes coalesce into a single capture after their terrain transition ends.
  func schedule(page: ScenePage?, screen: NSScreen?, spaceChanged: Bool = false) {
    self.page = page
    self.screen = screen
    if spaceChanged { allowDifferentDesktop = true }
    guard enabled, !stopping else { return }
    needsRefresh = true
    guard !busy, !recovering, !suspended else { return }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.capture() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
  }

  func setSuspended(_ suspended: Bool) {
    self.suspended = suspended
    if suspended {
      pending?.cancel()
      pending = nil
    } else if needsRefresh {
      schedule(page: page, screen: screen)
    }
  }

  /// Completion may be asynchronous while a setter propagates or the previous wallpaper restores.
  func stop(completion: @escaping () -> Void) {
    pending?.cancel()
    pending = nil
    needsRefresh = false
    stopping = true
    finishStop = completion
    if snapshotPending != nil {
      snapshotPending = nil
      busy = false
    }
    guard !busy else { return }
    restoreForStop()
  }

  private func continueWork() {
    if stopping { restoreForStop() }
    else if needsRefresh { schedule(page: page, screen: screen) }
  }

  private func restoreForStop() {
    busy = true
    restore { [weak self] succeeded in
      guard let self else { return }
      self.busy = false
      if !succeeded { self.disabledForSession = true }
      let completion = self.finishStop
      self.finishStop = nil
      completion?()
      if !self.stopping { self.continueWork() }
    }
  }

  private func readStore() throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw PreviewError("wallpaper store is not a regular file owned by the current user") }
    return try Data(contentsOf: store)
  }

  private func capture() {
    pending = nil
    guard enabled, !stopping, !busy, !suspended, let page, page.ready, let screen else { return }
    needsRefresh = false
    busy = true
    captureGeneration += 1
    let generation = captureGeneration
    snapshotPending = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      guard let self, self.snapshotPending == generation else { return }
      self.snapshotPending = nil
      self.busy = false
      Log.line("desktop preview snapshot timed out; late callback discarded")
      self.continueWork()
    }
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    page.view.takeSnapshot(with: configuration) { [weak self, weak page] image, error in
      guard let self, self.snapshotPending == generation else { return }
      self.snapshotPending = nil
      guard !self.stopping, !self.suspended, self.enabled, let page, self.page === page, page.ready else {
        self.busy = false
        self.continueWork()
        return
      }
      do {
        guard error == nil, let image,
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw PreviewError("scene snapshot failed") }
        let current = try self.readStore()
        if let entry = try self.journal.load() {
          let plan = try self.journal.planRestore(current: current)
          let currentURL = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
          let expectedURL = URL(string: entry.expectedImageURL)?.standardizedFileURL
          let externallyReplaced = !self.allowDifferentDesktop && currentURL != expectedURL
          guard plan.conflicts == 0 && !externallyReplaced else {
            self.disabledForSession = true
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            throw PreviewError("external wallpaper change detected; preview synchronization disabled")
          }
        }
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = self.folder.appendingPathComponent("scene-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // The expected URL is durable before the public setter, including its asynchronous work.
        if try self.journal.load() == nil {
          try self.journal.begin(original: current, expectedImageURL: url.absoluteString)
        } else {
          try self.journal.prepareApplication(current: current, expectedImageURL: url.absoluteString)
        }
        self.uncertainApplication = true
        do {
          try NSWorkspace.shared.setDesktopImageURL(url, for: screen,
                    options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        } catch {
          // Keep the journal until we inspect the store; even a failed setter may have side effects.
          Log.line("desktop preview setter: \(error.localizedDescription)")
        }
        self.confirmApplication(url: url, screen: screen, remaining: 10)
      } catch {
        Log.line("desktop preview skipped: \(error.localizedDescription)")
        self.busy = false
        self.continueWork()
      }
    }
  }

  private func confirmApplication(url: URL, screen: NSScreen, remaining: Int,
                                  previous: Data? = nil, stableSamples: Int = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      do {
        let current = try self.readStore()
        let stored = try WallpaperRestore.referencesImage(current, url: url.absoluteString)
        let visible = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == url.standardizedFileURL
        if stored && visible {
          let same = try previous.map {
            WallpaperRestore.semanticallyEqual(try WallpaperRestore.decode($0), try WallpaperRestore.decode(current))
          } ?? false
          let stable = same ? stableSamples + 1 : 1
          if stable >= 2 {
            try self.journal.recordApplied(current)
            self.uncertainApplication = false
            self.allowDifferentDesktop = false
            self.busy = false
            self.cleanupSnapshots(current: current)
            Log.line("desktop preview synchronized")
            self.continueWork()
            return
          }
          if remaining > 0 {
            self.confirmApplication(url: url, screen: screen, remaining: remaining - 1,
                                    previous: current, stableSamples: stable)
            return
          }
        }
      } catch { Log.line("desktop preview verification: \(error.localizedDescription)") }
      if remaining > 0 {
        self.confirmApplication(url: url, screen: screen, remaining: remaining - 1)
      } else {
        // Never discard undo state for a setter whose eventual result is unknown.
        self.disabledForSession = true
        self.busy = false
        Log.line("desktop preview propagation timed out; recovery journal retained")
        self.continueWork()
      }
    }
  }

  private func restore(completion: @escaping (Bool) -> Void) {
    do {
      guard let entry = try journal.load() else { completion(true); return }
      let current = try readStore()
      if entry.applied == nil {
        if uncertainApplication {
          Log.line("desktop preview result still pending; retaining recovery journal for next launch")
          completion(false)
          return
        } else if try WallpaperRestore.referencesImage(current, url: entry.expectedImageURL) {
          // A process crash may leave the system agent finishing its setter. Require a stable
          // persisted state here as well before treating those changes as the final apply.
          confirmRecoveredApplication(expected: entry.expectedImageURL, previous: current, remaining: 10,
                                      completion: completion)
          return
        } else {
          // Only startup/recovery may prove a crashed setter never changed the durable before
          // state. Persist that proof so a crash during the undo remains recoverable too.
          try journal.confirmNotApplied(current: current)
        }
      }
      let plan = try journal.planRestore(current: current)
      if plan.changed {
        guard try readStore() == current else {
          throw PreviewError("wallpaper changed while preparing restoration; retaining journal")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions]
        try plan.data.write(to: store, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: store.path) }
        // The setter cannot reconstruct dynamic providers. Exact undo therefore uses the validated,
        // journaled private store schema; compatibility failures leave the journal intact.
        try restartWallpaperAgent()
        Log.line("desktop preview restored \(plan.restoredFields) owned wallpaper choices; preserved \(plan.conflicts) conflicts")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + (plan.changed ? 0.8 : 0)) { [weak self] in
        guard let self else { return }
        do {
          let after = try self.readStore()
          let remaining = try self.journal.planRestore(current: after)
          guard !remaining.changed else { throw PreviewError("wallpaper restoration has not persisted") }
          try self.journal.clear()
          self.cleanupSnapshots(current: after)
          completion(true)
        } catch {
          Log.line("desktop preview restore verification failed; journal retained: \(error.localizedDescription)")
          completion(false)
        }
      }
    } catch {
      Log.line("desktop preview restore unavailable; journal retained: \(error.localizedDescription)")
      completion(false)
    }
  }

  private func confirmRecoveredApplication(expected: String, previous: Data, remaining: Int,
                                            completion: @escaping (Bool) -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      do {
        let current = try self.readStore()
        guard try WallpaperRestore.referencesImage(current, url: expected) else {
          throw PreviewError("pending preview changed during recovery; retaining journal")
        }
        if WallpaperRestore.semanticallyEqual(try WallpaperRestore.decode(previous), try WallpaperRestore.decode(current)) {
          try self.journal.recordApplied(current)
          self.restore(completion: completion)
        } else if remaining > 0 {
          self.confirmRecoveredApplication(expected: expected, previous: current, remaining: remaining - 1,
                                           completion: completion)
        } else {
          throw PreviewError("pending preview did not stabilize during recovery; retaining journal")
        }
      } catch {
        Log.line("desktop preview recovery failed: \(error.localizedDescription)")
        completion(false)
      }
    }
  }

  private func restartWallpaperAgent() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["-u", NSUserName(), "WallpaperAgent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
      throw PreviewError("could not restart the current user's WallpaperAgent")
    }
  }

  private func cleanupSnapshots(current: Data) {
    // Retain references held by both the live store and an unfinished undo journal. Do not touch
    // arbitrary support files, nor remove a frozen image still used by a conflicting/new Space.
    do {
      let entry = try journal.load()
      let protected = [current] + (entry.map { [$0.original, $0.baseline, $0.before] + ($0.applied.map { [$0] } ?? []) } ?? [])
      let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
      for file in files where file.lastPathComponent.hasPrefix("scene-") && file.pathExtension == "png" {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        if entry?.expectedImageURL == file.absoluteString { continue }
        let retained = try protected.contains { try WallpaperRestore.referencesImage($0, url: file.absoluteString) }
        if !retained { try FileManager.default.removeItem(at: file) }
      }
    } catch { Log.line("desktop preview cleanup deferred") }
  }
}

private struct PreviewError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
