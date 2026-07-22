import SwiftUI

/// Composites the watch skin artwork (case + hour/minute hand images) with
/// the e-ink face at fixed hand angles. All layers share the same frame and
/// centre, so hands rotate about the dial pivot (see WatchSkinStore).
struct WatchCompositeView: View {
    @ObservedObject var skin: WatchSkinStore
    let face: UIImage?
    var hourAngle: Double = 0
    var minuteAngle: Double = 0
    

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Portrait art is aspect-fit into a square, so its displayed
            // width is narrower than `side`; the face is sized from that.
            let aspect = skin.caseImage.map { min($0.size.width / $0.size.height, 1) } ?? 1
            let faceSize = side * aspect * skin.faceDiameterFraction
            ZStack {
                // Case first, then the e-ink face in the dial (rounded,
                // centred on the hand pivot), then the hands on top.
                layer(skin.caseImage, side: side)
                if let face {
                    Image(uiImage: face)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: faceSize, height: faceSize)
                        .clipShape(Circle())
                }
                layer(skin.hourHandImage, side: side)
                    .rotationEffect(.degrees(hourAngle))
                layer(skin.minuteHandImage, side: side)
                    .rotationEffect(.degrees(minuteAngle))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func layer(_ image: UIImage?, side: CGFloat) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
        }
    }
}
