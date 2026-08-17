//
//  LocalModelCatalog.swift
//  MinisApp
//
//  Which local models exist, and whether this build can actually run them.
//
//  THE RULE THIS FILE ENFORCES
//
//  A model is never offered unless we can show it will load. That is not a
//  slogan — it is a hard problem, because:
//
//    * MLX only runs models whose `model_type` is in its architecture registry.
//      A brand-new Qwen or Gemma release appears on Hugging Face weeks before
//      MLX gains support, and downloading 6GB to discover that is a genuinely
//      bad experience on a metered connection.
//    * A GGUF file downloaded by some other app is not usable here. MLX reads
//      safetensors in its own quantization layout. The two look
//      interchangeable in a file browser and are not.
//    * An iPad has a hard per-process memory limit well below its RAM. A 9B
//      4-bit model is ~6GB of weights; whether it loads depends on the device,
//      not on the model.
//
//  So the catalog is data, not code: a shipped seed list the user can extend
//  with any Hugging Face repo, and every entry — shipped or user-added — is
//  checked against the repo's real `config.json` before it is offered. The
//  check is a few kilobytes and answers all three questions above.
//
//  Pure Foundation. The compatibility logic is unit-tested against recorded
//  `config.json` payloads from the real repos.
//

import Foundation

// MARK: - Architecture support

/// Architectures MLXLLM can instantiate.
///
/// This mirrors `LLMTypeRegistry.shared` in the mlx-swift-lm package. It is a
/// duplicate, which is a cost — but the alternative is asking the model factory
/// at runtime, which means the check can only happen after the download. A
/// stale entry here fails safe: an architecture we don't list is reported as
/// "not supported by this build", which is recoverable by updating the list,
/// whereas listing one MLX can't build wastes a multi-gigabyte download.
///
/// Verified against ml-explore/mlx-swift-lm @ d7dc03d (2026-08-15).
enum MLXArchitectureSupport {

    /// `model_type` values with a registered model class.
    static let supported: Set<String> = [
        // Qwen
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen3_5_text",
        // Gemma
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "gemma4", "gemma4_unified", "gemma4_text",
        // Llama family
        "llama", "mistral", "mixtral", "mistral3",
        // Phi
        "phi", "phi3", "phimoe",
        // Others MLXLLM registers
        "glm4", "glm4_moe", "glm4_moe_lite", "smollm3", "granite",
        "deepseek_v2", "deepseek_v3", "internlm2", "cohere", "starcoder2",
        "openelm", "minicpm", "olmo2", "olmo3", "olmoe", "gpt_oss",
        "exaone4", "ernie4_5", "lfm2", "lfm2_moe", "nemotron_h", "mimo",
        "bitnet", "falcon_h1", "minimax", "nanochat", "apertus",
    ]

    static func isSupported(modelType: String?) -> Bool {
        guard let modelType else { return false }
        return supported.contains(modelType.lowercased())
    }
}

// MARK: - Compatibility

/// The verdict for one candidate model.
enum LocalModelCompatibility: Equatable, Sendable {
    /// Loadable on this build and this device.
    case supported
    /// MLX has no model class for this `model_type`.
    case unsupportedArchitecture(String)
    /// The repo has no MLX-format weights (e.g. it is a GGUF-only repo).
    case notMLXFormat(reason: String)
    /// Loadable in principle but too large for this device's memory budget.
    case tooLargeForDevice(requiredGB: Double, budgetGB: Double)
    /// The repo couldn't be inspected (offline, private, deleted).
    case unknown(reason: String)

    var isSupported: Bool { self == .supported }

    /// Sentence shown next to the model in the picker. Written to tell the user
    /// what to do, not just what went wrong.
    var explanation: String {
        switch self {
        case .supported:
            return "Ready to download."
        case .unsupportedArchitecture(let type):
            return "This build's inference engine has no implementation for the '\(type)' architecture. It will become available when the MLX package adds it."
        case .notMLXFormat(let reason):
            return "Not an MLX model: \(reason). MLX needs safetensors weights in its own quantization layout — a GGUF file from another app can't be reused."
        case .tooLargeForDevice(let required, let budget):
            return String(
                format: "Needs about %.1f GB of memory; this device's budget for one app is about %.1f GB. Try a smaller model or a lower quantization.",
                required, budget
            )
        case .unknown(let reason):
            return "Couldn't check this model: \(reason)"
        }
    }
}

// MARK: - Repository metadata

/// The subset of a Hugging Face `config.json` that decides compatibility.
struct HFModelConfig: Decodable, Sendable, Equatable {
    let modelType: String?
    let quantization: Quantization?
    let hiddenSize: Int?
    let numHiddenLayers: Int?
    let maxPositionEmbeddings: Int?

