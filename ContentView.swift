import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit

// MARK: - Color Processing Engine
class ColorProcessor {
    private let context: CIContext
    
    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        self.context = CIContext(mtlDevice: metalDevice!)
    }
    
    func processFrame(buffer: CVPixelBuffer,
                     red: Float,
                     green: Float,
                     blue: Float,
                     temperature: Float) -> CVPixelBuffer? {
        var outputBuffer: CVPixelBuffer?
        
        CVPixelBufferCreate(kCFAllocatorDefault,
                           CVPixelBufferGetWidth(buffer),
                           CVPixelBufferGetHeight(buffer),
                           CVPixelBufferGetPixelFormatType(buffer),
                           nil,
                           &outputBuffer)
        
        guard let output = outputBuffer else { return nil }
        
        let ciImage = CIImage(cvPixelBuffer: buffer)
        
        let processedImage = applyColorGrading(to: ciImage,
                                             red: red,
                                             green: green,
                                             blue: blue,
                                             temperature: temperature)
        
        context.render(processedImage,
                      to: output,
                      bounds: processedImage.extent,
                      colorSpace: CGColorSpaceCreateDeviceRGB())
        
        return output
    }
    
    private func applyColorGrading(to image: CIImage,
                                 red: Float,
                                 green: Float,
                                 blue: Float,
                                 temperature: Float) -> CIImage {
        let temperatureFilter = CIFilter.temperatureAndTint()
        temperatureFilter.inputImage = image
        temperatureFilter.neutral = CIVector(x: CGFloat(temperature), y: 0)
        
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = temperatureFilter.outputImage
        colorMatrix.rVector = CIVector(x: CGFloat(red), y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: CGFloat(green), z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(blue), w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        
        return colorMatrix.outputImage ?? image
    }
}

// MARK: - Video Player Manager
class VideoPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = true
    @Published var error: Error?
    
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private let colorProcessor = ColorProcessor()
    private var timeObserver: Any?
    
    @Published var red: Float = 1.0
    @Published var green: Float = 1.0
    @Published var blue: Float = 1.0
    @Published var temperature: Float = 6500.0
    
    func setupPlayer(with url: URL) -> AVPlayerLayer {
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp4"
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(playerItemDidReachEnd),
                                             name: .AVPlayerItemDidPlayToEndTime,
                                             object: playerItem)
        
        let videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: videoSettings)
        playerItem.add(videoOutput!)
        
        player = AVPlayer(playerItem: playerItem)
        playerLayer = AVPlayerLayer(player: player)
        playerLayer?.videoGravity = .resizeAspectFill
        
        playerItem.addObserver(self,
                             forKeyPath: "status",
                             options: [.new, .old],
                             context: nil)
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
        }
        
        asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self] in
            DispatchQueue.main.async {
                if asset.statusOfValue(forKey: "duration", error: nil) == .loaded {
                    self?.duration = asset.duration.seconds
                }
                self?.isLoading = false
            }
        }
        
        setupDisplayLink()
        
        return playerLayer!
    }
    
    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidUpdate))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func displayLinkDidUpdate() {
        guard let output = videoOutput,
              let player = player,
              player.rate > 0 else { return }
        
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        
        if let processedBuffer = colorProcessor.processFrame(buffer: pixelBuffer,
                                                           red: red,
                                                           green: green,
                                                           blue: blue,
                                                           temperature: temperature) {
            updateProcessedFrame(processedBuffer)
        }
    }
    
    private func updateProcessedFrame(_ buffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: buffer)
        if let cgImage = CIContext().createCGImage(image, from: image.extent) {
            DispatchQueue.main.async { [weak self] in
                self?.playerLayer?.contents = cgImage
            }
        }
    }
    
    override public func observeValue(forKeyPath keyPath: String?,
                                    of object: Any?,
                                    change: [NSKeyValueChangeKey : Any]?,
                                    context: UnsafeMutableRawPointer?) {
        if keyPath == "status",
           let playerItem = object as? AVPlayerItem {
            DispatchQueue.main.async { [weak self] in
                switch playerItem.status {
                case .readyToPlay:
                    self?.isLoading = false
                    self?.play()
                case .failed:
                    self?.isLoading = false
                    self?.error = playerItem.error
                default:
                    break
                }
            }
        }
    }
    
    @objc private func playerItemDidReachEnd() {
        seek(to: 0)
        play()
    }
    
    func play() {
        player?.play()
        isPlaying = true
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime)
    }
    
    deinit {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        displayLink?.invalidate()
    }
}

// MARK: - Color Slider View
struct ColorSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "%.1f", value))
                    .foregroundColor(.white.opacity(0.8))
                    .font(.system(.caption, design: .monospaced))
            }
            
            Slider(value: $value, in: range) { editing in
                if !editing {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .accentColor(color)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Video Player View
struct VideoPlayerView: UIViewRepresentable {
    @ObservedObject var playerManager: VideoPlayerManager
    let url: URL
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let playerLayer = playerManager.setupPlayer(with: url)
        view.layer.addSublayer(playerLayer)
        playerLayer.frame = view.bounds
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let playerLayer = uiView.layer.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = uiView.bounds
        }
    }
}

// MARK: - Content View
struct ContentView: View {
    @StateObject private var playerManager = VideoPlayerManager()
    
    private let videoURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                ZStack {
                    VideoPlayerView(playerManager: playerManager, url: videoURL)
                        .frame(height: UIScreen.main.bounds.height * 0.4)
                        .cornerRadius(16)
                    
                    if playerManager.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    }
                    
                    if let error = playerManager.error {
                        Text("Error: \(error.localizedDescription)")
                            .foregroundColor(.red)
                            .padding()
                    }
                }
                
                VStack(spacing: 16) {
                    ColorSlider(title: "Red", value: $playerManager.red, range: 0...2, color: .red)
                    ColorSlider(title: "Green", value: $playerManager.green, range: 0...2, color: .green)
                    ColorSlider(title: "Blue", value: $playerManager.blue, range: 0...2, color: .blue)
                    ColorSlider(title: "Temperature", value: $playerManager.temperature, range: 3000...9000, color: .yellow)
                    
                    HStack(spacing: 20) {
                        Button(playerManager.isPlaying ? "Pause" : "Play") {
                            if playerManager.isPlaying {
                                playerManager.pause()
                            } else {
                                playerManager.play()
                            }
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(8)
                        
                        Button("Reset") {
                            withAnimation {
                                playerManager.red = 1.0
                                playerManager.green = 1.0
                                playerManager.blue = 1.0
                                playerManager.temperature = 6500.0
                            }
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(8)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.5))
                .cornerRadius(16)
                
                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Preview Provider
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

