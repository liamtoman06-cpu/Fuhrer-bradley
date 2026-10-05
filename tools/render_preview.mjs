// Dev tool: renders the model (and the key poses from src/Poses.lua) with three.js in headless Chromium.
// setup: npm i three@0.160.0 playwright-core   (Chromium path: CHROME_PATH env)
// usage: python3 tools/build_model.py --preview preview.json
//        node tools/render_preview.mjs preview.json out/shot front three back face3
//        SHEET=guard,run,lungeThrust node tools/render_preview.mjs preview.json out/poses
import { chromium } from 'playwright-core';
import fs from 'fs';
import path from 'path';

const [,, jsonPath, outPrefix, ...viewArgs] = process.argv;
const data = fs.readFileSync(jsonPath, 'utf8');
const threeSrc = fs.readFileSync(new URL(import.meta.resolve('three')).pathname, 'utf8');

function parseLua(src){
  src = src.replace(/--\[\[[\s\S]*?\]\]/g,'').replace(/--[^\n]*/g,'');
  let i = src.indexOf('{', src.indexOf('return'));
  function ws(){ while(/\s|,|;/.test(src[i])) i++; }
  function val(){ ws(); if(src[i]==='{') return tbl(); const m=/^-?[0-9.]+/.exec(src.slice(i)); i+=m[0].length; return parseFloat(m[0]); }
  function tbl(){ i++; const arr=[], obj={}; let isObj=false; for(;;){ ws(); if(src[i]==='}'){ i++; break; } const m=/^([A-Za-z_]\w*)\s*=/.exec(src.slice(i)); if(m){ i+=m[0].length; obj[m[1]]=val(); isObj=true; } else arr.push(val()); } return isObj?obj:arr; }
  return tbl();
}
const posesJson = JSON.stringify(parseLua(fs.readFileSync(process.env.POSES_FILE || path.join(path.dirname(new URL(import.meta.url).pathname), '../src/Poses.lua'),'utf8')));
const views = viewArgs.length ? viewArgs : ['front', 'three', 'back', 'side', 'face', 'face3'];
const html = `<!doctype html><html><body style="margin:0;background:#9aa4b4">
<canvas id=c width=900 height=1100></canvas>
<script type="importmap">{"imports":{"three":"data:text/javascript;base64,${Buffer.from(threeSrc).toString('base64')}"}}</script>
<script type="module">
import * as THREE from 'three';
const data = ${data};
const POSES = ${posesJson};
const HRP = new THREE.Vector3(0,5,0);
const D2R = Math.PI/180;
const bones = data.bones;
const order = []; (function walk(parent){ for (const [n,b] of Object.entries(bones)) if (b.parent===parent){ order.push(n); walk(n);} })('HumanoidRootPart');
function bpos(n){ return n==='HumanoidRootPart'? HRP.clone() : new THREE.Vector3(...bones[n].pos); }
function ang(rx,ry,rz){ const m=new THREE.Matrix4(); m.makeRotationFromEuler(new THREE.Euler(rx,ry,rz,'XYZ')); return m; }
function tr(v){ return new THREE.Matrix4().makeTranslation(v.x,v.y,v.z); }
const meshes = [];
function fk(pose){
  const T = {}; for (const n of order) T[n]=new THREE.Matrix4();
  const g=(a,i)=> (a&&a[i]!==undefined)?a[i]:0;
  const setRot=(n,a,extraPos)=>{ if(!a) return; const m=ang(g(a,0)*D2R,g(a,1)*D2R,g(a,2)*D2R); if(extraPos) m.premultiply(tr(new THREE.Vector3(g(a,3),g(a,4),g(a,5)))); T[n]=m; };
  setRot('B_Hips',pose.hips,true); setRot('B_Spine',pose.spine); setRot('B_Chest',pose.chest); setRot('B_Neck',pose.neck); setRot('B_Head',pose.head);
  for (const [k,side,sfx] of [['R',1,'R'],['L',-1,'L']]) { const a=pose[k]; if(!a) continue;
    const mir=(v)=> v? [g(v,0), g(v,1)*side, g(v,2)*side] : null;
    setRot('B_Shoulder'+sfx, mir(a.sh)); if(a.el) T['B_Elbow'+sfx]=ang(a.el*D2R,0,0); setRot('B_Hand'+sfx, mir(a.wr)); setRot('B_Saber'+sfx, mir(a.sb)); }
  // rels
  const rel={HumanoidRootPart:new THREE.Matrix4()};
  const C0=(n)=> tr(bpos(n).sub(bpos(bones[n].parent)));
  const solve=()=>{ for(const n of order){ rel[n]=rel[bones[n].parent].clone().multiply(C0(n)).multiply(T[n]); } };
  solve();
  // leg IK (same as BossClient)
  for (const [sfx,side,fk_] of [['R',1,'fR'],['L',-1,'fL']]) {
    const th='B_Thigh'+sfx, sh='B_Shin'+sfx, ft='B_Foot'+sfx;
    const v1=bpos(sh).sub(bpos(th)), v2=bpos(ft).sub(bpos(sh));
    const L1=Math.hypot(v1.y,v1.z), L2=Math.hypot(v2.y,v2.z), a1=Math.atan2(-v1.z,-v1.y), a2=Math.atan2(-v2.z,-v2.y), dx=v1.x+v2.x;
    const pivot=bpos(th).sub(bpos('B_Hips'));
    const restAnkle=bpos(ft).sub(HRP);
    const f=pose[fk_]||[0,0,0,0];
    const target=restAnkle.clone().add(new THREE.Vector3(g(f,0)*side,g(f,1),g(f,2)));
    const inv=rel['B_Hips'].clone().invert();
    const d=target.clone().applyMatrix4(inv).sub(pivot);
    let D=Math.hypot(d.y,d.z); D=Math.min(Math.max(D,Math.abs(L1-L2)+0.05),(L1+L2)*0.9995);
    const phiD=Math.atan2(-d.z,-d.y);
    const alpha=Math.acos(Math.min(1,Math.max(-1,(L1*L1+D*D-L2*L2)/(2*L1*D))));
    const beta=Math.acos(Math.min(1,Math.max(-1,(L2*L2+D*D-L1*L1)/(2*L2*D))));
    const phi1=phiD+alpha, phi2=phiD-beta;
    const roll=Math.min(0.45,Math.max(-0.45,Math.atan2(d.x-dx,D)));
    const hr=pose.hips||[0,0,0];
    T[th]=ang(phi1-a1,0,roll); T[sh]=ang(phi2-phi1+a1-a2,0,0);
    T[ft]=ang(g(f,3)*D2R-(phi2-a2)-g(hr,0)*D2R,0,-(g(hr,2)*D2R+roll));
  }
  solve();
  for (const m of meshes){ const W=tr(HRP).multiply(rel[m.bone]).multiply(tr(bpos(m.bone)).invert()).multiply(m.rest); m.obj.matrix.copy(W.multiply(m.scale)); }
}
window.fk = fk;
const canvas = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({canvas, antialias:true, preserveDrawingBuffer:true});
renderer.setSize(900,1100,false);
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x9aa4b4);
scene.add(new THREE.HemisphereLight(0xffffff, 0x445066, 1.6));
const sun = new THREE.DirectionalLight(0xffffff, 2.2); sun.position.set(-4, 10, -8); scene.add(sun);
const fill = new THREE.DirectionalLight(0xbcd0ff, 0.6); fill.position.set(6, 3, 6); scene.add(fill);
const hide = (window.HIDE||[]);
function wedgeGeo(){
  const g = new THREE.BufferGeometry();
  const v = [
    [-.5,-.5,-.5],[.5,-.5,-.5],[-.5,-.5,.5],[.5,-.5,.5],[-.5,.5,.5],[.5,.5,.5]];
  const tri = [[0,2,1],[1,2,3], [2,4,3],[3,4,5], [0,1,4],[1,5,4], [0,4,2],[1,3,5]];
  const pos=[]; for(const t of tri){ for(const i of t) pos.push(...v[i]); }
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos,3)); g.computeVertexNormals(); return g;
}
const geos = { ell: new THREE.SphereGeometry(0.5, 28, 20), block: new THREE.BoxGeometry(1,1,1), cyl: new THREE.CylinderGeometry(0.5,0.5,1,28).rotateZ(-Math.PI/2), wedge: wedgeGeo() };
function ouroTex(){
  const c=document.createElement('canvas'); c.width=c.height=256; const g=c.getContext('2d');
  g.fillStyle='#ece2de'; g.beginPath(); g.arc(128,128,110,0,7); g.fill();
  g.strokeStyle='#de1620'; g.lineWidth=16; g.beginPath(); g.arc(128,128,104,0,7); g.stroke();
  g.lineWidth=5; g.beginPath(); g.arc(128,128,76,0,7); g.stroke();
  g.lineWidth=7; for(const r of [0,1]){ g.beginPath(); for(let k=0;k<4;k++){const a=(-90+120*k+180*r)*Math.PI/180; const x=128+69*Math.cos(a), y=128+69*Math.sin(a); k?g.lineTo(x,y):g.moveTo(x,y);} g.stroke(); }
  g.fillStyle='#140004'; g.beginPath(); g.ellipse(128,128,9,20,0,0,7); g.fill();
  return new THREE.CanvasTexture(c);
}
const group = new THREE.Group(); scene.add(group);
const outline = new THREE.Group(); scene.add(outline);
const blackMat = new THREE.MeshBasicMaterial({color:0x111111, side:THREE.BackSide});
for (const p of data.parts) {
  if (hide.some(h => p.name.startsWith(h))) continue;
  if (p.gui.includes('ouroboros')) {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(p.size[0], p.size[1]), new THREE.MeshBasicMaterial({map: ouroTex(), transparent:true}));
    const cf=p.cf; const M=new THREE.Matrix4().set(cf[3],cf[4],cf[5],cf[0], cf[6],cf[7],cf[8],cf[1], cf[9],cf[10],cf[11],cf[2], 0,0,0,1);
    m.applyMatrix4(new THREE.Matrix4().makeRotationY(Math.PI)); m.position.z -= 0; m.applyMatrix4(new THREE.Matrix4().makeTranslation(0,0,0));
    const holder=new THREE.Object3D(); holder.add(m); m.position.set(0,0,-p.size[2]/2-0.002); holder.matrixAutoUpdate=false; holder.matrix.copy(M); group.add(holder);
    if (window.SHOWEYE) continue; else { holder.visible = !!window.SHOWEYE; continue; }
  }
  if (p.tr >= 0.99) continue;
  const col = new THREE.Color(p.color[0]/255, p.color[1]/255, p.color[2]/255).convertSRGBToLinear();
  const mat = new THREE.MeshStandardMaterial({color: col, roughness: p.refl>0.1?0.35:0.85, metalness: p.refl>0.2?0.5:0.0});
  const mesh = new THREE.Mesh(geos[p.kind] || geos.block, mat);
  const cf = p.cf;
  const M = new THREE.Matrix4().set(cf[3],cf[4],cf[5],cf[0], cf[6],cf[7],cf[8],cf[1], cf[9],cf[10],cf[11],cf[2], 0,0,0,1);
  M.multiply(new THREE.Matrix4().makeScale(p.size[0], p.size[1], p.size[2]));
  mesh.matrixAutoUpdate = false; mesh.matrix.copy(M);
  group.add(mesh);
  const REST = new THREE.Matrix4().set(cf[3],cf[4],cf[5],cf[0], cf[6],cf[7],cf[8],cf[1], cf[9],cf[10],cf[11],cf[2], 0,0,0,1);
  meshes.push({obj: mesh, bone: p.bone, rest: REST, scale: new THREE.Matrix4().makeScale(p.size[0], p.size[1], p.size[2])});
  if (Math.min(...p.size) > 0.09) {
    const o = new THREE.Mesh(geos[p.kind] || geos.block, blackMat);
    const s = p.size.map(x => x + 0.035);
    const M2 = new THREE.Matrix4().set(cf[3],cf[4],cf[5],cf[0], cf[6],cf[7],cf[8],cf[1], cf[9],cf[10],cf[11],cf[2], 0,0,0,1).multiply(new THREE.Matrix4().makeScale(s[0],s[1],s[2]));
    o.matrixAutoUpdate=false; o.matrix.copy(M2); outline.add(o);
    meshes.push({obj: o, bone: p.bone, rest: new THREE.Matrix4().set(cf[3],cf[4],cf[5],cf[0], cf[6],cf[7],cf[8],cf[1], cf[9],cf[10],cf[11],cf[2], 0,0,0,1), scale: new THREE.Matrix4().makeScale(s[0],s[1],s[2])});
  }
}
const ground = new THREE.Mesh(new THREE.CircleGeometry(6, 40).rotateX(-Math.PI/2), new THREE.MeshStandardMaterial({color:0x6c7480})); scene.add(ground);
window.shot = (pos, target, fov) => {
  const cam = new THREE.PerspectiveCamera(fov, 900/1100, 0.05, 100);
  cam.position.set(...pos); cam.lookAt(new THREE.Vector3(...target));
  renderer.render(scene, cam);
  return canvas.toDataURL('image/png');
};
window.POSESX = POSES; window.ready = true;
</script></body></html>`;

