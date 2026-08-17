import SwiftUI

struct CropPanel: View {
    @ObservedObject var controller: ScanController

    private var dpi: Int { controller.settings.scanResolution }
    private var bed: CGSize { controller.bedSizeMM }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Crop")

            OptionPicker(label: "Crop size", selection: $controller.settings.cropPreset,
                         help: "Auto finds the page edges; Maximum uses the whole bed")

            OptionPicker(label: "Units", selection: $controller.settings.units)

            let editable = controller.settings.cropPreset == .manual
                || controller.settings.cropPreset == .auto

            Group {
                MeasurementField(label: "X offset",
                                 millimetres: $controller.settings.cropOriginMM.x,
                                 units: controller.settings.units, dpi: dpi,
                                 range: 0...bed.width)
                MeasurementField(label: "Y offset",
                                 millimetres: $controller.settings.cropOriginMM.y,
                                 units: controller.settings.units, dpi: dpi,
                                 range: 0...bed.height)
                MeasurementField(label: "Width",
                                 millimetres: $controller.settings.cropSizeMM.width,
                                 units: controller.settings.units, dpi: dpi,
                                 range: 1...bed.width)
                MeasurementField(label: "Height",
                                 millimetres: $controller.settings.cropSizeMM.height,
                                 units: controller.settings.units, dpi: dpi,
                                 range: 1...bed.height)
            }
            .disabled(!editable)
            .opacity(editable ? 1 : 0.45)

            OptionRow(label: "Output size") {
                Text(outputSizeSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            SectionHeader(title: "Shape")

            OptionToggle(label: "Lock aspect ratio", isOn: $controller.settings.lockAspectRatio)
            if controller.settings.lockAspectRatio {
                OptionSlider(label: "Aspect ratio", value: $controller.settings.aspectRatio,
                             range: 0.25...4.0, step: 0.01, format: "%.2f")
            }
            OptionSlider(label: "Border %", value: $controller.settings.borderPercent,
                         range: 0...25, step: 0.5, format: "%.1f",
                         help: "Trim a percentage off every edge after cropping")
            OptionSlider(label: "Auto buffer %", value: $controller.settings.autoCropBufferPercent,
                         range: 0...20, step: 0.5, format: "%.1f",
                         help: "Padding kept around the detected page edges")

            SectionHeader(title: "Presets")

            HStack(spacing: 5) {
                ForEach([CropPreset.maximum, .a4, .letter, .photo4x6], id: \.self) { preset in
                    Button(preset.rawValue) { apply(preset) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.leading, 126)

            HStack(spacing: 5) {
                Button("Centre") { centre() }
                    .controlSize(.small).buttonStyle(.bordered)
                Button("Full bed") { apply(.maximum) }
                    .controlSize(.small).buttonStyle(.bordered)
            }
            .padding(.leading, 126)
            .padding(.top, 3)

            Spacer(minLength: 8)
        }
    }

    private var outputSizeSummary: String {
        let rect = controller.settings.cropPreset == .maximum
            ? CGRect(origin: .zero, size: bed)
            : controller.settings.effectiveCropMM
        let w = Int(UnitConvert.mmToPixels(rect.width, dpi: dpi).rounded())
        let h = Int(UnitConvert.mmToPixels(rect.height, dpi: dpi).rounded())
        let megabytes = Double(w * h * controller.settings.bitDepth.channels
                               * controller.settings.bitDepth.bitsPerChannel / 8) / 1_048_576
        return String(format: "%d × %d px  ·  %.1f MB", w, h, megabytes)
    }

    private func apply(_ preset: CropPreset) {
        controller.settings.cropPreset = preset
        if let mm = preset.millimetres {
            controller.settings.cropSizeMM = CGSize(width: min(mm.width, bed.width),
                                                    height: min(mm.height, bed.height))
            centre()
        } else if preset == .maximum {
            controller.settings.cropOriginMM = .zero
            controller.settings.cropSizeMM = bed
        }
    }

    private func centre() {
        let size = controller.settings.cropSizeMM
        controller.settings.cropOriginMM = CGPoint(
            x: max(0, (bed.width - size.width) / 2),
            y: max(0, (bed.height - size.height) / 2)
        )
    }
}
