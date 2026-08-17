import SwiftUI
import AppKit

enum OptionTab: String, CaseIterable, Identifiable {
    case input = "Input"
    case crop = "Crop"
    case filter = "Filter"
    case color = "Color"
    case output = "Output"
    case prefs = "Prefs"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .input:  return "scanner"
        case .crop:   return "crop"
        case .filter: return "camera.filters"
        case .color:  return "paintpalette"
        case .output: return "square.and.arrow.down"
        case .prefs:  return "gearshape"
        }
    }
}

enum ViewerTab: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case scan = "Scan"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var controller: ScanController
    @State private var optionTab: OptionTab
    @State private var viewerTab: ViewerTab = .preview
    @State private var showLog = true

    init(controller: ScanController, initialTab: OptionTab = .input) {
        self.controller = controller
        _optionTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                optionsColumn
                    .frame(minWidth: 330, idealWidth: 360, maxWidth: 520)
                viewerColumn
                    .frame(minWidth: 380)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
    }

    // MARK: Options column

    private var optionsColumn: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch optionTab {
                    case .input:  InputPanel(controller: controller)
                    case .crop:   CropPanel(controller: controller)
                    case .filter: FilterPanel(controller: controller)
                    case .color:  ColorPanel(controller: controller)
                    case .output: OutputPanel(controller: controller)
                    case .prefs:  PrefsPanel(controller: controller)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            Divider()
            actionButtons
            if showLog {
                Divider()
                LogPane(controller: controller)
                    .frame(height: 128)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(OptionTab.allCases) { tab in
                Button {
                    optionTab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13))
                        Text(tab.rawValue)
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .foregroundStyle(optionTab == tab ? Color.accentColor : Color.secondary)
                    .background(optionTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    controller.preview()
                    viewerTab = .preview
                } label: {
                    Label("Preview", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(controller.isBusy)

                Button {
                    controller.scan()
                    viewerTab = .scan
                } label: {
                    Label("Scan", systemImage: "doc.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy)
            }

            HStack(spacing: 6) {
                Button {
                    controller.saveAgain()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(controller.isBusy || controller.processedPages.isEmpty)

                Button {
                    controller.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!controller.isBusy)
            }

            Toggle("Show log", isOn: $showLog)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.regular)
        .padding(8)
    }

    // MARK: Viewer column

    private var viewerColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $viewerTab) {
                    ForEach(ViewerTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                Spacer()

                if controller.processedPages.count > 1 {
                    HStack(spacing: 4) {
                        Button { controller.selectedPageIndex = max(0, controller.selectedPageIndex - 1); controller.reprocessNow() }
                            label: { Image(systemName: "chevron.left") }
                            .controlSize(.small)
                        Text("Page \(controller.selectedPageIndex + 1) of \(controller.processedPages.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button { controller.selectedPageIndex = min(controller.processedPages.count - 1, controller.selectedPageIndex + 1); controller.reprocessNow() }
                            label: { Image(systemName: "chevron.right") }
                            .controlSize(.small)
                    }
                }

                Text(imageSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            PreviewCanvas(
                controller: controller,
                image: viewerTab == .preview ? controller.previewImage : (controller.processedPreview ?? controller.previewImage),
                showCropOverlay: viewerTab == .preview
            )
        }
    }

    private var imageSummary: String {
        let image = viewerTab == .preview ? controller.previewImage : controller.processedPreview
        guard let image else { return "—" }
        return "\(image.width) × \(image.height) px"
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if controller.isBusy {
                ProgressView(value: controller.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
            }
            Text(controller.stage)
                .font(.system(size: 11))
                .foregroundStyle(controller.isBusy ? .primary : .secondary)

            Spacer()

            if let device = controller.selectedDevice {
                HStack(spacing: 5) {
                    Circle()
                        .fill(device.transport == .simulated ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(device.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No scanner")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct LogPane: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LOG")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { controller.clearLog() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.log) { entry in
                            HStack(alignment: .top, spacing: 5) {
                                Text(Self.time.string(from: entry.date))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(entry.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
                .onChange(of: controller.log.count) {
                    if let last = controller.log.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:    return .primary
        case .warn:    return .orange
        case .error:   return .red
        case .success: return .green
        }
    }
}
