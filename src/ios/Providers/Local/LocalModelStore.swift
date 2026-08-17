//
//  LocalModelStore.swift
//  MinisApp
//
//  The lifecycle of on-device models: which are known, which are downloaded,
//  which one is loaded, and how much disk they cost.
//
//  Kept separate from LocalModelCatalog (pure, testable) and from
//  MLXLocalProvider (gated behind the package) so the settings UI, the provider
//  factory and the compatibility check can all talk to one place without any of
//  them depending on MLX being linked.
//
//  Downloads themselves are MLX's job — `LLMModelFactory.loadContainer` fetches
//  from Hugging Face into its own cache and reports progress. Reimplementing
//  that would mean reimplementing resumable multi-file transfers and the Hub's
//  cache layout, for no gain. This type owns everything *around* it: the known
//  set, the compatibility verdicts, disk accounting and eviction.
//

import Foundation

@MainActor
final class LocalModelStore: ObservableObject {

    static let shared = LocalModelStore()

    /// Seed catalog plus anything the user added.
    @Published private(set) var models: [LocalModelEntry] = []

    /// Compatibility verdicts, populated by `refreshCompatibility`.
    @Published private(set) var compatibility: [String: LocalModelCompatibility] = [:]

    /// Which model is downloaded, downloading, or resident.
    @Published private(set) var states: [String: State] = [:]

    /// Repo id of the model currently loaded in memory, if any.
    @Published private(set) var loadedRepoID: String?

    enum State: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case downloaded
        case loaded
        case failed(String)
    }

    private static let userModelsKey = "unifiedAgent.localModels.userAdded"
    private static let lastUsedKey = "unifiedAgent.localModels.lastUsed"

    private init() {
        models = LocalModelCatalog.seed + loadUserAdded()
        for model in models where isDownloaded(model.repoID) {
            states[model.repoID] = .downloaded
        }
    }

    // MARK: - Catalog

    private func loadUserAdded() -> [LocalModelEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.userModelsKey) else { return [] }
        do {
            return try JSONDecoder().decode([LocalModelEntry].self, from: data)
        } catch {
            AppLogger(category: "LocalModel").error(
                "Could not decode user-added models: \(error.localizedDescription)")
            return []
        }
    }

    private func saveUserAdded() {
        let userAdded = models.filter { !$0.isBuiltIn }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(userAdded), forKey: Self.userModelsKey)
        } catch {
            AppLogger(category: "LocalModel").error(
                "Could not persist user-added models: \(error.localizedDescription)")
        }
    }

    enum AddError: LocalizedError {
        case malformedRepoID
        case alreadyPresent(String)

        var errorDescription: String? {
            switch self {
            case .malformedRepoID:
                return "That doesn't look like a Hugging Face repo. Use owner/name, e.g. mlx-community/Qwen3.5-4B-4bit"
            case .alreadyPresent(let repo):
                return "\(repo) is already in the list."
            }
        }
    }

    /// Add a user-supplied Hugging Face repo.
    ///
    /// The compatibility check runs immediately and its verdict is what the UI
    /// shows — the whole point is that the user learns a repo is unusable
    /// before spending gigabytes on it, not after.
    @discardableResult
    func addModel(repoID raw: String) async throws -> LocalModelEntry {
        guard let repoID = LocalModelCatalog.normalizeRepoID(raw) else {
            throw AddError.malformedRepoID
        }
        guard !models.contains(where: { $0.repoID == repoID }) else {
            throw AddError.alreadyPresent(repoID)
        }
        var entry = LocalModelEntry(
            repoID: repoID,
            displayName: repoID.split(separator: "/").last.map(String.init) ?? repoID,
            isBuiltIn: false
        )
        let probe = await HuggingFaceProbe.probe(repoID: repoID)
        entry.downloadBytes = probe.files?.totalBytes
        entry.quantizationBits = probe.config?.quantization?.bits
        models.append(entry)
        saveUserAdded()
        compatibility[repoID] = evaluate(probe)
        return entry
    }

    func removeModel(repoID: String) {
        guard let model = models.first(where: { $0.repoID == repoID }), !model.isBuiltIn else { return }
        models.removeAll { $0.repoID == repoID }
        compatibility.removeValue(forKey: repoID)
        states.removeValue(forKey: repoID)
        saveUserAdded()
    }

    // MARK: - Compatibility

    /// Re-check every model against this device.
    ///
    /// Runs on demand rather than at launch: it is N network round trips, and
    /// a user who never opens the local-models screen should never pay them.
    func refreshCompatibility() async {
        for model in models {
            let probe = await HuggingFaceProbe.probe(repoID: model.repoID)
            compatibility[model.repoID] = evaluate(probe)
            if let index = models.firstIndex(where: { $0.repoID == model.repoID }),
               let bytes = probe.files?.totalBytes {
                models[index].downloadBytes = bytes
            }
        }
    }

    private func evaluate(_ probe: HuggingFaceProbe.Result) -> LocalModelCompatibility {
        LocalModelCompatibilityChecker.check(
            config: probe.config,
            files: probe.files,
            memoryBudgetBytes: Self.deviceMemoryBudget
        )
    }

    /// This device's planning budget for one model.
    static var deviceMemoryBudget: Int64 {
        LocalModelMemoryBudget.estimatedBudget(
            physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory),
            hasIncreasedMemoryLimit: hasIncreasedMemoryLimitEntitlement
        )
    }

    /// Whether the build carries the increased-memory-limit entitlement.
    ///
    /// Read from the embedded provisioning profile rather than assumed: getting
    /// this wrong in the optimistic direction offers the user a 9B model that
    /// will be jetsammed mid-generation.
    static let hasIncreasedMemoryLimitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return false }
        return text.contains("com.apple.developer.kernel.increased-memory-limit")
    }()

    func isUsable(_ repoID: String) -> Bool {
        compatibility[repoID]?.isSupported ?? false
    }

    // MARK: - Disk

    /// Where MLX's Hub downloader puts models.
    ///
    /// Documents/huggingface is the layout swift-transformers' Hub API uses.
    /// Only read here — for disk accounting and eviction — never written, so a
    /// layout change upstream degrades to "0 bytes reported" rather than to a
    /// corrupted cache.
    static var cacheRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models", isDirectory: true)
    }

    static func cacheDirectory(for repoID: String) -> URL {
        repoID.split(separator: "/").reduce(cacheRoot) { $0.appendingPathComponent(String($1)) }
    }

    func isDownloaded(_ repoID: String) -> Bool {
        let dir = Self.cacheDirectory(for: repoID)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        // A directory with a config but no weights is an interrupted download,
        // not a usable model.
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    func diskBytes(_ repoID: String) -> Int64 {
        Self.directorySize(Self.cacheDirectory(for: repoID))
    }

    var totalDiskBytes: Int64 {
        models.reduce(0) { $0 + diskBytes($1.repoID) }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Delete a downloaded model's files.
    ///
    /// Refuses while the model is loaded — deleting weights out from under a
    /// live inference session is a crash, not an error message.
    func deleteDownload(repoID: String) throws {
        guard loadedRepoID != repoID else {
            throw NSError(domain: "LocalModelStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unload the model before deleting it.",
            ])
        }
        try FileManager.default.removeItem(at: Self.cacheDirectory(for: repoID))
        states[repoID] = .notDownloaded
    }

    // MARK: - Load lifecycle

    func setState(_ state: State, repoID: String) {
        states[repoID] = state
        if case .loaded = state {
            // Only one model is resident at a time; reflect that in the UI so a
            // stale "loaded" badge can't imply two models are in memory.
            for (key, value) in states where key != repoID && value == .loaded {
                states[key] = .downloaded
            }
            loadedRepoID = repoID
            UserDefaults.standard.set(repoID, forKey: Self.lastUsedKey)
        } else if loadedRepoID == repoID {
            loadedRepoID = nil
        }
    }

    /// The model to offer by default: the last one used, if it is still usable.
    var preferredRepoID: String? {
        if let last = UserDefaults.standard.string(forKey: Self.lastUsedKey),
           models.contains(where: { $0.repoID == last }), isDownloaded(last) {
            return last
        }
        return models.first { isDownloaded($0.repoID) }?.repoID
    }

    func entry(repoID: String) -> LocalModelEntry? {
        models.first { $0.repoID == repoID }
    }
}

