import AppKit
import FlyersCore
import UniformTypeIdentifiers

/// Reads images dropped on the window: files from Finder, and photos dragged out of Photos or a browser.
enum DropLoader {
    static let types: [UTType] = [.fileURL, .image]

    static func load(_ providers: [NSItemProvider]) async -> [DroppedPhoto] {
        var output: [DroppedPhoto] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let photo = await fromFile(provider) {
                output.append(photo)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), let photo = await fromImage(provider) {
                output.append(photo)
            }
        }
        return output
    }

    private static func fromFile(_ provider: NSItemProvider) async -> DroppedPhoto? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                continuation.resume(returning: DroppedPhoto(data: data, fileDate: created))
            }
        }
    }

    /// Photos and browsers hand over a temporary file, which only lasts while this runs.
    private static func fromImage(_ provider: NSItemProvider) async -> DroppedPhoto? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) }.map { DroppedPhoto(data: $0) })
            }
        }
    }
}
