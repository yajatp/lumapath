import Foundation
import CreateML
import CryptoKit

// Explicit prepared splits only. This executable never downloads images or automatically promotes a model.
let arguments = CommandLine.arguments
if arguments.count < 3 || arguments.contains("--help") {
    print("Usage: train_detector PREPARED_DATASET NEW_OUTPUT_DIRECTORY [ITERATIONS=500]")
    exit(arguments.contains("--help") ? 0 : 2)
}
let dataset = URL(fileURLWithPath: arguments[1],isDirectory: true)
let output = URL(fileURLWithPath: arguments[2],isDirectory: true)
let iterations = arguments.count > 3 ? Int(arguments[3]) ?? 0 : 500
func require(_ condition: Bool,_ message: String) throws {
    if !condition { throw NSError(domain: "LumaPathTraining",code: 1,userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    try require(iterations >= 1 && iterations <= 100_000,"Iterations must be explicit and bounded")
    try require(!FileManager.default.fileExists(atPath: output.path),"Use a new output directory")
    let provenanceData = try Data(contentsOf: dataset.appendingPathComponent("provenance.json"))
    let provenance = try JSONSerialization.jsonObject(with: provenanceData) as? [String: Any]
    try require((provenance?["schemaVersion"] as? Int) == 1,"Run prepare_dataset.py first")
    func source(_ split: String) -> MLObjectDetector.DataSource {
        .directoryWithImages(at: dataset.appendingPathComponent(split),annotationFile: dataset.appendingPathComponent(split+"/annotations.json"))
    }
    let parameters = MLObjectDetector.ModelParameters(validation: .dataSource(source("validation")),
        maxIterations: iterations,algorithm: .transferLearning(.objectPrint(revision: 1)))
    let detector = try MLObjectDetector(trainingData: source("train"),parameters: parameters,
        annotationType: .boundingBox(units: .pixel,origin: .topLeft,anchor: .center))
    let evaluation = detector.evaluation(on: source("test"))
    try require(evaluation.isValid,"Held-out evaluation failed")
    try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
    let modelURL = output.appendingPathComponent("Detector.mlmodel")
    try detector.write(to: modelURL)
    let digest = SHA256.hash(data: try Data(contentsOf: modelURL)).map { String(format: "%02x",$0) }.joined()
    let metrics: [String: Any] = ["schemaVersion": 1,"sha256": digest,"iterations": iterations,
        "createMLMeanAveragePrecision50": evaluation.meanAveragePrecision.IoU50,
        "createMLPerClassAveragePrecision50": evaluation.averagePrecision.IoU50,
        "sourceProvenanceSHA256": SHA256.hash(data: provenanceData).map { String(format: "%02x",$0) }.joined(),
        "ordinaryLiveAvailable": false,"remainingEvaluation": ["absent-target false detections","association error","on-device inference latency","protected physical validation"]]
    try JSONSerialization.data(withJSONObject: metrics,options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("training-results.json"))
    print("Exported \(modelURL.path); model remains unpromoted. Run held-out detector/association/latency evaluation.")
} catch {
    FileHandle.standardError.write(Data(("Training failed: \(error.localizedDescription)\n").utf8)); exit(1)
}
