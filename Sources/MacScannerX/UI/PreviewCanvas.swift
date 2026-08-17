import SwiftUI
import CoreGraphics

/// The preview pane: the last overview scan with a draggable crop rectangle on
/// top. The rectangle is stored in bed millimetres, so dragging it here and
/// typing numbers in the Crop tab are the same edit.
struct PreviewCanvas: View {
    @ObservedObject var controller: ScanController
    let image: CGImage?
    let showCropOverlay: Bool

    @State private var dragStartOrigin: CGPoint?
    @State private var dragStartSize: CGSize?
    @State private var activeHandle: Handle?
    @State private var zoom: Double = 1.0

    enum Handle: Hashable {
        case body
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    var body: some View {
        GeometryReader { geo in
            let bed = controller.bedSizeMM
            let fitted = Self.fit(bed: bed, into: geo.size.inset(by: 24), zoom: zoom)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                ZStack {
                    // Bed
                    Rectangle()
                        .fill(Color(white: 0.14))
                        .frame(width: fitted.width, height: fitted.height)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

                    if let image {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: fitted.width, height: fitted.height)
                            .clipped()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "scanner")
                                .font(.system(size: 34, weight: .thin))
                                .foregroundStyle(.tertiary)
                            Text("Press Preview to see the glass")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: fitted.width, height: fitted.height)
                    }

                    if showCropOverlay, image != nil {
                        cropOverlay(bed: bed, fitted: fitted)
                    }
                }
                .frame(width: fitted.width, height: fitted.height)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        zoomControls
                    }
                }
                .padding(10)
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { zoom = max(0.25, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = 1.0 } label: { Text("Fit").font(.system(size: 10)) }
            Button { zoom = min(6, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Crop overlay

    @ViewBuilder
    private func cropOverlay(bed: CGSize, fitted: CGSize) -> some View {
        let crop = controller.settings.cropPreset == .maximum
            ? CGRect(origin: .zero, size: bed)
            : controller.settings.effectiveCropMM
        let sx = fitted.width / bed.width
        let sy = fitted.height / bed.height
        let r = CGRect(x: crop.origin.x * sx, y: crop.origin.y * sy,
                       width: crop.width * sx, height: crop.height * sy)

        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: fitted.width, height: fitted.height)
                .mask {
                    Rectangle()
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay(alignment: .topLeading) {
                            Rectangle()
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.origin.x, y: r.origin.y)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.yellow.opacity(0.95), lineWidth: 1)
                .frame(width: r.width, height: r.height)
                .offset(x: r.origin.x, y: r.origin.y)
                .contentShape(Rectangle())
                .gesture(dragGesture(handle: .body, bed: bed, fitted: fitted))

            ForEach(Self.handles, id: \.0) { (handle, unit) in
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .offset(x: r.origin.x + r.width * unit.x - 4,
                            y: r.origin.y + r.height * unit.y - 4)
                    .gesture(dragGesture(handle: handle, bed: bed, fitted: fitted))
            }

            Text(String(format: "%.0f × %.0f mm", crop.width, crop.height))
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.black.opacity(0.65))
                .foregroundStyle(.yellow)
                .cornerRadius(2)
                .offset(x: r.origin.x + 2, y: max(0, r.origin.y - 14))
                .allowsHitTesting(false)
        }
        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
    }

    private static let handles: [(Handle, CGPoint)] = [
        (.topLeft, CGPoint(x: 0, y: 0)),
        (.top, CGPoint(x: 0.5, y: 0)),
        (.topRight, CGPoint(x: 1, y: 0)),
        (.right, CGPoint(x: 1, y: 0.5)),
        (.bottomRight, CGPoint(x: 1, y: 1)),
        (.bottom, CGPoint(x: 0.5, y: 1)),
        (.bottomLeft, CGPoint(x: 0, y: 1)),
        (.left, CGPoint(x: 0, y: 0.5))
    ]

    private func dragGesture(handle: Handle, bed: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartOrigin == nil {
                    // Dragging implies manual control; Auto/Maximum would fight the user.
                    if controller.settings.cropPreset == .maximum
                        || controller.settings.cropPreset == .auto {
                        controller.settings.cropSizeMM = controller.settings.effectiveCropMM.size == .zero
                            ? bed : controller.settings.cropSizeMM
                        if controller.settings.cropPreset == .maximum {
                            controller.settings.cropOriginMM = .zero
                            controller.settings.cropSizeMM = bed
                        }
                        controller.settings.cropPreset = .manual
                    }
                    dragStartOrigin = controller.settings.cropOriginMM
                    dragStartSize = controller.settings.cropSizeMM
                    activeHandle = handle
                }
                guard let start = dragStartOrigin, let size = dragStartSize else { return }

                let dxMM = value.translation.width / fitted.width * bed.width
                let dyMM = value.translation.height / fitted.height * bed.height

                var origin = start
                var newSize = size

                switch handle {
                case .body:
                    origin.x = start.x + dxMM
                    origin.y = start.y + dyMM
                case .left, .topLeft, .bottomLeft:
                    origin.x = start.x + dxMM
                    newSize.width = size.width - dxMM
                case .right, .topRight, .bottomRight:
                    newSize.width = size.width + dxMM
                default:
                    break
                }
                switch handle {
                case .top, .topLeft, .topRight:
                    origin.y = start.y + dyMM
                    newSize.height = size.height - dyMM
                case .bottom, .bottomLeft, .bottomRight:
                    newSize.height = size.height + dyMM
                default:
                    break
                }

                if controller.settings.lockAspectRatio, handle != .body,
                   controller.settings.aspectRatio > 0 {
                    newSize.width = newSize.height * controller.settings.aspectRatio
                }

                newSize.width = max(5, min(newSize.width, bed.width))
                newSize.height = max(5, min(newSize.height, bed.height))
                origin.x = max(0, min(origin.x, bed.width - newSize.width))
                origin.y = max(0, min(origin.y, bed.height - newSize.height))

                controller.settings.cropOriginMM = origin
                controller.settings.cropSizeMM = newSize
            }
            .onEnded { _ in
                dragStartOrigin = nil
                dragStartSize = nil
                activeHandle = nil
            }
    }

    // MARK: Layout

    private static func fit(bed: CGSize, into available: CGSize, zoom: Double) -> CGSize {
        guard bed.width > 0, bed.height > 0,
              available.width > 0, available.height > 0 else { return CGSize(width: 10, height: 10) }
        let scale = min(available.width / bed.width, available.height / bed.height) * zoom
        return CGSize(width: bed.width * scale, height: bed.height * scale)
    }
}

extension CGSize {
    func inset(by amount: CGFloat) -> CGSize {
        CGSize(width: max(1, width - amount * 2), height: max(1, height - amount * 2))
    }
}
