// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

struct ModelStore: Sendable {
    let manifest: AssetManifest
    private let resourcesURL: URL?
    init(manifest: AssetManifest = .current, resourcesURL: URL? = Bundle.main.resourceURL) {
        self.manifest = manifest
        self.resourcesURL = resourcesURL
    }
    func installedURL(_ id: ModelID) -> URL? {
        guard let asset = manifest.asset(id), let resourcesURL else { return nil }
        let library = resourcesURL.appendingPathComponent("ModelLibrary", isDirectory: true)
        guard ordinaryDirectory(library) else { return nil }
        let root = library.appendingPathComponent(id.rawValue, isDirectory: true)
        return complete(asset, at: root) ? root : nil
    }
    // Fast availability probe only. A recognizer must call validate before loading.
    func complete(_ asset: ModelAsset, at root: URL) -> Bool {
        guard validManifest(asset), ordinaryDirectory(root) else { return false }
        return asset.files.allSatisfy { file in
            guard ordinaryFile(file.path, under: root),
                  let size = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file.path).path)[.size] as? NSNumber else { return false }
            return size.int64Value == file.bytes
        }
    }
    private func safe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }
    }
    private func validManifest(_ asset: ModelAsset) -> Bool {
        guard ModelID(rawValue: asset.id) != nil, !asset.files.isEmpty,
              Set(asset.files.map(\.path)).count == asset.files.count else { return false }
        return asset.files.allSatisfy { file in
            safe(file.path) && file.bytes >= 0 && file.sha256.utf8.count == 64 &&
            file.sha256.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        }
    }
    private func ordinaryDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return v.isDirectory == true && v.isSymbolicLink != true
    }
    private func ordinaryFile(_ path: String, under root: URL) -> Bool {
        guard safe(path), ordinaryDirectory(root) else { return false }
        let parts = path.split(separator: "/"); var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            guard let v = try? current.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]), v.isSymbolicLink != true else { return false }
            if index == parts.count - 1 { return v.isRegularFile == true }
            if v.isDirectory != true { return false }
        }
        return false
    }
    func validate(_ id: ModelID) throws {
        guard let asset = manifest.asset(id), let root = installedURL(id) else { throw ASRError.message("内置模型文件不完整，请重新编译并安装完整 App。") }
        try validate(asset, at: root)
    }
    func validate(_ asset: ModelAsset, at root: URL) throws {
        guard complete(asset, at: root) else { throw ASRError.message("\(asset.id)：模型文件缺失、大小不符或不是普通文件。") }
        for file in asset.files {
            guard try digest(root.appendingPathComponent(file.path)) == file.sha256.lowercased() else { throw ASRError.message("模型校验失败：\(file.path)") }
        }
    }
    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
