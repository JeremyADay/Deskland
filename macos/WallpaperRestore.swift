// A three-way undo journal for the system wallpaper store. Never writes the system store.
// Part of the Mac host for Deskland. GPL-3.0-or-later, see LICENSE.
import Foundation

enum WallpaperRestore {
  enum Failure: Error, LocalizedError {
    case malformed(String), missingJournal, existingJournal, incomplete
    var errorDescription: String? {
      switch self {
      case .malformed(let reason): return "Invalid wallpaper restore data: \(reason)"
      case .missingJournal: return "No wallpaper restore journal"
      case .existingJournal: return "An existing wallpaper restore journal must be recovered first"
      case .incomplete: return "Wallpaper apply is incomplete; keeping its recovery journal"
      }
    }
  }
  struct Plan {
    let data: Data
    let changed: Bool
    let restoredFields: Int
    let conflicts: Int
  }
  private static let choiceKeys: Set<String> = ["Type", "Desktop", "Idle", "Linked"]
  private static let volatileKeys: Set<String> = ["LastUse", "LastSet"]

  static func decode(_ data: Data) throws -> [String: Any] {
    guard let store = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { throw Failure.malformed("root is not a dictionary") }
    try validate(store)
    return store
  }

  static func encode(_ store: [String: Any]) throws -> Data {
    try validate(store)
    return try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
  }

  private static func validate(_ store: [String: Any]) throws {
    func node(_ value: Any?) throws {
      guard let value = value as? [String: Any], let type = value["Type"] as? String,
        ["linked", "individual", "desktop", "idle"].contains(type)
      else { throw Failure.malformed("wallpaper choice has an unsupported shape") }
      for key in ["Desktop", "Idle", "Linked"] where value[key] != nil {
        guard let branch = value[key] as? [String: Any], let content = branch["Content"] as? [String: Any],
          let choices = content["Choices"] as? [[String: Any]],
          choices.allSatisfy({ ($0["Provider"] as? String)?.isEmpty == false })
        else { throw Failure.malformed("\(key) has invalid provider content") }
      }
      let required = ["linked": "Linked", "desktop": "Desktop", "idle": "Idle"][type]
      if let required, value[required] == nil { throw Failure.malformed("\(type) has no \(required)") }
      if type == "individual" && value["Desktop"] == nil && value["Idle"] == nil {
        throw Failure.malformed("individual has no choice")
      }
    }
    try node(store["SystemDefault"])
    if let all = store["AllSpacesAndDisplays"], all as? String != "$null" { try node(all) }
    for key in ["Displays", "Spaces"] {
      guard let value = store[key] else { continue }
      guard let map = value as? [String: Any] else { throw Failure.malformed("\(key) is not a dictionary") }
      for entry in map.values {
        if key == "Displays" { try node(entry); continue }
        guard let space = entry as? [String: Any] else { throw Failure.malformed("Space is not a dictionary") }
        if let value = space["Default"] { try node(value) }
        if let value = space["Displays"] {
          guard let displays = value as? [String: Any] else { throw Failure.malformed("Space displays are not a dictionary") }
          for value in displays.values { try node(value) }
        }
      }
    }
    guard PropertyListSerialization.propertyList(store, isValidFor: .binary) else {
      throw Failure.malformed("non-property-list value")
    }
  }

  /// Ignore only volatile wallpaper timestamps. Unknown fields remain significant.
  static func semanticallyEqual(_ left: Any?, _ right: Any?) -> Bool {
    if left == nil || right == nil { return left == nil && right == nil }
    if let a = left as? [String: Any], let b = right as? [String: Any] {
      let keys = Set(a.keys).union(b.keys).subtracting(volatileKeys)
      return keys.allSatisfy { semanticallyEqual(a[$0], b[$0]) }
    }
    if let a = left as? [Any], let b = right as? [Any] {
      return a.count == b.count && zip(a, b).allSatisfy { semanticallyEqual($0, $1) }
    }
    if let a = left as? Data, let b = right as? Data,
      let decodedA = try? PropertyListSerialization.propertyList(from: a, format: nil),
      let decodedB = try? PropertyListSerialization.propertyList(from: b, format: nil) {
      return semanticallyEqual(decodedA, decodedB)
    }
    return (left as? NSObject)?.isEqual(right) ?? false
  }

