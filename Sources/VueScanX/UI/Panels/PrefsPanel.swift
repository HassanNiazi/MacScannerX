import SwiftUI
import AppKit

struct PrefsPanel: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Display")

            OptionPicker(label: "Units", selection: $controller.settings.units)
            OptionToggle(label: "Advanced options", isOn: $controller.settings.showAdvancedOptions,
                         help: "Show the rarely-used controls in every tab")
            OptionToggle(label: "Preview after scan", isOn: $controller.settings.previewAfterScan)

            SectionHeader(title: "Device")

            OptionToggle(label: "Warm up lamp", isOn: $controller.settings.warmUpDevice,
                         help: "CCD scanners need a moment before colour is stable")

            SectionHeader(title: "Settings file")

            OptionRow(label: "Stored at") {
                Text(ScanSettings.storeURL.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(spacing: 5) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([ScanSettings.storeURL])
                }
                .controlSize(.small).buttonStyle(.bordered)

                Button("Reset all") { controller.resetSettings() }
                    .controlSize(.small).buttonStyle(.bordered)
            }
            .padding(.leading, 126)
            .padding(.top, 4)

            SectionHeader(title: "HP DeskJet 2300 notes")

            Text("""
                 The 2300 series is a flatbed-only all-in-one: no feeder, no duplex, \
                 no transparency unit. Its optical sensor is 1200 × 1200 dpi with an \
                 A4/Letter platen. Over USB it appears through Image Capture; over \
                 Wi-Fi it advertises AirScan (_uscan._tcp) and VueScanX drives it \
                 directly with eSCL.

                 If the scanner does not appear: confirm it is on the same Wi-Fi \
                 network, then allow VueScanX under System Settings › Privacy & \
                 Security › Local Network.
                 """)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 126)
                .padding(.trailing, 6)

            Spacer(minLength: 8)
        }
    }
}
