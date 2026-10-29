#!/usr/bin/env python3
"""Compile real driver functions with mocked DRM/firmware seams, not hardware.
--baseline extracts pinned local snapshot (ce9f2eba selected source).
"""
from pathlib import Path
import subprocess, sys, os
root=Path(os.environ["ASAHI_TEST_SOURCE"])
baseline='--baseline' in sys.argv
def extract(file,name):
    path='drivers/gpu/drm/apple/'+file
    s=subprocess.check_output(['git','show','HEAD:'+path],cwd=root,text=True) if baseline else (root/path).read_text()
    pos=s.index(name+'('); start=s.rfind('\n',0,pos)+1
    brace=s.index('{',pos); end=brace+1; depth=1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
preamble=r'''
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#include <assert.h>
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
#define atomic_read(x) (*(x))
#define WARN_ONCE(...) ((void)0)
#define DCP_FIRMWARE_V_12_3 1
#define DCP_FIRMWARE_V_13_5 2
struct drm_display_mode { int hdisplay,vdisplay; };
struct drm_crtc_state { bool active,active_changed,mode_changed,color_mgmt_changed; struct drm_display_mode mode; };
struct apple_connector { bool connected; };
struct channel { bool warned_busy; };
struct apple_dcp { void *dev; bool hdmi_hpd,valid_mode; int hdmi_generation,hdmi_recovered,fw_compat,vblank_wq; struct apple_connector *connector; struct channel ch_cmd; };
struct platform_device { struct apple_dcp *data; };
struct apple_crtc { struct platform_device *dcp; };
struct drm_crtc { struct apple_crtc apple; };
struct drm_device { int unused; };
struct drm_atomic_state { struct drm_crtc_state *cs; struct drm_crtc *crtc; bool allow_modeset; };
#define to_apple_crtc(c) (&(c)->apple)
#define platform_get_drvdata(p) ((p)->data)
#define for_each_new_crtc_in_state(s,c,newcs,i) for ((i)=0,(c)=(s)->crtc,(newcs)=(s)->cs;(i)<1;(i)++)
static int power_calls,mode_calls,submit_calls,vblanks,power_error,mode_error,race;
static struct drm_crtc_state *drm_atomic_get_new_crtc_state(struct drm_atomic_state *s,struct drm_crtc *c) { (void)c;return s->cs; }
static bool drm_atomic_crtc_needs_modeset(struct drm_crtc_state *s) { return s->mode_changed || s->active_changed; }
static int drm_atomic_helper_check(struct drm_device *d,struct drm_atomic_state *s) { (void)d;return !s->allow_modeset && drm_atomic_crtc_needs_modeset(s->cs) ? -EINVAL : 0; }
int dcp_poweron(struct platform_device *p) { (void)p;power_calls++;return power_error; }
static int iomfb_modeset_v12_3(struct apple_dcp *d, struct drm_crtc_state *s) { (void)s;mode_calls++;if(race)d->hdmi_generation++;if(!mode_error)d->valid_mode=true;return mode_error; }
#define iomfb_modeset_v13_3 iomfb_modeset_v12_3
static bool dcp_channel_busy(struct channel *c) { (void)c;return false; }
#define dev_err(...) ((void)0)
static void schedule_work(int *w) { (void)w;vblanks++; }
static void iomfb_flush_v12_3(struct apple_dcp *d,struct drm_crtc *c,struct drm_atomic_state *s) { (void)d;(void)c;(void)s;submit_calls++; }
#define iomfb_flush_v13_3 iomfb_flush_v12_3
'''
functions=[]
if baseline:
    functions.append('static bool dcp_needs_recovery(struct platform_device *p) { return p->data->hdmi_hpd && p->data->hdmi_generation != p->data->hdmi_recovered; }')
    functions.append('static int apple_atomic_check(struct drm_device *d, struct drm_atomic_state *s) { return drm_atomic_helper_check(d,s); }')
else:
    functions += [extract('dcp.c','dcp_needs_recovery'),extract('apple_drv.c','apple_atomic_check')]
functions += [extract('iomfb.c','dcp_crtc_atomic_modeset'),extract('iomfb.c','dcp_flush')]
main=r'''
#define CHECK(x) do { if (!(x)) { printf("FAIL: %s\n",#x); failures++; } } while(0)
int main(void) {
 int failures=0;
 struct apple_connector con={.connected=true};
 struct apple_dcp d={.hdmi_hpd=true,.hdmi_generation=2,.hdmi_recovered=0,.fw_compat=1,.connector=&con};
 struct platform_device p={.data=&d};
 struct drm_crtc c={.apple={.dcp=&p}};
 struct drm_crtc_state cs={.active=true,.mode={1920,1080}};
 struct drm_atomic_state s={.cs=&cs,.crtc=&c,.allow_modeset=true};
 struct drm_device dev={0};
 // Same active/mode as before unplug. Check must schedule recovery, no IO.
 CHECK(apple_atomic_check(&dev,&s)==0);
 CHECK(cs.mode_changed && !cs.active_changed);
 CHECK(power_calls==0 && mode_calls==0 && d.hdmi_recovered==0);
 s.allow_modeset=false; CHECK(apple_atomic_check(&dev,&s)==-EINVAL);
 s.allow_modeset=true;
 CHECK(dcp_crtc_atomic_modeset(&c,&s)==0);
 CHECK(power_calls==1 && mode_calls==1 && d.hdmi_recovered==2);
 dcp_flush(&c,&s); CHECK(submit_calls==1);
 // Pending newer generation at flush, including HPD after atomic_check.
 d.hdmi_generation++; dcp_flush(&c,&s);
 CHECK(submit_calls==1 && vblanks==1);
 power_error=-ETIMEDOUT; mode_calls=0;
 CHECK(dcp_crtc_atomic_modeset(&c,&s)==-ETIMEDOUT);
 CHECK(mode_calls==0 && d.hdmi_recovered==2);
 power_error=0; mode_error=-EIO;
 CHECK(dcp_crtc_atomic_modeset(&c,&s)==-EIO);
 CHECK(d.hdmi_recovered==2);
 mode_error=0; race=1;
 CHECK(dcp_crtc_atomic_modeset(&c,&s)==0);
 CHECK(dcp_needs_recovery(&p));
 dcp_flush(&c,&s); CHECK(submit_calls==1);
 race=0; CHECK(dcp_crtc_atomic_modeset(&c,&s)==0);
 CHECK(!dcp_needs_recovery(&p));
 // Generic invalid mode without HDMI generation is NOT evidence of poweroff.
 power_calls=0; d.valid_mode=false;
 CHECK(dcp_crtc_atomic_modeset(&c,&s)==0); CHECK(power_calls==0);
 // Disconnected recovery must not power on or consume generation.
 d.hdmi_generation++;con.connected=false;
 CHECK(dcp_crtc_atomic_modeset(&c,&s)==-ENOLINK); CHECK(power_calls==0);
 // Internal display is excluded even with different counters.
 d.hdmi_hpd=false; CHECK(!dcp_needs_recovery(&p));
 printf("C seam regression: %s (%d failures)\n",failures?"RED":"GREEN",failures);
 return failures?1:0;
}
'''
tag='baseline' if baseline else 'patched'
cfile=root/f'seam-{tag}.c';exe=root/f'seam-{tag}'
cfile.write_text(preamble+'\n'.join(functions)+main)
subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(cfile),'-o',str(exe)],check=True)
sys.exit(subprocess.run([str(exe)]).returncode)
