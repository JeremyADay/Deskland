// Pure undo/journal checks. Never reads or modifies the live wallpaper store.
import Foundation

@main struct WallpaperRestoreTests {
  static let image = "file:///tmp/deskland-preview-test.png"
  static let nextImage = "file:///tmp/deskland-preview-next.png"
  static var checks = 0

  static func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
  }
  static func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected failure: \(message)") }
    catch { checks += 1 }
  }
  static func content(_ path: String) -> [String: Any] {
    let config: [String: Any] = ["type": "imageFile", "url": ["relative": path]]
    let blob = try! PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
    return ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image", "Configuration": blob]]],
            "LastSet": Date(timeIntervalSince1970: 10), "LastUse": Date(timeIntervalSince1970: 10)]
  }
  static var originalChoice: [String: Any] { ["Type": "linked", "Linked": content("file:///original.heic")] }
  static func appliedChoice(_ image: String = image) -> [String: Any] {
    ["Type": "individual", "Desktop": content(image), "Idle": content("file:///original.heic")]
  }
  static var original: [String: Any] {
    ["SystemDefault": originalChoice, "AllSpacesAndDisplays": originalChoice, "Spaces": [:], "Displays": [:]]
  }
  static func applied(_ image: String = image) -> [String: Any] {
    ["SystemDefault": appliedChoice(image), "AllSpacesAndDisplays": ["Type": "idle", "Idle": content("file:///original.heic")],
     "Spaces": ["space-a": ["Default": appliedChoice(image)], "space-b": ["Default": appliedChoice(image)]],
     "Displays": ["display-a": appliedChoice(image)]]
  }
  static func encoded(_ value: [String: Any]) -> Data { try! WallpaperRestore.encode(value) }
  static func decoded(_ data: Data) -> [String: Any] { try! WallpaperRestore.decode(data) }

  static func main() throws {
    let before = original, after = applied()
    var restored = try WallpaperRestore.merged(original: before, applied: after, current: after)
    expect(WallpaperRestore.semanticallyEqual(restored, before), "Untouched application choices must restore exactly")

    var current = after
    var system = current["SystemDefault"] as! [String: Any]
    var desktop = system["Desktop"] as! [String: Any]
    desktop["LastUse"] = Date(timeIntervalSince1970: 999)
    system["Desktop"] = desktop; current["SystemDefault"] = system
    restored = try WallpaperRestore.merged(original: before, applied: after, current: current)
    expect(WallpaperRestore.semanticallyEqual(restored, before), "Timestamp drift must not block restoration")

    current = after
    current["SystemDefault"] = appliedChoice("file:///user-replacement.jpg")
    restored = try WallpaperRestore.merged(original: before, applied: after, current: current)
    expect(WallpaperRestore.semanticallyEqual(restored["SystemDefault"], current["SystemDefault"]),
           "A new user wallpaper and its Type must remain atomic")
    expect(WallpaperRestore.semanticallyEqual(restored["Displays"], before["Displays"]),
           "An unrelated display still owned by the app must restore")

    current = after
    var spaces = current["Spaces"] as! [String: Any]
    spaces["space-a"] = ["Default": appliedChoice("file:///user-space.jpg")]
    spaces["new-user-space"] = ["Default": originalChoice, "NewMetadata": "keep"]
    current["Spaces"] = spaces; current["UnrelatedMetadata"] = ["value": 42]
    restored = try WallpaperRestore.merged(original: before, applied: after, current: current)
    let restoredSpaces = restored["Spaces"] as! [String: Any]
    expect(WallpaperRestore.semanticallyEqual(restoredSpaces["space-a"], spaces["space-a"]), "Preserve changed Space")
    expect(restoredSpaces["space-b"] == nil, "Remove unchanged app-created Space node")
    expect(WallpaperRestore.semanticallyEqual(restoredSpaces["new-user-space"], spaces["new-user-space"]), "Preserve new user Space")
    expect(WallpaperRestore.semanticallyEqual(restored["UnrelatedMetadata"], current["UnrelatedMetadata"]), "Preserve unrelated metadata")

    current = after
    system = current["SystemDefault"] as! [String: Any]
    system["UserMetadata"] = "new"
    current["SystemDefault"] = system
    restored = try WallpaperRestore.merged(original: before, applied: after, current: current)
    let restoredSystem = restored["SystemDefault"] as! [String: Any]
    expect(restoredSystem["Type"] as? String == "linked" && restoredSystem["UserMetadata"] as? String == "new",
           "Restore a choice while preserving new sibling metadata")

    current = after
    system = current["SystemDefault"] as! [String: Any]
    system["Idle"] = content("file:///user-screensaver.jpg")
    current["SystemDefault"] = system
    restored = try WallpaperRestore.merged(original: before, applied: after, current: current)
    expect(WallpaperRestore.semanticallyEqual(restored["SystemDefault"], system), "Keep changed Idle and related Type/choice group atomic")

    rejects("malformed current Type") {
      var bad = after; bad["SystemDefault"] = ["Type": 17, "Desktop": content(image)]
      _ = try WallpaperRestore.merged(original: before, applied: after, current: bad)
    }
    rejects("missing root choice") { _ = try WallpaperRestore.encode(["Spaces": [:]]) }
    rejects("malformed provider content") {
      var bad = after; bad["SystemDefault"] = ["Type": "desktop", "Desktop": [:]]
      _ = try WallpaperRestore.encode(bad)
    }
    rejects("malformed Space map") {
      var bad = after; bad["Spaces"] = ["space": 5]
      _ = try WallpaperRestore.encode(bad)
    }
    expect(try WallpaperRestore.referencesImage(encoded(after), url: image), "Find expected URL in nested binary configuration")
    expect(!(try WallpaperRestore.referencesImage(encoded(after), url: nextImage)), "Reject a different image URL")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = WallpaperRestoreJournal(url: directory.appendingPathComponent("restore.plist"))
    rejects("missing journal") { _ = try journal.planRestore(current: encoded(after)) }
    try journal.begin(original: encoded(before), expectedImageURL: image)
    let initialPending = try journal.planRestore(current: encoded(before))
    expect(!initialPending.changed && initialPending.conflicts == 0,
           "A first-apply crash before the setter must recover as a no-op")
    rejects("incomplete journal") { _ = try journal.planRestore(current: encoded(after)) }
    rejects("begin cannot replace backup") { try journal.begin(original: encoded(after), expectedImageURL: image) }
    rejects("wrong applied image") { try journal.recordApplied(encoded(before)) }
    try journal.recordApplied(encoded(after))
    expect(try journal.planRestore(current: encoded(after)).changed, "Completed journal creates restore plan")
    expect(try journal.load()?.original == encoded(before), "Original backup remains immutable")

    // A user changes another Space between two app snapshots. Rebase before applying again.
    current = after
    spaces = current["Spaces"] as! [String: Any]
    spaces["space-b"] = ["Default": appliedChoice("file:///user-owned-space.jpg")]
    current["Spaces"] = spaces
    try journal.prepareApplication(current: encoded(current), expectedImageURL: nextImage)
    let pendingUndo = try journal.planRestore(current: encoded(current))
    let pendingStore = decoded(pendingUndo.data)
    let pendingSpaces = pendingStore["Spaces"] as! [String: Any]
    expect(pendingUndo.changed && WallpaperRestore.semanticallyEqual(pendingStore["SystemDefault"], before["SystemDefault"]),
           "A later crash before the setter must undo previously applied snapshots")
    expect(WallpaperRestore.semanticallyEqual(pendingSpaces["space-b"], spaces["space-b"]),
           "Pending rollback must preserve user choices captured before the new setter")
    expect(pendingSpaces["space-a"] == nil, "Pending rollback removes prior unchanged app-owned Space nodes")
    var uncertainPending = current
    uncertainPending["SystemDefault"] = appliedChoice("file:///concurrent-after-prepare.jpg")
    rejects("changed pending store cannot be assumed pre-setter") {
      _ = try journal.planRestore(current: encoded(uncertainPending))
    }
    expect(try journal.load()?.applied == nil, "Planning pending rollback must not rewrite the journal")
    rejects("cannot confirm a pending apply against a changed store") {
      try journal.confirmNotApplied(current: encoded(uncertainPending))
    }
    // Model restart after the first app snapshot and crash before the second setter, then
    // another crash after the recovery write but before journal cleanup.
    let recovery = WallpaperRestoreJournal(url: directory.appendingPathComponent("recovery.plist"))
    try recovery.begin(original: encoded(before), expectedImageURL: image)
    try recovery.recordApplied(encoded(after))
    try recovery.prepareApplication(current: encoded(current), expectedImageURL: nextImage)
    try recovery.confirmNotApplied(current: encoded(current))
    let recoveryWrite = try recovery.planRestore(current: encoded(current))
    let afterRecoveryWrite = try recovery.planRestore(current: recoveryWrite.data)
    expect(!afterRecoveryWrite.changed && afterRecoveryWrite.conflicts == 0,
           "Rollback verification/restart after the recovery write must be a clean no-op")
    expect(try recovery.load()?.applied != nil, "Pre-setter recovery confirmation must be durable")
    var next = applied(nextImage)
    var nextSpaces = next["Spaces"] as! [String: Any]
    nextSpaces["space-b"] = spaces["space-b"]
    // A concurrent user-created Space and unrelated metadata arrive during the setter.
    nextSpaces["user-new-during-apply"] = ["Default": appliedChoice("file:///user-new.jpg")]
    next["Spaces"] = nextSpaces; next["ConcurrentMetadata"] = "keep"
    try journal.recordApplied(encoded(next))
    let plan = try journal.planRestore(current: encoded(next))
    restored = decoded(plan.data)
    let undoSpaces = restored["Spaces"] as! [String: Any]
    expect(WallpaperRestore.semanticallyEqual(undoSpaces["space-b"], spaces["space-b"]), "Later applies must not claim existing user changes")
    expect(WallpaperRestore.semanticallyEqual(undoSpaces["user-new-during-apply"], nextSpaces["user-new-during-apply"]),
           "Later capture must not claim concurrent new user choices")
    expect(restored["ConcurrentMetadata"] as? String == "keep", "Later capture must not claim metadata")
    expect(undoSpaces["space-a"] == nil, "Repeated app-owned choices still restore")
    expect(try journal.load()?.original == encoded(before), "Repeated applies keep first backup")
    expect(plan.conflicts == 0, "Already-known external choices are not restore conflicts")
    var external = next; external["SystemDefault"] = appliedChoice("file:///later-user.jpg")
    expect(try journal.planRestore(current: encoded(external)).conflicts > 0, "New replacement of an owned choice is a conflict")

    let concurrentJournal = WallpaperRestoreJournal(url: directory.appendingPathComponent("concurrent.plist"))
    try concurrentJournal.begin(original: encoded(before), expectedImageURL: image)
    var concurrent = after
    var concurrentDefault = concurrent["SystemDefault"] as! [String: Any]
    concurrentDefault["Idle"] = content("file:///screensaver-changed-during-apply.jpg")
    concurrent["SystemDefault"] = concurrentDefault
    try concurrentJournal.recordApplied(encoded(concurrent))
    let concurrentUndo = decoded(try concurrentJournal.planRestore(current: encoded(concurrent)).data)
    expect(WallpaperRestore.semanticallyEqual(concurrentUndo["SystemDefault"], concurrentDefault),
           "Expected snapshot URL must not claim concurrent Idle change")

    // macOS materializes newly created Spaces by copying an existing app snapshot, even
    // after that snapshot has been replaced on the active Space.
    let inheritedJournal = WallpaperRestoreJournal(url: directory.appendingPathComponent("inherited.plist"))
    try inheritedJournal.begin(original: encoded(before), expectedImageURL: image)
    try inheritedJournal.recordApplied(encoded(after))
    var inherited = after
    var inheritedSpaces = inherited["Spaces"] as! [String: Any]
    inheritedSpaces["created-after-setter"] = ["Default": appliedChoice(), "Displays": ["display-a": appliedChoice()]]
    inheritedSpaces["custom-new-space"] = ["Default": appliedChoice("file:///custom-new-space.jpg")]
    inherited["Spaces"] = inheritedSpaces
    let inheritedUndo = decoded(try inheritedJournal.planRestore(current: encoded(inherited)).data)
    expect((inheritedUndo["Spaces"] as! [String: Any])["created-after-setter"] == nil,
           "A late new Space inheriting a recorded app choice restores original inheritance")
    expect((inheritedUndo["Spaces"] as! [String: Any])["custom-new-space"] != nil,
           "A new Space with a custom image survives inherited-choice cleanup")
    try inheritedJournal.prepareApplication(current: encoded(inherited), expectedImageURL: nextImage)
    var inheritedNext = applied(nextImage)
    var inheritedNextSpaces = inheritedNext["Spaces"] as! [String: Any]
    inheritedNextSpaces["created-after-setter"] = inheritedSpaces["created-after-setter"]
    inheritedNextSpaces["custom-new-space"] = inheritedSpaces["custom-new-space"]
    inheritedNextSpaces["created-during-setter"] = ["Default": appliedChoice()]
    inheritedNext["Spaces"] = inheritedNextSpaces
    try inheritedJournal.recordApplied(encoded(inheritedNext))
    var late = inheritedNext
    var lateSpaces = late["Spaces"] as! [String: Any]
    lateSpaces["created-after-later-setter"] = ["Default": appliedChoice()]
    late["Spaces"] = lateSpaces
    let lateUndo = decoded(try inheritedJournal.planRestore(current: encoded(late)).data)
    let lateUndoSpaces = lateUndo["Spaces"] as! [String: Any]
    expect(lateUndoSpaces.count == 1 && lateUndoSpaces["custom-new-space"] != nil,
           "History restores inherited older snapshots created before, during, or after a later setter")
    expect(try inheritedJournal.load()?.ownedChoices.count == 2, "Both exact snapshot choices are durable")
    var userIdle = appliedChoice()
    userIdle["Idle"] = content("file:///custom-screensaver.jpg")
    var userPlacement = appliedChoice()
    var userDesktop = userPlacement["Desktop"] as! [String: Any]
    userDesktop["UserPlacement"] = "center"; userPlacement["Desktop"] = userDesktop
    lateSpaces["custom-idle"] = ["Default": userIdle]
    lateSpaces["custom-placement"] = ["Default": userPlacement]
    var metadata = appliedChoice(); metadata["UnrelatedMetadata"] = "keep"
    lateSpaces["new-metadata"] = ["Default": metadata]
    late["Spaces"] = lateSpaces
    let customUndo = decoded(try inheritedJournal.planRestore(current: encoded(late)).data)
    let customSpaces = customUndo["Spaces"] as! [String: Any]
    expect(WallpaperRestore.semanticallyEqual(customSpaces["custom-idle"], lateSpaces["custom-idle"]),
           "The same snapshot URL with a custom Idle choice must be preserved")
    expect(WallpaperRestore.semanticallyEqual(customSpaces["custom-placement"], lateSpaces["custom-placement"]),
           "The same snapshot URL with custom placement must be preserved")
    let metadataChoice = (customSpaces["new-metadata"] as! [String: Any])["Default"] as! [String: Any]
    expect(metadataChoice["UnrelatedMetadata"] as? String == "keep" && metadataChoice["Type"] as? String == "linked",
           "Unknown metadata survives with a valid original inherited wallpaper choice")

    // Pilot journals had no exact-choice history and are deliberately unsupported.
    let legacy = WallpaperRestoreJournal(url: directory.appendingPathComponent("legacy.plist"))
    let legacyMap: [String: Any] = ["version": 1, "original": encoded(before), "baseline": encoded(before),
      "before": encoded(after), "applied": encoded(after), "expectedImageURL": image]
    try PropertyListSerialization.data(fromPropertyList: legacyMap, format: .binary, options: 0).write(to: legacy.url)
    rejects("unproven version-1 ownership must fail closed") { _ = try legacy.load() }

    var changedDefault = late
    changedDefault["SystemDefault"] = appliedChoice("file:///user-new-default.jpg")
    let changedDefaultUndo = decoded(try inheritedJournal.planRestore(current: encoded(changedDefault)).data)
    let changedDefaultSpaces = changedDefaultUndo["Spaces"] as! [String: Any]
    let inheritedMetadata = (changedDefaultSpaces["new-metadata"] as! [String: Any])["Default"] as! [String: Any]
    var inheritedWithoutMetadata = inheritedMetadata; inheritedWithoutMetadata["UnrelatedMetadata"] = nil
    expect(WallpaperRestore.semanticallyEqual(inheritedWithoutMetadata, changedDefaultUndo["SystemDefault"]),
           "New Space metadata must retain the current user-chosen inherited default")

    try Data("not a plist".utf8).write(to: journal.url)
    rejects("malformed journal") { _ = try journal.load() }

    // Optional real before/after files are read only; no system paths are built into this test.
    if CommandLine.arguments.count == 3 {
      let realBefore = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      let realAfter = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
      let roundTrip = try WallpaperRestore.plan(original: realBefore, applied: realAfter, current: realAfter)
      expect(WallpaperRestore.semanticallyEqual(decoded(roundTrip.data), decoded(realBefore)), "Actual store provider round trip")
      let actualSystem = decoded(realAfter)["SystemDefault"] as! [String: Any]
      let actualDesktop = actualSystem["Desktop"] as! [String: Any]
      let actualContent = actualDesktop["Content"] as! [String: Any]
      let choice = (actualContent["Choices"] as! [[String: Any]])[0]
      let configuration = try PropertyListSerialization.propertyList(from: choice["Configuration"] as! Data, format: nil) as! [String: Any]
      let actualURL = (configuration["url"] as! [String: Any])["relative"] as! String
      let actualJournal = WallpaperRestoreJournal(url: directory.appendingPathComponent("actual.plist"))
      try actualJournal.begin(original: realBefore, expectedImageURL: actualURL)
      try actualJournal.recordApplied(realAfter)
      let actualPlan = try actualJournal.planRestore(current: realAfter)
      expect(WallpaperRestore.semanticallyEqual(decoded(actualPlan.data), decoded(realBefore)), "Actual scoped journal provider round trip")
      print("Actual supplied wallpaper store round trip passed (in memory only)")
    }
    print("WallpaperRestore: \(checks) checks passed")
  }
}
