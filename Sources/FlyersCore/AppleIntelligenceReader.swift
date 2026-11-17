import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads flyers with Apple Intelligence, with nothing to set up and nothing to pay: Apple's larger
/// model on Private Cloud Compute when the app may use it, otherwise the model on this device. Both
/// take images. Needs macOS 27 or iOS 27 on a device that supports Apple Intelligence, with it on.
///
/// It asks the same questions as the Claude reader and fills in the same answer, so everything
/// after reading works the same whichever reads the flyer.
public struct AppleIntelligenceReader: EventExtracting {
    /// Which model reads. `.automatic` tries Private Cloud Compute and falls back to this device.
    public enum Model: Sendable { case automatic, cloud, onDevice }
    public var model: Model

    public init(model: Model = .automatic) { self.model = model }

    public var needsAPIKey: Bool { false }

    /// Whether Apple Intelligence can read flyers on this device right now, and if not, why.
    public static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("This device doesn't support Apple Intelligence.")
            case .unavailable:
                return .unavailable("Turn on Apple Intelligence in System Settings, or wait for it to finish setting up.")
            }
        }
        #endif
        return .unavailable("Apple Intelligence needs macOS 27 or iOS 27.")
    }

    public enum Status: Equatable, Sendable {
        case available
        case unavailable(String)

        public var isAvailable: Bool { self == .available }
    }

    public func extract(jpegs: [Data], context: PhotoContext, apiKey: String) async throws -> (ExtractionResult, TokenUsage) {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            return try await read(jpegs: jpegs, context: context)
        }
        #endif
        throw ExtractionError.permanent("Apple Intelligence needs macOS 27 or iOS 27.")
    }

    #if canImport(FoundationModels)
    @available(macOS 27.0, iOS 27.0, *)
    private func read(jpegs: [Data], context: PhotoContext) async throws -> (ExtractionResult, TokenUsage) {
        let images = jpegs.compactMap { ImageTools.decode($0) }
        guard images.count == jpegs.count else { throw ExtractionError.permanent("Couldn't open the photo") }

        // Several photos are labeled so the instructions and the model can refer to them by number.
        var parts: [Prompt] = []
        for (index, image) in images.enumerated() {
            if images.count > 1 { parts.append(Prompt("Photo \(index + 1):")) }
            parts.append(Prompt(Attachment(image)))
        }
        parts.append(Prompt(context.promptText))

        let schema: GenerationSchema
        do {
            schema = try GenerationSchema(root: Self.dynamicSchema(ExtractionPrompt.schema, name: "Answer"), dependencies: [])
        } catch {
            throw ExtractionError.permanent("Couldn't describe the answer to Apple Intelligence: \(error)")
        }

        let prompt = Prompt { parts }
        let json: String
        do {
            switch model {
            case .onDevice:
                json = try await Self.respond(SystemLanguageModel.default, prompt: prompt, schema: schema)
            case .cloud:
                json = try await Self.respond(PrivateCloudComputeLanguageModel(), prompt: prompt, schema: schema)
            case .automatic:
                do {
                    json = try await Self.respond(PrivateCloudComputeLanguageModel(), prompt: prompt, schema: schema)
                } catch let error as PrivateCloudComputeLanguageModel.Error {
                    // The limit, the network: Private Cloud Compute is allowed but can't now.
                    throw error
                } catch {
                    // Not allowed to use Private Cloud Compute, or it's not ready: read on this device.
                    json = try await Self.respond(SystemLanguageModel.default, prompt: prompt, schema: schema)
                }
            }
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached:
                // Stops the scan, like running out of credit, so the rest wait for the quota to reset.
                throw ExtractionError.outOfCredit("Apple Intelligence has read as many flyers as it allows for now. Scanning picks up again later.")
            case .networkFailure, .serviceUnavailable:
                throw ExtractionError.temporary(error.localizedDescription)
            @unknown default:
                throw ExtractionError.temporary(error.localizedDescription)
            }
        } catch {
            // Refusals and answers that don't fit won't go better on a retry.
            throw ExtractionError.permanent(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8), let result = try? decoder.decode(ExtractionResult.self, from: data) else {
            throw ExtractionError.permanent("Apple Intelligence's answer couldn't be read")
        }
        // Free to you, so nothing counts toward the monthly spending limit.
        return (result, TokenUsage(input: 0, output: 0))
    }

    @available(macOS 27.0, iOS 27.0, *)
    private static func respond(_ model: some LanguageModel, prompt: Prompt, schema: GenerationSchema) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: ExtractionPrompt.system)
        return try await session.respond(to: prompt, schema: schema).content.jsonString
    }

    /// Turns the JSON schema the Claude reader uses into Apple's form, so both fill in the same
    /// answer. Fields that may be null become optional.
    @available(macOS 27.0, iOS 27.0, *)
    static func dynamicSchema(_ json: [String: Any], name: String) -> DynamicGenerationSchema {
        let type = json["type"]
        if let choices = json["enum"] as? [String] {
            return DynamicGenerationSchema(name: name, anyOf: choices)
        }
        switch type as? String {
        case "object":
            let properties = json["properties"] as? [String: Any] ?? [:]
            let required = Set(json["required"] as? [String] ?? [])
            return DynamicGenerationSchema(
                name: name,
                properties: properties.keys.sorted().map { key in
                    let property = properties[key] as? [String: Any] ?? [:]
                    let nullable = (property["type"] as? [String])?.contains("null") ?? false
                    return DynamicGenerationSchema.Property(
                        name: key,
                        schema: dynamicSchema(property, name: "\(name)_\(key)"),
                        isOptional: nullable || !required.contains(key)
                    )
                }
            )
        case "array":
            return DynamicGenerationSchema(arrayOf: dynamicSchema(json["items"] as? [String: Any] ?? [:], name: "\(name)_item"))
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        default:
            // "string", and ["string", "null"], whose null is handled by making it optional.
            return DynamicGenerationSchema(type: String.self)
        }
    }
    #endif
}
