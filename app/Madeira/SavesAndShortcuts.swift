// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Two things players of other Windows game launchers expect:
//
// * Save backups. A game's progress lives in the Wine prefix (C:\users\...),
//   which a prefix reset, an experiment or a reinstall under another bundle
//   id takes with it. Settings › Saves writes every Windows user's Documents,
//   Saved Games and AppData (caches, and Valve's client and web caches, left
//   out) into one zip to keep in Files or iCloud Drive, and puts one back.
// * Home Screen shortcuts. madeira://play?exe=<Windows path> starts that game
//   if it is in the library (after JIT, like Play on its details page). Game
//   details copies the link; the Shortcuts app turns it into a Home Screen icon.

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Compression
import zlib

// MARK: - Shortcut links

final class ShortcutRouter: ObservableObject {
    static let shared = ShortcutRouter()

    /// A Windows path waiting for the library to launch it.
    @Published var pendingExe: String?

    static func link(for windowsPath: String) -> String {
        var c = URLComponents()
        c.scheme = "madeira"
        c.host = "play"
        c.queryItems = [URLQueryItem(name: "exe", value: windowsPath)]
        return c.string ?? "madeira://play"
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "madeira", url.host?.lowercased() == "play",
              let exe = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "exe" })?.value, !exe.isEmpty else { return }
        LogStore.shared.log("[shortcut] asked to start \(exe)")
        pendingExe = exe
    }
}

/// The Steam game a game in the last Dock session asked to start (LibraryModel.steamRunRequest).
/// The next app run starts it once, if that run begins within 30 minutes.
enum NextSteamApp {
    private static let key = "madeira.nextSteamApp"
    static func set(_ appID: Int) {
        UserDefaults.standard.set(["app": appID, "at": Date().timeIntervalSince1970], forKey: key)
    }
    static func take() -> Int? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        guard let app = saved["app"] as? Int, app > 0, app <= Int(UInt32.max),
              let at = saved["at"] as? Double else { return nil }
        let age = Date().timeIntervalSince1970 - at
        guard age >= 0, age < 30 * 60 else { return nil }
        return app
    }
}

/// The game pressed while a launch was held for a restart (one session per app run): the next
/// app run starts it once through launchShortcut, if that run begins within 30 minutes. Taken
/// before the start, so a start that crashes is not tried again.
enum NextGameAfterRestart {
    private static let key = "madeira.nextGame"
    /// Remembers `entry`; the words to add to the restart notice. launchShortcut does not start the Desktop.
    static func hold(_ entry: LibraryEntry) -> String {
        guard entry.desktop != true else { return "" }
        UserDefaults.standard.set(["exe": entry.windowsPath, "at": Date().timeIntervalSince1970], forKey: key)
        return " " + entry.title + " starts by itself when Madeira opens again within 30 minutes."
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
    static func take() -> String? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        clear()
        guard let exe = saved["exe"] as? String, !exe.isEmpty, let at = saved["at"] as? Double else { return nil }
        let age = Date().timeIntervalSince1970 - at
        guard age >= 0, age < 30 * 60 else { return nil }
        return exe
    }
}

// MARK: - Importing games

/// The library's + › Import folder and Import .zip/.7z: a game's files into a new folder in
/// drive_c's Games folder, a staging copy first, so a stopped import leaves nothing behind. Then
/// the usual Add executable page opens on that folder. Published state is the main thread's.
final class LibraryImporter: ObservableObject {
    static let shared = LibraryImporter()
    enum Source { case folder, archive }
    @Published var picking = false
    @Published var sheetShown = false
    @Published private(set) var source = Source.folder
    @Published private(set) var running = false
    @Published private(set) var name = ""
    @Published private(set) var progress: Double?
    @Published private(set) var failure: String?
    private var finished: URL?
    private var task: Task<Void, Never>?

    var allowedTypes: [UTType] {
        source == .folder ? [.folder] : [.zip, .archive, UTType(filenameExtension: "7z") ?? .data]
    }

    func pick(_ source: Source) {
        self.source = source
        picking = true
    }

