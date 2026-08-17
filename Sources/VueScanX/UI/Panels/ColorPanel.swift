import SwiftUI

struct ColorPanel: View {
    @ObservedObject var controller: ScanController

    private var manual: Bool { controller.settings.colorBalance == .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Balance")

            OptionPicker(label: "Color balance", selection: $controller.settings.colorBalance,
                         help: "Auto levels reads the histogram; Manual uses the points below")

            OptionSlider(label: "White point %", value: $controller.settings.whitePointPercent,
                         range: 0...10, step: 0.1, format: "%.1f",
                         help: "Percentage of the brightest pixels clipped to pure white")
            OptionSlider(label: "Black point %", value: $controller.settings.blackPointPercent,
                         range: 0...10, step: 0.1, format: "%.1f",
                         help: "Percentage of the darkest pixels clipped to pure black")

            SectionHeader(title: "Curve")

            OptionSlider(label: "Curve low", value: $controller.settings.curveLow,
                         range: 0...1, step: 0.01, format: "%.2f",
                         help: "Output level at the quarter-tone control point")
            OptionSlider(label: "Curve high", value: $controller.settings.curveHigh,
                         range: 0...1, step: 0.01, format: "%.2f",
                         help: "Output level at the three-quarter-tone control point")

            CurvePreview(low: controller.settings.curveLow, high: controller.settings.curveHigh)
                .frame(height: 74)
                .padding(.leading, 126)
                .padding(.trailing, 6)
                .padding(.vertical, 4)

            SectionHeader(title: "Brightness")

            OptionSlider(label: "Brightness", value: $controller.settings.brightness,
                         range: 0.2...3.0, step: 0.01, format: "%.2f")
            OptionSlider(label: "Saturation", value: $controller.settings.saturation,
                         range: 0...2.0, step: 0.01, format: "%.2f")

            Group {
                OptionSlider(label: "Red brightness", value: $controller.settings.redBrightness,
                             range: 0.2...3.0, step: 0.01, format: "%.2f")
                OptionSlider(label: "Green brightness", value: $controller.settings.greenBrightness,
                             range: 0.2...3.0, step: 0.01, format: "%.2f")
                OptionSlider(label: "Blue brightness", value: $controller.settings.blueBrightness,
                             range: 0.2...3.0, step: 0.01, format: "%.2f")
            }
            .disabled(controller.settings.media.isMonochrome)
            .opacity(controller.settings.media.isMonochrome ? 0.45 : 1)

            SectionHeader(title: "Output")

            OptionPicker(label: "Color space", selection: $controller.settings.outputColorSpace,
                         help: "ICC profile tagged onto every saved file")
            OptionToggle(label: "Invert", isOn: $controller.settings.invert,
                         help: "Negative — also applied automatically for B/W negative media")

            HStack(spacing: 5) {
                Button("Neutral") {
                    controller.settings.brightness = 1
                    controller.settings.saturation = 1
                    controller.settings.redBrightness = 1
                    controller.settings.greenBrightness = 1
                    controller.settings.blueBrightness = 1
                    controller.settings.curveLow = 0.25
                    controller.settings.curveHigh = 0.75
                }
                .controlSize(.small).buttonStyle(.bordered)

                Button("Punchy") {
                    controller.settings.curveLow = 0.16
                    controller.settings.curveHigh = 0.84
                    controller.settings.saturation = 1.18
                }
                .controlSize(.small).buttonStyle(.bordered)
            }
            .padding(.leading, 126)
            .padding(.top, 4)

            Spacer(minLength: 8)
        }
    }
}

/// Draws the tone curve the Color tab is currently describing, with the
/// identity diagonal behind it for reference.
struct CurvePreview: View {
    let low: Double
    let high: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)

                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    let points: [CGPoint] = [
                        CGPoint(x: 0, y: h),
                        CGPoint(x: w * 0.25, y: h * (1 - low)),
                        CGPoint(x: w * 0.5, y: h * 0.5),
                        CGPoint(x: w * 0.75, y: h * (1 - high)),
                        CGPoint(x: w, y: 0)
                    ]
                    p.move(to: points[0])
                    for i in 1..<points.count {
                        let prev = points[i - 1], cur = points[i]
                        let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                        p.addQuadCurve(to: mid, control: prev)
                        p.addLine(to: cur)
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.6)
            }
        }
    }
}
