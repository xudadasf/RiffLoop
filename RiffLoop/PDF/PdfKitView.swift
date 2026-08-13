import PDFKit
import SwiftUI

struct PdfKitView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let scaleFactor: Double
    let requestedProgress: Double?
    let onPageChanged: (Int) -> Void
    let onProgressChanged: (Double) -> Void
    let onManualInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .black
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = false
        view.minScaleFactor = 0.75
        view.maxScaleFactor = 2.5
        view.document = document
        view.scaleFactor = scaleFactor
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didPan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        context.coordinator.attachScrollView(from: view)
        go(to: pageIndex, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document {
            view.document = document
        }
        if abs(view.scaleFactor - scaleFactor) > 0.001 {
            view.scaleFactor = scaleFactor
        }
        if let current = view.currentPage, document.index(for: current) != pageIndex {
            go(to: pageIndex, in: view)
        }
        if let requestedProgress, let scrollView = context.coordinator.scrollView {
            context.coordinator.isProgrammatic = true
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: maximum * requestedProgress),
                animated: true
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                context.coordinator.isProgrammatic = false
            }
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.contentOffsetObservation = nil
    }

    private func go(to index: Int, in view: PDFView) {
        guard let page = document.page(at: min(max(index, 0), max(0, document.pageCount - 1))) else {
            return
        }
        view.go(to: page)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PdfKitView
        weak var scrollView: UIScrollView?
        var isProgrammatic = false
        var contentOffsetObservation: NSKeyValueObservation?

        init(parent: PdfKitView) {
            self.parent = parent
        }

        func attachScrollView(from view: UIView) {
            if let scroll = view as? UIScrollView {
                scrollView = scroll
                contentOffsetObservation = scroll.observe(\.contentOffset, options: [.new]) {
                    [weak self] scrollView, _ in
                    self?.reportProgress(scrollView)
                }
                return
            }
            for subview in view.subviews {
                attachScrollView(from: subview)
                if scrollView != nil { return }
            }
        }

        @objc func didPan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { parent.onManualInteraction() }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard
                let view = notification.object as? PDFView,
                let page = view.currentPage,
                let document = view.document
            else { return }
            parent.onPageChanged(document.index(for: page))
        }

        private func reportProgress(_ scrollView: UIScrollView) {
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let progress = maximum > 0
                ? Double(scrollView.contentOffset.y / maximum)
                : 0
            DispatchQueue.main.async { [weak self] in
                self?.parent.onProgressChanged(min(max(progress, 0), 1))
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
