import SwiftUI

/// An option row is a fixed-width label on the left and a control on the right,
/// packed tightly. Everything in the options panel goes through here so the
/// columns line up across all six tabs.
struct OptionRow<Content: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
                .lineLimit(1)
                .truncationMode(.tail)
            content
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help ?? label)
        .padding(.vertical, 1)
    }
}

/// Labelled slider with a live numeric readout — brightness, threshold and
/// quality all read better with the number visible while dragging.
struct OptionSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"
    var help: String? = nil

    var body: some View {
        OptionRow(label: label, help: help) {
            HStack(spacing: 6) {
                Slider(value: $value, in: range, step: step)
                    .controlSize(.mini)
                Text(String(format: format, value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

struct OptionPicker<T: Hashable & Identifiable & CaseIterable & RawRepresentable>: View
where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let label: String
    @Binding var selection: T
    var help: String? = nil

    var body: some View {
        OptionRow(label: label, help: help) {
            Picker("", selection: $selection) {
                ForEach(Array(T.allCases)) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

/// Picker constrained to a runtime-provided subset — used where the hardware
/// dictates the legal values (sources, resolutions).
struct OptionChoice<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String
    var help: String? = nil

    var body: some View {
        OptionRow(label: label, help: help) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { item in
                    Text(title(item)).tag(item)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

struct OptionToggle: View {
    let label: String
    @Binding var isOn: Bool
    var help: String? = nil

    var body: some View {
        OptionRow(label: label, help: help) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
    }
}

/// Numeric field that stores millimetres but displays whatever unit the Prefs
/// tab has selected. Every crop dimension goes through it, so the conversion
/// lives in one place instead of at each call site.
struct MeasurementField: View {
    let label: String
    /// CGFloat rather than Double because every caller reads out of a CGPoint/CGSize.
    @Binding var millimetres: CGFloat
    let units: Units
    let dpi: Int
    var range: ClosedRange<CGFloat> = 0...1000

    private var displayed: Binding<Double> {
        Binding(
            get: { UnitConvert.display(Double(millimetres), units: units, dpi: dpi) },
            set: {
                let mm = CGFloat(UnitConvert.toMM($0, units: units, dpi: dpi))
                millimetres = min(max(mm, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        OptionRow(label: label) {
            HStack(spacing: 4) {
                TextField("", value: displayed, format: .number.precision(.fractionLength(units == .inch ? 2 : 0)))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 74)
                Text(units.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}
