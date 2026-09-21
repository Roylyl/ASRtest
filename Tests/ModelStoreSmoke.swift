import Foundation
import UIKit
import CryptoKit

private enum CheckError: Error { case failed(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckError.failed(message) }
    print("PASS \(message)"); fflush(stdout)
}
private func mustThrow(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { print("PASS \(label)"); return }
    throw CheckError.failed("Expected error: \(label)")
}
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func fixture(_ id: ModelID, _ data: Data, path: String = "ggml-tiny.bin") -> ModelAsset {
    ModelAsset(id: id.rawValue, revision: "test", files: [.init(path: path, bytes: Int64(data.count), sha256: sha(data), url: "https://models.asrtest.invalid/\(path)")])
}
private func put(_ data: Data, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
private func runChecks() async throws {
    guard Bundle.main.bundleIdentifier == "com.roylyl.asrtest.model-store-smoke" else { throw CheckError.failed("Must run in isolated smoke-test app") }
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("bundle-store-smoke-\(UUID().uuidString)")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    let first = Data("tiny A".utf8)
    let a = fixture(.whisperTiny, first)
    let resources = work.appendingPathComponent("Resources", isDirectory: true)
    let root = resources.appendingPathComponent("ModelLibrary/whisperTiny", isDirectory: true)
    let file = root.appendingPathComponent("ggml-tiny.bin")
    try put(first, file)
    let store = ModelStore(manifest: AssetManifest(models: [a]), resourcesURL: resources)
    try? fm.removeItem(at: SessionStore.directory)
    try check(store.installedURL(.whisperTiny)?.standardizedFileURL == root.standardizedFileURL, "model resolves exclusively inside supplied Bundle ModelLibrary")
    try store.validate(.whisperTiny)
    try check(try Data(contentsOf: file) == first, "read-only validation leaves model unchanged")
    try check(store.installedURL(.whisperBase) == nil, "model absent from manifest is unavailable")
    try check(ModelStore(manifest: AssetManifest(models: [a]), resourcesURL: nil).installedURL(.whisperTiny) == nil, "missing Bundle resource URL is unavailable")
    try put(Data("wrong!".utf8), file)
    try mustThrow("same-size SHA tamper rejected") { try store.validate(.whisperTiny) }
    try put(Data("bad".utf8), file)
    try check(store.installedURL(.whisperTiny) == nil, "wrong-size bundled file is unavailable")
    try mustThrow("wrong-size bundled file fails validation") { try store.validate(.whisperTiny) }
    try fm.removeItem(at: file)
    try check(store.installedURL(.whisperTiny) == nil, "missing bundled file is unavailable")
    try mustThrow("missing bundled file fails validation") { try store.validate(.whisperTiny) }
    try put(first, file)
    try store.validate(.whisperTiny)

    // Decoys emulate data left by the earlier import/download app. They must
    // never make an incomplete new app bundle appear usable.
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/whisperTiny/ggml-tiny.bin")
    try put(first, support)
    defer { try? fm.removeItem(at: support.deletingLastPathComponent()) }
    let emptyResources = work.appendingPathComponent("EmptyResources", isDirectory: true)
    try put(first, emptyResources.appendingPathComponent("StarterModels/whisperTiny/ggml-tiny.bin"))
    let emptyStore = ModelStore(manifest: AssetManifest(models: [a]), resourcesURL: emptyResources)
    try check(emptyStore.installedURL(.whisperTiny) == nil, "Application Support and legacy StarterModels cannot mask missing Bundle ModelLibrary")
    try mustThrow("no fallback when bundled model is absent") { try emptyStore.validate(.whisperTiny) }

    let linkedResources = work.appendingPathComponent("LinkedResources")
    let linkedRoot = linkedResources.appendingPathComponent("ModelLibrary/whisperTiny")
    try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent("ggml-tiny.bin"), withDestinationURL: file)
    let linkedStore = ModelStore(manifest: AssetManifest(models: [a]), resourcesURL: linkedResources)
    try check(linkedStore.installedURL(.whisperTiny) == nil, "symbolic-link model file is unavailable")
    try mustThrow("symbolic-link model file rejected") { try linkedStore.validate(.whisperTiny) }
    let rootLinkResources = work.appendingPathComponent("RootLinkResources")
    try fm.createDirectory(at: rootLinkResources.appendingPathComponent("ModelLibrary"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: rootLinkResources.appendingPathComponent("ModelLibrary/whisperTiny"), withDestinationURL: root)
    try check(ModelStore(manifest: AssetManifest(models: [a]), resourcesURL: rootLinkResources).installedURL(.whisperTiny) == nil, "symbolic-link model directory is unavailable")
    let libraryLinkResources = work.appendingPathComponent("LibraryLinkResources")
    try fm.createDirectory(at: libraryLinkResources, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: libraryLinkResources.appendingPathComponent("ModelLibrary"), withDestinationURL: resources.appendingPathComponent("ModelLibrary"))
    try check(ModelStore(manifest: AssetManifest(models: [a]), resourcesURL: libraryLinkResources).installedURL(.whisperTiny) == nil, "symbolic-link ModelLibrary directory is unavailable")
    let nestedAsset = fixture(.voskEnglish, first, path: "am/final.mdl")
    let nestedResources = work.appendingPathComponent("NestedResources")
    let outside = work.appendingPathComponent("outside")
    try put(first, outside.appendingPathComponent("final.mdl"))
    let nestedRoot = nestedResources.appendingPathComponent("ModelLibrary/voskEnglish")
    try fm.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: nestedRoot.appendingPathComponent("am"), withDestinationURL: outside)
    let nestedStore = ModelStore(manifest: AssetManifest(models: [nestedAsset]), resourcesURL: nestedResources)
    try mustThrow("ancestor symbolic link rejected") { try nestedStore.validate(.voskEnglish) }
    for path in ["../outside", "/absolute", "am/../final.mdl", "am//final.mdl"] {
        let invalid = ModelAsset(id: "whisperTiny", revision: nil, files: [.init(path: path, bytes: 0, sha256: String(repeating:"0",count:64), url:nil)])
        try check(!store.complete(invalid, at: root), "invalid manifest path rejected: \(path)")
    }
    let duplicated = ModelAsset(id: a.id, revision: nil, files: [a.files[0], a.files[0]])
    try check(!store.complete(duplicated, at: root), "duplicate manifest paths rejected")

    // The script supplies physical model files copied from the final ASRtest
    // build product when BUNDLED_MODELS_ROOT is set. No App Support is used here.
    let bundledStore = ModelStore()
    try check(AssetManifest.current.models.count == 8 && AssetManifest.current.asset(.voskChinese)?.files.count == 14, "real eight-model manifest decodes provenance")
    let bundleModels = Bundle.main.resourceURL!.appendingPathComponent("ModelLibrary", isDirectory: true)
    var totalBytes: Int64 = 0
    for id in ModelID.allCases {
        guard let asset = AssetManifest.current.asset(id), let installed = bundledStore.installedURL(id) else { throw CheckError.failed("Missing bundled model: \(id.rawValue)") }
        try check(installed.standardizedFileURL == bundleModels.appendingPathComponent(id.rawValue).standardizedFileURL, "\(id.rawValue) resolves inside Bundle")
        try bundledStore.validate(id)
        totalBytes += asset.bytes
        print("PASS bundled SHA256 \(id.rawValue) files=\(asset.files.count) bytes=\(asset.bytes)"); fflush(stdout)
    }
    print("PASS all eight bundled models validated bytes=\(totalBytes)")
    var older = SessionRecord(modelID: .whisperTiny, modelName: "tiny", framework: "test", options: RecognitionOptions(), device: "simulator", input: "built-in", inputUID: "test", hardwareSampleRate: 48000, modelRevision: "test", modelFiles: [a.files[0]])
    older.startedAt = Date(timeIntervalSince1970: 100); older.text = "第一条"; older.state = "完成"
    var newer = older; newer.id = UUID().uuidString; newer.startedAt = Date(timeIntervalSince1970: 200); newer.text = "第二条"
    try SessionStore.save(older); try SessionStore.save(newer)
    try check(SessionStore.all().map(\.id) == [newer.id, older.id], "session save/load sorts newest first")
    older.text = "修改后"; try SessionStore.save(older)
    try check(SessionStore.all().count == 2 && SessionStore.all().last?.text == "修改后", "session atomic overwrite")
    try put(Data("{broken".utf8), SessionStore.directory.appendingPathComponent("broken.json"))
    let mismatch = SessionStore.directory.appendingPathComponent(UUID().uuidString+".json")
    try put(try JSONEncoder().encode(older), mismatch)
    try fm.createSymbolicLink(at: SessionStore.directory.appendingPathComponent(UUID().uuidString+".json"), withDestinationURL: SessionStore.url(older.id))
    try check(SessionStore.all().count == 2, "damaged JSON, mismatched IDs and symlinks ignored")
    var hostile = older; hostile.id = "../escaped"
    try mustThrow("session path traversal rejected on save") { try SessionStore.save(hostile) }
    try mustThrow("session path traversal rejected on delete") { try SessionStore.delete(hostile) }
    try check(SessionStore.url(hostile.id).deletingLastPathComponent() == SessionStore.directory, "nonthrowing session URL remains inside log folder")
    try put(Data("event".utf8), SessionStore.url(older.id, extension: "jsonl"))
    try SessionStore.delete(older)
    try check(SessionStore.all().map(\.id) == [newer.id] && !fm.fileExists(atPath: SessionStore.url(older.id, extension: "jsonl").path), "delete removes selected JSON and JSONL only")
    print("BUNDLED MODEL STORE AND SESSION STORE PASS")
}
@main
final class ModelStoreSmokeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Smoke", sessionRole: session.role)
        configuration.delegateClass = ModelStoreSmokeScene.self
        return configuration
    }
}
final class ModelStoreSmokeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
        Task.detached {
            do { try await runChecks(); fflush(stdout); exit(0) }
            catch { print("SMOKE FAIL: \(error)"); fflush(stdout); exit(1) }
        }
    }
}