    func begin(_ url: URL) {
        guard !running else { return }
        let isFolder = source == .folder
        running = true; failure = nil; finished = nil; progress = nil
        name = url.lastPathComponent
        sheetShown = true
        task = Task.detached(priority: .userInitiated) {
            var lastPercent = -1
            let report: (UInt64, UInt64) -> Void = { done, total in
                guard total > 0 else { return }
                let percent = Int(Double(done) / Double(total) * 100)
                guard percent != lastPercent else { return }
                lastPercent = percent
                DispatchQueue.main.async { LibraryImporter.shared.progress = Double(percent) / 100 }
            }
            do {
                let target = try isFolder ? LibraryImporter.copyFolder(url, report: report) : LibraryImporter.unpackArchive(url, report: report)
                DispatchQueue.main.async { LibraryImporter.shared.end(target) }
            } catch is CancellationError {
                DispatchQueue.main.async { LibraryImporter.shared.end(nil) }
            } catch {
                let words = error.localizedDescription
                LogStore.shared.log("[import] \(url.lastPathComponent) not imported: \(words)", level: .error)
                DispatchQueue.main.async { LibraryImporter.shared.failed(words) }
            }
        }
    }

    func cancel() { task?.cancel() }

    private func end(_ target: URL?) {
        running = false; task = nil; finished = target
        if let target { LogStore.shared.log("[import] into \(target.lastPathComponent)") }
        sheetShown = false
    }

    func failed(_ words: String) {
        running = false; task = nil; failure = words
        sheetShown = true
    }

    /// The new folder, once, for the Add executable page.
    func takeFinished() -> URL? {
        defer { finished = nil }
        return finished
    }

    private static func checkRoom(_ bytes: UInt64) throws {
        guard let free = ItchLibrary.freeSpace(at: URL.documentsDirectory) else { return }
        let needed = bytes.addingReportingOverflow(256 << 20)   // the same margin as moving a game to a drive
        guard needed.overflow || Int64(clamping: needed.partialValue) > free else { return }
        let want = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        throw LibraryError.message("Not enough free space: this game needs \(want), and \(have) is free.")
    }

    /// A new, unused folder name in drive_c/Games, by Wine's rule that case does not count.
    private static func newGameFolder(named raw: String) throws -> URL {
        let fm = FileManager.default
        let games = LibraryModel.drive.appendingPathComponent("Games", isDirectory: true)
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        var base = ClaudeHelp.safeName(raw)
        while base.hasPrefix(".") { base.removeFirst() }
        while base.hasSuffix(".") || base.hasSuffix(" ") { base.removeLast() }
        if base.isEmpty { base = "Game" }
        let taken = Set(((try? fm.contentsOfDirectory(atPath: games.path)) ?? []).map { $0.lowercased() })
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) || taken.contains("." + name.lowercased() + ".importing") {
            name = "\(base) \(number)"
            number += 1
        }
        return games.appendingPathComponent(name, isDirectory: true)
    }

    /// Folders and regular files only: a link is not followed out of the chosen folder.
    private static func copyFolder(_ source: URL, report: (UInt64, UInt64) -> Void) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard LibraryModel.relativeToDrive(source) == nil else {
            throw LibraryError.message("This folder is already in drive_c. Tap + and choose its .exe.")
        }
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: source.path) else { throw LibraryError.message("This folder could not be read.") }
        var folders: [String] = []
        var files: [(path: String, size: UInt64)] = []
        var total: UInt64 = 0
        while let relative = walker.nextObject() as? String {
            try Task.checkCancellation()
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                folders.append(relative)
            } else if type == .typeRegular {
                let leaf = (relative as NSString).lastPathComponent
                if leaf.hasPrefix("."), leaf.hasSuffix(".icloud") {
                    throw LibraryError.message("Some files in this folder are still in iCloud. Download the folder in the Files app first.")
                }
                let size = (walker.fileAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
                files.append((relative, size))
                total += size
            }
        }
        guard !files.isEmpty else { throw LibraryError.message("This folder has no files.") }
        try checkRoom(total)
        let target = try newGameFolder(named: source.lastPathComponent)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("." + target.lastPathComponent + ".importing", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for folder in folders {
                try fm.createDirectory(at: staging.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
            }
            var done: UInt64 = 0
            for file in files {
                try Task.checkCancellation()
                try fm.copyItem(at: source.appendingPathComponent(file.path), to: staging.appendingPathComponent(file.path))
                done += file.size
                report(done, total)
            }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return target
    }

    /// Coordinated, so a file provider has the file here first; ItchArchive does the rest, from its own staging folder.
    private static func unpackArchive(_ source: URL, report: @escaping (UInt64, UInt64) -> Void) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordination: NSError?
        var outcome: Swift.Result<URL, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordination) { local in
            outcome = Swift.Result<URL, Error>(catching: {
                guard let bytes = try ItchArchive.unpackedBytes(local) else {
                    throw LibraryError.message("This is not a .zip or .7z archive.")
                }
                try checkRoom(bytes)
                let target = try newGameFolder(named: source.deletingPathExtension().lastPathComponent)
                _ = try ItchArchive.unpackAny(local, to: target, progress: report)
                return target
            })
        }
        if let coordination { throw coordination }
        guard let outcome else { throw LibraryError.message("This file could not be read.") }
        return try outcome.get()
    }
}

