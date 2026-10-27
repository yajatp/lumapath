import Foundation
import LumaPathDomain

/// Presentation only. These values never change sensing or hazard thresholds.
public struct EnhancementSettings: Equatable, Sendable {
    public var enhanced = true
    public var exposure = 0.0
    public var contrast = 1.0
    public var highlightCompression = 0.25
    public var edges = 0.0
    public var shadowLift = 0.0
    public var gamma = 1.0
    public init() {}
    public var isValid: Bool {
        (-1...2).contains(exposure) && (0.5...2).contains(contrast)
        && (0...1).contains(highlightCompression) && (0...1).contains(edges)
        && (0...1).contains(shadowLift) && (0.5...1.5).contains(gamma)
    }
}

public enum RenderBoundary {
    /// Bounded output independent of camera resolution. At most 1280² RGBA bytes per image.
    public static func outputSize(for viewport: PixelSize) -> PixelSize? {
        guard viewport.isValid else { return nil }
        let scale = min(1, 1280 / Double(max(viewport.width, viewport.height)))
        return PixelSize(width: max(1, Int(Double(viewport.width) * scale)),
                         height: max(1, Int(Double(viewport.height) * scale)))
    }
    public static func accepts(_ frame: FrameDescriptor, context: CaptureContext,
                               orientation: ImageOrientation, viewport: PixelSize, at now: TimeInterval) -> Bool {
        (try? frame.validate()) != nil && frame.orientation == orientation && frame.viewportSize == viewport
        && frame.envelope.isCurrent(in: context, at: now)
    }
    /// Input is ORIGINAL normalized top-left image coordinates. Apply the producer transform once.
    /// Never pass GeometryDetails.displayBounds here: those coordinates are already transformed.
    public static func project(_ bounds: NormalizedBounds, through transform: DisplayTransform) -> NormalizedBounds? {
        guard transform.isValid, [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              bounds.minX < bounds.maxX, bounds.minY < bounds.maxY else { return nil }
        let points = [transform.apply(x: bounds.minX, y: bounds.minY), transform.apply(x: bounds.maxX, y: bounds.minY),
                      transform.apply(x: bounds.minX, y: bounds.maxY), transform.apply(x: bounds.maxX, y: bounds.maxY)]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return NormalizedBounds(minX: points.map(\.x).min()!, minY: points.map(\.y).min()!,
                                maxX: points.map(\.x).max()!, maxY: points.map(\.y).max()!).clipped
    }
    /// A request is valid only for the exact image actually on screen, including calibration.
    public static func overlays(_ request: RendererRequest, displayedFrame: FrameDescriptor,
                                context: CaptureContext, orientation: ImageOrientation,
                                viewport: PixelSize, at now: TimeInterval) -> [NormalizedBounds] {
        guard request.frame == displayedFrame,
              accepts(displayedFrame, context: context, orientation: orientation, viewport: viewport, at: now) else { return [] }
        return request.geometry.prefix(32).compactMap { observation in
            guard observation.envelope.frameID == displayedFrame.envelope.frameID,
                  observation.envelope.isCurrent(in: context, at: now), let details = observation.details else { return nil }
            return project(details.imageBounds, through: displayedFrame.imageToDisplay)
        }
    }
}