  private static func choices(_ value: [String: Any]) -> [String: Any] {
    value.filter { choiceKeys.contains($0.key) }
  }

  private static func merge(_ original: Any?, _ applied: Any?, _ current: Any?,
                            restored: inout Int, conflicts: inout Int) -> Any? {
    if semanticallyEqual(original, applied) { return current }
    if semanticallyEqual(current, applied) { restored += 1; return original }
    guard let now = current as? [String: Any], let after = applied as? [String: Any],
      original == nil || original is [String: Any]
    else {
      if !semanticallyEqual(current, original) { conflicts += 1 }
      return current
    }
    let before = original as? [String: Any] ?? [:]
    var result = now
    let isChoice = before["Type"] != nil || after["Type"] != nil || now["Type"] != nil
    if isChoice {
      let oldChoice = choices(before), appliedChoice = choices(after), currentChoice = choices(now)
      if !semanticallyEqual(oldChoice, appliedChoice) {
        if semanticallyEqual(currentChoice, appliedChoice) && !oldChoice.isEmpty {
          for key in choiceKeys { result[key] = before[key] }
          restored += 1
        } else if !semanticallyEqual(currentChoice, oldChoice) {
          // A new node with extra user metadata is retained whole rather than made invalid.
          conflicts += 1
        }
      }
    }
    for key in Set(before.keys).union(after.keys) where !volatileKeys.contains(key) && !(isChoice && choiceKeys.contains(key)) {
      result[key] = merge(before[key], after[key], now[key], restored: &restored, conflicts: &conflicts)
    }
    return result.isEmpty && original == nil ? nil : result
  }

  static func merged(original: [String: Any], applied: [String: Any], current: [String: Any]) throws -> [String: Any] {
    try decode(plan(original: encode(original), applied: encode(applied), current: encode(current)).data)
  }

  static func plan(original: Data, applied: Data, current: Data) throws -> Plan {
    let old = try decode(original), after = try decode(applied), now = try decode(current)
    var restored = 0, conflicts = 0
    guard let result = merge(old, after, now, restored: &restored, conflicts: &conflicts) as? [String: Any]
    else { throw Failure.malformed("merged root") }
    return Plan(data: try encode(result), changed: !semanticallyEqual(result, now),
                restoredFields: restored, conflicts: conflicts)
  }

  static func referencesImage(_ data: Data, url: String) throws -> Bool {
    containsImage(try decode(data), url: url)
  }

  /// Only wallpaper choice nodes, never arbitrary metadata dictionaries.
  private static func nodes(_ store: [String: Any]) -> [(path: [String], value: [String: Any])] {
    var result: [(path: [String], value: [String: Any])] = []
    for key in ["SystemDefault", "AllSpacesAndDisplays"] {
      if let node = store[key] as? [String: Any] { result.append(([key], node)) }
    }
    for (display, node) in store["Displays"] as? [String: Any] ?? [:] {
      if let node = node as? [String: Any] { result.append((["Displays", display], node)) }
    }
    for (space, value) in store["Spaces"] as? [String: Any] ?? [:] {
      guard let value = value as? [String: Any] else { continue }
      if let node = value["Default"] as? [String: Any] { result.append((["Spaces", space, "Default"], node)) }
      for (display, node) in value["Displays"] as? [String: Any] ?? [:] {
        if let node = node as? [String: Any] { result.append((["Spaces", space, "Displays", display], node)) }
      }
    }
    return result
  }

  private static func value(_ store: [String: Any], at path: [String]) -> Any? {
    var value: Any? = store
    for key in path { value = (value as? [String: Any])?[key] }
    return value
  }

