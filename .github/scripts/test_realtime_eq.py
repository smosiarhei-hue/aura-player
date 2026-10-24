"""Compile and exercise the actual portable PCM DSP, not an imitation of its math."""
import ctypes as C
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DSP = ROOT / 'Packages/StreamAudioProbe/Sources/StreamAudioProbe'
FREQUENCIES=[40,60,120,250,500,1000,2000,4000,8000,15000]
N=len(FREQUENCIES)
LEGACY=[30,62.5,125,250,500,1000,2000,4000,8000,20000]
def expanded(gains):
    return list(gains)+[0]*(N-len(gains))

def migrated_factory(gains):
    result=[]
    for f in FREQUENCIES:
        upper=next((i for i,x in enumerate(LEGACY) if x>=f),9)
        if upper==0: result.append(gains[0]);continue
        lower=upper-1
        fraction=math.log(f/LEGACY[lower])/math.log(LEGACY[upper]/LEGACY[lower])
        result.append(gains[lower]+(gains[upper]-gains[lower])*fraction)
    return result

def array(gains):return (C.c_float*N)(*expanded(gains))


class RealtimeEQTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        wrapper = Path(cls.tmp.name) / 'wrapper.c'
        wrapper.write_text('''
#include "RealtimeEQ.h"
#include <stdlib.h>
void *create(double rate,const float *g,int on) {
 SonivoRealtimeEQ *p=malloc(sizeof(*p)); SonivoEQInit(p);
 SonivoEQSet(p,g,SONIVO_EQ_BANDS,on,SonivoEQPreamp(g,SONIVO_EQ_BANDS,rate)); SonivoEQPrepare(p,rate); return p;
}
void update(void *p,const float *g,int on,double rate) {
 SonivoEQSet(p,g,SONIVO_EQ_BANDS,on,SonivoEQPreamp(g,SONIVO_EQ_BANDS,rate));
}
void process(void *p,float *buffer,unsigned channels,size_t frames,int interleaved) {
 float *ptrs[8]; size_t strides[8];
 for(unsigned ch=0;ch<channels;ch++) { ptrs[ch]=buffer+(interleaved?ch:ch*frames); strides[ch]=interleaved?channels:1; }
 SonivoEQProcess(p,ptrs,strides,channels,frames);
}
void destroy(void *p) { free(p); }
''')
        lib = Path(cls.tmp.name) / ('eq.dylib' if os.uname().sysname == 'Darwin' else 'eq.so')
        subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-shared','-fPIC',
                        '-I',str(DSP),str(wrapper),str(DSP / 'RealtimeEQ.c'),'-lm','-o',str(lib)],check=True,capture_output=True)
        cls.lib = C.CDLL(str(lib))
        fp = C.POINTER(C.c_float)
        cls.lib.create.argtypes = [C.c_double,fp,C.c_int]; cls.lib.create.restype = C.c_void_p
        cls.lib.update.argtypes = [C.c_void_p,fp,C.c_int,C.c_double]
        cls.lib.process.argtypes = [C.c_void_p,fp,C.c_uint,C.c_size_t,C.c_int]
        cls.lib.destroy.argtypes = [C.c_void_p]
        cls.lib.SonivoEQPreamp.argtypes = [fp,C.c_size_t,C.c_double]
        cls.lib.SonivoEQPreamp.restype = C.c_float

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_audio(self, samples, gains, rate=48000, on=True, channels=1, interleaved=True):
        g=array(gains); audio=(C.c_float*len(samples))(*samples)
        ptr=self.lib.create(rate,g,on)
        try: self.lib.process(ptr,audio,channels,len(samples)//channels,interleaved)
        finally: self.lib.destroy(ptr)
        return list(audio)

    def response(self,gains,hz,rate=48000):
        samples=[.01*math.sin(2*math.pi*hz*n/rate) for n in range(int(rate))]
        output=self.run_audio(samples,gains,rate)
        rms=lambda x: math.sqrt(sum(y*y for y in x)/len(x))
        return 20*math.log10(rms(output[len(output)//2:])/rms(samples[len(samples)//2:]))

    def preamp(self, gains, rate=48000):
        return self.lib.SonivoEQPreamp(array(gains),N,rate)

    def test_compact_centers_are_real_independently_adjustable_filters(self):
        for hz in [60,120,250,500,1000,2000,4000,8000]:
            gains=[0]*N;gains[FREQUENCIES.index(hz)]=6
            self.assertAlmostEqual(self.response(gains,hz)-self.preamp(gains),6,delta=.08)
        gains=[0]*N;gains[FREQUENCIES.index(120)]=6
        self.assertLess(self.response(gains,30),1)
        self.assertLess(self.response(gains,500),1)
    def test_flat_and_disabled_are_exact_bypass(self):
        samples=[.95*math.sin(n*.031) for n in range(5000)]
        exact=list((C.c_float*len(samples))(*samples))
        self.assertEqual(self.run_audio(samples,[0]*10),exact)
        self.assertEqual(self.run_audio(samples,[12]*10,on=False),exact)

    def test_octave_peak_matches_requested_db(self):
        gains=[0]*N;gains[FREQUENCIES.index(1000)]=6
        pre=self.lib.SonivoEQPreamp(array(gains),N,48000)
        self.assertAlmostEqual(self.response(gains,1000)-pre,6,delta=.06)
        self.assertLess(self.response(gains,100)-pre,.2)

    def test_extended_bass_range_is_real_and_does_not_boost_high_band_limits(self):
        strong=[18,0,0,0,0,0,0,0,0,0]
        mild=[12,0,0,0,0,0,0,0,0,0]
        self.assertGreater((self.response(strong,12)-self.preamp(strong))-(self.response(mild,12)-self.preamp(mild)),5)
        self.assertAlmostEqual(self.response(strong,1000)-self.preamp(strong),0,delta=.1)
        self.assertAlmostEqual(self.response([0]*5+[18]+[0]*4,1000),self.response([0]*5+[12]+[0]*4,1000),delta=.1)
        self.assertTrue(all(math.isfinite(x) for x in self.run_audio([.01*math.sin(n*.01) for n in range(10000)],[18]*4+[12]*6)))
        gains=[0]*N;gains[3]=18
        self.assertAlmostEqual(self.response(gains,250)-self.preamp(gains),18,delta=.1)
        gains[3]=24
        self.assertAlmostEqual(self.response(gains,250)-self.preamp(gains),18,delta=.1)
    def test_shelves_control_bass_and_treble_without_edge_resonance(self):
        bass=[6]+[0]*9;treble=[0]*9+[6]
        self.assertGreater(self.response(bass,12)-self.response(bass,1000),5.5)
        self.assertGreater(self.response(treble,22000)-self.response(treble,1000),5.5)

    def test_overlapping_boosts_do_not_apply_fixed_master_attenuation(self):
        for gains in [[12]*10,[18,10,3,-3,0,0,0,0,3,6],[6]+[0]*9]:
            self.assertEqual(self.preamp(gains),0)
        # Low-level audio remains linear, without a static whole-song volume cut.
        self.assertAlmostEqual(self.response([6]+[0]*9,1000),0,delta=.1)
        self.assertGreater(self.response([6]+[0]*9,20),5)
        self.assertGreater(self.response([12]*10,16000),6)
        self.assertEqual(self.preamp([-12]*10),0)
        self.assertEqual(self.preamp([0]*10),0)

    def test_high_level_signal_has_linked_peak_protection(self):
        samples=[2*math.sin(n*.13)+.4*math.sin(n*.023) for n in range(12000)]
        output=self.run_audio(samples,[12]*10)
        self.assertTrue(all(math.isfinite(x) for x in output))
        self.assertLessEqual(max(map(abs,output)),.980001)
        self.assertGreater(max(map(abs,output)),.5)

    def test_bass_profiles_emphasize_subbass_without_low_mid_mud(self):
        import re
        models=(ROOT/'Sonivo/models.swift').read_text()
        for name in ['airPodsPro2Bass','bassBoost']:
            values=re.search(r'static let '+name+r' = EQPreset\(name: "[^"]+", gains: \[([^\]]+)\]',models).group(1)
            gains=[float(x.strip()) for x in values.split(',')]
            self.assertEqual(len(gains),10)
            gains=migrated_factory(gains)
            mid=self.response(gains,500)
            self.assertGreater(self.response(gains,20)-mid,4)
            self.assertGreater(self.response(gains,63)-mid,5)
            self.assertLess(self.response(gains,250)-mid,2)
            # High-level multitone stays finite and below the sample-peak ceiling.
            signal=[.6*math.sin(n*.004)+.3*math.sin(n*.12) for n in range(10000)]
            output=self.run_audio(signal,gains)
            self.assertTrue(all(math.isfinite(x) for x in output))
            self.assertLessEqual(max(map(abs,output)),.980001)

    def test_channels_do_not_crossmix_in_planar_or_interleaved_audio(self):
        for interleaved in [False,True]:
            frames=1024;channels=8;samples=[0.]*(frames*channels)
            samples[3 if interleaved else 3*frames]=.3
            output=self.run_audio(samples,[4]*10,channels=channels,interleaved=interleaved)
            for ch in range(channels):
                data=output[ch::channels] if interleaved else output[ch*frames:(ch+1)*frames]
                if ch==3:self.assertGreater(max(map(abs,data)),.01)
                else:self.assertEqual(max(map(abs,data)),0)

    def test_peak_protection_preserves_stereo_ratio(self):
        samples=[]
        for n in range(5000):
            x=2*math.sin(n*.13); samples.extend([x,x*.25])
        output=self.run_audio(samples,[3]*10,channels=2)
        self.assertLessEqual(max(map(abs,output)),.980001)
        self.assertLess(max(abs(output[i+1]-output[i]*.25) for i in range(0,len(output),2)),1e-6)

    def test_sample_rates_and_invalid_gains_remain_finite(self):
        for rate in [8000,32000,44100,48000,96000]:
            gains=[float('nan'),float('inf'),-float('inf'),12,-12,6,-6,12,12,12]+[0]*(N-10)
            output=self.run_audio([.5*math.sin(n*.37) for n in range(10000)],gains,rate)
            self.assertTrue(all(math.isfinite(x) for x in output))
            sanitized=[0,0,0,12,-12,6,-6,12,12,12]+[0]*(N-10)
            self.assertEqual(output,self.run_audio([.5*math.sin(n*.37) for n in range(10000)],sanitized,rate))

    def test_toggle_and_slider_updates_are_smooth_and_return_to_exact_bypass(self):
        g=array([0]*N);ptr=self.lib.create(48000,g,0)
        last=0.;largest=0.
        try:
            for block in range(240):
                if block==2:self.lib.update(ptr,array([12]*N),1,48000)
                if block==12:self.lib.update(ptr,array([-12]*N),1,48000)
                if block==22:self.lib.update(ptr,g,0,48000)
                raw=[.1*math.sin(2*math.pi*1000*(block*512+i)/48000) for i in range(512)]
                audio=(C.c_float*512)(*raw);self.lib.process(ptr,audio,1,512,1)
                for x in audio:largest=max(largest,abs(x-last));last=x
                if block==239:self.assertEqual(list(audio),list((C.c_float*512)(*raw)))
            self.assertLess(largest,.05)
        finally:self.lib.destroy(ptr)

    def test_hot_sweep_impulses_and_parameter_changes_stay_bounded(self):
        for rate in [8000,32000,44100,48000,96000]:
            frames=8192
            signal=[.95*math.sin(2*math.pi*(20*n/rate + (rate*.42-20)*n*n/(2*rate*frames))) for n in range(frames)]
            signal[0]=1;signal[4000]=-1
            result=self.run_audio(signal,[18]*4+[12]*6,rate)
            self.assertLessEqual(max(map(abs,result)),.980001)
        ptr=self.lib.create(48000,array([0]*N),0)
        try:
            for block in range(120):
                gains=[18 if i<4 else 12 for i in range(N)] if block%2 else [-12]*N
                self.lib.update(ptr,array(gains),1,48000)
                raw=[.85*math.sin((block*128+i)*.079) for i in range(128)]
                audio=(C.c_float*128)(*raw);self.lib.process(ptr,audio,1,128,1)
                self.assertTrue(all(math.isfinite(x) and abs(x)<=.980001 for x in audio))
        finally:self.lib.destroy(ptr)

    def test_disabling_strong_bass_does_not_restore_a_fixed_master_cut(self):
        gains=[18,10,3,-3,0,0,0,0,3,6]
        ptr=self.lib.create(48000,array(gains),1)
        try:
            # Warm the actual filters at an unaffected midrange frequency.
            warm=(C.c_float*48000)(*[.3*math.sin(2*math.pi*1000*n/48000) for n in range(48000)])
            self.lib.process(ptr,warm,1,48000,1)
            rms=lambda x: math.sqrt(sum(y*y for y in x)/len(x))
            before=rms(list(warm)[-480:])
            self.lib.update(ptr,array(gains),0,48000)
            levels=[];last=[]
            for block in range(240):
                raw=[.3*math.sin(2*math.pi*1000*(block*480+n)/48000) for n in range(480)]
                audio=(C.c_float*480)(*raw);self.lib.process(ptr,audio,1,480,1)
                levels.append(rms(audio));last=list(audio)
            self.assertLess(20*math.log10(levels[1]/before),.1)
            self.assertLess(max(abs(20*math.log10(b/a)) for a,b in zip([before]+levels,levels)),.8)
            self.assertLess(abs(20*math.log10(levels[-1]/before)),.3)
            self.assertEqual(last,list((C.c_float*480)(*raw)))
        finally:self.lib.destroy(ptr)

    def test_headroom_attack_does_not_step_when_changing_an_active_curve(self):
        ptr=self.lib.create(48000,array([0]*9+[-6]),1)
        try:
            warm=(C.c_float*48000)(*([.1]*48000));self.lib.process(ptr,warm,1,48000,1)
            previous=warm[-1]
            self.lib.update(ptr,array([18]+[0]*8+[-6]),1,48000)
            audio=(C.c_float*2048)(*([.1]*2048));self.lib.process(ptr,audio,1,2048,1)
            steps=[abs(audio[0]-previous)]+[abs(audio[i]-audio[i-1]) for i in range(1,len(audio))]
            self.assertLess(max(steps),.005)
        finally:self.lib.destroy(ptr)

    def test_preamp_invalid_input_and_rate_fallback_are_deterministic(self):
        for rate in [float('nan'),float('inf'),0,-1]:
            self.assertEqual(self.preamp([12]*N,rate),self.preamp([12]*N,48000))
        self.assertEqual(self.lib.SonivoEQPreamp(None,0,48000),0)
        self.assertEqual(self.preamp([float('nan')]*N),0)

    def test_held_peak_envelope_reduces_sustained_bass_harmonics(self):
        rate=48000;hz=40
        output=self.run_audio([.8*math.sin(2*math.pi*hz*n/rate) for n in range(rate*2)],[12]+[0]*9)
        tail=output[-24000:]
        def amplitude(harmonic):
            w=2*math.pi*hz*harmonic/rate
            a=sum(x*math.cos(w*n) for n,x in enumerate(tail))
            b=sum(x*math.sin(w*n) for n,x in enumerate(tail))
            return 2*math.hypot(a,b)/len(tail)
        thd=math.sqrt(sum(amplitude(h)**2 for h in range(2,11)))/amplitude(1)
        self.assertLess(thd,.0015, "Limiter modulates sustained 40 Hz bass")
        self.assertLessEqual(max(map(abs,output)),.980001)

    def test_response_preview_uses_actual_cascade_coefficients(self):
        response=self.lib.SonivoEQResponse
        response.argtypes=[C.POINTER(C.c_float),C.c_size_t,C.c_double,C.POINTER(C.c_float),C.c_size_t]
        values=(C.c_float*121)();gains=[0]*N;gains[5]=6;gains[1]=4
        response(array(gains),N,48000,values,len(values))
        for index in [10,35,68,95,110]:
            hz=20*1000**(index/120)
            self.assertAlmostEqual(values[index],self.response(gains,hz),delta=.08)
        response(array([0]*N),N,48000,values,len(values))
        self.assertTrue(all(abs(x)<1e-6 for x in values))

    def test_disabling_an_actually_limited_signal_reaches_dry_without_boundary_jump(self):
        gains=[12]+[0]*9;rate=48000
        ptr=self.lib.create(rate,array(gains),1)
        try:
            warm=(C.c_float*48000)(*[.8*math.sin(2*math.pi*40*n/rate) for n in range(48000)])
            self.lib.process(ptr,warm,1,48000,1)
            self.lib.update(ptr,array(gains),0,rate)
            previous=warm[-1];max_step=0
            for block in range(100):
                raw=[.8*math.sin(2*math.pi*40*(48000+block*480+n)/rate) for n in range(480)]
                audio=(C.c_float*480)(*raw);self.lib.process(ptr,audio,1,480,1)
                for sample in audio: max_step=max(max_step,abs(sample-previous));previous=sample
            self.assertLess(max_step,.02)
            self.assertEqual(list(audio),list((C.c_float*480)(*raw)))
        finally:self.lib.destroy(ptr)

    def test_stream_and_native_integration_safety(self):
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        tap=(ROOT/'Sonivo/streambeat.swift').read_text()
        session=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/PlaybackAudioSessionSetup.swift').read_text()
        source=(DSP/'StreamAudioProbe.c').read_text()
        self.assertNotIn('VocalIsolationManager.processBuffer(buffer)',core)
        self.assertIn('engine.connect(vocalUnit, to: outputLimiter',core)
        self.assertIn('outputLimiter.bypass = true',core)
        self.assertIn('self?.outputLimiter.bypass = !needsProtection',core)
        render=(DSP/'RealtimeEQ.c').read_text().split('void SonivoEQProcess',1)[1]
        self.assertIn('result[ch]*eq->limiter',render)
        self.assertIn('peak>.98',render)
        self.assertNotIn('SonivoEQPreamp(',render)
        self.assertIn('mode: .default',session);self.assertNotIn('.moviePlayback',session)
        self.assertIn('kAudioFormatEnhancedAC3',tap)
        self.assertIn('.spatialPassthrough',tap)
        self.assertNotIn('download',tap.split('func updateEQ',1)[1].split('func attach',1)[0])
        process=source.split('static void probeProcess',1)[1].split('MTAudioProcessingTapRef Sonivo',1)[0]
        self.assertLess(process.index('processEQ('),process.index('SonivoPCMPush('))
        self.assertNotIn('atomic_flag_test_and_set',process)
        for forbidden in ['malloc(', 'calloc(', 'dispatch_', 'mutex', 'sleep(']:
            self.assertNotIn(forbidden,process)
