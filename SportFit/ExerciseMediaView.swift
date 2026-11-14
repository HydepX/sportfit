import SwiftUI
import AVKit

/// Add rights-cleared, reviewed media under Resources/media/<stable exercise ID>/.
/// No network downloads; missing assets always use the accessible placeholder.
struct ExerciseMediaView: View {
    let exerciseId: String
    @EnvironmentObject private var store: FitnessStore
    @State private var photo: UIImage?
    @State private var zooming = false
    @State private var scale: CGFloat = 1
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    private var videoURL: URL? {
        Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "media/\(exerciseId)")
    }
    var body: some View {
        VStack {
          Group {
            if let player { VideoPlayer(player: player) }
            else if let photo {
                Button { zooming = true } label: { Image(uiImage: photo).resizable().scaledToFit() }
                    .buttonStyle(.plain).accessibilityLabel("Открыть фото техники").accessibilityIdentifier("technique-photo")
            }
            else if let url = Bundle.main.url(forResource: "start", withExtension: "jpg", subdirectory: "media/\(exerciseId)"),
                    let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 58))
                    Text("Медиа пока нет — техника описана ниже").font(.caption)
                }.foregroundStyle(.mint).frame(maxWidth: .infinity)
            }
          }.frame(height: 210)
          HStack {
              ForEach(["start", "middle", "finish"], id: \.self) { position in
                  if let url = Bundle.main.url(forResource: position, withExtension: "jpg", subdirectory: "media/\(exerciseId)"),
                     let image = UIImage(contentsOfFile: url.path) {
                      Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                          .accessibilityLabel(position == "start" ? "Начальное положение" : position == "middle" ? "Движение" : "Конечное положение")
                  }
              }
          }
        }.background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityLabel("Техника упражнения")
            .sheet(isPresented: $zooming) {
                NavigationStack {
                    Group { if let photo { Image(uiImage: photo).resizable().scaledToFit().scaleEffect(scale)
                        .gesture(MagnificationGesture().onChanged { scale = min(4, max(1, $0)) }) } }
                        .navigationTitle(store.exercise(exerciseId)?.title ?? "Фото техники")
                        .navigationBarTitleDisplayMode(.inline).toolbar { Button("Готово") { zooming = false; scale = 1 } }
                }
            }
            .onAppear {
                photo = TechniquePhotos.image(exerciseId: exerciseId, descriptor: store.exercise(exerciseId)?.media?.photo)
                guard player == nil, let url = videoURL else { player?.play(); return }
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                queue.isMuted = true
                player = queue
                queue.play()
            }
            .onDisappear { player?.pause() }
    }
}

@MainActor enum TechniquePhotos {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(exerciseId: String, descriptor: ExercisePhoto?) -> UIImage? {
        guard let descriptor, descriptor.columns > 0, descriptor.rows > 0,
              descriptor.index >= 0, descriptor.index < descriptor.columns * descriptor.rows else { return nil }
        let key = (exerciseId + ":" + descriptor.asset + ":\(descriptor.columns):\(descriptor.rows):\(descriptor.index)") as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = Bundle.main.url(forResource: descriptor.asset, withExtension: nil, subdirectory: "media"),
              let original = UIImage(contentsOfFile: url.path) else { return nil }
        let image: UIImage
        if original.imageOrientation == .up { image = original }
        else {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            image = UIGraphicsImageRenderer(size: original.size, format: format).image { _ in original.draw(at: .zero) }
        }
        guard let source = image.cgImage else { return nil }
        let w = Double(source.width) / Double(descriptor.columns), h = Double(source.height) / Double(descriptor.rows)
        let rect = CGRect(x: floor(Double(descriptor.index % descriptor.columns) * w),
                          y: floor(Double(descriptor.index / descriptor.columns) * h), width: floor(w), height: floor(h))
        guard let crop = source.cropping(to: rect) else { return nil }
        let result = UIImage(cgImage: crop, scale: image.scale, orientation: image.imageOrientation)
        cache.countLimit = 64; cache.setObject(result, forKey: key)
        return result
    }
}
