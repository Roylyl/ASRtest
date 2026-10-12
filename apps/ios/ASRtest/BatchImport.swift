import Foundation

struct BatchAudioFile: Identifiable, Sendable {
    let id: String
    let filename: String
    let localURL: URL?
    let importError: String?
}

struct BatchImportSelection: Sendable {
    let directory: URL
    let files: [BatchAudioFile]
}

enum BatchImport {
    static let maximumFiles = 100

    static func stage(_ urls: [URL]) throws -> BatchImportSelection {
        guard (1...maximumFiles).contains(urls.count) else {
            throw ASRError.message("每批请选择 1–\(maximumFiles) 个 WAV 文件。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASRtest-Batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ordered = urls.enumerated().sorted {
            let result = $0.element.lastPathComponent.localizedStandardCompare($1.element.lastPathComponent)
            return result == .orderedSame ? $0.offset < $1.offset : result == .orderedAscending
        }.map(\.element)
        let files = ordered.map { source -> BatchAudioFile in
            let id = UUID().uuidString
            let target = directory.appendingPathComponent(id).appendingPathExtension("wav")
            do {
                guard source.pathExtension.lowercased() == "wav" else { throw ASRError.message("仅支持 WAV 文件。") }
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var copyError: Error?
                coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                    do {
                        let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else {
                            throw ASRError.message("选择项不是普通文件。")
                        }
                        try FileManager.default.copyItem(at: readable, to: target)
                    } catch { copyError = error }
                }
                if let error = coordinationError ?? (copyError as NSError?) { throw error }
                return BatchAudioFile(id: id, filename: source.lastPathComponent, localURL: target, importError: nil)
            } catch {
                try? FileManager.default.removeItem(at: target)
                return BatchAudioFile(id: id, filename: source.lastPathComponent, localURL: nil, importError: error.localizedDescription)
            }
        }
        return BatchImportSelection(directory: directory, files: files)
    }

    static func remove(_ selection: BatchImportSelection?) {
        guard let selection,
              selection.directory.lastPathComponent.hasPrefix("ASRtest-Batch-"),
              selection.directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: selection.directory)
    }
}
