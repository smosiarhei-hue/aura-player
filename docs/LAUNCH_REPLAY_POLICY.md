# Startup animation replay policy

The approved finite 3.5-second S + sound intro appears on every new process launch,
including offline launches, cached libraries and fast account restoration. It does
not wait for network, scanning or synchronization and does not finish when those
operations finish. RootView mounts immediately under the reveal.

The in-memory process claim prevents replay when returning from background or when
SwiftUI recreates the host. No persistent "already seen" preference is written.
Playback already running, external player deep links, backgrounding/disappearance
and cancellation bypass/end the reveal immediately. Reduced Motion keeps the
existing short static 0.35-second presentation. Music haptics are unchanged.

The startup gate and session lifecycle execute in the macOS Swift fixture; source
checks cover mounting, no preparation gate, bypass and accessibility. This is not
a claim of runtime animation smoothness on an iPhone.

The new vector scene uses medium transient-only launch haptics, with peak API intensity 0.70. Music haptics remain unchanged.

First-frame fix: the in-memory pending-decision cover exists before the scene task
starts. A recreated host after a consumed process claim does not show a new cover.
The system launch color and native scene use the same opaque SonivoLaunchBackground
asset. Root still mounts underneath immediately. Visuals and haptics both run at
1.2× speed; total duration is 3.5 seconds instead of 4.2. Reduced Motion remains 0.35s.
