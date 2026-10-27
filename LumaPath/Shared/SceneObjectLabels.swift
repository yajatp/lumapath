import Foundation

/// Exact shared NMS classes embedded in Apple's pinned full and Tiny Darknet YOLOv3 assets.
public enum SceneObjectLabels {
    public static let rawClassNames = "person|bicycle|car|motorbike|aeroplane|bus|train|truck|boat|traffic light|fire hydrant|stop sign|parking meter|bench|bird|cat|dog|horse|sheep|cow|elephant|bear|zebra|giraffe|backpack|umbrella|handbag|tie|suitcase|frisbee|skis|snowboard|sports ball|kite|baseball bat|baseball glove|skateboard|surfboard|tennis racket|bottle|wine glass|cup|fork|knife|spoon|bowl|banana|apple|sandwich|orange|broccoli|carrot|hot dog|pizza|donut|cake|chair|sofa|pottedplant|bed|diningtable|toilet|tvmonitor|laptop|mouse|remote|keyboard|cell phone|microwave|oven|toaster|sink|refrigerator|book|clock|vase|scissors|teddy bear|hair drier|toothbrush"
    private static let displayAliases = ["motorbike": "motorcycle", "aeroplane": "airplane", "pottedplant": "potted plant", "diningtable": "dining table", "tvmonitor": "television"]
    public static let mapping: [String: String] = Dictionary(uniqueKeysWithValues: rawClassNames.split(separator: "|").map {
        let raw = String($0); return (raw, displayAliases[raw] ?? raw)
    })
    public static let names = Set(mapping.values)
    public static func name(forUserQuery input: String) -> String? {
        let label = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = mapping[label] { return name }
        if names.contains(label) { return label }
        return ["couch": "sofa", "table": "dining table", "plant": "potted plant", "tv": "television", "phone": "cell phone"][label]
    }
}