  private static func inheritedChoice(_ original: [String: Any], at path: [String]) -> [String: Any] {
    if path.first == "Spaces", path.count == 4,
      let node = value(original, at: ["Spaces", path[1], "Default"]) as? [String: Any] { return choices(node) }
    if path.first == "Spaces", path.contains("Displays"), let display = path.last,
      let node = value(original, at: ["Displays", display]) as? [String: Any] { return choices(node) }
    return choices(original["SystemDefault"] as? [String: Any] ?? [:])
  }

  static func validateOwnedChoices(_ history: [Data]) throws {
    for data in history {
      guard let node = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        Set(node.keys).isSubset(of: choiceKeys) else { throw Failure.malformed("owned choice history") }
      try validate(["SystemDefault": node])
    }
  }

  /// Remember complete choices instead of just URLs: a user changing the screensaver,
  /// placement, or another option must not accidentally make that new choice ours.
  static func recordingOwnedChoices(_ history: [Data], baseline: Data, applied: Data,
                                    expectedImageURL: String) throws -> [Data] {
    let old = try decode(baseline), after = try decode(applied)
    var result = history
    for (path, node) in nodes(after) where containsImage(node, url: expectedImageURL) {
      let group = choices(node)
      let baselineGroup = choices(value(old, at: path) as? [String: Any] ?? [:])
      guard !semanticallyEqual(group, baselineGroup) else { continue }
      let data = try PropertyListSerialization.data(fromPropertyList: group, format: .binary, options: 0)
      if !result.contains(where: { semanticallyEqual($0, data) }) { result.append(data) }
    }
    return result
  }

  /// A new Space can inherit an older app snapshot after the setter has completed.
  /// Its wallpaper override belongs to the app when the entire choice matches history.
  /// Removing that override does not remove the actual Space; it restores inheritance.
  static func restoringInheritedChoices(_ data: Data, original: Data, history: [Data]) throws -> Data {
    let store = try decode(data), initial = try decode(original)
    let known = try history.map { try PropertyListSerialization.propertyList(from: $0, format: nil) }
    let candidates = nodes(store).filter { path, node in
      (path.first == "Spaces" || path.first == "Displays") && value(initial, at: path) == nil &&
        known.contains { semanticallyEqual($0, choices(node)) }
    }
    func update(_ dictionary: [String: Any], path: ArraySlice<String>, fullPath: [String], inheritance: [String: Any]) -> [String: Any]? {
      guard let key = path.first else { return dictionary }
      var result = dictionary
      if path.count == 1, let node = result[key] as? [String: Any] {
        let extras = node.filter { !choiceKeys.contains($0.key) && !volatileKeys.contains($0.key) }
        // Preserve unknown node metadata with a valid inherited original choice.
        result[key] = extras.isEmpty ? nil : extras.merging(inheritedChoice(inheritance, at: fullPath)) { _, inherited in inherited }
      } else if let child = result[key] as? [String: Any] {
        let prefix = Array(fullPath.prefix(fullPath.count - path.count + 1))
        let changed = update(child, path: path.dropFirst(), fullPath: fullPath, inheritance: inheritance)
        result[key] = changed?.isEmpty == true && value(initial, at: prefix) == nil ? nil : changed
      }
      return result
    }
    var result = store
    for (path, _) in candidates { result = update(result, path: path[...], fullPath: path, inheritance: result) ?? result }
    return try encode(result)
  }

  private static func containsImage(_ value: Any, url: String, depth: Int = 0) -> Bool {
    guard depth < 32 else { return false }
    if let text = value as? String {
      if text == url { return true }
      if let a = URL(string: text), let b = URL(string: url), a.isFileURL, b.isFileURL {
        return a.standardizedFileURL.path == b.standardizedFileURL.path
      }
    }
    if let map = value as? [String: Any] { return map.values.contains { containsImage($0, url: url, depth: depth + 1) } }
    if let list = value as? [Any] { return list.contains { containsImage($0, url: url, depth: depth + 1) } }
    if let blob = value as? Data, let decoded = try? PropertyListSerialization.propertyList(from: blob, format: nil) {
      return containsImage(decoded, url: url, depth: depth + 1)
    }
    return false
  }

