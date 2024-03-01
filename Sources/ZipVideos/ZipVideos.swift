import Foundation
import AVKit

public protocol VideoEditorDelegate: AnyObject {
    
    func zipVideoUpdate(_ progress: Float, uuid ofVideoUUID: String)
    
}

public final class VideoEditor {
    
    public var assetReaders: [AVAssetReader] = []
    public var assetWriters: [AVAssetWriter] = []
    
    /// Compress a video URL to H264 in mp4 format
    /// - Parameters:
    ///   - asset: video asset to compress
    ///   - uuID: unique id to identify progress of each video
    ///   - delegate: to handle progress
    ///   - URL: new compressed video url
    public func compressVideo(_ asset: AVAsset,
                              uuID: String?,
                              delegate: VideoEditorDelegate?,
                              bitrate: NSNumber = NSNumber(value: 6000000)) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            compressVideo(asset,
                          uuID: uuID,
                          delegate: delegate,
                          bitrate: bitrate) { result in
                continuation.resume(with: result)
            }
        }
    }
    
    /// Compress a video URL to H264 in mp4 format
    /// - Parameters:
    ///   - asset: video asset to compress
    ///   - uuID: unique id to identify progress of each video
    ///   - delegate: to handle progress
    ///   - completion: new compressed video url
    public func compressVideo(_ asset: AVAsset,
                              uuID: String?,
                              delegate: VideoEditorDelegate?,
                              bitrate: NSNumber = NSNumber(value: 6000000),
                              completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global().async {
            //Patch for iCloud videos
            guard let videoData = asset.dataToUpload,
                  let asset = self.avAssetFrom(data: videoData) else {
                completion(.failure(Errors.nilAVAssetData))
                return
            }
            
            guard let reader = try? AVAssetReader(asset: asset) else {
                completion(.failure(Errors.nilAssetReader))
                return
            }
            self.assetReaders.append(reader) //To prevent reader being release while reading
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                completion(.failure(Errors.nilVideoTrack))
                return
            }
            let videoReaderSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
            let assetReaderVideoOutput = AVAssetReaderTrackOutput(track: videoTrack,
                                                                  outputSettings: videoReaderSettings)
            
            guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
                completion(.failure(Errors.failToAddAudio))
                return
            }
            
            let audioReaderSettings: [String : Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
            let assetReaderAudioOutput = AVAssetReaderTrackOutput(track: audioTrack,
                                                                  outputSettings: audioReaderSettings)
            guard reader.canAdd(assetReaderAudioOutput) else {
                completion(.failure(Errors.failToAddAudio))
                return
            }
            reader.add(assetReaderAudioOutput)
            
            guard reader.canAdd(assetReaderVideoOutput) else {
                completion(.failure(Errors.failToAddVideo))
                return
            }
            reader.add(assetReaderVideoOutput)
            
            let videoSettings: [String : Any] = [
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoHeightKey: videoTrack.naturalSize.height,
                AVVideoWidthKey: videoTrack.naturalSize.width,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill
            ]
            
            let audioSettings: [String:Any] = [AVFormatIDKey : kAudioFormatMPEG4AAC,
                                       AVNumberOfChannelsKey : 2,
                                             AVSampleRateKey : 44100.0,
                                          AVEncoderBitRateKey: 128000
            ]
            
            let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio,
                                                outputSettings: audioSettings)
            let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video,
                                                outputSettings: videoSettings)
            videoInput.transform = videoTrack.preferredTransform
            
            let videoInputQueue = DispatchQueue(label: "videoQueue")
            let audioInputQueue = DispatchQueue(label: "audioQueue")
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
            let date = Date()
            let tempDir = NSTemporaryDirectory()
            let outputPath = "\(tempDir)/\(formatter.string(from: date)).mp4"
            let outputURL = URL(fileURLWithPath: outputPath)
            
            guard let writer = try? AVAssetWriter(outputURL: outputURL,
                                                  fileType: AVFileType.mp4) else {
                completion(.failure(Errors.nilAssetWriter))
                return
            }
            self.assetWriters.append(writer) //To prevent writer being release while writing
            writer.shouldOptimizeForNetworkUse = true
            writer.add(videoInput)
            writer.add(audioInput)
            
            writer.startWriting()
            reader.startReading()
            writer.startSession(atSourceTime: CMTime.zero)
            
            let closeWriter: () -> Void = {
                Task {
                    await writer.finishWriting()
                    do {
                        let data = try Data(contentsOf: writer.outputURL)
                        //TODO: track file size
                        print("compressFile -file size after compression: \(Double(data.count / 1048576)) mb")
                    } catch {
                        completion(.failure(error))
                        return
                    }
                    completion(.success(writer.outputURL))
                    writer.cancelWriting()
                    self.assetWriters = self.assetWriters.filter { $0.outputURL != outputURL }
                    self.assetReaders = self.assetReaders.filter { $0.asset != asset }
                }
            }
            
            let group = DispatchGroup()
            
            group.enter()
            self.processAsset(input: audioInput,
                              reader: reader,
                              queue: audioInputQueue,
                              group: group,
                              trackOutput: assetReaderAudioOutput,
                              asset: asset)
            
            let progressHandler: (Float) -> () = { progress in
                guard let uuID = uuID else {
                    //TODO: handle error
                    return
                }
                delegate?.zipVideoUpdate(progress, uuid: uuID)
            }
            
            group.enter()
            self.processAsset(input: videoInput,
                              reader: reader,
                              queue: videoInputQueue,
                              group: group,
                              trackOutput: assetReaderVideoOutput,
                              asset: asset,
                              progress: progressHandler)
            
            group.notify(queue: .global()) {
                closeWriter()
            }
        }
    }
    
}