const VIEWS = {
  front: [[0, 4.8, -16], [0, 4.6, 0], 34],
  three: [[-9, 5.5, -12], [0, 4.6, 0], 34],
  back: [[2, 5.5, 15], [0, 4.6, 0], 34],
  side: [[16, 4.8, 0], [0, 4.6, 0], 34],
  face: [[0, 8.25, -3.2], [0, 8.2, -0.2], 22],
  face3: [[-2.2, 8.4, -2.6], [0, 8.2, -0.2], 22],
  facer: [[2.4, 8.3, -2.4], [0, 8.2, -0.2], 22],
  torso: [[0, 6.3, -7], [0, 6.0, 0], 30],
  hand: [[3.5, 4.2, -3], [1.4, 3.9, -1.2], 30],
  top: [[0, 14, -3], [0, 6, 0], 40],
  eye: [[-0.4, 8.26, -1.6], [-0.165, 8.24, -0.5], 8],
};

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--use-gl=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 900, height: 1100 } });
const hide = process.env.HIDE ? process.env.HIDE.split(',') : ['HiltR_', 'HiltL_'];
await page.addInitScript(`window.HIDE=${JSON.stringify(hide)}; window.SHOWEYE=${process.env.SHOWEYE ? 'true' : 'false'};`);
page.on('console', m => { if (m.type() === 'error') console.log('console:', m.text()); });
page.on('pageerror', e => console.log('pageerror:', e.message));
const tmp = outPrefix + '_page.html';
fs.writeFileSync(tmp, html);
await page.goto('file://' + path.resolve(tmp));
await page.waitForFunction('window.ready === true', null, { timeout: 60000 });
if (process.env.SHEET) {
  const names = process.env.SHEET.split(',');
  const view = process.env.SHEETVIEW || 'three';
  const [pos, target, fov] = VIEWS[view];
  const urls = [];
  for (const n of names) { urls.push(await page.evaluate(([n,p,t,f]) => { window.fk(window.POSESX[n]||{}); return window.shot(p,t,f); }, [n,pos,target,fov])); }
  const sheet = await page.evaluate(async ([urls, names]) => {
    const cols = Math.min(4, urls.length), rows = Math.ceil(urls.length/cols);
    const c = document.createElement('canvas'); c.width = cols*360; c.height = rows*440; const g = c.getContext('2d');
    for (let k=0;k<urls.length;k++){ const im = new Image(); im.src = urls[k]; await im.decode(); g.drawImage(im, (k%cols)*360, Math.floor(k/cols)*440, 360, 440); g.fillStyle='#000'; g.font='20px sans-serif'; g.fillText(names[k], (k%cols)*360+8, Math.floor(k/cols)*440+24); }
    return c.toDataURL('image/png'); }, [urls, names]);
  fs.writeFileSync(`${outPrefix}_sheet_${view}.png`, Buffer.from(sheet.split(',')[1], 'base64'));
}
for (const v of (process.env.SHEET ? [] : views)) {
  const [pos, target, fov] = VIEWS[v];
  const url = await page.evaluate(([p, t, f]) => window.shot(p, t, f), [pos, target, fov]);
  fs.writeFileSync(`${outPrefix}_${v}.png`, Buffer.from(url.split(',')[1], 'base64'));
}
await browser.close();
console.log('rendered', views.join(','));
