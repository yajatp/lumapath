import Foundation
import CoreML
import Vision
import ImageIO
import CryptoKit

let arguments = CommandLine.arguments
if arguments.count != 4 || arguments.contains("--help") {
    print("Usage: infer_evaluation Detector.mlmodel PREPARED_DATASET NEW_RESULTS.jsonl")
    exit(arguments.contains("--help") ? 0 : 2)
}
do {
    let modelURL = URL(fileURLWithPath: arguments[1])
    let dataset = URL(fileURLWithPath: arguments[2],isDirectory: true)
    let output = URL(fileURLWithPath: arguments[3])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw NSError(domain: "Evaluation",code: 1,userInfo: [NSLocalizedDescriptionKey: "Output already exists"]) }
    let digest = SHA256.hash(data: try Data(contentsOf: modelURL)).map { String(format: "%02x",$0) }.joined()
    let compiled = try MLModel.compileModel(at: modelURL)
    defer { try? FileManager.default.removeItem(at: compiled) }
    let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
    let provenance = try JSONSerialization.jsonObject(with: Data(contentsOf: dataset.appendingPathComponent("provenance.json"))) as! [String: Any]
    let rows = (provenance["rows"] as! [[String: Any]]).filter { ($0["split"] as? String) == "test" }
    let targets = provenance["targets"] as! [String]
    let annotations = try JSONSerialization.jsonObject(with: Data(contentsOf: dataset.appendingPathComponent("test/annotations.json"))) as! [[String: Any]]
    guard rows.count == annotations.count, !rows.isEmpty else { throw NSError(domain: "Evaluation",code: 2) }
    var lines: [String] = []
    for (row,annotation) in zip(rows,annotations) {
        let file = dataset.appendingPathComponent("test").appendingPathComponent(annotation["image"] as! String)
        let request = VNCoreMLRequest(model: model); request.imageCropAndScaleOption = .scaleFill
        let start = ProcessInfo.processInfo.systemUptime
        try VNImageRequestHandler(url: file,orientation: .up,options: [:]).perform([request])
        let duration = (ProcessInfo.processInfo.systemUptime-start)*1000
        guard let objects = request.results as? [VNRecognizedObjectObservation] else { throw NSError(domain: "Evaluation",code: 3,userInfo: [NSLocalizedDescriptionKey: "Model did not return object boxes"]) }
        let predictions: [[String: Any]] = objects.compactMap { object in
            guard let label = object.labels.first, targets.contains(label.identifier), label.confidence >= 0.6 else { return nil }
            let box = object.boundingBox
            return ["target": label.identifier,"score": Double(label.confidence),"box": [box.minX,1-box.maxY,box.maxX,1-box.minY]]
        }
        let width = (row["width"] as! NSNumber).doubleValue, height = (row["height"] as! NSNumber).doubleValue
        let truth: [[String: Any]] = (row["annotations"] as! [[String: Any]]).map { value in
            let box = (value["box"] as! [NSNumber]).map(\.doubleValue)
            var item: [String: Any] = ["target": value["label"]!,"box": [box[0]/width,box[1]/height,(box[0]+box[2])/width,(box[1]+box[3])/height]]
            if let range = value["rangeMeters"] { item["rangeMeters"] = range }
            return item
        }
        let result: [String: Any] = ["id": row["id"]!,"split": "test","environmentID": row["environmentID"]!,"sessionID": row["sessionID"]!,
            "modelSHA256": digest,"evaluatedTargets": targets,"inferenceMilliseconds": duration,"truth": truth,"predictions": predictions]
        let data = try JSONSerialization.data(withJSONObject: result,options: [.sortedKeys])
        lines.append(String(decoding: data,as: UTF8.self))
    }
    try (lines.joined(separator: "\n")+"\n").write(to: output,atomically: true,encoding: .utf8)
    print("Measured \(rows.count) held-out images. Host inference timings are not iPhone latency evidence.")
} catch { FileHandle.standardError.write(Data(("Evaluation failed: \(error.localizedDescription)\n").utf8)); exit(1) }
