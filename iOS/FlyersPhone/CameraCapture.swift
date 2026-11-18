import CoreLocation
import FlyersCore
import SwiftUI
import UIKit

/// The system camera, for photographing a flyer from inside Flyers. The photo goes straight to
/// Flyers to read, tagged with now and where you are, and never into your Photos library.
struct CameraCapture: UIViewControllerRepresentable {
    let onPhoto: (DroppedPhoto) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                // Where you're standing helps find the flyer's place on the map.
                let location = CLLocationManager().location?.coordinate
                parent.onPhoto(DroppedPhoto(data: data, takenAt: Date(), latitude: location?.latitude, longitude: location?.longitude))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
