import PDFKit
import SwiftUI

struct PdfKitView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let scaleFactor: Double
    let verticalProgress: Double
    let requestedProgress: Double?
    let onPageChanged: (Int) -> Void
    let onProgressChanged: (Double) -> Void
    let onScaleChanged: (Double) -> Void
    let onTap: () -> Void
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
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: view
        )
        context.coordinator.attachScrollView(from: view)
        go(to: pageIndex, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        let boundsChanged = context.coordinator.lastBoundsSize != view.bounds.size
        context.coordinator.lastBoundsSize = view.bounds.size
        if view.document !== document {
            view.document = document
        }
        if abs(view.scaleFactor - scaleFactor) > 0.001 {
            context.coordinator.programmaticScaleFactor = CGFloat(scaleFactor)
            view.scaleFactor = scaleFactor
        }
        if let current = view.currentPage, document.index(for: current) != pageIndex {
            go(to: pageIndex, in: view)
        }
        let progressToApply = requestedProgress ?? (boundsChanged ? verticalProgress : nil)
        if
            let progressToApply,
            let scrollView = context.coordinator.scrollView,
            boundsChanged
                || context.coordinator.lastRequestedProgress.map({
                    abs($0 - progressToApply) > 0.000_1
                }) != false
        {
            context.coordinator.applyProgress(progressToApply, in: scrollView)
        } else if requestedProgress == nil {
            context.coordinator.lastRequestedProgress = nil
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.contentOffsetObservation = nil
        coordinator.contentSizeObservation = nil
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
        var contentSizeObservation: NSKeyValueObservation?
        var lastRequestedProgress: Double?
        var pendingProgress: Double?
        var lastBoundsSize = CGSize.zero
        var programmaticScaleFactor: CGFloat?

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
                contentSizeObservation = scroll.observe(\.contentSize, options: [.new]) {
                    [weak self] scrollView, _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let pendingProgress = self.pendingProgress else { return }
                        self.applyProgress(pendingProgress, in: scrollView)
                    }
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

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { parent.onTap() }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard
                let view = notification.object as? PDFView,
                let page = view.currentPage,
                let document = view.document
            else { return }
            parent.onPageChanged(document.index(for: page))
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard
                let view = notification.object as? PDFView,
                view.scaleFactor.isFinite
            else { return }
            if
                let programmaticScaleFactor,
                abs(view.scaleFactor - programmaticScaleFactor) < 0.001
            {
                self.programmaticScaleFactor = nil
                return
            }
            programmaticScaleFactor = nil
            parent.onManualInteraction()
            parent.onScaleChanged(Double(view.scaleFactor))
        }

        func applyProgress(_ progress: Double, in scrollView: UIScrollView) {
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            guard maximum > 0 || progress == 0 else {
                pendingProgress = progress
                return
            }
            pendingProgress = nil
            lastRequestedProgress = progress
            isProgrammatic = true
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: maximum * progress),
                animated: false
            )
            isProgrammatic = false
        }

        private func reportProgress(_ scrollView: UIScrollView) {
            guard !isProgrammatic else { return }
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
