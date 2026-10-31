// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import ModSupport

let fixtureVersion = "2.4.3-macgacha.1"
let fixtureRuntime = "d3dmetal-wine11.20-gptk4.0b3"
let zeroDigest = String(repeating: "0", count: 64)

func makeTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ModSupportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func removeTestRoot(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

func sha256(_ data: Data) -> String {
    var hasher = StreamingHasher(.sha256)
    hasher.update(data)
    return hasher.finalize().hex
}

func writeFile(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try data.write(to: url)
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String], from directory: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func makeZip(source: URL, archive: URL, extraArguments: [String] = [], storeSymlinks: Bool = false) throws {
    try? FileManager.default.removeItem(at: archive)
    var arguments = ["-X", "-q"]
    if storeSymlinks { arguments.append("-y") }
    arguments.append(contentsOf: ["-r", archive.path, "."])
    arguments.append(contentsOf: extraArguments)
    let status = try runProcess("/usr/bin/zip", arguments, from: source)
    guard status == 0 else { throw LauncherError.io("fixture zip failed") }
}

struct PackageFixture {
    let root: URL
    let version: String
    let archive: URL
    let files: [String: Data]

    init(root: URL, version: String = fixtureVersion, overrides: [String: Data] = [:]) throws {
        self.root = root
        self.version = version
        let source = root.appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        var contents: [String: Data] = [
            "hook-runner.exe": Data("runner".utf8),
            "3dmloader.dll": Data("injector".utf8),
            "payload/d3d11.dll": Data("payload".utf8),
            "payload/Core/SRMI/main.ini": Data("[Core]\nload = 1\n".utf8),
            "payload/d3dx.ini": Data(("; fixture\r\n[Loader]\r\ntarget = Other.exe\r\nloader = old.exe\r\n"
                + "module = d3d11.dll\r\n\r\n[System]\r\nproxy_d3d11 = Z:\\old\\d3d11.dll\r\n\r\n"
                + "[Include]\r\ninclude_recursive = Mods\r\n").utf8),
        ]
        for (path, data) in overrides { contents[path] = data }
        files = contents
        for (path, data) in contents {
            try writeFile(data, to: source.appendingPathComponent(path))
        }
        archive = root.appendingPathComponent("package-\(UUID().uuidString).zip")
        try makeZip(source: source, archive: archive)
    }

    func manifest(declaredPaths: [String]? = nil, extraFiles: [ModPackageFile] = [],
        archiveSHA256: String? = nil, fileSHA256: [String: String] = [:]) throws -> ModPackageManifest {
        let archiveData = try Data(contentsOf: archive)
        let paths = declaredPaths ?? files.keys.sorted()
        var entries: [ModPackageFile] = []
        for path in paths {
            if let data = files[path] {
                entries.append(ModPackageFile(path: path, size: Int64(data.count),
                    sha256: fileSHA256[path] ?? sha256(data)))
            } else if let extra = extraFiles.first(where: { $0.path == path }) {
                entries.append(extra)
            } else {
                entries.append(ModPackageFile(path: path, size: 0, sha256: zeroDigest))
            }
        }
        entries.append(contentsOf: extraFiles.filter { !paths.contains($0.path) })
        return ModPackageManifest(id: "srmi", version: version, gameID: "starrail",
            supportedRuntimeBundleIDs: [fixtureRuntime], runnerPath: "hook-runner.exe",
            injectorPath: "3dmloader.dll", payloadPath: "payload/d3d11.dll",
            archiveSize: Int64(archiveData.count), archiveSHA256: archiveSHA256 ?? sha256(archiveData),
            files: entries, sources: ["srmi": "2.4.3", "xxmi": "1.2.2"], license: "GPL-3.0-only")
    }
}

func makeModFolder(root: URL, name: String, extra: [String: Data] = [:]) throws -> URL {
    let folder = root.appendingPathComponent("mods-\(UUID().uuidString)").appendingPathComponent(name)
    var files = ["mod.ini": Data("[TextureOverride]\nhash = fixture\n".utf8),
        "textures/body.dds": Data("DDS fixture".utf8)]
    for (path, data) in extra { files[path] = data }
    for (path, data) in files { try writeFile(data, to: folder.appendingPathComponent(path)) }
    return folder
}

func makeBackend(root: URL) throws -> URL {
    let url = root.appendingPathComponent("runtime/lib/wine/x86_64-windows/d3d11.dll")
    try writeFile(Data("backend".utf8), to: url)
    return url
}

func appPaths(_ root: URL) -> AppPaths {
    AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
}
