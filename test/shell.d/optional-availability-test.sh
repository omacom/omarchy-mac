#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
run_node_test <<'JS'
const fs = require('fs'), os = require('os'), cp = require('child_process')
const menu = requireFromRoot('shell/plugins/menu/MenuModel.js')
const items = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
const byId = Object.fromEntries(items.map(item => [item.id, item]))
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'availability-'))
try {
  const bin = path.join(tmp, 'bin'), calls = path.join(tmp, 'calls')
  fs.mkdirSync(bin)
  function stub(name, body) { fs.writeFileSync(path.join(bin, name), '#!/bin/bash\n'+body+'\n', {mode:0o755}) }
  stub('pacman', `echo "$*" >> "$CALLS"
case $1 in
-Slq) for p in primary secondary zed omazed xpadneo-dkms linux-headers linux-asahi-headers linux-aurora-headers; do [[ $p == "\${MISSING:-}" ]] || echo "$p"; done ;;
-Sp) [[ \${*: -1} == provided || \${*: -1} == 'provided>=1' ]] ;;
-Qq|-Qi) exit 0 ;;
*) exit 1 ;;
esac`)
  stub('uname', 'echo uname >> "$CALLS"; echo "${ARCH:-x86_64}"')
  stub('omarchy-hw-apple-silicon', '[[ ${APPLE:-0} == 1 ]]')
  stub('omarchy-pkg-kernel-headers', '[[ -n ${HEADERS:-} ]] && echo "$HEADERS"')
  const env = {...process.env, OMARCHY_PATH:root, CALLS:calls, PATH:bin+':'+root+'/bin:'+process.env.PATH}
  function run(script, extra={}) { return cp.spawnSync('bash', ['-euo','pipefail','-c',script], {env:{...env,...extra},encoding:'utf8'}) }
  const prelude = menu.guardScript({probe:{id:'probe',when:'true'}}).split('\n').filter(l=>!l.startsWith('if {')).join('\n')
  for (const targets of ['', 'primary secondary', 'primary missing', 'provided', "'provided>=1'", "'provided>=9'", "''"]) {
    const expected = ['primary missing', "'provided>=9'", "''"].includes(targets)?1:0
    for (const script of [`"${root}/bin/omarchy-pkg-available" ${targets}`, prelude+`\nomarchy-pkg-available ${targets}`]) {
      const result=run(script); assertEqual(result.status,expected,`CLI/batch explicit targets: ${targets}`,result.stderr)
    }
  }
  function checkRow(id, expected, extra={}) {
    const item=byId[id]; assert(item,`menu row exists: ${id}`)
    const direct=run(item.when,extra)
    const batch=run(menu.guardScript({[id]:{...item,disabled:''}}),extra)
    assertEqual(direct.status,expected,`direct guard ${id}`,direct.stderr)
    assertEqual(batch.status,0,`batch evaluates ${id}`,batch.stderr)
    assertEqual(batch.stdout.trim(),`${id}:w:${expected===0?1:0}`,`batch guard ${id}`)
  }
  for (const arch of ['x86_64','aarch64','riscv64']) {
    for (const browser of ['chrome','edge']) checkRow('install.browser.'+browser, arch==='x86_64'?0:1,{ARCH:arch})
    for (const browser of ['brave','brave-origin','zen']) checkRow('install.browser.'+browser,arch==='riscv64'?1:0,{ARCH:arch})
  }
  checkRow('install.editor.zed',0)
  checkRow('install.editor.zed',1,{MISSING:'zed'})
  for (const headers of ['linux-headers','linux-asahi-headers','linux-aurora-headers']) {
    checkRow('install.gaming.xbox-controllers',0,{HEADERS:headers})
    checkRow('install.gaming.xbox-controllers',1,{HEADERS:headers,MISSING:headers})
    checkRow('install.gaming.xbox-controllers',1,{HEADERS:headers,MISSING:'xpadneo-dkms'})
    checkRow('install.gaming.xbox-controllers',0,{HEADERS:headers,MISSING:headers==='linux-headers'?'linux-asahi-headers':'linux-headers'})
  }
  checkRow('install.gaming.xbox-controllers',1,{HEADERS:''})
  fs.writeFileSync(calls,'')
  const cacheItems={}
  for (const id of ['install.browser.chrome','install.browser.brave']) cacheItems[id]={...byId[id],disabled:''}
  const cache=run(menu.guardScript(cacheItems)+'\nomarchy-pkg-available primary provided\nomarchy-pkg-available secondary provided')
  assertEqual(cache.status,0,'cached batch completes',cache.stderr)
  const lines=fs.readFileSync(calls,'utf8').trim().split('\n')
  assertEqual(lines.filter(l=>l==='uname').length,1,'architecture is read once per batch')
  assertEqual(lines.filter(l=>l==='-Slq').length,1,'sync database is read once per batch')
  assertEqual(lines.filter(l=>l.startsWith('-Sp')&&l.endsWith('provided')).length,1,'provider lookup is cached')
  const incomplete=path.join(tmp,'incomplete');fs.mkdirSync(path.join(incomplete,'bin'),{recursive:true})
  stub('omarchy-pkg-available','echo recursive-dispatch >> "$CALLS"; exit 42')
  const file=path.join(incomplete,'bin/omarchy-pkg-available')
  for (const content of [null,'','return 1','omarchy-pkg-available() { return 0; }','__omarchy_pkg_available_ready=true']) {
    fs.rmSync(file,{force:true});if(content!==null)fs.writeFileSync(file,content)
    fs.writeFileSync(calls,'')
    const result=run(prelude+'\nomarchy-pkg-available primary',{OMARCHY_PATH:incomplete})
    assertEqual(result.status,1,'incomplete source aborts the batch')
    assert(!fs.readFileSync(calls,'utf8').includes('recursive-dispatch'),'incomplete source never dispatches through PATH')
  }
} finally { fs.rmSync(tmp,{recursive:true,force:true}) }
JS
