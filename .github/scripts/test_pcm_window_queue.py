"""Execute the same portable C11 queue used by Apple's processing tap."""
import ctypes as C
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
DSP=ROOT/'Packages/StreamAudioProbe/Sources/StreamAudioProbe'

class PCMWindowQueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(); base=Path(cls.tmp.name)
        wrapper=base/'queue.c'
        wrapper.write_text(r'''
#include "PCMWindowQueue.h"
#include <stdlib.h>
#include <pthread.h>
#include <sched.h>
void *create(void) { SonivoPCMWindowQueue *q=calloc(1,sizeof(*q)); SonivoPCMInit(q); return q; }
void destroy(void *q) { free(q); }
void reset(void *q) { SonivoPCMReset(q); }
void feed(void *q,const float *samples,size_t n,double start,double rate) {
 for(size_t i=0;i<n;i++) SonivoPCMPush(q,samples[i],start+(i+1)/rate,rate);
}
size_t take(void *q,float *out,double *rate,double *time) { return SonivoPCMPop(q,out,1024,rate,time); }
unsigned long long drops(void *q) { return atomic_load(&((SonivoPCMWindowQueue *)q)->dropped); }
typedef struct { SonivoPCMWindowQueue *q; atomic_int done; } Stress;
static void *produce(void *ptr) {
 Stress *s=ptr;
 for(int i=0;i<250000;i++) SonivoPCMPush(s->q,(float)i,(double)(i+1)/48000,48000);
 atomic_store_explicit(&s->done,1,memory_order_release); return NULL;
}
int stress(void) {
 SonivoPCMWindowQueue *q=create(); Stress s={.q=q}; atomic_init(&s.done,0);
 pthread_t worker; if(pthread_create(&worker,NULL,produce,&s)!=0) { free(q);return 1; }
 float out[1024];double rate,time;int bad=0,seen=0;float last=-1;
 for(;;) {
  if(take(q,out,&rate,&time)) {
   if(out[0]<=last || rate!=48000 || fabs(time-(out[0]+512.0)/rate)>1e-9) bad=2;
   for(int i=0;i<1024;i++) if(out[i]!=out[0]+i) bad=3;
   last=out[0];seen++;
  } else if(atomic_load_explicit(&s.done,memory_order_acquire) && atomic_load(&q->read)==atomic_load(&q->written)) break;
  else sched_yield();
 }
 pthread_join(worker,NULL);free(q);return seen ? bad : 4;
}
''')
        lib=base/('queue.dylib' if os.uname().sysname=='Darwin' else 'queue.so')
        subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-shared','-fPIC','-pthread','-I',str(DSP),str(wrapper),'-lm','-o',str(lib)],check=True,capture_output=True)
        cls.lib=C.CDLL(str(lib)); fp=C.POINTER(C.c_float); dp=C.POINTER(C.c_double)
        cls.lib.create.restype=C.c_void_p
        cls.lib.destroy.argtypes=[C.c_void_p];cls.lib.reset.argtypes=[C.c_void_p]
        cls.lib.feed.argtypes=[C.c_void_p,fp,C.c_size_t,C.c_double,C.c_double]
        cls.lib.take.argtypes=[C.c_void_p,fp,dp,dp];cls.lib.take.restype=C.c_size_t
        cls.lib.drops.argtypes=[C.c_void_p];cls.lib.drops.restype=C.c_ulonglong
        cls.lib.stress.restype=C.c_int
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def setUp(self): self.q=self.lib.create()
    def tearDown(self): self.lib.destroy(self.q)
    def feed(self,samples,start=0,rate=48000):
        self.lib.feed(self.q,(C.c_float*len(samples))(*samples),len(samples),start,rate)
    def drain(self):
        result=[]
        while True:
            out=(C.c_float*1024)();rate=C.c_double();time=C.c_double()
            if not self.lib.take(self.q,out,C.byref(rate),C.byref(time)): return result
            result.append((list(out),rate.value,time.value))
    def test_large_callback_preserves_early_short_attacks(self):
        samples=[0.0]*4096;samples[800]=1;samples[2100]=.75
        self.feed(samples);windows=self.drain()
        self.assertEqual(len(windows),13)
        for index,(out,rate,time) in enumerate(windows):
            self.assertEqual(out,samples[index*256:index*256+1024])
            self.assertAlmostEqual(time,(index*256+512)/rate,places=10)
        self.assertTrue(any(1 in out for out,_,_ in windows))
        self.assertTrue(any(.75 in out for out,_,_ in windows))
        self.assertNotIn(1,samples[-1024:]) # The former latest-only capture missed this attack.
    def test_arbitrary_callback_boundaries_keep_every_hop(self):
        samples=[math.sin(i*.02) for i in range(9000)];offset=0;got=[]
        for size in [17,2048,3,4096,105,2731]:
            chunk=samples[offset:offset+size];self.feed(chunk,start=3+offset/44100,rate=44100)
            got.extend(self.drain());offset+=len(chunk)
        expected=(len(samples)-1024)//256+1
        self.assertEqual(len(got),expected)
        exact=list((C.c_float*len(samples))(*samples))
        for i,(out,rate,time) in enumerate(got):
            self.assertEqual(out,exact[i*256:i*256+1024]);self.assertEqual(rate,44100)
            self.assertAlmostEqual(time,3+(i*256+512)/rate,places=9)
    def test_seek_epoch_discards_old_pcm_and_never_mixes_windows(self):
        self.feed([1]*3000,start=60);self.lib.reset(self.q)
        self.feed([-.5]*2048,start=4)
        got=self.drain();self.assertEqual(len(got),5)
        self.assertTrue(all(out==[-.5]*1024 for out,_,_ in got))
        self.assertAlmostEqual(got[0][2],4+512/48000,places=10)
    def test_overflow_is_bounded_and_observable(self):
        self.feed([.25]*(1024+300*256))
        self.assertEqual(len(self.drain()),256);self.assertEqual(self.lib.drops(self.q),45)
        self.feed([.5]*256,start=5);self.assertEqual(len(self.drain()),1)
    def test_invalid_samples_are_sanitized(self):
        self.feed([math.nan,math.inf,-math.inf]+[.25]*1021)
        out,_,_=self.drain()[0];self.assertEqual(out[:3],[0,0,0]);self.assertTrue(all(math.isfinite(x) for x in out))
    def test_concurrent_audio_and_analysis_never_read_torn_windows(self):
        for _ in range(6): self.assertEqual(self.lib.stress(),0)
if __name__=='__main__': unittest.main()
