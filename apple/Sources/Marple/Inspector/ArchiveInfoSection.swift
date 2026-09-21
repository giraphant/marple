import SwiftUI
import AppKit
import MarpleKit

struct ArchiveInfoSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let manifest = model.openArchiveManifest {
                Text("档案原件").font(.headline)
                sourceLink(manifest.source)
                if !manifest.coverage.isEmpty {
                    Text(manifest.coverage).font(.callout).textSelection(.enabled)
                }
                if manifest.files.isEmpty {
                    Label("仅保存来源，未保存原件", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(manifest.files, id: \.path) { file in
                        let url = manifest.localURL(for: file, entryPath: model.openPath ?? "",
                                                    workspaceRoot: model.workspaceRoot)
                        Button {
                            model.previewAttachment(file.path)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: url == nil ? "exclamationmark.circle" : "doc")
                                Text((file.path as NSString).lastPathComponent)
                                    .lineLimit(2).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if url == model.attachmentPreviewURL && url != nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(url == nil)
                        .help(url == nil ? String(localized: "原件在本机不可用") : file.path)
                    }
                }
                if let file = model.selectedArchiveFile {
                    Divider()
                    Text("当前原件").font(.subheadline.bold())
                    sourceLink(manifest.source(for: file))
                    Text(file.mediaType).font(.caption).foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("保存时间", value: captureTime(file.capturedAt)).font(.caption)
                    if let download = URL(string: file.url), ["http", "https"].contains(download.scheme ?? "") {
                        Link("原件下载地址", destination: download).font(.caption)
                    }
                }
            } else if let error = model.archiveManifestError {
                Label("无法读取原件清单", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func sourceLink(_ source: ArchiveManifest.Source) -> some View {
        if let url = source.webURL {
            Link(destination: url) {
                Label(source.title ?? url.host ?? source.url, systemImage: "arrow.up.right.square")
                    .lineLimit(2)
            }
            .help(source.url)
        }
    }

    private func captureTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
