import AudioToolbox
import AVFoundation

/// Read the encoded file format/bitrate, not the decoded engine's PCM format or filename.
nonisolated enum LocalAudioQualityReader {
    static func read(_ file: AVAudioFile) -> PlaybackQualityFacts {
        let format = file.fileFormat.streamDescription.pointee.mFormatID
        let codec: String?
        switch format {
        case kAudioFormatFLAC: codec = "flac"
        case kAudioFormatAppleLossless: codec = "alac"
        case kAudioFormatLinearPCM: codec = "pcm"
        case kAudioFormatMPEGLayer3: codec = "mp3"
        case kAudioFormatMPEG4AAC: codec = "aac"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = "he-aac"
        default: codec = nil
        }
        var handle: AudioFileID?
        var bitrate: Int?
        if AudioFileOpenURL(file.url as CFURL, .readPermission, 0, &handle) == noErr, let handle {
            defer { AudioFileClose(handle) }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileGetProperty(handle, kAudioFilePropertyBitRate, &size, &value) == noErr, value > 0 {
                bitrate = Int((Double(value) / 1000).rounded())
            }
        }
        return PlaybackQualityFacts(codec: codec, bitrate: bitrate)
    }
}
