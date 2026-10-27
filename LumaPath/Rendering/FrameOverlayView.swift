#if os(iOS)
import SwiftUI
import LumaPathDomain

/// B3's composition boundary: layer this over the exact rendered viewport, never a resized/cropped sibling.
/// Bounds are recomputed from original image coordinates and independently expire even without new frames.
public struct FrameOverlayView: View {
    private let request: RendererRequest
    private let displayedFrame: FrameDescriptor
    private let context: CaptureContext
    private let orientation: ImageOrientation
    private let viewport: PixelSize
    private let outlineWidth: Double
    private let color: Color
    private let dualStroke: Bool
    private let density: Int
    public init(request: RendererRequest, displayedFrame: FrameDescriptor, context: CaptureContext,
                orientation: ImageOrientation, viewport: PixelSize, outlineWidth: Double = 4, color: Color = .yellow, dualStroke: Bool = true, density: Int = 32) {
        self.request = request; self.displayedFrame = displayedFrame; self.context = context
        self.orientation = orientation; self.viewport = viewport
        self.outlineWidth = outlineWidth.isFinite ? min(10, max(2, outlineWidth)) : 4
        self.color = color; self.dualStroke = dualStroke; self.density = min(32, max(1, density))
    }
    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            Canvas { canvas, size in
                let bounds = RenderBoundary.overlays(request, displayedFrame: displayedFrame, context: context,
                    orientation: orientation, viewport: viewport, at: SystemMonotonicClock().now())
                for bound in bounds.prefix(density) {
                    let rect = CGRect(x: bound.minX * size.width, y: bound.minY * size.height,
                        width: (bound.maxX-bound.minX) * size.width, height: (bound.maxY-bound.minY) * size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 4)
                    if dualStroke { canvas.stroke(path, with: .color(.black), lineWidth: outlineWidth + 3) }
                    canvas.stroke(path, with: .color(color), lineWidth: outlineWidth)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
        // Text/speech equivalents are owned by the B3 event consumer, not inferred from rectangles.
    }
}
#endif
