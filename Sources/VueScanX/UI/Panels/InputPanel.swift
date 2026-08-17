import SwiftUI

struct InputPanel: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Device")

            OptionRow(label: "Task", help: "What VueScanX does once the page is acquired") {
                Picker("", selection: $controller.settings.task) {
                    ForEach(ScanTask.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().controlSize(.small)
            }

            OptionRow(label: "Source", help: "Scanner to acquire from") {
                HStack(spacing: 4) {
                    Picker("", selection: Binding(
                        get: { controller.selectedDeviceID ?? "" },
                        set: { controller.selectDevice($0) }
                    )) {
                        if controller.devices.isEmpty {
                            Text("No scanners found").tag("")
                        }
                        ForEach(controller.devices) { device in
                            Text(device.displayName).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Button {
                        controller.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Look for scanners again")
                }
            }

            if let device = controller.selectedDevice {
                OptionRow(label: "Status") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(device.transport == .simulated ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(device.transport == .simulated
                             ? "Simulated device — no hardware attached"
                             : "\(device.model.isEmpty ? device.name : device.model)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            OptionChoice(label: "Mode",
                         selection: $controller.settings.source,
                         options: controller.availableSources,
                         title: { $0.rawValue },
                         help: "Flatbed glass or automatic document feeder")

            SectionHeader(title: "Acquisition")

            OptionPicker(label: "Media", selection: $controller.settings.media,
                         help: "Drives colour mode and default tone handling")

            OptionPicker(label: "Bits per pixel", selection: $controller.settings.bitDepth,
                         help: "Requested from the scanner; falls back if unsupported")

            OptionChoice(label: "Scan resolution",
                         selection: $controller.settings.scanResolution,
                         options: controller.availableResolutions,
                         title: { "\($0) dpi" },
                         help: "Optical resolution used for the final scan")

            OptionChoice(label: "Preview resolution",
                         selection: $controller.settings.previewResolution,
                         options: controller.availableResolutions.filter { $0 <= 300 },
                         title: { "\($0) dpi" },
                         help: "Lower is faster; only used for the preview pass")

            OptionRow(label: "Samples", help: "Average N passes to cut sensor noise") {
                Stepper(value: $controller.settings.numberOfSamples, in: 1...4) {
                    Text("\(controller.settings.numberOfSamples)")
                        .font(.system(size: 11, design: .monospaced))
                }
                .controlSize(.small)
            }

            SectionHeader(title: "Orientation")

            OptionPicker(label: "Rotation", selection: $controller.settings.rotation)
            OptionToggle(label: "Mirror", isOn: $controller.settings.mirror,
                         help: "Flip horizontally — for film scanned emulsion-up")
            OptionToggle(label: "Auto skew", isOn: $controller.settings.autoSkew,
                         help: "Straighten a page that sat crooked on the glass")
            OptionToggle(label: "Auto rotate", isOn: $controller.settings.autoRotate,
                         help: "Detect text direction and rotate upright")

            if controller.settings.showAdvancedOptions {
                SectionHeader(title: "Batch")
                OptionPicker(label: "Batch scan", selection: $controller.settings.batchMode,
                             help: "Feed several pages without re-pressing Scan")
                if controller.settings.batchMode != .off {
                    OptionRow(label: "Pages") {
                        Stepper(value: $controller.settings.batchCount, in: 1...200) {
                            Text("\(controller.settings.batchCount)")
                                .font(.system(size: 11, design: .monospaced))
                        }.controlSize(.small)
                    }
                }
                OptionToggle(label: "Eject after scan", isOn: $controller.settings.autoEjectAfterScan)
            }

            Spacer(minLength: 8)
        }
    }
}