  /// Incorporate unowned changes that occurred during the setter into the undo baseline.
  /// Only choices containing the expected image, plus its known global unlink side effect,
  /// become owned. Metadata and unrelated user choices are never claimed by this apply.
  static func baselineAfterApply(baseline: Data, before: Data, after: Data, expectedImageURL: String) throws -> Data {
    let old = try decode(baseline), prior = try decode(before), actual = try decode(after)
    guard containsImage(actual, url: expectedImageURL) else { throw Failure.incomplete }
    let priorDefault = prior["SystemDefault"] as? [String: Any] ?? [:]
    func rebase(_ baseline: Any?, _ before: Any?, _ after: Any?, path: [String]) -> Any? {
      if semanticallyEqual(before, after) { return baseline }
      guard let next = after as? [String: Any], before == nil || before is [String: Any],
        baseline == nil || baseline is [String: Any] else { return after }
      let previous = before as? [String: Any] ?? [:]
      var result = baseline as? [String: Any] ?? [:]
      let typed = next["Type"] != nil || previous["Type"] != nil
      if typed && !semanticallyEqual(choices(previous), choices(next)) {
        // A setter converts a linked choice into Desktop + the original Idle choice. Do not
        // claim a concurrent screensaver change merely because Desktop is our snapshot.
        let priorNode = previous.isEmpty ? priorDefault : previous
        let priorIdle = priorNode["Idle"] ?? priorNode["Linked"]
        let ownsDesktop = containsImage(next["Desktop"] ?? [:], url: expectedImageURL) &&
          semanticallyEqual(next["Idle"], priorIdle) && next["Linked"] == nil
        let ownsLinked = containsImage(next["Linked"] ?? [:], url: expectedImageURL) &&
          next["Desktop"] == nil && next["Idle"] == nil
        let ownsImage = ownsDesktop || ownsLinked
        let unlinked = path == ["AllSpacesAndDisplays"] && previous["Type"] as? String == "linked" &&
          next["Type"] as? String == "idle" && semanticallyEqual(previous["Linked"], next["Idle"])
        if !ownsImage && !unlinked {
          for key in choiceKeys { result[key] = next[key] }
        }
      }
      for key in Set(previous.keys).union(next.keys) where !(typed && choiceKeys.contains(key)) {
        result[key] = rebase(result[key], previous[key], next[key], path: path + [key])
      }
      return result.isEmpty && baseline == nil ? nil : result
    }
    guard let result = rebase(old, prior, actual, path: []) as? [String: Any] else { throw Failure.malformed("undo baseline") }
    return try encode(result)
  }
}

final class WallpaperRestoreJournal {
  typealias Plan = WallpaperRestore.Plan
  struct Entry {
    let original: Data
    let baseline: Data
    let before: Data
    let applied: Data?
    let expectedImageURL: String
    let ownedChoices: [Data]
  }
  let url: URL
  init(url: URL) { self.url = url }

