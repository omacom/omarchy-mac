#!/usr/bin/env python3
"""Source regression gates; not a firmware/hardware simulation."""
import pathlib, unittest, re, os
P = pathlib.Path(os.environ['ASAHI_TEST_SOURCE']) / 'drivers/gpu/drm/apple'
def src(n): return (P/n).read_text()
def body(n, fn):
    text = src(n); start = text.index(fn+'('); start = text.index('{', start)
    level=1; end=start+1
    while level:
        level += (text[end]=='{')-(text[end]=='}'); end+=1
    return text[start:end]
class Reconnect(unittest.TestCase):
    def test_first_reconnect_gets_real_modeset_before_helper(self):
        s=src('apple_drv.c')
        self.assertIn('static int apple_atomic_check(',s,
                      'baseline submits first reconnect without DRM modeset')
        b=body('apple_drv.c','apple_atomic_check')
        self.assertLess(b.index('mode_changed = true'),b.index('drm_atomic_helper_check('))
        self.assertIn('dcp_needs_recovery',b)
        self.assertIn('crtc_state->active',b)
        self.assertNotIn('active_changed =',b)
        self.assertNotIn('dcp_poweron(',b) # TEST_ONLY must not consume recovery
        self.assertRegex(s,r'\.atomic_check\s*= apple_atomic_check')
    def test_recovery_power_ack_before_modeset_and_generation_retained(self):
        b=body('iomfb.c','dcp_crtc_atomic_modeset')
        self.assertIn('dcp_poweron(',b,'mode_changed alone still skips poweron')
        self.assertLess(b.index('dcp_poweron('),b.index('iomfb_modeset_v12_3('))
        self.assertIn('if (ret)',b)
        self.assertIn('WRITE_ONCE(dcp->hdmi_recovered, generation)',b)
        self.assertIn('if (!ret && recover)',b)
        p=src('iomfb_template.c')
        self.assertIn('int DCP_FW_NAME(iomfb_poweron)',p)
        self.assertIn('return ret > 0 ? 0 : -ETIMEDOUT;',p)
        self.assertIn('atomic_inc(&dcp->hdmi_generation)',p)
        self.assertIn('atomic_inc(&dcp->hdmi_generation)',body('dcp.c','dcp_dp2hdmi_hpd'))
        f=body('iomfb.c','dcp_flush')
        self.assertLess(f.index('dcp_needs_recovery('),f.index('iomfb_flush_v12_3('))
        self.assertIn('schedule_work(&dcp->vblank_wq)',f)
        self.assertNotIn('active_changed =',src('apple_drv.c'))
        # Preserve clear-submit ACK path; never pretend swap_complete is ACK.
        self.assertIn('dcp_swap_start(dcp, false, &swap_req, dcp_swap_clear_started, cookie);',p)
        self.assertIn('wait_for_completion_timeout(&cookie->done, msecs_to_jiffies(50))',p)
if __name__=='__main__': unittest.main(verbosity=2)
