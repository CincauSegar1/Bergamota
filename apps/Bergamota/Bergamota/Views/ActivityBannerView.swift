import SwiftUI

struct ActivityBannerView: View {
    @Environment(AppModel.self) private var model
    var big = false
    /// Control Plane layout scale (fits an iPad Sidecar display); 1 elsewhere.
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let b = model.activityBanner(now: ctx.date)
            let dark = [Color.yellow, .orange, .cyan, .green].contains(b.color)
            let fg: Color = dark ? .black : .white
            HStack(spacing: (big ? 28 : 16) * scale) {
                Image(systemName: b.symbol).font(.system(size: (big ? 84 : 34) * scale, weight: .bold))
                VStack(alignment: .leading, spacing: (big ? 8 : 2) * scale) {
                    Text(b.title).font(.system(size: (big ? 64 : 30) * scale, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.4)
                    if !b.subtitle.isEmpty {
                        Text(b.subtitle).font(.system(size: (big ? 28 : 14) * scale, weight: .semibold)).lineLimit(2).opacity(0.85)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(fg)
            .padding((big ? 24 : 16) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: big ? 28 : 14)
                if let p = b.progress {
                    // progress bar: dimmed track, the filled part in the banner colour
                    ZStack(alignment: .leading) {
                        shape.fill(b.color.opacity(0.35))
                        GeometryReader { g in
                            Rectangle().fill(b.color.gradient).frame(width: g.size.width * max(0, min(1, p)))
                                .animation(.linear(duration: 1), value: p)
                        }
                    }
                    .clipShape(shape)
                } else {
                    shape.fill(b.color.gradient)
                }
            }
            .modifier(StateFlash(key: (b.progress == nil ? b.title : b.symbol) + "|\(b.color)", radius: big ? 28 : 14))  // percent ticks are not a state change
            .accessibilityElement(children: .combine)
        }
    }
}

/// A ray of light sweeps across the banner whenever its state changes (title or colour), so a
/// change is noticed from across the room. Elapsed-time updates in the subtitle don't count.
private struct StateFlash: ViewModifier {
    let key: String
    let radius: CGFloat
    @State private var phase: CGFloat = -1      // -1: ray left of the banner, 1: right of it
    @State private var showing = false
    @State private var seen: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width, band = max(120, w * 0.18)
                    LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                           .init(color: .white.opacity(0.75), location: 0.5),
                                           .init(color: .white.opacity(0), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band, height: geo.size.height * 2)
                        .rotationEffect(.degrees(20))
                        .offset(x: (phase + 1) / 2 * (w + band * 2) - band * 1.5, y: -geo.size.height / 2)
                        .blendMode(.plusLighter)
                        .opacity(showing ? 1 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .allowsHitTesting(false)
            }
            .onAppear { seen = key }
            .onChange(of: key) { _, new in
                guard seen != nil, seen != new else { seen = new; return }
                seen = new
                Task { @MainActor in
                    for _ in 0..<2 {
                        phase = -1      // snap back without animation, let it render, then sweep
                        showing = true
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        withAnimation(.easeInOut(duration: 0.9)) { phase = 1 }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    showing = false
                    phase = -1
                }
            }
    }
}
