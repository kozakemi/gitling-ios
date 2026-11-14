import AVKit
import PDFKit
import QuickLook
import SwiftUI
import UIKit

struct PreviewTextPage: View {
    @AppStorage("file.preview.lineNumbers") private var lineNumbers = true
    @Environment(\.dynamicTypeSize) private var textSize
    let state: WorkspacePreviewModel.TextState
    @Binding var markdownMode: PreviewMarkdownMode
    var localContext: MarkdownImageContext? = nil
    var choose: (PreviewTextEncoding) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PreviewEncodingBar(encoding: state.encoding, confidence: state.confidence, choose: choose)
                if state.encoding != nil, state.kind != .markdown || markdownMode == .source {
                    Button { lineNumbers.toggle() } label: {
                        Label("Line numbers", systemImage: lineNumbers ? "list.number" : "text.alignleft")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityValue(lineNumbers ? String(localized: "On") : String(localized: "Off"))
                    .accessibilityIdentifier("file.preview.line-numbers")
                }
            }
            .padding(.horizontal).padding(.bottom, 8)
            if state.kind == .markdown, state.encoding != nil, state.failure == nil {
                markdownPicker
                    .padding(.horizontal)

            }
            if let note = state.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("file.preview.note")
            }
            if let failure = state.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("file.preview.encoding.failure")
            } else if state.encoding == nil {
                ContentUnavailableView("Files", systemImage: "textformat", description: Text(state.prompt ?? ""))
                    .accessibilityIdentifier("file.preview.encoding.prompt")
            } else if state.kind == .markdown, markdownMode == .rendered {
                PreviewMarkdownView(markdown: state.text, localContext: localContext)
            } else {
                SourceTextView(text: state.text, spans: state.spans, lineNumbers: lineNumbers)
            }
        }
    }

    @ViewBuilder
    private var markdownPicker: some View {
        let picker = Picker("Markdown", selection: $markdownMode) {
            ForEach(PreviewMarkdownMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .accessibilityIdentifier("file.preview.markdown.mode")
        if textSize >= .xxxLarge {
            picker.pickerStyle(.menu)
        } else {
            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented)
                picker.pickerStyle(.menu)
            }
        }
    }
}

struct PreviewEncodingBar: View {
    var encoding: PreviewTextEncoding?
    var confidence: PreviewEncodingConfidence?
    var choose: (PreviewTextEncoding) -> Void

    var body: some View {
        Menu {
            ForEach(PreviewTextEncoding.allCases) { item in
                Button {
                    choose(item)
                } label: {
                    if item == encoding {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            Text(PreviewLabels.encodingCaption(encoding: encoding, confidence: confidence))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("file.preview.encoding")
    }
}

struct WorkspaceQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        // Quick Look owns navigation UI and its remote preview lifecycle. Give
        // it a UIKit navigation container rather than loading its view early.
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        guard let controller = navigation.viewControllers.first as? QLPreviewController else { return }
        guard context.coordinator.url != url || controller.dataSource == nil else { return }
        context.coordinator.url = url
        if controller.dataSource == nil { controller.dataSource = context.coordinator }
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            PreviewFileItem(url: url)
        }
    }
}

struct WorkspacePlayerPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: PreviewPlayback.asset(url)))
        player.actionAtItemEnd = .pause
        player.pause()
        controller.player = player
        context.coordinator.url = url
        controller.allowsPictureInPicturePlayback = false
        controller.loadViewIfNeeded()
        controller.view.accessibilityIdentifier = "file.preview.player"
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player == nil || context.coordinator.url != url {
            controller.player?.pause()
            controller.player?.replaceCurrentItem(with: nil)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: PreviewPlayback.asset(url)))
            player.pause()
            controller.player = player
            context.coordinator.url = url
        }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        controller.player?.replaceCurrentItem(with: nil)
        controller.player = nil
    }
    final class Coordinator { var url: URL? }
}

/// Pinch and double-tap zoom for one already-downsampled image.
/// The scroll view only scales that bitmap; it does not reopen the worktree file.
struct WorkspaceImagePreview: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PreviewImageCanvas {
        PreviewImageCanvas(image: image)
    }

    func updateUIView(_ view: PreviewImageCanvas, context: Context) {
        guard view.imageView.image !== image else { return }
        view.imageView.image = image
        view.resetFit()
    }
}

final class PreviewImageCanvas: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var fittedBounds = CGSize.zero
    private var fitting = false

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .secondarySystemBackground
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        imageView.image = image
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "file.preview.image"
        imageView.accessibilityLabel = String(localized: "Image preview")
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
        accessibilityIdentifier = "file.preview.zoom"
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !fitting, bounds.width > 1, bounds.height > 1 else { return }
        if bounds.size != fittedBounds, zoomScale <= minimumZoomScale + 0.01 {
            fittedBounds = bounds.size
            fitting = true
            fit()
            fitting = false
        }
        centerImage()
    }

    func resetFit() {
        fittedBounds = .zero
        setZoomScale(minimumZoomScale, animated: false)
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0, bounds.width > 1, bounds.height > 1 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        zoomScale = minimumZoomScale
    }

    private func centerImage() {
        let extraX = max(0, (bounds.width - contentSize.width) / 2)
        let extraY = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: extraY, left: extraX, bottom: extraY, right: extraX)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let next = min(maximumZoomScale, 3)
        let width = bounds.width / next
        let height = bounds.height / next
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
    }
}

/// Shows one validated PDF snapshot. PDFKit draws pages as they become visible.
struct WorkspacePDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .cropBox
        view.backgroundColor = .secondarySystemBackground
        view.accessibilityIdentifier = "file.preview.pdf"
        view.accessibilityLabel = String(localized: "PDF preview")
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
    }
}
