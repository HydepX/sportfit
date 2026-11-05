import SwiftUI
import AVKit

/// Add rights-cleared, reviewed media under Resources/media/<stable exercise ID>/.
/// No network downloads; missing assets always use the accessible placeholder.
struct ExerciseMediaView: View {
    let exerciseId: String
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    private var videoURL: URL? {
        Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "media/\(exerciseId)")
    }
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else if let url = Bundle.main.url(forResource: "start", withExtension: "jpg", subdirectory: "media/\(exerciseId)"),
                    let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 58))
                    Text("Медиа пока нет — техника описана ниже").font(.caption)
                }.foregroundStyle(.mint).frame(maxWidth: .infinity)
            }
        }.frame(height: 210).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityLabel("Техника упражнения")
            .onAppear {
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
