from pathlib import Path
import subprocess
import tempfile

def verify_video_shot_playback(root):
    main = '''
import Foundation
@main struct Checks {
    static func main() {
        for mask in 0..<256 {
            let b = (0..<8).map { (mask & (1 << $0)) != 0 }
            let actual = VideoShotPlaybackPolicy.shouldPlay(enabled:b[0],ready:b[1],matchingTrack:b[2],
                musicPlaying:b[3],sceneActive:b[4],playerVisible:b[5],lyricsVisible:b[6],reduceMotion:b[7])
            precondition(actual == (b[0...5].allSatisfy { $0 } && !b[6] && !b[7]))
        }
        let track = UUID(), account = UUID()
        let original = VideoShotLoadKey(trackID:track,playbackTrackID:track,enabled:true,reduceMotion:false,accountGeneration:account)
        precondition(original == original)
        precondition(original != VideoShotLoadKey(trackID:track,playbackTrackID:track,enabled:false,reduceMotion:false,accountGeneration:account))
        precondition(original != VideoShotLoadKey(trackID:track,playbackTrackID:track,enabled:true,reduceMotion:true,accountGeneration:account))
        precondition(original != VideoShotLoadKey(trackID:track,playbackTrackID:UUID(),enabled:true,reduceMotion:false,accountGeneration:account))
        precondition(original != VideoShotLoadKey(trackID:UUID(),playbackTrackID:track,enabled:true,reduceMotion:false,accountGeneration:account))
        precondition(original != VideoShotLoadKey(trackID:track,playbackTrackID:track,enabled:true,reduceMotion:false,accountGeneration:UUID()))
    }
}
'''
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        (directory / 'Checks.swift').write_text(main)
        result = subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor',
            '-strict-concurrency=complete','-parse-as-library',str(root/'Sonivo/VideoShotPlaybackPolicy.swift'),
            str(directory/'Checks.swift'),'-o',str(directory/'checks')],capture_output=True,text=True)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(directory/'checks')],capture_output=True,text=True)
        assert result.returncode == 0, result.stdout + result.stderr

    from check_native_videoshot import verify_native_videoshot
    verify_native_videoshot(root)
