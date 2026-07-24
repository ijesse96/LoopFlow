import SwiftUI
import UIKit

struct BarRulerView: View {
    @ObservedObject var vm: ProjectViewModel

    @State private var loopDragOriginStart: Int?
    @State private var lastSnappedBeat: Int?
    @State private var scrubOriginBeats: Double?

    private var loopOn: Bool { vm.project.loopEnabled }
    private var rulerHeight: CGFloat { ArrangeMetrics.rulerHeight(loopEnabled: loopOn) }
    private var loopBandHeight: CGFloat { ArrangeMetrics.loopBandHeight(loopEnabled: loopOn) }
    private var totalBars: Int { max(1, vm.project.totalBars) }
    private var width: CGFloat { CGFloat(totalBars) * vm.pixelsPerBar }

    var body: some View {
        let sel = vm.project.currentRegion
        let selX = CGFloat(sel.startBar - 1) * vm.pixelsPerBar
        let selW = CGFloat(sel.lengthBars) * vm.pixelsPerBar
        let playheadX = vm.xPosition(forBeats: vm.project.secondsToBeats(vm.playheadSeconds))
        let capH = ArrangeMetrics.playheadCapHeight

        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(AppTheme.surface)
                )
                let labelY = loopOn ? (capH + loopBandHeight / 2) : (size.height / 2)
                let lineTop: CGFloat = loopOn ? capH : 0
                for bar in 0..<totalBars {
                    let x = CGFloat(bar) * vm.pixelsPerBar
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: lineTop))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(AppTheme.gridLine), lineWidth: 1)
                    let label = Text("\(bar + 1)")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                    context.draw(label, at: CGPoint(x: x + 4, y: labelY), anchor: .leading)
                }
            }

            if loopOn {
                // Selection band — hit target scoped to the loop window only.
                Rectangle()
                    .fill(AppTheme.regionHighlight)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(AppTheme.record.opacity(0.85))
                            .frame(height: 2)
                    }
                    .frame(width: max(selW, 4), height: loopBandHeight)
                    .offset(x: selX, y: capH)
                    .contentShape(Rectangle())
                    .gesture(loopBandDrag)
                    .zIndex(1)

                // Handles above the band so they receive drags.
                moveHandle(x: selX, y: capH + loopBandHeight / 2)
                moveHandle(x: selX + selW, y: capH + loopBandHeight / 2)
            }

            PlayheadHandleView()
                .frame(width: 44, height: max(capH + 8, rulerHeight))
                .contentShape(Rectangle())
                .position(x: playheadX, y: loopOn ? capH / 2 : rulerHeight / 2)
                .highPriorityGesture(playheadDrag)
                .zIndex(10)
        }
        .frame(width: width, height: rulerHeight)
        .animation(.easeInOut(duration: 0.15), value: loopOn)
    }

    private func moveHandle(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(AppTheme.accent)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
            .frame(width: 44, height: max(loopBandHeight, 1))
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .highPriorityGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if loopDragOriginStart == nil {
                            loopDragOriginStart = vm.project.selectionStartBar
                        }
                        let barDelta = Int((value.translation.width / vm.pixelsPerBar).rounded())
                        let origin = loopDragOriginStart ?? vm.project.selectionStartBar
                        vm.moveLoopSelection(toStartBar: origin + barDelta, commit: false)
                    }
                    .onEnded { _ in
                        loopDragOriginStart = nil
                        vm.endLoopSelectionDrag()
                    }
            )
            .zIndex(5)
    }

    private var playheadDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if scrubOriginBeats == nil {
                    scrubOriginBeats = vm.project.secondsToBeats(vm.playheadSeconds)
                }
                let originBeats = scrubOriginBeats ?? 0
                // Dampened scrub: finger must travel farther for the same timeline move
                let dampedDeltaX = value.translation.width * ArrangeMetrics.playheadScrubGain
                let beatDelta = vm.beats(atX: abs(dampedDeltaX)) * (dampedDeltaX < 0 ? -1 : 1)
                var target = originBeats + beatDelta
                if vm.project.snapEnabled {
                    target = vm.snapBeats(target)
                    let step = max(vm.snapStepBeats, 0.000_1)
                    let stepIndex = Int((target / step).rounded())
                    if lastSnappedBeat != stepIndex {
                        lastSnappedBeat = stepIndex
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                vm.scrubPlayhead(toBeats: max(0, target))
            }
            .onEnded { _ in
                scrubOriginBeats = nil
                lastSnappedBeat = nil
            }
    }

    private var loopBandDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if loopDragOriginStart == nil {
                    loopDragOriginStart = vm.project.selectionStartBar
                }
                if abs(value.translation.width) > 8 {
                    let barDelta = Int((value.translation.width / vm.pixelsPerBar).rounded())
                    let origin = loopDragOriginStart ?? vm.project.selectionStartBar
                    vm.moveLoopSelection(toStartBar: origin + barDelta, commit: false)
                }
            }
            .onEnded { _ in
                vm.endLoopSelectionDrag()
                loopDragOriginStart = nil
            }
    }
}

/// White inverted triangle scrubber — visually distinct from orange loop handles.
struct PlayheadHandleView: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(AppTheme.playhead)
                .frame(width: 14, height: 10)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            Rectangle()
                .fill(AppTheme.playhead)
                .frame(width: 2, height: 6)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
