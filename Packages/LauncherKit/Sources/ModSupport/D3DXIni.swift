// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// The per-session payload points its D3D11 proxy at the runtime MacGacha
/// selected and keeps loading mods from the session payload.
struct D3DXIni {
    private var lines: [String]
    private let newline: String

    init(_ contents: String?) {
        if let contents, !contents.isEmpty {
            newline = contents.contains("\r\n") ? "\r\n" : "\n"
            var parsed = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if parsed.last == "" { parsed.removeLast() }
            lines = parsed.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        } else {
            newline = "\n"
            lines = ["[Loader]", "", "[System]", "", "[Include]"]
        }
    }

    mutating func set(section: String, key: String, value: String) throws {
        let range = try sectionRange(section)
        var found: Int?
        var index = range.lowerBound + 1
        while index < range.upperBound {
            guard let parsed = Self.keyValue(lines[index]) else { index += 1; continue }
            if parsed.key.caseInsensitiveCompare(key) == .orderedSame {
                guard found == nil else { throw LauncherError.io("d3dx.ini has duplicate \(key) settings") }
                found = index
            }
            index += 1
        }
        let line = "\(key) = \(value)"
        if let found { lines[found] = line }
        else { lines.insert(line, at: range.lowerBound + 1) }
    }

    mutating func addIfMissing(section: String, key: String, value: String) throws {
        let range = try sectionRange(section)
        var index = range.lowerBound + 1
        while index < range.upperBound {
            if let parsed = Self.keyValue(lines[index]), parsed.key.caseInsensitiveCompare(key) == .orderedSame {
                return
            }
            index += 1
        }
        lines.insert("\(key) = \(value)", at: range.upperBound)
    }

    func rendered() -> String {
        lines.joined(separator: newline) + newline
    }

    private mutating func sectionRange(_ name: String) throws -> Range<Int> {
        var start: Int?
        var end = lines.count
        for index in lines.indices {
            guard let header = Self.sectionName(lines[index]) else { continue }
            if start == nil {
                if header.caseInsensitiveCompare(name) == .orderedSame { start = index }
            } else {
                end = index
                break
            }
        }
        guard let start else {
            lines.append("")
            lines.append("[\(name)]")
            return (lines.count - 1)..<lines.count
        }
        return start..<end
    }

    private static func sectionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"),
            let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}

enum ModBackendPath {
    static func windowsPath(for url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.isEmpty,
            !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw LauncherError.io("Invalid D3D11 backend path")
        }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw LauncherError.io("Invalid D3D11 backend path")
        }
        let fs = try ContainedFileSystem(root: parent)
        guard try fs.itemType(at: SafeRelativePath(name)) == .regularFile else {
            throw LauncherError.io("D3D11 backend is missing")
        }
        return "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }
}
