"""Production library projection/lookup/persistence fixture, no UI/audio/network."""
from pathlib import Path
import subprocess
import tempfile

def verify_library_performance(root):
    checks = r'''
import Foundation
nonisolated struct Track: Codable, Sendable, Identifiable {
    let id: UUID
    var fileName: String
    var title: String
    var artist: String
    var album: String = ""
    var isStream = false
    var isFavorite = false
    var addedAt = Date()
    var url: URL { URL(fileURLWithPath: fileName) }
}
nonisolated struct OffMainSnapshot: Encodable, Sendable {
    let version: Int
    func encode(to encoder: Encoder) throws {
        precondition(!Thread.isMainThread, "Metadata encoded on main thread")
        var container = encoder.singleValueContainer(); try container.encode(version)
    }
}
@main struct Checks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("tracks.json"), b = directory.appendingPathComponent("playlists.json")
        let writer = LibraryPersistenceWriter(delay: .seconds(30))
        for i in 0..<1000 { writer.write(OffMainSnapshot(version:i), to:a) }
        writer.write(OffMainSnapshot(version:42), to:b)
        precondition(writer.diagnostics.pendingFiles == 2, "Pending snapshots are not bounded by file")
        await writer.flush()
        let storedA = try JSONDecoder().decode(Int.self,from:Data(contentsOf:a))
        let storedB = try JSONDecoder().decode(Int.self,from:Data(contentsOf:b))
        precondition(storedA == 999 && storedB == 42)
        precondition(writer.diagnostics.writes == 2 && writer.diagnostics.lastError == nil)
        writer.write(OffMainSnapshot(version:1001),to:a); writer.remove(a); await writer.flush()
        precondition(!FileManager.default.fileExists(atPath:a.path), "Reset raced an older write")
        writer.remove(b); writer.write(OffMainSnapshot(version:45),to:b); await writer.flush()
        let updatedB = try JSONDecoder().decode(Int.self,from:Data(contentsOf:b))
        precondition(updatedB == 45)
        // Lookup must exactly preserve old first-match semantics including filename/ID collisions.
        var collection: [Track] = []
        collection.reserveCapacity(10000)
        for n in 0..<10000 {
            let artist = n % 2 == 0 ? "Artist A" : "Artist B"
            let item = Track(id:UUID(),fileName:"ym_\(n).mp3",title:"Song \(n)",artist:artist,
                             isStream:true,isFavorite:n % 5 == 0,addedAt:Date(timeIntervalSince1970:Double(n)))
            collection.append(item)
        }
        collection[10].fileName = collection[0].fileName
        collection[20] = Track(id:collection[30].id,fileName:"alias",title:"Alias",artist:"Other",isStream:true,isFavorite:true,addedAt:Date(timeIntervalSince1970:20))
        let lookup = LibraryTrackLookup(collection)
        for track in collection.prefix(1000) {
            let legacy: Track? = collection.first { candidate in
                let sameName = candidate.fileName == track.fileName && !track.fileName.isEmpty
                return sameName || candidate.id == track.id
            }
            precondition(lookup.matching(track)?.id == legacy?.id && lookup.matching(track)?.isFavorite == legacy?.isFavorite)
        }
        let start = ContinuousClock.now
        for track in collection { precondition(lookup.matching(track) != nil) }
        let lookupDuration = start.duration(to:.now)
        let key = LibraryProjectionKey(revision:1,loggedIn:true,filter:.favorites,query:"Artist A")
        let projected = try LibraryTrackProjection.build(collection,key:key)
        let reference = Array(collection.prefix(1000))
        let referenceIDs: Set<UUID> = Set(reference.map { $0.id })
        let expected: [Track] = reference.filter { track in
            let stored: Track? = collection.first { candidate in
                let sameName = candidate.fileName == track.fileName && !track.fileName.isEmpty
                return sameName || candidate.id == track.id
            }
            let favorite = track.isFavorite || stored?.isFavorite == true
            return favorite && track.artist.contains("Artist A")
        }
        let actualIDs: [UUID] = projected.filtered.filter { referenceIDs.contains($0.id) }.map { $0.id }
        let expectedIDs: [UUID] = expected.map { $0.id }
        precondition(actualIDs == expectedIDs)
        let recent = try LibraryTrackProjection.build(collection,key:.init(revision:2,loggedIn:true,filter:.recent,query:""))
        precondition(recent.filtered.count == 30 && recent.filtered.first!.title == "Song 9999")
        let localFile = directory.appendingPathComponent("fixture.txt"); try Data("metadata fixture".utf8).write(to:localFile)
        let local = Track(id:UUID(),fileName:localFile.path,title:"Local",artist:"Local")
        let missing = Track(id:UUID(),fileName:directory.appendingPathComponent("missing").path,title:"Missing",artist:"Local")
        let guest = try LibraryTrackProjection.visibleOnly([collection[0],local,missing],loggedIn:false)
        precondition(guest.map { $0.id } == [local.id], "Guest remote/missing file gating changed")
        let immutableCollection = collection
        let cancelled = Task.detached { try await Task.sleep(for:.seconds(1)); return try LibraryTrackProjection.build(immutableCollection,key:key) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled projection accepted") } catch is CancellationError { }
        print("Library fixture: 10,000 indexed lookups \(lookupDuration); legacy filter parity, guest gating, cancellation, bounded latest snapshots, off-main encoding, flush and ordered reset passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as directory:
        p = Path(directory); (p/'Checks.swift').write_text(checks)
        files = [root/'Sonivo/LibraryPersistenceWriter.swift',root/'Sonivo/LibraryTrackProjection.swift',p/'Checks.swift']
        compiled = subprocess.run(['swiftc','-swift-version','6',*map(str,files),'-o',str(p/'checks')],capture_output=True,text=True)
        assert compiled.returncode == 0,compiled.stderr
        result = subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=60)
        assert result.returncode == 0,result.stdout + result.stderr
        print(result.stdout.strip())
