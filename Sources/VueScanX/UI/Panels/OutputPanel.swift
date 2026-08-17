import SwiftUI
import AppKit

struct OutputPanel: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Destination")

            OptionRow(label: "Default folder") {
                HStack(spacing: 4) {
                    Text(controller.settings.outputFolder.path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { chooseFolder() }
                        .controlSize(.small)
                }
            }

            OptionRow(label: "File name", help: "'+' auto-increments. %date and %time expand too.") {
                TextField("scan+.jpg", text: $controller.settings.fileNameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            OptionRow(label: "Next file") {
                Text(nextFilePreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            SectionHeader(title: "Formats")

            OptionToggle(label: "JPEG file", isOn: $controller.settings.writeJPEG)
            if controller.settings.writeJPEG {
                OptionSlider(label: "JPEG quality", value: $controller.settings.jpegQuality,
                             range: 0.2...1.0, step: 0.01, format: "%.2f")
            }
            OptionToggle(label: "TIFF file", isOn: $controller.settings.writeTIFF)
            if controller.settings.writeTIFF {
                OptionPicker(label: "TIFF compression", selection: $controller.settings.tiffCompression)
            }
            OptionToggle(label: "PNG file", isOn: $controller.settings.writePNG)
            OptionToggle(label: "PDF file", isOn: $controller.settings.writePDF)
            if controller.settings.writePDF {
                OptionToggle(label: "PDF multi page", isOn: $controller.settings.pdfMultiPage,
                             help: "One PDF containing every page from the feeder")
                OptionPicker(label: "PDF paper size", selection: $controller.settings.pdfPaperSize,
                             help: "Auto derives page size from pixel count ÷ dpi")
                OptionToggle(label: "Searchable PDF", isOn: $controller.settings.pdfSearchable,
                             help: "Runs OCR and embeds an invisible text layer")
            }

            SectionHeader(title: "Text recognition")

            OptionToggle(label: "OCR text file", isOn: $controller.settings.writeOCRText,
                         help: "Write a .txt sidecar with the recognised text")
            if controller.settings.writeOCRText || controller.settings.pdfSearchable {
                OptionChoice(label: "OCR language",
                             selection: $controller.settings.ocrLanguage,
                             options: ["en-US", "fr-FR", "de-DE", "es-ES", "it-IT",
                                       "pt-BR", "zh-Hans", "ja-JP", "ko-KR"],
                             title: { $0 })
            }

            SectionHeader(title: "After saving")

            OptionToggle(label: "Reveal in Finder", isOn: $controller.settings.revealInFinderAfterSave)

            if !controller.lastSavedFiles.isEmpty {
                SectionHeader(title: "Last saved")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.lastSavedFiles, id: \.self) { url in
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(url.lastPathComponent).lineLimit(1)
                            }
                            .font(.system(size: 10))
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.leading, 126)
            }

            Spacer(minLength: 8)
        }
    }

    private var nextFilePreview: String {
        let writer = OutputWriter(settings: controller.settings)
        let ext = firstEnabledExtension
        return writer.resolveName(template: controller.settings.fileNameTemplate,
                                  ext: ext, in: controller.settings.outputFolder)
            .lastPathComponent
    }

    private var firstEnabledExtension: String {
        let s = controller.settings
        if s.writeJPEG { return "jpg" }
        if s.writeTIFF { return "tif" }
        if s.writePNG  { return "png" }
        if s.writePDF  { return "pdf" }
        if s.writeOCRText { return "txt" }
        return "jpg"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller.settings.outputFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            controller.settings.outputFolder = url
        }
    }
}
