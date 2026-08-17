import SwiftUI

struct FilterPanel: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Restoration")

            OptionToggle(label: "Restore colors", isOn: $controller.settings.restoreColors,
                         help: "Rebuild saturation and neutralise the cast on aged prints")
            OptionToggle(label: "Restore fading", isOn: $controller.settings.restoreFading,
                         help: "Stretch contrast on a washed-out original")

            SectionHeader(title: "Descreen")

            OptionToggle(label: "Descreen", isOn: $controller.settings.descreen,
                         help: "Remove the halftone dot pattern from printed matter")
            if controller.settings.descreen {
                OptionChoice(label: "Screen frequency",
                             selection: $controller.settings.descreenDPI,
                             options: [65, 85, 100, 120, 133, 150, 175, 200, 300],
                             title: { "\($0) lpi" },
                             help: "Newspaper ≈ 85, magazine ≈ 133–150, fine art ≈ 175+")
                Text("Blur radius follows scan dpi ÷ screen frequency, so set the "
                     + "frequency to match the original's print process.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 126)
                    .padding(.trailing, 6)
                    .padding(.top, 2)
            }

            SectionHeader(title: "Noise & detail")

            OptionPicker(label: "Grain reduction", selection: $controller.settings.grainReduction,
                         help: "Smooths sensor and film grain before sharpening")
            OptionPicker(label: "Sharpen", selection: $controller.settings.sharpen,
                         help: "Unsharp mask, applied last so it does not amplify noise")

            if controller.settings.media.isBilevel || controller.settings.bitDepth == .bw1 {
                SectionHeader(title: "Line art")
                OptionSlider(label: "Threshold", value: $controller.settings.bilevelThreshold,
                             range: 0.05...0.95, step: 0.01, format: "%.2f",
                             help: "Luminance below this becomes black, above becomes white")
            }

            SectionHeader(title: "Pipeline order")

            Text("crop → rotate → restore → descreen → grain → tone → colour → sharpen → threshold")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 126)
                .padding(.trailing, 6)

            Spacer(minLength: 8)
        }
    }
}
