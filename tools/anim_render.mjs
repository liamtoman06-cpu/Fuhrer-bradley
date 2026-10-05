// Renders Animator output (tools/luau harness frames) on the skinned GLB in headless Chromium.
//   node tools/anim_render.mjs model.glb rig.json frames.json out_prefix [clip:view:frames|all] ...
//   e.g.  run:side:0,4,8,12   or   run:three:gif   (gif = every frame -> out_prefix_run.gif via ffmpeg)
import { chromium } from 'playwright-core';
import fs from 'fs'; import path from 'path'; import { execSync } from 'child_process';
const [,, glbPath, rigPath, framesPath, outPrefix, ...jobs] = process.argv;
const three = fs.readFileSync(new URL(import.meta.resolve('three')).pathname, 'utf8');
const dir = path.dirname(new URL(import.meta.resolve('three')).pathname) + '/../examples/jsm/';
const loader = fs.readFileSync(dir + 'loaders/GLTFLoader.js', 'utf8');
const utils = fs.readFileSync(dir + 'utils/BufferGeometryUtils.js', 'utf8');
const b64 = s => 'data:text/javascript;base64,' + Buffer.from(s).toString('base64');
const glb = fs.readFileSync(glbPath).toString('base64');
const rig = JSON.parse(fs.readFileSync(rigPath, 'utf8'));
const hips = rig.bones.find(b => b.name === 'B_Hips').head;
const W = 640, H = 760;
const html = `<!doctype html><body style="margin:0"><canvas id=c width=${W} height=${H}></canvas>
<script type="importmap">{"imports":{"three":"${b64(three)}","three/addons/utils/BufferGeometryUtils.js":"${b64(utils)}","gltfloader":"${b64(loader.replace(/'\.\.\/utils\/BufferGeometryUtils\.js'/g, "'three/addons/utils/BufferGeometryUtils.js'"))}"}}</script>
<script type="module">
import * as THREE from 'three'; import { GLTFLoader } from 'gltfloader';
const r = new THREE.WebGLRenderer({canvas: document.getElementById('c'), antialias: true, preserveDrawingBuffer: true});
r.setSize(${W},${H},false); r.toneMapping = THREE.ACESFilmicToneMapping; r.outputColorSpace = THREE.SRGBColorSpace;
const scene = new THREE.Scene(); scene.background = new THREE.Color(0x8d97a6);
scene.add(new THREE.HemisphereLight(0xffffff, 0x404858, 1.5));
const sun = new THREE.DirectionalLight(0xffffff, 2.4); sun.position.set(-2, 4, -5); scene.add(sun);
const rim = new THREE.DirectionalLight(0xc8d8ff, 1.0); rim.position.set(3, 2, 4); scene.add(rim);
const grid = new THREE.GridHelper(20, 40, 0x556070, 0x6c7684); grid.position.y = -${hips[1]}; scene.add(grid);
const bin = Uint8Array.from(atob('${glb}'), c => c.charCodeAt(0));
const HOLDER = new THREE.Matrix4().makeRotationY(Math.PI).invert().multiply(new THREE.Matrix4().makeTranslation(${-hips[0]}, ${-hips[1]}, ${-hips[2]}));
new GLTFLoader().parse(bin.buffer, '', g => {
  const root = g.scene; root.matrixAutoUpdate = false; scene.add(root);
  const bones = {}, rest = {};
  root.traverse(o => { if (o.isBone) { bones[o.name] = o; o.updateMatrix(); rest[o.name] = o.matrix.clone(); } if (o.isMesh) o.frustumCulled = false; });
  window.apply = (fr) => {
    root.matrix.copy(new THREE.Matrix4().makeTranslation(fr.root[0], fr.root[1], fr.root[2]).multiply(HOLDER));
    for (const [n, a] of Object.entries(fr.bones)) {
      const b = bones[n]; if (!b) continue;
      const T = new THREE.Matrix4().set(a[3],a[4],a[5],a[0], a[6],a[7],a[8],a[1], a[9],a[10],a[11],a[2], 0,0,0,1);
      const m = rest[n].clone().multiply(T); m.decompose(b.position, b.quaternion, b.scale);
    }
    root.updateMatrixWorld(true);
  };
  window.shot = (p, t, fov) => { const cam = new THREE.PerspectiveCamera(fov, ${W}/${H}, 0.01, 60); cam.position.set(...p); cam.lookAt(...t); r.render(scene, cam); return r.domElement.toDataURL('image/png'); };
  window.hide = (prefixes) => { root.traverse(o => { if (o.isMesh) o.visible = !prefixes.some(p => o.name.startsWith(p) || (o.parent && o.parent.name.startsWith(p))); }); };
  window.ready = true;
}, e => { document.title = 'ERR ' + e; });
</script></body>`;
const data = JSON.parse(fs.readFileSync(framesPath, 'utf8'));
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--use-gl=swiftshader','--enable-webgl','--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: W, height: H } });
page.on('pageerror', e => console.log('pageerror', e.message));
fs.writeFileSync(outPrefix + '_page.html', html);
await page.goto('file://' + path.resolve(outPrefix + '_page.html'));
await page.waitForFunction('window.ready === true || document.title.startsWith("ERR")', null, { timeout: 120000 });
if (process.env.HIDE) await page.evaluate(h => window.hide(h.split(',')), process.env.HIDE);
const VIEWS = { front: [[0, 0.1, -3.6], [0, -0.05, 0], 32], three: [[-2.2, 0.45, -2.9], [0, -0.05, 0], 32], side: [[3.6, 0.1, 0], [0, -0.05, 0], 32],
  back: [[0.4, 0.4, 3.6], [0, -0.05, 0], 32], left: [[-3.6, 0.1, 0], [0, -0.05, 0], 32], face: [[0, 0.7, -1.2], [0, 0.7, 0], 26], high: [[-2.5, 1.6, -2.5], [0, -0.1, 0], 34] };