// MARK: - Hugging Face probe

/// Reads a repo's `config.json` and file listing.
///
/// Deliberately unauthenticated and read-only. It touches two public endpoints
/// and a few kilobytes, which is the entire cost of not downloading a
/// multi-gigabyte model that was never going to work.
enum HuggingFaceProbe {

    struct Result: Sendable {
        let config: HFModelConfig?
        let files: HFRepoFiles?
        let error: String?
    }

    private static let apiBase = "https://huggingface.co"

    static func probe(repoID: String, session: URLSession = .shared) async -> Result {
        async let config = fetchConfig(repoID: repoID, session: session)
        async let files = fetchFiles(repoID: repoID, session: session)
        let (c, f) = await (config, files)
        return Result(config: c, files: f,
                      error: (c == nil && f == nil) ? "couldn't reach huggingface.co" : nil)
    }

    private static func fetchConfig(repoID: String, session: URLSession) async -> HFModelConfig? {
        guard let url = URL(string: "\(apiBase)/\(repoID)/raw/main/config.json") else { return nil }
        guard let data = try? await session.data(from: url).0 else { return nil }
        return try? HFModelConfig.decode(data)
    }

    private static func fetchFiles(repoID: String, session: URLSession) async -> HFRepoFiles? {
        guard let url = URL(string: "\(apiBase)/api/models/\(repoID)?blobs=true") else { return nil }
        guard let data = try? await session.data(from: url).0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = root["siblings"] as? [[String: Any]] else { return nil }
        let names = siblings.compactMap { $0["rfilename"] as? String }
        let total = siblings.reduce(Int64(0)) { $0 + Int64(($1["size"] as? Int) ?? 0) }
        return HFRepoFiles(filenames: names, totalBytes: total > 0 ? total : nil)
    }
}