  func begin(original: Data, expectedImageURL: String) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw WallpaperRestore.Failure.existingJournal }
    try save(Entry(original: original, baseline: original, before: original, applied: nil,
                   expectedImageURL: expectedImageURL, ownedChoices: []))
  }

  func prepareApplication(current: Data, expectedImageURL: String) throws {
    guard let entry = try load() else { throw WallpaperRestore.Failure.missingJournal }
    guard entry.applied != nil else { throw WallpaperRestore.Failure.incomplete }
    let rebased = try planRestore(current: current)
    try save(Entry(original: entry.original, baseline: rebased.data, before: current, applied: nil,
                   expectedImageURL: expectedImageURL, ownedChoices: entry.ownedChoices))
  }

  func recordApplied(_ current: Data) throws {
    guard let entry = try load() else { throw WallpaperRestore.Failure.missingJournal }
    guard entry.applied == nil else { throw WallpaperRestore.Failure.existingJournal }
    let provisional = try WallpaperRestore.baselineAfterApply(baseline: entry.baseline, before: entry.before,
      after: current, expectedImageURL: entry.expectedImageURL)
    let owned = try WallpaperRestore.recordingOwnedChoices(entry.ownedChoices, baseline: provisional,
      applied: current, expectedImageURL: entry.expectedImageURL)
    let baseline = try WallpaperRestore.restoringInheritedChoices(provisional, original: entry.original, history: owned)
    try save(Entry(original: entry.original, baseline: baseline, before: entry.before, applied: current,
                   expectedImageURL: entry.expectedImageURL, ownedChoices: owned))
  }

  /// Establish that a pending setter never changed the store. The caller must first exclude
  /// any setter still capable of completing. Persisting this proof also makes a crash during
  /// the following rollback recoverable through the ordinary completed-journal path.
  func confirmNotApplied(current: Data) throws {
    guard let entry = try load() else { throw WallpaperRestore.Failure.missingJournal }
    guard entry.applied == nil,
      WallpaperRestore.semanticallyEqual(try WallpaperRestore.decode(current),
                                         try WallpaperRestore.decode(entry.before))
    else { throw WallpaperRestore.Failure.incomplete }
    try save(Entry(original: entry.original, baseline: entry.baseline, before: entry.before,
                   applied: entry.before, expectedImageURL: entry.expectedImageURL, ownedChoices: entry.ownedChoices))
  }

  func planRestore(current: Data) throws -> Plan {
    guard let entry = try load() else { throw WallpaperRestore.Failure.missingJournal }
    let applied: Data
    if let completed = entry.applied {
      applied = completed
    } else {
      // A crash before the setter leaves the store exactly at the durable pre-apply state.
      // The rebased baseline still describes the undo for previously completed snapshots.
      // The caller must exclude an in-process setter that could still complete later.
      guard WallpaperRestore.semanticallyEqual(try WallpaperRestore.decode(current),
                                               try WallpaperRestore.decode(entry.before))
      else { throw WallpaperRestore.Failure.incomplete }
      applied = entry.before
    }
    let plan = try WallpaperRestore.plan(original: entry.baseline, applied: applied, current: current)
    let inherited = try WallpaperRestore.restoringInheritedChoices(plan.data, original: entry.original,
      history: entry.ownedChoices)
    return Plan(data: inherited,
      changed: !WallpaperRestore.semanticallyEqual(try WallpaperRestore.decode(inherited), try WallpaperRestore.decode(current)),
      restoredFields: plan.restoredFields, conflicts: plan.conflicts)
  }

  func load() throws -> Entry? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    guard let map = value as? [String: Any], map["version"] as? Int == 2,
      let original = map["original"] as? Data, let baseline = map["baseline"] as? Data,
      let before = map["before"] as? Data, let expected = map["expectedImageURL"] as? String,
      let image = URL(string: expected), image.isFileURL,
      map["applied"] == nil || map["applied"] is Data,
      let owned = map["ownedChoices"] as? [Data]
    else { throw WallpaperRestore.Failure.malformed("journal") }
    for data in [original, baseline, before] { _ = try WallpaperRestore.decode(data) }
    let applied = map["applied"] as? Data
    if let applied { _ = try WallpaperRestore.decode(applied) }
    try WallpaperRestore.validateOwnedChoices(owned)
    return Entry(original: original, baseline: baseline, before: before, applied: applied,
                 expectedImageURL: expected, ownedChoices: owned)
  }

  private func save(_ entry: Entry) throws {
    guard let image = URL(string: entry.expectedImageURL), image.isFileURL else { throw WallpaperRestore.Failure.malformed("expected image URL") }
    for data in [entry.original, entry.baseline, entry.before] { _ = try WallpaperRestore.decode(data) }
    if let applied = entry.applied { _ = try WallpaperRestore.decode(applied) }
    try WallpaperRestore.validateOwnedChoices(entry.ownedChoices)
    var map: [String: Any] = ["version": 2, "original": entry.original, "baseline": entry.baseline,
      "before": entry.before, "expectedImageURL": entry.expectedImageURL, "ownedChoices": entry.ownedChoices]
    map["applied"] = entry.applied
    let data = try PropertyListSerialization.data(fromPropertyList: map, format: .binary, options: 0)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
  }

  func clear() throws { try FileManager.default.removeItem(at: url) }
}
