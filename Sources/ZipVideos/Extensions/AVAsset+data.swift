import Foundation
import Photos

extension AVAsset {
    
    public var dataToUpload: Data? {
        if let avassetURL = self as? AVURLAsset {
            guard let video = try? Data(contentsOf: avassetURL.url) else {
                return nil
            }
            return video
        } else {
            return nil
        }
    }
}
