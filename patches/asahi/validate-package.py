#!/usr/bin/env python3
import hashlib,json,pathlib,subprocess,sys
base=pathlib.Path(sys.argv[1]).resolve()
packages=list(base.glob('linux-asahi-hdmi-recover-*.pkg.tar.zst'))
assert len(packages)==1,packages
p=packages[0]
subprocess.run(['zstd','--test',str(p)],check=True)
names=subprocess.check_output(['bsdtar','-tf',str(p)],text=True).splitlines()
release='7.1.13-1-1-ARCH-hdmi-recover'
prefix=f'usr/lib/modules/{release}/'
assert prefix+'vmlinuz' in names
assert prefix+'pkgbase' in names
assert any(n.startswith(prefix+'dtbs/') and n.endswith('.dtb') for n in names)
assert prefix+'modules.dep' in names
assert prefix+'modules.builtin' in names
assert subprocess.check_output(['bsdtar','-xOf',str(p),prefix+'pkgbase']).strip()==b'linux-asahi-hdmi-recover'
info=subprocess.check_output(['bsdtar','-xOf',str(p),'.PKGINFO'],text=True)
assert 'pkgname = linux-asahi-hdmi-recover\n' in info
assert 'arch = aarch64\n' in info
releases=sorted({n.split('/')[3] for n in names if n.startswith('usr/lib/modules/') and len(n.split('/'))>4})
assert releases==[release],releases
modules=[n for n in names if n.endswith(('.ko','.ko.zst','.ko.xz'))]
assert modules
assert any('/appledrm.ko' in n for n in modules), 'Missing Apple DRM module'
assert not any(n.startswith(('boot/','etc/')) for n in names)
h=hashlib.sha256()
with p.open('rb') as f:
    for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
report={'package':str(p),'size_bytes':p.stat().st_size,'sha256':h.hexdigest(),'release':release,'modules':len(modules),'archive_entries':len(names),'archive_integrity':'zstd --test PASS','pkginfo':info,'hardware_verified':False}
(base/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
(base/'SHA256SUMS').write_text(f'{h.hexdigest()}  {p.name}\n')
print(json.dumps(report,indent=2))
