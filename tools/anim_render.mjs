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
  window.shot = (p, t, fov, roll) => { const cam = new THREE.PerspectiveCamera(fov, ${W}/${H}, 0.01, 60); cam.position.set(...p); cam.lookAt(...t); if (roll) cam.rotateZ(roll); r.render(scene, cam); return r.domElement.toDataURL('image/png'); };
  window.bonePos = (n) => { const v = new THREE.Vector3(); if (bones[n]) bones[n].getWorldPosition(v); return [v.x, v.y, v.z]; };
  // a stand-in player (R15-sized: root 3 studs up, 5.2 studs tall) for the cutscene previews
  const dummy = new THREE.Group(); const mat = new THREE.MeshStandardMaterial({ color: 0x9aa3ad });
  window.makeDummy = (U) => {
    const add = (w, h, d, y) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w * U, h * U, d * U), mat); m.position.y = y * U; dummy.add(m); };
    add(1.7, 2.0, 0.8, -2.0); add(2.0, 1.9, 1.0, -0.05); const head = new THREE.Mesh(new THREE.SphereGeometry(0.62 * U, 16, 12), mat); head.position.y = 1.55 * U; dummy.add(head);
    dummy.visible = false; scene.add(dummy); };
  window.placeDummy = (p) => { if (!p) { dummy.visible = false; return; } dummy.visible = true; dummy.position.set(...p); };
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
await page.evaluate(u => window.makeDummy(u), Number(process.env.CINE_U || 0.204));
const VIEWS = { front: [[0, 0.1, -3.6], [0, -0.05, 0], 32], three: [[-2.2, 0.45, -2.9], [0, -0.05, 0], 32], side: [[3.6, 0.1, 0], [0, -0.05, 0], 32],
  back: [[0.4, 0.4, 3.6], [0, -0.05, 0], 32], left: [[-3.6, 0.1, 0], [0, -0.05, 0], 32], face: [[0, 0.7, -1.2], [0, 0.7, 0], 26], high: [[-2.5, 1.6, -2.5], [0, -0.1, 0], 34] };
for (const job of jobs) {
  const [clipName, view, sel] = job.split(':');
  const clip = data.clips.find(c => c.name === clipName); if (!clip) { console.log('no clip', clipName); continue; }
  let idx = sel === 'gif' || sel === 'all' ? clip.frames.map((_, i) => i) : sel.split(',').map(Number);
  const urls = [];
  for (const i of idx) {
    const fr = clip.frames[Math.min(i, clip.frames.length - 1)];
    if (view === 'cine') {
      urls.push(await page.evaluate(([fr, cine, Uval]) => {
        window.apply(fr);
        const V = (a) => ({ x: a[0], y: a[1], z: a[2] }), add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]], sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]], mul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
        const len = (a) => Math.hypot(a[0], a[1], a[2]), unit = (a) => mul(a, 1 / (len(a) || 1)), lerp = (a, b, k) => add(a, mul(sub(b, a), k));
        const clamp01 = (x) => Math.max(0, Math.min(1, x)), prog = (a, b, x) => clamp01((x - a) / (b - a)), smooth = (x) => x * x * (3 - 2 * x), smoother = (x) => x * x * x * (x * (6 * x - 15) + 10);
        const U = Uval, t = fr.t, c = cine.cfg;
        // the victim: a player standing cine.victim studs ahead of where he started; launched at the kick
        let v = [0, -cine.hipsY + 3.0 * U, -cine.victim * U];
        const kd = [0, 0, -1], side = [-kd[2], 0, kd[0]];
        if (cine.kind === 'execution' && t >= c.KickAt) { const tau = t - c.KickAt; v = add(v, add(mul(kd, 125 * U * tau), [0, (55 * tau - 0.5 * 196.2 * tau * tau) * U, 0])); }
        window.placeDummy(cine.kind === 'execution' || cine.showTarget ? v : null);
        let P, T, fov, roll = 0;
        if (cine.kind === 'gaze') {
          const eye = window.bonePos('B_Patch'); const tgt = add(v, [0, 0.8 * U, 0]);
          const look = unit(sub(tgt, eye)); const sd = unit([-look[2], 0, look[0]]);
          const push = smoother(prog(c.Gaze[0], c.Gaze[0] + 0.32, t)), hold = prog(c.Gaze[0] + 0.32, c.Gaze[1], t);
          const close = add(add(add(eye, mul(look, (1.7 - 0.6 * hold) * U)), mul(sd, 0.12 * U)), [0, 0.05 * U, 0]);
          const from = add(tgt, [0, 3 * U, 9 * U]);
          P = lerp(from, close, push); T = lerp(cine.bossChest || [0, 0, 0], eye, push); fov = 70 + (20 - 70) * push + 10 * hold * push; roll = (7 - 13 * hold) * Math.PI / 180 * push;
        } else {
          const vChest = add(v, [0, 0.8 * U, 0]), boss = window.bonePos('B_Chest');
          if (t < c.DashStart) { const k = prog(0, c.DashStart, t); P = add(add(add(vChest, mul(side, (6.2 - 1.0 * k) * U)), mul(kd, -1.0 * U)), [0, 0.35 * U, 0]); T = add(vChest, mul(kd, -0.5 * U)); fov = 40 - 4 * k; roll = 6; }
          else if (t < c.DashEnd + 0.04) { const k = prog(c.DashStart, c.DashEnd + 0.04, t); P = add(add(add(v, mul(kd, (3.0 - 0.6 * k) * U)), mul(side, 2.6 * U)), [0, -1.2 * U, 0]); T = boss; fov = 60 - 20 * k; roll = -6; }
          else if (t < c.KickAt) { const k = prog(c.DashEnd + 0.04, c.KickAt, t); const mid = mul(add(boss, vChest), 0.5); P = add(add(mid, mul(side, (14 - 1.5 * k) * U)), [0, -1.0 * U, 0]); T = add(mid, [0, 0.5 * U, 0]); fov = 50; roll = -8; }
          else if (t < c.KickAt + 0.16) { P = add(add(add(boss, mul(side, 10 * U)), mul(kd, -6 * U)), [0, 2.5 * U, 0]); T = lerp(boss, v, 0.5); fov = 60; roll = 0; } else { P = add(add(add(v, mul(side, 9 * U)), mul(kd, -3 * U)), [0, 2 * U, 0]); T = add(v, mul(kd, 2 * U)); fov = 60; roll = 0; }
          roll = roll * Math.PI / 180;
        }
        return window.shot(P, T, fov, roll);
      }, [fr, JSON.parse(process.env.CINE || '{}'), Number(process.env.CINE_U || 0.204)]));
      continue;
    }
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
