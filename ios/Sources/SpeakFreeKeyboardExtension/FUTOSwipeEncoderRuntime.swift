// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import ExecuTorch
import Foundation
import SpeakFreeKeyboardCore

enum FUTOSwipeRuntimeError: LocalizedError {
    case missingModel
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingModel: "FUTO Swipe encoder model is missing from the keyboard bundle."
        case .invalidOutput: "FUTO Swipe encoder returned an unexpected tensor."
        }
    }
}

/// Independent Swift integration for the published FUTO Swipe encoder contract.
/// This does not include or link FUTO's GPL-licensed swipe-library implementation.
final class FUTOSwipeEncoderRuntime: SwipeModelRuntime {
    let labels: [Character]
    let blankIndex = 64

    private let module: Module
    private let layoutValues: [Float]
    private let layoutMask: [Bool]

    init(bundle: Bundle = .main) throws {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let unused = (0..<38).compactMap { UnicodeScalar(0xE000 + $0).map(Character.init) }
        labels = letters + unused

        guard let url = Self.resourceURL(
            named: "model_fp32",
            extension: "pte",
            bundle: bundle
        ) else { throw FUTOSwipeRuntimeError.missingModel }

        module = Module(filePath: url.path, loadMode: .mmap)
        try module.load("forward")

        let centers = Dictionary(
            uniqueKeysWithValues: QWERTYKeyboardLayout.standardKeys.map { ($0.character, $0.center) }
        )
        var values = [Float](repeating: 0, count: 64 * 2)
        var mask = [Bool](repeating: false, count: 64)
        for (index, letter) in letters.enumerated() {
            guard let center = centers[letter] else { continue }
            values[index * 2] = Float(center.x)
            values[index * 2 + 1] = Float(center.y)
            mask[index] = true
        }
        layoutValues = values
        layoutMask = mask
    }

    func predict(input: SwipeTensor) throws -> [[Float]] {
        let features = Tensor<Float>(input.values, shape: input.shape)
        let layout = Tensor<Float>(layoutValues, shape: [1, 64, 2])
        let mask = Tensor<Bool>(layoutMask, shape: [1, 64])
        let outputs = try module.forward([features, layout, mask])
        guard let first = outputs.first,
              let tensor: Tensor<Float> = first.tensor(),
              tensor.shape == [1, 32, 65] else {
            throw FUTOSwipeRuntimeError.invalidOutput
        }
        let values = tensor.scalars()
        guard values.count == 32 * 65 else { throw FUTOSwipeRuntimeError.invalidOutput }
        return (0..<32).map { time in
            Array(values[(time * 65)..<((time + 1) * 65)])
        }
    }

    private static func resourceURL(named name: String, extension ext: String, bundle: Bundle) -> URL? {
        if let direct = bundle.url(forResource: name, withExtension: ext) { return direct }
        return bundle.urls(forResourcesWithExtension: ext, subdirectory: nil)?
            .first(where: { $0.deletingPathExtension().lastPathComponent == name })
    }
}