// MARK: - Private

extension VideoEditor {
    
    private func processAsset(input: AVAssetWriterInput,
                              reader: AVAssetReader,
                              queue: DispatchQueue,
                              group: DispatchGroup,
                              trackOutput: AVAssetReaderTrackOutput,
                              asset: AVAsset,
                              progress: ((Float) -> ())? = nil) {
        input.requestMediaDataWhenReady(on: queue) {
            while(input.isReadyForMoreMediaData) {
                guard let cmSampleBuffer = trackOutput.copyNextSampleBuffer() else {
                    switch reader.status {
                    case .completed:
                        input.markAsFinished()
                        group.leave()
                    case  .failed, .cancelled:
                        if let _ = reader.error {
                            //TODO: handle error
                        } else {
                            //TODO: handle error
                        }
                        input.markAsFinished()
                        group.leave()
                    case .reading:
                        //TODO: handle error
                        break
                    case .unknown:
                        //TODO: handle error
                        break
                    @unknown default:
                        //TODO: handle error
                        break
                    }
                    return
                }
                
                input.append(cmSampleBuffer)
                
                if let progress = progress {
                    let assetDuration = CMTimeGetSeconds(asset.duration)
                    let timeStamp = CMSampleBufferGetPresentationTimeStamp(cmSampleBuffer)
                    let timeInSecond = CMTimeGetSeconds(timeStamp)
                    let progressValue = Float(timeInSecond / assetDuration)
                    progress(progressValue)
                }
            }
        }
    }
    
    private func avAssetFrom(data: Data) -> AVAsset? {
        let directory = NSTemporaryDirectory()
        let fileName = "\(NSUUID().uuidString).mov"
        guard let fullURL = NSURL.fileURL(withPathComponents: [directory, fileName]) else {
            return nil
        }
        do {
            try data.write(to: fullURL)
            let asset = AVAsset(url: fullURL)
            return asset
        } catch {
            return nil
        }
    }
    
}

// MARK: = Helping Structures

extension VideoEditor {
    
    public enum Errors: Error {
        case nilAssetReader
        case nilAssetWriter
        case failToAddAudio
        case failToAddVideo
        case nilVideoTrack
        case failToCreateLocalURL
        case failToWriteData
        case nilAVAssetData
    }
    
}
