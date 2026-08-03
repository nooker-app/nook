import AppKit
import Foundation
import Vision

// Fails if any screenshot has a detectable human face in it. Store screenshots
// show real feeds, and a real feed will sooner or later serve a portrait: an
// author photo, a conference stage, a product page with a person on it. Nothing
// about the capture flow notices, so this does — run it over captures/ and
// output/ before publishing a set.
var offenders: [String] = []

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path),
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let cgImage = rep.cgImage
    else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        exit(2)
    }

    let request = VNDetectFaceRectanglesRequest()
    do {
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    } catch {
        FileHandle.standardError.write(Data("detection failed for \(path): \(error)\n".utf8))
        exit(2)
    }

    let faces = request.results ?? []
    guard !faces.isEmpty else { continue }
    offenders.append(path)
    let boxes = faces.map { face in
        String(
            format: "(%.2f,%.2f %.2fx%.2f conf %.2f)",
            face.boundingBox.origin.x, face.boundingBox.origin.y,
            face.boundingBox.width, face.boundingBox.height, face.confidence)
    }
    print("FACE  \(path)  \(faces.count): \(boxes.joined(separator: " "))")
}

if offenders.isEmpty {
    print("No faces in \(CommandLine.arguments.count - 1) screenshots.")
} else {
    print("\n\(offenders.count) screenshot(s) show a face. Recapture on a different article.")
    exit(1)
}
