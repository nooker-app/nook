// Appended to the copied canvas by build.py so the demo can use its exact camera.
// None of these navigation experiments alter the shipping canvas.
struct DemoCameraPosition {
    var zoom: Double
    var pan: CGPoint
    var orbit: RecommendationOrbit
    var center: CGPoint
    var centerDepth: Double
}

extension RecommendationCanvasView {
    var demoFitZoom: Double {
        let box = demoNavigationBounds
        return max(0.018, min(1.1, min(max(100, bounds.width - 140) / max(1, box.width),
                                    max(100, bounds.height - 180) / max(1, box.height))))
    }
    private var demoCameraPosition: DemoCameraPosition {
        DemoCameraPosition(zoom: zoom, pan: pan, orbit: orbit,
                           center: projectionCenter, centerDepth: projectionCenterDepth)
    }
    func demoRememberCamera() {
        guard firstFit else { return }
        let current = demoCameraPosition
        if let last = demoCameraHistory.last,
           abs(last.zoom - current.zoom) < 0.0001,
           hypot(last.pan.x-current.pan.x, last.pan.y-current.pan.y) < 2,
           abs(last.orbit.yaw-current.orbit.yaw) < 0.001,
           abs(last.orbit.pitch-current.orbit.pitch) < 0.001 { return }
        demoCameraHistory.append(current)
        if demoCameraHistory.count > 20 { demoCameraHistory.removeFirst() }
    }
    func demoBack() {
        guard let saved = demoCameraHistory.popLast() else { return }
        momentum = .zero; orbitVelocity = .zero; cameraAnimation = nil
        orbit = saved.orbit; projectionCenter = saved.center; projectionCenterDepth = saved.centerDepth
        projectionDirty = true; updateProjection()
        setCamera(zoom: saved.zoom, pan: saved.pan, animated: false)
        demoConstrainNavigation()
        needsDisplay = true
    }
    func demoFit() {
        demoRememberCamera(); orbitVelocity = .zero; fit(animated: true)
    }
    func demoResetDirection() {
        demoRememberCamera(); orbitVelocity = .zero; momentum = .zero
        orbit = RecommendationOrbit(); projectionDirty = true
        fit(animated: true)
    }
    func demoFocus() {
        guard let selected else { return }
        demoRememberCamera(); orbitVelocity = .zero; momentum = .zero
        updateProjection()
        // Keep the established orbit pivot. Frame the selected neighborhood
        // instead of jumping to a fixed zoom that loses all surrounding stories.
        var box = CGRect(origin: projected[selected].point, size: .zero)
        for i in neighbors.prefix(12) { box = box.union(CGRect(origin: projected[i].point, size: .zero)) }
        let padding = max(180, 75 / max(0.02, demoFitZoom * 3))
        box = box.insetBy(dx: -padding, dy: -padding)
        let scale = min((bounds.width - 180) / max(1, box.width), (bounds.height - 180) / max(1, box.height))
        animateCamera(to: max(demoFitZoom, min(demoFitZoom * 4, scale)),
                      center: CGPoint(x: box.midX, y: box.midY))
    }
    func demoZoom(_ factor: Double) {
        demoRememberCamera()
        zoomBy(factor, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
        demoConstrainNavigation()
    }
    func demoNavigate(to normalized: CGPoint, remember: Bool) {
        if remember { demoRememberCamera() }
        orbitVelocity = .zero; momentum = .zero; cameraAnimation = nil
        updateProjection()
        let box = demoNavigationBounds
        let requested = CGPoint(x: box.minX + min(1, max(0, normalized.x)) * box.width,
                                y: box.minY + min(1, max(0, normalized.y)) * box.height)
        // The overview is a navigator for stories, not empty space. A click
        // between clusters lands at the nearest actual story, keeping context
        // in the center instead of leaving a single marker at the screen edge.
        let point = demoOverviewPoints.min { a, b in
            hypot(a.x-requested.x, a.y-requested.y) < hypot(b.x-requested.x, b.y-requested.y)
        } ?? requested
        setCamera(zoom: zoom, pan: CGPoint(x: bounds.midX-point.x*zoom, y: bounds.midY-point.y*zoom), animated: false)
        demoConstrainNavigation()
    }
    private func demoRefreshNavigationGeometry() {
        demoNavigationBounds = projectedBounds
        let step = max(1, Int(ceil(Double(projected.count) / 600)))
        demoOverviewPoints = stride(from: 0, to: projected.count, by: step).map { projected[$0].point }
    }
    private func demoConstrainNavigation() {
        guard spatial, !nodes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        updateProjection()
        let previous = pan
        let box = demoNavigationBounds
        let inset = min(90, min(bounds.width, bounds.height) * 0.15)
        pan.x = min(bounds.width - inset - box.minX * zoom, max(inset - box.maxX * zoom, pan.x))
        pan.y = min(bounds.height - inset - box.minY * zoom, max(inset - box.maxY * zoom, pan.y))
        let visible = CGRect(x: (inset-pan.x)/zoom, y: (inset-pan.y)/zoom, width: (bounds.width-2*inset)/zoom, height: (bounds.height-2*inset)/zoom)
        let hasContent = demoOverviewPoints.contains { visible.contains($0) } || projectedIndex.query(visible).contains { visible.contains(projected[$0].point) }
        let currentScale = zoom, offset = pan, canvasSize = bounds.size
        if !hasContent, let closest = demoOverviewPoints.min(by: { a, b in
            func distance(_ p: CGPoint) -> Double {
                let q = CGPoint(x: p.x*currentScale+offset.x, y: p.y*currentScale+offset.y)
                let dx = max(inset-q.x, 0, q.x-(canvasSize.width-inset))
                let dy = max(inset-q.y, 0, q.y-(canvasSize.height-inset))
                return dx*dx+dy*dy
            }
            return distance(a) < distance(b)
        }) {
            let q = screen(closest)
            pan.x += min(bounds.width-inset, max(inset, q.x)) - q.x
            pan.y += min(bounds.height-inset, max(inset, q.y)) - q.y
        }
        // Stop inertial drift at the boundary, rather than continuing to push
        // against it after the user has released the trackpad.
        if abs(pan.x-previous.x) > 0.5 { momentum.x = 0 }
        if abs(pan.y-previous.y) > 0.5 { momentum.y = 0 }
    }
    private func demoPublishOverview() {
        guard !demoOverviewQueued else { return }
        demoOverviewQueued = true
        let delay = max(0, 0.05 - (CACurrentMediaTime() - demoOverviewPublished))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.demoOverviewQueued = false
            self.demoOverviewPublished = CACurrentMediaTime()
            let box = self.demoNavigationBounds
            guard box.width > 0, box.height > 0 else { return }
            func normalize(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x-box.minX)/box.width, y: (p.y-box.minY)/box.height)
            }
            let viewport = CGRect(x: -self.pan.x/self.zoom, y: -self.pan.y/self.zoom,
                                  width: self.bounds.width/self.zoom, height: self.bounds.height/self.zoom)
            let snapshot = DemoOverviewSnapshot(points: self.demoOverviewPoints.map(normalize),
                viewport: CGRect(origin: normalize(viewport.origin),
                    size: CGSize(width: viewport.width/box.width, height: viewport.height/box.height)),
                selected: self.selected.map { normalize(self.projected[$0].point) },
                canGoBack: !self.demoCameraHistory.isEmpty,
                percent: Int((self.zoom/self.demoFitZoom*100).rounded()))
            self.onDemoOverview?(snapshot)
        }
    }
}