    struct Quantization: Decodable, Sendable, Equatable {
        let bits: Int?
        let groupSize: Int?

        private enum CodingKeys: String, CodingKey {
            case bits
            case groupSize = "group_size"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case quantization
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case maxPositionEmbeddings = "max_position_embeddings"
    }

    static func decode(_ data: Data) throws -> HFModelConfig {
        try JSONDecoder().decode(HFModelConfig.self, from: data)
    }
}

/// What the repo's file listing tells us about format.
struct HFRepoFiles: Sendable, Equatable {
    let filenames: [String]
    /// Total download size in bytes, when the API reported it.
    let totalBytes: Int64?

    var hasSafetensors: Bool { filenames.contains { $0.hasSuffix(".safetensors") } }
    var hasGGUF: Bool { filenames.contains { $0.lowercased().hasSuffix(".gguf") } }
    var hasTokenizer: Bool {
        filenames.contains { $0 == "tokenizer.json" || $0 == "tokenizer.model" || $0 == "tokenizer_config.json" }
    }
    var hasConfig: Bool { filenames.contains("config.json") }
}

// MARK: - Compatibility check

enum LocalModelCompatibilityChecker {

    /// Decide whether a repo can be loaded, given its config, file list, and
    /// this device's memory budget.
    ///
    /// Order matters. Format is checked before architecture because a GGUF-only
    /// repo has no meaningful `model_type` for us, and size is checked last
    /// because it's the only verdict the user can act on by picking a different
    /// quantization of the same model.
    static func check(
        config: HFModelConfig?,
        files: HFRepoFiles?,
        memoryBudgetBytes: Int64
    ) -> LocalModelCompatibility {
        if let files {
            if !files.hasSafetensors {
                if files.hasGGUF {
                    return .notMLXFormat(reason: "this repo ships GGUF weights only")
                }
                return .notMLXFormat(reason: "no .safetensors weights in the repo")
            }
            if !files.hasTokenizer {
                return .notMLXFormat(reason: "the repo has no tokenizer files")
            }
        }

        guard let config else {
            return .unknown(reason: "the repo has no readable config.json")
        }
        guard MLXArchitectureSupport.isSupported(modelType: config.modelType) else {
            return .unsupportedArchitecture(config.modelType ?? "unknown")
        }

        if let totalBytes = files?.totalBytes, totalBytes > 0 {
            let required = estimatedPeakBytes(weightBytes: totalBytes)
            if required > memoryBudgetBytes {
                return .tooLargeForDevice(
                    requiredGB: Double(required) / 1e9,
                    budgetGB: Double(memoryBudgetBytes) / 1e9
                )
            }
        }
        return .supported
    }

    /// Peak resident bytes for a model whose repo downloads to `weightBytes`.
    ///
    /// Weights dominate, but they are not the whole story: the KV cache grows
    /// with context, activations need scratch, and the tokenizer and graph hold
    /// their own. Measured MLX behaviour puts the overhead well under half the
    /// weight size for the context lengths an iPad agent uses, so 1.35x plus a
    /// flat 400MB is a deliberately conservative estimate — being wrong in the
    /// optimistic direction means an OOM kill mid-generation, which loses the
    /// user's turn, while being wrong pessimistically only hides a model that
    /// would have been marginal anyway.
    ///
    /// This is an estimate and is labelled as one everywhere it surfaces. The
    /// real numbers come from the on-device benchmark harness.
    static func estimatedPeakBytes(weightBytes: Int64) -> Int64 {
        Int64(Double(weightBytes) * 1.35) + 400_000_000
    }
}

// MARK: - Catalog entry

/// One model the user can download and run locally.
struct LocalModelEntry: Codable, Hashable, Sendable, Identifiable {
    /// Hugging Face repo id, e.g. `mlx-community/Qwen3.5-4B-4bit`. Also the
    /// stable identity — one repo is one entry.
    let repoID: String
    var displayName: String
    /// Parameter count in billions, for the picker's size hint.
    var parameterBillions: Double?
    /// Quantization bits, when known from the repo name or config.
    var quantizationBits: Int?
    /// Download size in bytes, when known. Filled in by the repo probe.
    var downloadBytes: Int64?
    /// Context window to advertise. MLX itself will honour whatever the model
    /// declares; this is what the app's context accounting uses.
    var contextWindow: Int
    /// True for entries shipped with the app, false for user-added repos.
    var isBuiltIn: Bool
    /// One-line role hint shown in the picker.
    var note: String?