/// An import under way, or why it stopped.
struct LibraryImportSheet: View {
    @ObservedObject private var importer = LibraryImporter.shared
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !importer.name.isEmpty { Text(importer.name) }
                    if importer.running {
                        if let progress = importer.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                    }
                    if let failure = importer.failure { Text(failure).foregroundStyle(.red) }
                } footer: {
                    if importer.running { Text("Into drive_c › Games. Keep Madeira open until it finishes.") }
                }
            }
            .navigationTitle("Import game").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if importer.running {
                        Button("Cancel") { importer.cancel() }
                    } else {
                        Button("Done") { importer.sheetShown = false }
                    }
                }
            }
        }
        .interactiveDismissDisabled(importer.running)
    }
}

// MARK: - Zip writing (stored)

/// Uncompressed zip (saves are small, and many are compressed already). No
/// zip64: the backup stops before 3.5 GB or 65,535 files.
final class SaveZipWriter {
    static let maxEntries = 0xFFFF
    private let handle: FileHandle
    private var central = Data()
    private(set) var count = 0
    private(set) var offset: UInt64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private static func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 2) }
    private static func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    func add(name: String, data: Data) throws {
        let n = Data(name.utf8)
        let crc = data.withUnsafeBytes { raw -> UInt32 in
            UInt32(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
        let size = UInt32(data.count)
        // Version 2.0, UTF-8 names (bit 11), stored, 1980-01-01 00:00.
        var local = Data()
        local += Self.le32(0x0403_4b50); local += Self.le16(20); local += Self.le16(0x0800)
        local += Self.le16(0); local += Self.le16(0); local += Self.le16(0x21)
        local += Self.le32(crc); local += Self.le32(size); local += Self.le32(size)
        local += Self.le16(n.count); local += Self.le16(0); local += n
        var cd = Data()
        cd += Self.le32(0x0201_4b50); cd += Self.le16(20); cd += Self.le16(20); cd += Self.le16(0x0800)
        cd += Self.le16(0); cd += Self.le16(0); cd += Self.le16(0x21)
        cd += Self.le32(crc); cd += Self.le32(size); cd += Self.le32(size)
        cd += Self.le16(n.count); cd += Self.le16(0); cd += Self.le16(0)
        cd += Self.le16(0); cd += Self.le16(0); cd += Self.le32(0)
        cd += Self.le32(UInt32(offset)); cd += n
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)
        offset += UInt64(local.count + data.count)
        central += cd
        count += 1
    }

    func finish() throws {
        var end = Data()
        end += Self.le32(0x0605_4b50); end += Self.le16(0); end += Self.le16(0)
        end += Self.le16(count); end += Self.le16(count)
        end += Self.le32(UInt32(central.count)); end += Self.le32(UInt32(offset)); end += Self.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

// MARK: - Zip reading (stored and deflate, zip64 aware)

/// Reads the backup back, or a zip of the same files made elsewhere (the
/// Files app's Compress writes deflate). The file is memory-mapped, not read.
struct SaveZipReader {
    struct Entry { let name: String; let method: Int; let compressedSize: Int; let size: Int; let localOffset: Int }

    private let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        let b = try Data(contentsOf: url, options: .alwaysMapped)
        data = b
        func fail(_ m: String) -> Error { LibraryError.message(m) }
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= b.count else { throw fail("The zip is truncated.") }
            return Int(b[b.startIndex + o]) | Int(b[b.startIndex + o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int { let lo = try u16(o), hi = try u16(o + 2); return lo | hi << 16 }
        func u64(_ o: Int) throws -> Int {
            let lo = try u32(o), hi = try u32(o + 4)
            guard hi < 0x10000 else { throw fail("The zip is too large.") }
            return lo | hi << 32
        }
        guard b.count >= 22 else { throw fail("Not a zip file.") }
        var eocd = -1
        var p = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while p >= lowest {
            if try u32(p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw fail("Not a zip file.") }
        var count = try u16(eocd + 10)
        var cdOffset = try u32(eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            let loc = eocd - 20
            guard try u32(loc) == 0x0706_4b50 else { throw fail("Broken zip64 record.") }
            let z = try u64(loc + 8)
            guard try u32(z) == 0x0606_4b50 else { throw fail("Broken zip64 record.") }
            count = try u64(z + 32)
            cdOffset = try u64(z + 48)
        }
        var list: [Entry] = []
        var q = cdOffset
        for _ in 0..<count {
            guard try u32(q) == 0x0201_4b50 else { throw fail("Broken zip directory.") }
            let method = try u16(q + 10)
            var csize = try u32(q + 20)
            var usize = try u32(q + 24)
            let nlen = try u16(q + 28), elen = try u16(q + 30), clen = try u16(q + 32)
            var loff = try u32(q + 42)
            guard q + 46 + nlen <= b.count else { throw fail("The zip is truncated.") }
            let start = b.startIndex + q + 46
            let name = String(decoding: b[start..<(start + nlen)], as: UTF8.self)
            // zip64 extra field: the 0xFFFFFFFF fields, in this order.
            var x = q + 46 + nlen
            let xend = x + elen
            while x + 4 <= xend {
                let id = try u16(x), len = try u16(x + 2)
                if id == 0x0001 {
                    var f = x + 4
                    if usize == 0xFFFF_FFFF { usize = try u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF { csize = try u64(f); f += 8 }
                    if loff == 0xFFFF_FFFF { loff = try u64(f) }
                }
                x += 4 + len
            }
            list.append(Entry(name: name, method: method, compressedSize: csize, size: usize, localOffset: loff))
            q += 46 + nlen + elen + clen
        }
        entries = list
    }

    func extract(_ e: Entry) throws -> Data {
        let b = data
        let o = e.localOffset
        // A size in the directory is only a claim: nothing larger than a backup holds is allocated.
        guard e.size >= 0, e.size <= SaveBackup.maxFile, e.compressedSize <= SaveBackup.maxFile + (1 << 20) else {
            throw LibraryError.message("\(e.name) is too large to restore.")
        }
        guard o >= 0, o + 30 <= b.count,
              b[b.startIndex + o] == 0x50, b[b.startIndex + o + 1] == 0x4b,
              b[b.startIndex + o + 2] == 0x03, b[b.startIndex + o + 3] == 0x04 else {
            throw LibraryError.message("Broken zip entry \(e.name).")
        }
        let nlen = Int(b[b.startIndex + o + 26]) | Int(b[b.startIndex + o + 27]) << 8
        let elen = Int(b[b.startIndex + o + 28]) | Int(b[b.startIndex + o + 29]) << 8
        let start = o + 30 + nlen + elen
        guard e.compressedSize >= 0, start + e.compressedSize <= b.count else { throw LibraryError.message("The zip is truncated.") }
        let src = b.subdata(in: (b.startIndex + start)..<(b.startIndex + start + e.compressedSize))
        switch e.method {
        case 0:
            return src
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let written: Int = out.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, e.size, sp, s.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { throw LibraryError.message("\(e.name) could not be decompressed.") }
            return out
        default:
            throw LibraryError.message("\(e.name) uses zip method \(e.method), which is not supported.")
        }
    }
}

// MARK: - Save backups

enum SaveBackup {
    /// Folders under each C:\users\<name> that hold saves and settings.
    static let roots = ["Documents", "Saved Games", "AppData/Roaming", "AppData/LocalLow", "AppData/Local"]
    /// Folder names that are caches or Windows' own files, never saves.
    /// "steam" and "htmlcache": the Steam client Madeira Dock runs keeps its sign-in
    /// state (local.vdf) and web cookies under AppData\Local\Steam; never in a backup.
    static let skipped: Set<String> = ["madeira", "temp", "shadercache", "d3dscache", "nvidia", "microsoft",
                                       "cache", "caches", "crashdumps", "logs", "webcache", "steam", "htmlcache"]
    static let maxFile = 256 << 20
    static let maxTotal: UInt64 = 3_500 << 20

    struct BackupResult { let url: URL; let files: Int; let bytes: UInt64; let leftOut: Int }

    /// Writes the zip into the temporary directory; entries are named from
    /// drive_c ("users/<name>/Documents/..."), which is where restore puts them.
    static func backup(includeSettings: Bool = false) throws -> BackupResult {
        let fm = FileManager.default
        let drive = LibraryModel.drive
        let users = drive.appendingPathComponent("users", isDirectory: true)
        guard fm.fileExists(atPath: users.path) else { throw LibraryError.message("There is no Windows drive yet.") }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HH-mm"
        let out = fm.temporaryDirectory.appendingPathComponent("Madeira-saves-\(stamp.string(from: Date())).zip")
        try? fm.removeItem(at: out)
        let zip = try SaveZipWriter(url: out)
        var leftOut = 0
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            for root in roots {
                let base = "users/\(user)/\(root)"
                let dir = drive.appendingPathComponent(base, isDirectory: true)
                // Relative paths, so entry names never depend on how the
                // container path is spelled (/var or /private/var).
                guard let e = fm.enumerator(atPath: dir.path) else { continue }
                while let rel = e.nextObject() as? String {
                    let type = e.fileAttributes?[.type] as? FileAttributeType
                    if type == .typeDirectory {
                        if skipped.contains((rel as NSString).lastPathComponent.lowercased()) { e.skipDescendants() }
                        continue
                    }
                    guard type == .typeRegular else { continue }   // links are not followed
                    let size = (e.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
                    if size > maxFile || zip.offset + UInt64(size) > maxTotal || zip.count >= SaveZipWriter.maxEntries { leftOut += 1; continue }
                    guard let data = try? Data(contentsOf: dir.appendingPathComponent(rel)) else { continue }
                    try zip.add(name: base + "/" + rel, data: data)
                }
            }
        }
        if includeSettings { try addSettings(to: &leftOut, zip) }
        try zip.finish()
        LogStore.shared.log("[saves] backup: \(zip.count) files, \(zip.offset) bytes, \(leftOut) left out, settings=\(includeSettings ? 1 : 0)")
        return BackupResult(url: out, files: zip.count, bytes: zip.offset, leftOut: leftOut)
    }

    // MARK: Madeira's settings in a backup
    //
    // "Include Madeira settings": the library, madeira.cfg, the control layouts and the games' own
    // config files, under madeira-settings/. Sign-ins live in the Keychain and are never in these
    // files; a config line whose name reads like a credential is left out as well.

    static let settingsFolder = "madeira-settings"
    static let libraryFile = "madeira-library.json"
    static let presetsFile = "madeira-control-presets.json"
    /// Far above what these files hold; a bad archive's claim is not believed past it.
    static let settingsFileLimit = 32 << 20

    private static let credentialWords = ["token", "passw", "secret", "apikey", "api_key", "api-key", "credential", "ticket"]
    private static func withoutCredentialLines(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.components(separatedBy: .newlines).filter { line in
            guard let eq = line.firstIndex(of: "=") else { return true }
            let key = line[..<eq].lowercased()
            return !credentialWords.contains { key.contains($0) }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// A game's config file name, as GameProfile.url makes it: 16 hex digits and .cfg.
    static func isGameConfigName(_ name: String) -> Bool {
        guard name.utf8.count == 20, name.hasSuffix(".cfg") else { return false }
        let digits = Set("0123456789abcdef")
        return name.dropLast(4).allSatisfy { digits.contains($0) }
    }

    private static func addSettings(to leftOut: inout Int, _ zip: SaveZipWriter) throws {
        LibraryFileWriter.drain()   // a queued library save lands first
        let documents = LibraryModel.documents
        func add(_ source: URL, as name: String, scrub: Bool) throws {
            guard let data = try? Data(contentsOf: source) else { return }
            guard data.count <= settingsFileLimit else { leftOut += 1; return }
            try zip.add(name: settingsFolder + "/" + name, data: scrub ? withoutCredentialLines(data) : data)
        }
        try add(documents.appendingPathComponent(libraryFile), as: libraryFile, scrub: false)
        try add(documents.appendingPathComponent(MadeiraConfig.fileName), as: MadeiraConfig.fileName, scrub: true)
        try add(documents.appendingPathComponent(presetsFile), as: presetsFile, scrub: false)
        guard let configs = GameProfile.directory else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: configs.path)) ?? [] where isGameConfigName(name) {
            try add(configs.appendingPathComponent(name), as: "GameConfigs/" + name, scrub: true)
        }
    }

    struct RestoreResult {
        let files: Int
        let settingsFiles: Int
        /// The backup's library, checked; LibraryModel.replaceEntries takes it on the main thread.
        let library: [LibraryEntry]?
        let presets: Bool
    }

    /// The settings a backup holds, every one checked before anything is written, so a bad file
    /// stops the restore with nothing replaced. Only the names below are looked at: any other
    /// path in the archive is ignored.
    private static func readSettings(_ zip: SaveZipReader) throws -> (writes: [(URL, Data)], library: [LibraryEntry]?, presets: Bool) {
        var writes: [(URL, Data)] = []
        var library: [LibraryEntry]?
        var presets = false
        func text(_ data: Data, _ name: String) throws {
            guard data.count < 1 << 20, String(data: data, encoding: .utf8) != nil else {
                throw LibraryError.message("The backup's \(name) cannot be read, so nothing was restored.")
            }
        }
        for e in zip.entries where e.name.hasPrefix(settingsFolder + "/") {
            let name = String(e.name.dropFirst(settingsFolder.count + 1))
            let isConfig = name.hasPrefix("GameConfigs/") && isGameConfigName(String(name.dropFirst("GameConfigs/".count)))
            guard name == libraryFile || name == presetsFile || name == MadeiraConfig.fileName || isConfig else { continue }
            guard e.size <= settingsFileLimit else {
                throw LibraryError.message("The backup's \(name) is too large, so nothing was restored.")
            }
            let data = try zip.extract(e)
            if name == libraryFile {
                do { library = try LibraryModel.decodeLibrary(data) } catch {
                    throw LibraryError.message("The backup's library cannot be read, so nothing was restored.")
                }
            } else if name == presetsFile {
                do { _ = try ControlPresetStore.decoded(data) } catch {
                    throw LibraryError.message("The backup's control layouts cannot be read, so nothing was restored.")
                }
                presets = true
                writes.append((LibraryModel.documents.appendingPathComponent(presetsFile), data))
            } else if name == MadeiraConfig.fileName {
                try text(data, name)
                writes.append((LibraryModel.documents.appendingPathComponent(name), data))
            } else if let configs = GameProfile.directory {
                try text(data, name)
                writes.append((configs.appendingPathComponent(String(name.dropFirst("GameConfigs/".count))), data))
            }
        }
        return (writes, library, presets)
    }

    /// Puts a backup's files back (overwriting). Only entries under users/, and with `settings`
    /// the files of "Include Madeira settings", which are checked first.
    static func restore(from url: URL, settings: Bool = false) throws -> RestoreResult {
        let drive = LibraryModel.drive
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let zip = try SaveZipReader(url: url)
        let fm = FileManager.default
        var held: (writes: [(URL, Data)], library: [LibraryEntry]?, presets: Bool) = ([], nil, false)
        if settings { held = try readSettings(zip) }
        var n = 0
        for e in zip.entries where !e.name.hasSuffix("/") {
            let parts = e.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0].lowercased() == "users",
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") || $0.contains("\0") }) else { continue }
            let dst = parts.reduce(drive) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.extract(e).write(to: dst, options: .atomic)
            n += 1
        }
        for (target, data) in held.writes { try data.write(to: target, options: .atomic) }
        let settingsFiles = held.writes.count + (held.library == nil ? 0 : 1)
        if n == 0 && settingsFiles == 0 { throw LibraryError.message("That zip holds no saves (nothing under users/).") }
        LogStore.shared.log("[saves] restored \(n) files and \(settingsFiles) settings files from \(url.lastPathComponent)")
        return RestoreResult(files: n, settingsFiles: settingsFiles, library: held.library, presets: held.presets)
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Settings › Saves.
struct SavesSection: View {
    @State private var busy = false
    @State private var message: String?
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var pendingRestore: URL?
    @AppStorage("madeira.backupIncludeSettings") private var includeSettings = false

    var body: some View {
        Section {
            Button {
                busy = true
                message = nil
                let settings = includeSettings
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Swift.Result { try SaveBackup.backup(includeSettings: settings) }
                    DispatchQueue.main.async {
                        busy = false
                        switch r {
                        case .success(let b):
                            message = "\(b.files) files, \(ByteCountFormatter.string(fromByteCount: Int64(b.bytes), countStyle: .file))"
                                + (b.leftOut > 0 ? "; \(b.leftOut) very large files left out" : "")
                            shareURL = b.url
                        case .failure(let e):
                            message = e.localizedDescription
                        }
                    }
                }
            } label: {
                HStack {
                    Label("Back up saves", systemImage: "externaldrive.badge.icloud")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy)
            Button { importing = true } label: {
                Label("Restore saves from a backup…", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(busy)
            Toggle("Include Madeira settings", isOn: $includeSettings)
            if includeSettings {
                Text("Backing up adds the library, madeira.cfg, control layouts and games' config files; restoring replaces them, but only from a backup whose library reads. Sign-ins stay in the Keychain and are never included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Saves")
        } footer: {
            Text("A backup is one zip of every Windows user's Documents, Saved Games and AppData (caches left out), "
                 + "to keep in Files or iCloud Drive. Restoring puts those files back and overwrites saves with "
                 + "the same names.")
        }
        // The zip is a copy made for sharing: removed once the share sheet closes.
        .sheet(item: Binding(get: { shareURL.map { SharedFile(url: $0) } }, set: {
            if $0 == nil {
                if let url = shareURL { try? FileManager.default.removeItem(at: url) }
                shareURL = nil
            }
        })) { f in
            ActivitySheet(items: [f.url])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { r in
            if case .success(let url) = r { pendingRestore = url }
        }
        .confirmationDialog("Restore saves from \(pendingRestore?.lastPathComponent ?? "the backup")?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                guard let url = pendingRestore else { return }
                pendingRestore = nil
                busy = true
                let settings = includeSettings
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Swift.Result { try SaveBackup.restore(from: url, settings: settings) }
                    DispatchQueue.main.async {
                        busy = false
                        switch r {
                        case .success(let result):
                            message = "\(result.files) files restored."
                            if let library = result.library { LibraryModel.shared.replaceEntries(library) }
                            if result.presets { ControlPresetsModel.shared.reloadFromDisk() }
                            if result.settingsFiles > 0 {
                                message = "\(result.files) files and \(result.settingsFiles) settings files restored. Close Madeira and open it again for all of them to apply."
                            }
                        case .failure(let e): message = e.localizedDescription
                        }
                    }
                }
            }
        } message: {
            if includeSettings {
                Text("Files with the same names in C:\\users are overwritten, and the backup's Madeira settings replace this device's. Restore only a backup of your own.")
            } else {
                Text("Files with the same names in C:\\users are overwritten.")
            }
        }
    }
}
