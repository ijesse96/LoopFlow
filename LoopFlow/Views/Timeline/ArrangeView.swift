import SwiftUI

/// BandLab-style arrange: track headers on the left, timeline lanes on the right, row-aligned.
struct ArrangeView: View {
    @ObservedObject var vm: ProjectViewModel

    @State private var pinchStartPixels: CGFloat = 64
    @GestureState private var magnify: CGFloat = 1

    private var contentHeight: CGFloat {
        ArrangeMetrics.rulerHeight(loopEnabled: vm.project.loopEnabled)
            + ArrangeMetrics.laneHeight * CGFloat(vm.project.tracks.count)
    }

    private var timelineWidth: CGFloat {
        CGFloat(max(1, vm.project.totalBars)) * vm.pixelsPerBar
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    leftRail
                        .frame(width: ArrangeMetrics.headerWidth)

                    Rectangle()
                        .fill(AppTheme.accent.opacity(0.85))
                        .frame(width: 2)
                        .frame(height: max(contentHeight, geo.size.height))

                    ScrollView(.horizontal, showsIndicators: true) {
                        TimelineView(vm: vm)
                            .frame(
                                width: max(geo.size.width - ArrangeMetrics.headerWidth - 2, timelineWidth),
                                height: max(contentHeight, geo.size.height),
                                alignment: .topLeading
                            )
                    }
                    .simultaneousGesture(pinchZoom)
                    .frame(maxWidth: .infinity)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .background(AppTheme.background)
        .sheet(isPresented: Binding(
            get: { vm.timelineInteraction.showEditSheet && vm.timelineInteraction.selectedClipId != nil },
            set: { if !$0 { vm.timelineInteraction.showEditSheet = false } }
        )) {
            RegionEditSheet(vm: vm)
        }
    }

    private var pinchZoom: some Gesture {
        MagnificationGesture()
            .updating($magnify) { value, state, _ in
                state = value
            }
            .onChanged { value in
                if magnify == 1, value != 1 {
                    pinchStartPixels = vm.pixelsPerBar
                }
                let start = pinchStartPixels == 0 ? vm.pixelsPerBar : pinchStartPixels
                let playheadBeats = vm.project.secondsToBeats(vm.playheadSeconds)
                vm.setPixelsPerBar(start * value, anchorBeats: playheadBeats)
            }
            .onEnded { _ in
                pinchStartPixels = vm.pixelsPerBar
            }
    }

    private var leftRail: some View {
        VStack(spacing: 0) {
            Button {
                vm.addTrack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Track")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            }
            .frame(height: ArrangeMetrics.rulerHeight(loopEnabled: vm.project.loopEnabled))
            .background(AppTheme.surface)

            List {
                ForEach(Array(vm.project.tracks.indices), id: \.self) { index in
                    let track = vm.project.tracks[index]
                    TrackHeaderView(
                        track: Binding(
                            get: { vm.project.tracks[index] },
                            set: { vm.updateTrack($0) }
                        ),
                        isSelected: vm.project.selectedTrackId == track.id,
                        isRecordingHere: vm.project.selectedTrackId == track.id
                            && vm.recording.phase != .idle
                            && track.type != .instrumental,
                        monitorBlockedByRoute: track.inputMonitorEnabled
                            && !vm.audio.isHeadphoneOrBluetoothOutput,
                        showInputMeter: (track.inputMonitorEnabled
                            || (vm.project.selectedTrackId == track.id && vm.recording.phase != .idle))
                            && (track.type == .vocal || track.type == .audio),
                        inputLevel: vm.audio.inputLevel,
                        onSelect: {
                            vm.selectTrack(id: track.id)
                            vm.selectClip(nil)
                        },
                        onToggleInputMonitor: { enabled in
                            vm.setInputMonitor(trackId: track.id, enabled: enabled)
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .frame(height: ArrangeMetrics.laneHeight)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            vm.deleteTrack(id: track.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: ArrangeMetrics.laneHeight * CGFloat(vm.project.tracks.count))
            .environment(\.defaultMinListRowHeight, ArrangeMetrics.laneHeight)
        }
        .frame(width: ArrangeMetrics.headerWidth, alignment: .top)
        .background(AppTheme.surface)
    }
}