for (const job of jobs) {
  const [clipName, view, sel] = job.split(':');
  const clip = data.clips.find(c => c.name === clipName); if (!clip) { console.log('no clip', clipName); continue; }
  let idx = sel === 'gif' || sel === 'all' ? clip.frames.map((_, i) => i) : sel.split(',').map(Number);
  const urls = [];
  for (const i of idx) {
    const fr = clip.frames[Math.min(i, clip.frames.length - 1)];
    const [p, t, f] = VIEWS[view];
    const follow = [fr.root[0], fr.root[1], fr.root[2]];
    const P = [p[0] + follow[0], p[1] + follow[1], p[2] + follow[2]], Tg = [t[0] + follow[0], t[1] + follow[1], t[2] + follow[2]];
    urls.push(await page.evaluate(([fr, P, Tg, f]) => { window.apply(fr); return window.shot(P, Tg, f); }, [fr, P, Tg, f]));
  }
  if (sel === 'gif') {
    const tmp = outPrefix + '_' + clipName + '_frames'; fs.mkdirSync(tmp, { recursive: true });
    urls.forEach((u, i) => fs.writeFileSync(`${tmp}/f${String(i).padStart(4, '0')}.png`, Buffer.from(u.split(',')[1], 'base64')));
    const ff = process.env.FFMPEG || '/opt/pw-browsers/ffmpeg-1011/ffmpeg-linux';
    try { execSync(`${ff} -y -loglevel error -framerate 30 -i ${tmp}/f%04d.png -vf "scale=400:-1:flags=lanczos" ${outPrefix}_${clipName}_${view}.webm`); } catch (e) { console.log('ffmpeg failed', e.message); }
    continue;
  }
  const sheet = await page.evaluate(async ([urls, labels]) => {
    const cols = Math.min(5, urls.length), rows = Math.ceil(urls.length / cols), w = 300, h = 356;
    const c = document.createElement('canvas'); c.width = cols * w; c.height = rows * h; const g = c.getContext('2d');
    for (let k = 0; k < urls.length; k++) { const im = new Image(); im.src = urls[k]; await im.decode(); g.drawImage(im, (k % cols) * w, Math.floor(k / cols) * h, w, h); g.fillStyle = '#000'; g.font = '16px sans-serif'; g.fillText(labels[k], (k % cols) * w + 6, Math.floor(k / cols) * h + 18); }
    return c.toDataURL('image/png'); }, [urls, idx.map(i => `${clipName} ${(clip.frames[Math.min(i, clip.frames.length-1)].t).toFixed(2)}s`)]);
  fs.writeFileSync(`${outPrefix}_${clipName}_${view}.png`, Buffer.from(sheet.split(',')[1], 'base64'));
}
await browser.close(); console.log('done');
