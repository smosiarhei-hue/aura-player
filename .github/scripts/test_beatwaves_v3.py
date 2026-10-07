"""Scoped v3 fixes. Portable C executes on Linux/macOS; Accelerate parity on macOS."""
import ctypes as C
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
DSP=ROOT/'Packages/StreamAudioProbe/Sources/StreamAudioProbe'

class BeatWavesV3Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();base=Path(cls.tmp.name)
        wrapper=base/'v3.c'
        wrapper.write_text(r'''
#include "RealtimeEQ.c"
#include "ProbeDiagnostics.h"
#include "PCMWindowQueue.h"
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>

typedef struct { SonivoRealtimeEQ eq; atomic_int done; } EQStress;
static void *eqWrite(void *ptr) {
 EQStress *s=ptr;float gains[10];
 for(unsigned i=0;i<100000;i++) {
  float g=i&1 ? 9 : 3;
  for(unsigned b=0;b<10;b++) gains[b]=b&1 ? -g : g;
  SonivoEQSet(&s->eq,gains,10,1,-g);
  if((i&255)==0) sched_yield();
 }
 atomic_store_explicit(&s->done,1,memory_order_release);return NULL;
}
static int eqSnapshotValid(SonivoRealtimeEQ *eq) {
 if(eq->appliedSequence==0) return 1;
 double g=fabs(eq->target[0].b0-coefficients(0,3,48000).b0)<1e-12 ? 3 : 9;
 for(unsigned b=0;b<10;b++) {
  SonivoEQCoefficients expected=coefficients(b,b&1 ? -g : g,48000);
  SonivoEQCoefficients actual=eq->target[b];
  if(fabs(actual.b0-expected.b0)>1e-12 || fabs(actual.b1-expected.b1)>1e-12 ||
     fabs(actual.b2-expected.b2)>1e-12 || fabs(actual.a1-expected.a1)>1e-12 ||
     fabs(actual.a2-expected.a2)>1e-12) return 0;
 }
 return eq->wantsWet && fabs(eq->targetPreGain-pow(10,-g/20))<1e-12;
}
int eqStress(void) {
 EQStress *s=calloc(1,sizeof(*s));SonivoEQInit(&s->eq);SonivoEQPrepare(&s->eq,48000);
 atomic_init(&s->done,0);pthread_t writer;
 if(pthread_create(&writer,NULL,eqWrite,s)!=0) { free(s);return 1; }
 int bad=0;unsigned snapshots=0,last=0;
 for(;;) {
  consume(&s->eq,0);
  if(s->eq.appliedSequence!=last) { snapshots++;last=s->eq.appliedSequence; }
  if(!eqSnapshotValid(&s->eq)) bad=2;
  if(atomic_load_explicit(&s->done,memory_order_acquire)) { consume(&s->eq,0);if(!eqSnapshotValid(&s->eq)) bad=3;break; }
 }
 pthread_join(writer,NULL);free(s);return snapshots ? bad : 4;
}
unsigned long long skippedTest(void) {
 SonivoProbeDiagnostics d;SonivoProbeDiagnosticsInit(&d);float samples[16]={0};
 if(!SonivoProbeCheckBuffer(&d,samples,2,0,8,sizeof(samples),8)) return 100;
 if(SonivoProbeCheckBuffer(&d,NULL,2,0,8,sizeof(samples),8)) return 101;
 if(SonivoProbeCheckBuffer(&d,samples,0,0,8,sizeof(samples),8)) return 102;
 if(SonivoProbeCheckBuffer(&d,samples,9,0,8,sizeof(samples),1)) return 103;
 if(SonivoProbeCheckBuffer(&d,samples,2,7,8,sizeof(samples),1)) return 104;
 if(SonivoProbeCheckBuffer(&d,samples,2,0,8,4,8)) return 105;
 SonivoProbeRecordSkipped(&d); // Other processEQ early-exit reasons use this same counter.
 return atomic_load_explicit(&d.skipped,memory_order_relaxed);
}
int unstampedTest(void) {
 SonivoPCMWindowQueue *q=calloc(1,sizeof(*q));SonivoPCMInit(q);
 for(int i=0;i<2048;i++) SonivoPCMPush(q,.1f,NAN,48000);
 if(atomic_load(&q->unstamped)!=5) { free(q);return 1; }
 float out[1024];double rate,time;
 for(int i=0;i<5;i++) if(SonivoPCMPop(q,out,1024,&rate,&time)!=1024 || !isnan(time)) { free(q);return 2; }
 SonivoPCMReset(q);
 for(int i=0;i<1024;i++) SonivoPCMPush(q,.1f,3+(i+1)/48000.0,48000);
 if(atomic_load(&q->unstamped)!=5) { free(q);return 3; }
 if(!SonivoPCMPop(q,out,1024,&rate,&time) || fabs(time-(3+512/48000.0))>1e-10) { free(q);return 4; }
 SonivoPCMReset(q);
 for(int i=0;i<1024+300*256;i++) SonivoPCMPush(q,.1f,NAN,48000);
 int okay=atomic_load(&q->unstamped)==306 && atomic_load(&q->dropped)==45;
 free(q);return okay ? 0 : 5;
}
int formatRoundTrip(void) {
 SonivoProbeDiagnostics d;SonivoProbeDiagnosticsInit(&d);
 double rate=-123;uint32_t out[8]={99,99,99,99,99,99,99,99};
 if(SonivoProbeLoadFormat(&d,&rate,out) || rate!=-123 || out[0]!=99) return 1;
 uint32_t source[8]={0x6c70636d,12,4,1,4,2,16,0x1234}; // Int16 metadata must survive unchanged.
 SonivoProbeStoreFormat(&d,44100,source);
 if(!SonivoProbeLoadFormat(&d,&rate,out) || rate!=44100 || memcmp(source,out,sizeof(out))) return 2;
 atomic_fetch_add(&d.formatSequence,1);
 rate=-456;out[0]=77;
 if(SonivoProbeLoadFormat(&d,&rate,out) || rate!=-456 || out[0]!=77) return 3;
 return 0;
}
typedef struct { SonivoProbeDiagnostics d;atomic_int done; } FormatStress;
static void *formatWrite(void *ptr) {
 FormatStress *s=ptr;uint32_t fields[8];
 for(unsigned i=0;i<100000;i++) {
  uint32_t g=i&1 ? 27 : 26;
  for(unsigned b=0;b<8;b++) fields[b]=g+b;
  SonivoProbeStoreFormat(&s->d,g==26 ? 44100 : 48000,fields);
  if((i&255)==0) sched_yield();
 }
 atomic_store_explicit(&s->done,1,memory_order_release);return NULL;
}
int formatStress(void) {
 FormatStress s;SonivoProbeDiagnosticsInit(&s.d);atomic_init(&s.done,0);pthread_t writer;
 if(pthread_create(&writer,NULL,formatWrite,&s)!=0) return 1;
 int bad=0;unsigned seen=0;
 for(;;) {
  double rate;uint32_t fields[8];
  if(SonivoProbeLoadFormat(&s.d,&rate,fields)) {
   seen++;uint32_t g=rate==44100 ? 26 : 27;
   if(rate!=44100 && rate!=48000) bad=2;
   for(unsigned b=0;b<8;b++) if(fields[b]!=g+b) bad=3;
  }
  if(atomic_load_explicit(&s.done,memory_order_acquire)) break;
 }
 pthread_join(writer,NULL);return seen ? bad : 4;
}
''')
        lib=base/('v3.dylib' if os.uname().sysname=='Darwin' else 'v3.so')
        compiled=subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-shared','-fPIC','-pthread','-I',str(DSP),str(wrapper),'-lm','-o',str(lib)],capture_output=True,text=True)
        if compiled.returncode: raise AssertionError(compiled.stderr)
        cls.lib=C.CDLL(str(lib));cls.lib.skippedTest.restype=C.c_ulonglong
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def test_a1_acquire_fence_precedes_relaxed_sequence_recheck(self):
        s=(DSP/'RealtimeEQ.c').read_text().split('static void consume(',1)[1].split('void SonivoEQPrepare',1)[0]
        gains=s.index('values[b]=atomic_load_explicit(&eq->gains[b],memory_order_relaxed)')
        fence=s.index('atomic_thread_fence(memory_order_acquire)')
        recheck=s.index('if (seq!=atomic_load_explicit(&eq->sequence,memory_order_relaxed))')
        self.assertLess(gains,fence);self.assertLess(fence,recheck)
    def test_a1_actual_consume_never_accepts_mixed_gain_pairs(self):
        for _ in range(8): self.assertEqual(self.lib.eqStress(),0)
    def test_a4_skipped_buffer_validation_counter(self): self.assertEqual(self.lib.skippedTest(),6)
    def test_a4_unstamped_counter_preserves_nan_and_counts_overflow(self): self.assertEqual(self.lib.unstampedTest(),0)
    def test_a5_original_format_roundtrip_even_without_float32(self): self.assertEqual(self.lib.formatRoundTrip(),0)
    def test_a5_concurrent_format_read_has_no_mixed_snapshot(self):
        for _ in range(6): self.assertEqual(self.lib.formatStress(),0)
    def test_a4_a5_exports_and_realtime_callback_have_no_logs_or_waits(self):
        source=(DSP/'StreamAudioProbe.c').read_text();header=(DSP/'include/StreamAudioProbe.h').read_text()
        for api in ['SonivoStreamProbeSkipped','SonivoStreamProbeUnstamped','SonivoStreamProbeFormat']:
            self.assertIn(api,source);self.assertIn(api,header)
        self.assertIn('SonivoProbeStoreFormat(&p->diagnostics,format->mSampleRate,fields)',source)
        self.assertIn('SonivoProbeCheckBuffer(&p->diagnostics',source)
        self.assertIn('atomic_load_explicit(&p->eqReady,memory_order_acquire)',source)
        process=source.split('static void processEQ',1)[1].split('MTAudioProcessingTapRef SonivoStreamProbeCreate',1)[0]
        for forbidden in ['malloc(', 'calloc(', 'mutex', 'sleep(', 'NSLog', 'printf(', 'SonivoDiagnostics', 'dispatch_']:
            self.assertNotIn(forbidden,process)
        swift=(ROOT/'Sonivo/streambeat.swift').read_text()
        diag=swift.split('private func logProbeDiagnostics',1)[1].split('// The audible deck',1)[0]
        self.assertIn('now-probe.lastDiagnosticAt>=5',diag)
        self.assertIn('if !probe.didLogFormat',diag)
        self.assertIn('probe.didLogFormat=true',diag)
        self.assertIn('tag: "BEAT_WAVE"',diag)
    def test_a6_configuration_is_event_driven_and_duplicate_push_removed(self):
        renderer=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        tick=renderer.split('fileprivate func tick(',1)[1].split('func draw(in view:',1)[0]
        self.assertNotIn('presentation.push(capture)',tick)
        self.assertNotIn('configureOutput(',tick);self.assertNotIn('configureFrameRate()',tick)
        self.assertIn('override func didMoveToWindow()',renderer)
        self.assertIn('UIScreen.modeDidChangeNotification',renderer)
        self.assertIn('UIScreen.brightnessDidChangeNotification',renderer)
        self.assertIn('Task { @MainActor [weak self]',renderer)
        create=(DSP/'StreamAudioProbe.c').read_text().split('MTAudioProcessingTapRef SonivoStreamProbeCreate',1)[1].split('size_t SonivoStreamProbeReadTimed',1)[0]
        self.assertIn('volatile MTAudioProcessingTapCallbacks callbacks',create)
        self.assertIn('callbacks.process = probeProcess',create)
    def test_m2_is_readonly_queue_tail_minus_media_clock_and_process_maximum(self):
        motion=(ROOT/'Sonivo/BeatWaveMotion.swift').read_text()
        self.assertIn('var latestQueuedMediaTime: TimeInterval? { queue.last?.mediaTime }',motion)
        renderer=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('diagnosticQueuedFuture=queuedTime-clock.time',renderer)
        self.assertIn('queuedFuture=%.6f queuedFutureMax=%.6f',renderer)
        self.assertIn('private enum BeatWaveMeasurement',renderer)
        stop=renderer.split('func stop()',1)[1].split('fileprivate func tick',1)[0]
        self.assertNotIn('queuedFutureMax=',stop)
    def test_c1_obsolete_latest_only_description_removed(self):
        s=(ROOT/'docs/beatwaves-native-handoff.md').read_text()
        self.assertNotIn('the C capture still exposes the latest window',s)
        self.assertIn('at every 256-sample hop in a bounded 256-window SPSC queue',s)
    def test_a2_preallocated_scratch_and_macos_numeric_parity(self):
        s=(ROOT/'Sonivo/spectrumanalyzer.swift').read_text()
        process=s.split('    func process(buffer:',1)[1].split('    func processStreamLevel',1)[0]
        self.assertNotIn('[Float](repeating',process);self.assertNotIn('[Int](repeating',process)
        self.assertNotIn('Array(repeating',process)
        fields=s.split('nonisolated private final class SpectrumDSP:',1)[1].split('    init()',1)[0]
        for name in ['input','real','imaginary','magnitudes','values','counts']:
            self.assertRegex(fields,r'private var '+name+r'\s*=')
        self.assertIn('lock.lock(); defer { lock.unlock() }',process)
        self.assertIn('values[band]=0; counts[band]=0',process)
        # Linux still executes the structural assertions; only Apple has Accelerate/AVFoundation.
        if os.uname().sysname!='Darwin': return
        self.run_macos_parity(s)
    def run_macos_parity(self,source):
        reference=(ROOT/'.github/fixtures/SpectrumDSP-before-A2.swift').read_text()
        optimized=source[source.index('nonisolated private final class SpectrumDSP:'):]
        reference=reference.replace('class SpectrumDSP:', 'class SpectrumDSPReference:')
        optimized=optimized.replace('class SpectrumDSP:', 'class SpectrumDSPOptimized:')
        snapshot=source[source.index('nonisolated private struct SpectrumSnapshot:'):source.index('nonisolated private final class SpectrumDSP:')]
        prelude='''import Accelerate
@preconcurrency import AVFoundation
import Foundation
nonisolated enum SpectrumAnalyzer { static let bandCount=32 }
nonisolated final class HapticStub: @unchecked Sendable { func processRawBands(_ values: [Float]) {} }
nonisolated enum MusicHapticsManager { static let core=HapticStub() }
'''
        main=r'''
func same(_ a: Float,_ b: Float,_ name: String) {
 if a.bitPattern != b.bitPattern { fatalError("A2 mismatch \(name): \(a) vs \(b)") }
}
for rate in [44100.0,48000.0] {
 let before=SpectrumDSPReference(),after=SpectrumDSPOptimized()
 let format=AVAudioFormat(standardFormatWithSampleRate: rate,channels: 1)!
 let pcm=AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 1024)!
 pcm.frameLength=1024
 for hop in 0..<160 {
  let start=hop*256
  for i in 0..<1024 {
   let t=Double(start+i)/rate
   let elapsed=t.truncatingRemainder(dividingBy: 0.5)
   let kick=exp(-elapsed/0.025)*sin(2*Double.pi*63*t)*0.2
   let voice=sin(2*Double.pi*220*t)*0.08+sin(2*Double.pi*1700*t)*0.02
   pcm.floatChannelData![0][i]=hop<120 ? Float(kick+voice) : 0
  }
  let stamp=1+Double(start+512)/rate
  let a=before.process(buffer: pcm,sampleRate: rate,capturedAt: stamp,mediaTime: stamp,observedAt: 123)!
  let b=after.process(buffer: pcm,sampleRate: rate,capturedAt: stamp,mediaTime: stamp,observedAt: 123)!
  for i in 0..<32 { same(a.bands[i],b.bands[i],"band \(i)") }
  for (x,y,n) in [(a.bass,b.bass,"bass"),(a.kick,b.kick,"kick"),(a.mids,b.mids,"mids"),(a.highs,b.highs,"highs"),(a.level,b.level,"level")] { same(x,y,n) }
  let x=a.beatWaveFrame,y=b.beatWaveFrame
  for (m,n,label) in [(x.subBass,y.subBass,"subBass"),(x.bass,y.bass,"frame bass"),(x.lowMids,y.lowMids,"lowMids"),(x.mids,y.mids,"frame mids"),(x.highs,y.highs,"frame highs"),(x.rms,y.rms,"rms"),(x.kickEnvelope,y.kickEnvelope,"envelope"),(x.kickConfidence,y.kickConfidence,"confidence"),(x.bassFlux!,y.bassFlux!,"bassFlux"),(x.attackFlux!,y.attackFlux!,"attackFlux")] { same(m,n,label) }
  if x.kickEventID != y.kickEventID || x.mediaTime != y.mediaTime { fatalError("A2 event/time mismatch") }
 }
}
print("A2 parity: 320 windows at 44.1/48 kHz; all bands, envelopes, flux and onset IDs bit-identical")
'''
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);(p/'main.swift').write_text(prelude+snapshot+reference+optimized+main)
            compiled=subprocess.run(['swiftc','-swift-version','6',str(ROOT/'Sonivo/BeatWaveMotion.swift'),str(p/'main.swift'),'-o',str(p/'parity')],capture_output=True,text=True)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            checked=subprocess.run([str(p/'parity')],capture_output=True,text=True)
            self.assertEqual(checked.returncode,0,checked.stdout+checked.stderr)
            print(checked.stdout.strip())
if __name__=='__main__': unittest.main()
