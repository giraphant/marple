import SwiftUI
import WebKit
import AVKit
import Quartz
import MarpleKit

struct AttachmentPreview: View {
    let url: URL
    var mediaType: String? = nil
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("无法预览此文件", systemImage: "doc.questionmark",
                                       description: Text(error))
            } else if LocalAttachment.previewKind(url, mediaType: mediaType) == .webarchive {
                WebArchivePreview(url: url, onError: { error = $0 })
            } else if LocalAttachment.previewKind(url, mediaType: mediaType) == .media {
                LocalMediaPreview(url: url)
            } else if LocalAttachment.previewKind(url, mediaType: mediaType) == .unsupported {
                ContentUnavailableView {
                    Label("此格式请在外部打开", systemImage: "doc")
                } actions: {
                    Button("在外部打开") { NSWorkspace.shared.open(url) }
                }
            } else {
                QuickLookAttachmentPreview(url: url)
            }
        }
    }
}

/// WebKit reads the archive and its embedded resources directly. A snapshot is
/// a document, so scripts stay disabled and clicked web links open in the browser.
struct WebArchivePreview: NSViewRepresentable {
    let url: URL
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onError: onError) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadFileURL(url, allowingReadAccessTo: url)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.pauseAllMediaPlayback()
        view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let url: URL
        let onError: (String) -> Void
        init(url: URL, onError: @escaping (String) -> Void) {
            self.url = url
            self.onError = onError
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated, ["https", "http"].contains(target.scheme ?? "") {
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
            } else {
                decisionHandler(target.isFileURL && target.path == url.path ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }
    }
}

struct LocalMediaPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url) // Opening an attachment never autoplays.
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
    }
}

private struct QuickLookAttachmentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
