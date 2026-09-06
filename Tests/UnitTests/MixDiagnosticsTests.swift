// Path: Tests/UnitTests/MixDiagnosticsTests.swift

import MixDiagnostics
import Testing

@Suite("MixDiagnostics")
struct MixDiagnosticsTests {
    @Test("Ring buffer keeps newest events")
    func ringBufferCapacity() async {
        let store = MixDiagnosticsStore(capacity: 2)
        await store.record(MixDiagnosticEvent(category: "test", message: "one"))
        await store.record(MixDiagnosticEvent(category: "test", message: "two"))
        await store.record(MixDiagnosticEvent(category: "test", message: "three"))

        let events = await store.allEvents()
        #expect(events.map(\.message) == ["two", "three"])
    }
}
