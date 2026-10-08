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
 SonivoEQSet(p,g,10,on,SonivoEQPreamp(g,10,rate)); SonivoEQPrepare(p,rate); return p;
}
void update(void *p,const float *g,int on,double rate) {
 SonivoEQSet(p,g,10,on,SonivoEQPreamp(g,10,rate));
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
        g=(C.c_float*10)(*gains); audio=(C.c_float*len(samples))(*samples)
        ptr=self.lib.create(rate,g,on)
        try: self.lib.process(ptr,audio,channels,len(samples)//channels,interleaved)
        finally: self.lib.destroy(ptr)
        return list(audio)

    def response(self,gains,hz,rate=48000):
        samples=[.01*math.sin(2*math.pi*hz*n/rate) for n in range(int(rate))]
        output=self.run_audio(samples,gains,rate)
        rms=lambda x: math.sqrt(sum(y*y for y in x)/len(x))
        return 20*math.log10(rms(output[len(output)//2:])/rms(samples[len(samples)//2:]))

    def test_flat_and_disabled_are_exact_bypass(self):
        samples=[.95*math.sin(n*.031) for n in range(5000)]
        exact=list((C.c_float*len(samples))(*samples))
        self.assertEqual(self.run_audio(samples,[0]*10),exact)
        self.assertEqual(self.run_audio(samples,[12]*10,on=False),exact)

    def test_octave_peak_matches_requested_db(self):
        gains=[0]*10;gains[5]=6
        pre=self.lib.SonivoEQPreamp((C.c_float*10)(*gains),10,48000)
        self.assertAlmostEqual(self.response(gains,1000)-pre,6,delta=.06)
        self.assertLess(self.response(gains,100)-pre,.2)

    def test_shelves_control_bass_and_treble_without_edge_resonance(self):
        bass=[6]+[0]*9;treble=[0]*9+[6]
        self.assertGreater(self.response(bass,12)-self.response(bass,1000),5.5)
        self.assertGreater(self.response(treble,22000)-self.response(treble,1000),5.5)

    def test_overlapping_boosts_keep_unity_preamp_without_automatic_attenuation(self):
        gains=[12]*10
        pre=self.lib.SonivoEQPreamp((C.c_float*10)(*gains),10,48000)
        self.assertEqual(pre,0)
        for frequency in [31,63,125,250,500,1000,2000,4000,8000,16000,22000]:
            self.assertGreater(self.response(gains,frequency),6)

    def test_bass_boost_does_not_turn_down_unaffected_midrange(self):
        gains=[6]+[0]*9
        self.assertEqual(self.lib.SonivoEQPreamp((C.c_float*10)(*gains),10,48000),0)
        self.assertAlmostEqual(self.response(gains,1000),0,delta=.1)
        self.assertGreater(self.response(gains,20),4)

    def test_high_level_eq_is_not_limited_or_clipped_by_app(self):
        gains=[12]+[0]*9
        low=[.06*math.sin(2*math.pi*20*n/48000) for n in range(12000)]
        high=[x*10 for x in low]
        a=self.run_audio(low,gains);b=self.run_audio(high,gains)
        self.assertGreater(max(map(abs,b)),1.0)
        self.assertTrue(all(math.isfinite(x) for x in b))
        self.assertLess(max(abs(y-x*10) for x,y in zip(a,b)),1e-5)

    def test_bass_profiles_emphasize_subbass_without_low_mid_mud(self):
        import re
        models=(ROOT/'Sonivo/models.swift').read_text()
        for name in ['airPodsPro2Bass','bassBoost']:
            values=re.search(r'static let '+name+r' = EQPreset\(name: "[^"]+", gains: \[([^\]]+)\]',models).group(1)
            gains=[float(x.strip()) for x in values.split(',')]
            self.assertEqual(len(gains),10)
            mid=self.response(gains,500)
            self.assertGreater(self.response(gains,20)-mid,4)
            self.assertGreater(self.response(gains,63)-mid,5)
            self.assertLess(self.response(gains,250)-mid,2)
            # High-level multitone remains finite but is intentionally not peak-limited.
            signal=[.6*math.sin(n*.004)+.3*math.sin(n*.12) for n in range(10000)]
            output=self.run_audio(signal,gains)
            self.assertTrue(all(math.isfinite(x) for x in output))
            self.assertGreater(max(map(abs,output)),1.0)

    def test_channels_do_not_crossmix_in_planar_or_interleaved_audio(self):
        for interleaved in [False,True]:
            frames=1024;channels=8;samples=[0.]*(frames*channels)
            samples[3 if interleaved else 3*frames]=.3
            output=self.run_audio(samples,[4]*10,channels=channels,interleaved=interleaved)
            for ch in range(channels):
                data=output[ch::channels] if interleaved else output[ch*frames:(ch+1)*frames]
                if ch==3:self.assertGreater(max(map(abs,data)),.01)
                else:self.assertEqual(max(map(abs,data)),0)

    def test_unlimited_output_preserves_stereo_ratio(self):
        samples=[]
        for n in range(5000):
            x=2*math.sin(n*.13); samples.extend([x,x*.25])
        output=self.run_audio(samples,[3]*10,channels=2)
        self.assertGreater(max(map(abs,output)),1.0)
        self.assertLess(max(abs(output[i+1]-output[i]*.25) for i in range(0,len(output),2)),1e-6)

    def test_sample_rates_and_invalid_gains_remain_finite(self):
        for rate in [8000,32000,44100,48000,96000]:
            gains=[float('nan'),float('inf'),-float('inf'),12,-12,6,-6,12,12,12]
            output=self.run_audio([.5*math.sin(n*.37) for n in range(10000)],gains,rate)
            self.assertTrue(all(math.isfinite(x) for x in output))
            sanitized=[0,0,0,12,-12,6,-6,12,12,12]
            self.assertEqual(output,self.run_audio([.5*math.sin(n*.37) for n in range(10000)],sanitized,rate))

    def test_toggle_and_slider_updates_are_smooth_and_return_to_exact_bypass(self):
        g=(C.c_float*10)(*[0]*10);ptr=self.lib.create(48000,g,0)
        last=0.;largest=0.
        try:
            for block in range(80):
                if block==2:self.lib.update(ptr,(C.c_float*10)(*[12]*10),1,48000)
                if block==12:self.lib.update(ptr,(C.c_float*10)(*[-12]*10),1,48000)
                if block==22:self.lib.update(ptr,g,0,48000)
                raw=[.1*math.sin(2*math.pi*1000*(block*512+i)/48000) for i in range(512)]
                audio=(C.c_float*512)(*raw);self.lib.process(ptr,audio,1,512,1)
                for x in audio:largest=max(largest,abs(x-last));last=x
                if block==79:self.assertEqual(list(audio),list((C.c_float*512)(*raw)))
            self.assertLess(largest,.05)
        finally:self.lib.destroy(ptr)

    def test_stream_and_native_integration_safety(self):
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        tap=(ROOT/'Sonivo/streambeat.swift').read_text()
        session=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/PlaybackAudioSessionSetup.swift').read_text()
        source=(DSP/'StreamAudioProbe.c').read_text()
        self.assertNotIn('VocalIsolationManager.processBuffer(buffer)',core)
        self.assertIn('engine.connect(vocalUnit, to: outputLimiter',core)
        self.assertIn('outputLimiter.bypass = true',core)
        self.assertNotIn('outputLimiter.bypass = false',core)
        render=(DSP/'RealtimeEQ.c').read_text().split('void SonivoEQProcess',1)[1]
        self.assertNotIn('eq->limiter)',render)
        self.assertNotIn('peak>.99',render)
        self.assertIn('mode: .default',session);self.assertNotIn('.moviePlayback',session)
        self.assertIn('kAudioFormatEnhancedAC3',tap)
        self.assertIn('.spatialPassthrough',tap)
        self.assertNotIn('download',tap.split('func updateEQ',1)[1].split('func attach',1)[0])
        process=source.split('static void probeProcess',1)[1].split('MTAudioProcessingTapRef Sonivo',1)[0]
        self.assertLess(process.index('processEQ('),process.index('SonivoPCMPush('))
        self.assertNotIn('atomic_flag_test_and_set',process)
        for forbidden in ['malloc(', 'calloc(', 'dispatch_', 'mutex', 'sleep(']:
            self.assertNotIn(forbidden,process)
