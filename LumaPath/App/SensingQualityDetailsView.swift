import SwiftUI
import LumaPathDomain

struct SensingQualityDetailsView: View {
    let quality: QualityAssessment?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let quality {
                Text("Sensing state: \(quality.state.rawValue)").font(.headline)
                ForEach(SensingLimitation.reasons(for: quality), id: \.self) { Text($0.message) }
                Text("Overall usable depth: \(percent(quality.usableDepthFraction))")
                if let details = quality.details {
                    Text("Quality configuration \(details.configurationVersion). Tracking: \(details.tracking.rawValue).")
                    Text("Sample age when evaluated: \(details.sampleAge * 1000, specifier: "%.0f") milliseconds. Current observations expire with their source frame.")
                    Text(details.worldDependentFunctionsSupported ? "World reference supported for this sample." : "World-dependent functions unsupported for this sample.")
                    ForEach(Array(details.regions.enumerated()), id: \.offset) { _, region in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(region.region.rawValue.capitalized), \(region.band.rawValue) image band").font(.headline)
                            Text("Depth: \(region.coverage.rawValue); usable samples: \(percent(region.usableDepthFraction)).")
                            Text(region.confidenceKnown ? "Confidence counts: low \(region.lowConfidencePixels ?? 0), medium \(region.mediumConfidencePixels ?? 0), high \(region.highConfidencePixels ?? 0), invalid \(region.invalidConfidencePixels ?? 0)." : "Depth confidence unknown.")
                            if let image = region.image {
                                Text("Original image: \(percent(image.darkFraction)) dark; \(percent(image.clippedFraction)) clipped; local contrast \(percent(image.localContrast)).")
                            } else { Text("Original image conditions unknown.") }
                            if region.temporalRangeChanged == true { Text("Nearest cell depth changed. This is not an object-motion estimate.") }
                        }.accessibilityElement(children: .combine)
                    }
                } else { Text("No current regional measurements. Unknown areas are not clear space.") }
            } else { Text("Sensing has not started. No measurements or regional coverage are available.") }
            Text("Coverage is not a probability of safety. Dark or enhanced images do not erase supported depth obstacles. Image bands do not establish floor or overhead geometry.")
            Text("Engineering thresholds v\(QualityConfiguration.current.configurationVersion): high coverage \(percent(QualityConfiguration.current.highCoverage)); limited coverage \(percent(QualityConfiguration.current.limitedCoverage)); dark luma at or below \(QualityConfiguration.current.darkLuma); clipped luma at or above \(QualityConfiguration.current.clippedLuma); recovery requires \(QualityConfiguration.current.recoveryFrames) frames. Physical calibration remains pending.")
        }.accessibilityIdentifier("quality.details")
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0*100) } ?? "unknown" }
}