    var id: String { repoID }

    init(
        repoID: String,
        displayName: String,
        parameterBillions: Double? = nil,
        quantizationBits: Int? = nil,
        downloadBytes: Int64? = nil,
        contextWindow: Int = 32_768,
        isBuiltIn: Bool = false,
        note: String? = nil
    ) {
        self.repoID = repoID
        self.displayName = displayName
        self.parameterBillions = parameterBillions
        self.quantizationBits = quantizationBits
        self.downloadBytes = downloadBytes
        self.contextWindow = contextWindow
        self.isBuiltIn = isBuiltIn
        self.note = note
    }

    /// Human size, e.g. "3.1 GB". nil when the size isn't known yet.
    var downloadSizeText: String? {
        guard let downloadBytes, downloadBytes > 0 else { return nil }
        return String(format: "%.1f GB", Double(downloadBytes) / 1e9)
    }

    /// Model id used inside the app's provider/entry machinery. Prefixed so it
    /// can never collide with a remote provider's model id.
    var appModelID: String { "local/\(repoID)" }
}

// MARK: - Seed catalog

enum LocalModelCatalog {

    /// The models shipped as suggestions.
    ///
    /// Repo ids, `model_type`s and download sizes below were verified against
    /// the Hugging Face API and against MLXLLM's architecture registry on
    /// 2026-08-17. They are still only *candidates*: an entry appears in the
    /// picker with its real size and its live compatibility verdict, and the
    /// app refuses to load anything the verdict rejects. Nothing here is
    /// presented as "known working on an M4 iPad" — that claim needs the
    /// device, and the benchmark harness exists to produce it.
    static let seed: [LocalModelEntry] = [
        LocalModelEntry(
            repoID: "mlx-community/Qwen3.5-4B-4bit",
            displayName: "Qwen 3.5 4B (4-bit)",
            parameterBillions: 4, quantizationBits: 4,
            downloadBytes: 3_061_130_647,
            contextWindow: 32_768, isBuiltIn: true,
            note: "Default local agent — fastest of the three."
        ),
        LocalModelEntry(
            repoID: "mlx-community/Qwen3.5-9B-4bit",
            displayName: "Qwen 3.5 9B (4-bit)",
            parameterBillions: 9, quantizationBits: 4,
            downloadBytes: 5_977_073_303,
            contextWindow: 32_768, isBuiltIn: true,
            note: "Higher quality; needs the most memory."
        ),
        LocalModelEntry(
            repoID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B (4-bit)",
            parameterBillions: 2, quantizationBits: 4,
            downloadBytes: 3_583_088_661,
            contextWindow: 32_768, isBuiltIn: true,
            note: "Lightweight option."
        ),
        LocalModelEntry(
            repoID: "mlx-community/Qwen3.5-2B-4bit",
            displayName: "Qwen 3.5 2B (4-bit)",
            parameterBillions: 2, quantizationBits: 4,
            downloadBytes: 1_749_081_927,
            contextWindow: 32_768, isBuiltIn: true,
            note: "Smallest — for quick classification and title generation."
        ),
    ]

    /// Validate a user-entered repo id before spending a network request.
    /// Hugging Face ids are `owner/name`.
    static func normalizeRepoID(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a pasted URL as well as a bare id — that is what people
        // actually have on the clipboard.
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] {
            if s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        while s.hasSuffix("/") { s.removeLast() }
        // Strip a /tree/main or /blob/... suffix from a copied browser URL.
        for marker in ["/tree/", "/blob/", "/resolve/"] {
            if let r = s.range(of: marker) { s = String(s[s.startIndex..<r.lowerBound]) }
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "/" }) else { return nil }
        return s
    }
}

// MARK: - Device memory budget

enum LocalModelMemoryBudget {

    /// How much of the device's RAM one app may realistically hold.
    ///
    /// iOS kills an app that exceeds a per-process limit that is well below
    /// total RAM and is not published. The widely-observed shape is roughly
    /// half of physical RAM for a normal app, more with the
    /// `com.apple.developer.kernel.increased-memory-limit` entitlement. 55% is
    /// used here as a conservative planning number.
    ///
    /// This decides only whether a model is *offered*. The runtime also sets an
    /// MLX cache limit and handles memory-pressure notifications, because a
    /// budget computed up front cannot account for what else the user is doing.
    static func estimatedBudget(physicalMemory: Int64, hasIncreasedMemoryLimit: Bool = false) -> Int64 {
        let fraction = hasIncreasedMemoryLimit ? 0.72 : 0.55
        return Int64(Double(physicalMemory) * fraction)
    }
}
