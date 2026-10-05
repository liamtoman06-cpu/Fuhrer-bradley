"""
King Bradley - rebuild of the premade GLB into a skinned, animation-ready character (Blender 4.2).

    python3 tools/blender/build_rig.py <input.glb> <out_dir>

Steps
  1. import the premade design (Blender: X = his left, -Y = forward, Z = up; metres)
  2. sculpt a new upper body: a watertight, anatomical skin mesh (traps, delts, pecs, lats, biceps,
     triceps, elbows, forearms) fused by voxel remesh, smoothed, decimated
  3. fit a compression shirt shell over it (short sleeves with a rib hem) and move the suspenders
     and buckles onto the new chest so nothing floats or clips
  4. build the armature: every bone points straight up with zero roll, so every joint's rest frame
     equals the character frame (the animation code relies on that only through measured data)
  5. skin everything: bone heat on the body, weight transfer onto the shirt, smooth chain weights on
     legs and trousers, a bilinear cloth grid on the cape, rigid props on their own bones
  6. split props for the scripts (4 spare saber hilts), name every mesh <Region>_<Material>
  7. decimate to Roblox limits (< 20k triangles per mesh) and export GLB + FBX
"""
import sys
import math
import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
SRC = argv[0] if len(argv) > 0 else "/root/.claude/uploads/f706b68f-529f-5d80-8f4b-0a0acfa52ad2/fc13b1a1-King_Bradley_Boss.glb"
OUT = argv[1] if len(argv) > 1 else "/tmp/bradley_out"
FAST = "--fast" in sys.argv

import os
os.makedirs(OUT, exist_ok=True)

V = Vector


def log(*a):
    print("[build]", *a, flush=True)


# =================================================================================================
# 1. Import
# =================================================================================================
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
scene = bpy.context.scene

# flatten the hierarchy (keep world transforms), drop the empties
for o in list(bpy.data.objects):
    if o.type == "MESH":
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
for o in list(bpy.data.objects):
    if o.type != "MESH":
        bpy.data.objects.remove(o, do_unlink=True)


def obj(name):
    return bpy.data.objects.get(name)


def select_only(objs, active=None):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or (objs[0] if objs else None)


def apply_all_transforms(o):
    select_only([o])
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


for o in list(bpy.data.objects):
    apply_all_transforms(o)


def mesh_verts(o):
    n = len(o.data.vertices)
    a = np.empty(n * 3)
    o.data.vertices.foreach_get("co", a)
    return a.reshape(n, 3)


def set_verts(o, arr):
    o.data.vertices.foreach_set("co", arr.reshape(-1))
    o.data.update()


def tri_count(o):
    o.data.calc_loop_triangles()
    return len(o.data.loop_triangles)


def material_of(o):
    return o.data.materials[0] if o.data.materials else None


# =================================================================================================
# 2. Joints (measured from the premade mesh; left side, mirrored for the right)
# =================================================================================================
J = {
    "Hips": V((0.0, 0.0, 0.975)),
    "Spine": V((0.0, 0.005, 1.10)),
    "Chest": V((0.0, 0.01, 1.27)),
    "Neck": V((0.0, 0.0, 1.50)),
    "Head": V((0.0, -0.005, 1.585)),
    "Clavicle": V((0.035, -0.02, 1.455)),
    "UpperArm": V((0.195, 0.0, 1.425)),
    "Forearm": V((0.325, -0.005, 1.122)),
    "Hand": V((0.448, -0.052, 0.886)),
    "Thigh": V((0.095, 0.0, 0.935)),
    "Shin": V((0.118, -0.012, 0.50)),
    "Foot": V((0.134, 0.004, 0.098)),
    "Toe": V((0.152, -0.135, 0.03)),
}


def mirror(v):
    return V((-v.x, v.y, v.z))


def side_point(name, side):
    p = J[name]
    return p if side == "L" else mirror(p)


# =================================================================================================
# 3. The new upper body (skin): muscle volumes fused by voxel remesh
# =================================================================================================
def ellipsoid(bm, center, radii, axes=None, segs=20, rings=12):
    """Adds an ellipsoid to bm. axes: 3x3 columns (u, v, w) the radii run along."""
    ret = bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0)
    M = Matrix.Identity(4)
    if axes is None:
        axes = Matrix.Identity(3)
    for i in range(3):
        for j in range(3):
            M[i][j] = axes[i][j] * radii[j]
    M.translation = center
    bmesh.ops.transform(bm, matrix=M, verts=ret["verts"])


def frame_from(u, hint):
    """3x3 matrix with columns (u, a, b): u = main axis, a = hint orthogonalised, b = u x a."""
    u = u.normalized()
    a = (hint - u * hint.dot(u)).normalized()
    b = u.cross(a)
    m = Matrix.Identity(3)
    for i in range(3):
        m[i][0], m[i][1], m[i][2] = u[i], a[i], b[i]
    return m


def capsule(bm, a, b, ra, rb, n=6):
    """Tapered capsule from a to b as a chain of overlapping spheres."""
    for k in range(n + 1):
        t = k / n
        p = a.lerp(b, t)
        r = ra + (rb - ra) * t
        ellipsoid(bm, p, (r, r, r), segs=16, rings=10)


def build_left_arm(bm):
    S, E, W = J["UpperArm"], J["Forearm"], J["Hand"]
    fwd = V((0, -1, 0))
    u1 = (E - S).normalized()
    lat1 = fwd.cross(u1).normalized()  # outward, away from the body
    f1 = (fwd - u1 * fwd.dot(u1)).normalized()
    u2 = (W - E).normalized()
    lat2 = fwd.cross(u2).normalized()
    f2 = (fwd - u2 * fwd.dot(u2)).normalized()

    def P1(a, f=0.0, l=0.0):
        return S + u1 * a + f1 * f + lat1 * l

    def P2(a, f=0.0, l=0.0):
        return E + u2 * a + f2 * f + lat2 * l

    A1 = frame_from(u1, f1)  # columns: along arm, forward, outward
    A2 = frame_from(u2, f2)
    # shoulder: acromion cap and the three heads of the deltoid wrapping the joint
    ellipsoid(bm, P1(-0.005, 0.0, 0.022), (0.052, 0.058, 0.05), A1)
    ellipsoid(bm, P1(0.062, 0.042, 0.022), (0.088, 0.046, 0.05), frame_from(u1 * 0.94 + lat1 * -0.12 + f1 * 0.3, f1))
    ellipsoid(bm, P1(0.058, 0.0, 0.05), (0.095, 0.05, 0.05), A1)
    ellipsoid(bm, P1(0.065, -0.044, 0.02), (0.088, 0.047, 0.05), frame_from(u1 * 0.94 + f1 * -0.3, f1))
    ellipsoid(bm, P1(0.145, 0.0, 0.034), (0.045, 0.03, 0.03), A1)  # deltoid insertion
    # humerus core
    capsule(bm, P1(0.02), P1(0.29), 0.043, 0.04)
    # biceps (peaked), brachialis, triceps long + lateral heads, flat triceps tendon
    ellipsoid(bm, P1(0.165, 0.028, 0.0), (0.083, 0.046, 0.042), A1)
    ellipsoid(bm, P1(0.235, 0.008, 0.03), (0.055, 0.032, 0.032), A1)
    ellipsoid(bm, P1(0.13, -0.034, 0.028), (0.075, 0.036, 0.036), A1)
    ellipsoid(bm, P1(0.155, -0.04, -0.012), (0.09, 0.04, 0.036), A1)
    ellipsoid(bm, P1(0.255, -0.032, 0.0), (0.05, 0.026, 0.032), A1)
    # elbow: olecranon and both epicondyles
    ellipsoid(bm, E + f1 * -0.034, (0.024, 0.024, 0.026), A1)
    ellipsoid(bm, E + lat1 * 0.036, (0.022, 0.022, 0.022), A1)
    ellipsoid(bm, E + lat1 * -0.034, (0.022, 0.022, 0.022), A1)
    ellipsoid(bm, E, (0.04, 0.041, 0.042), A1)
    # forearm: brachioradialis + extensors (outer), flexors (inner), tapering to the wrist
    ellipsoid(bm, P2(0.065, 0.012, 0.036), (0.075, 0.032, 0.032), A2)
    ellipsoid(bm, P2(0.085, -0.022, 0.022), (0.08, 0.03, 0.03), A2)
    ellipsoid(bm, P2(0.075, 0.022, -0.026), (0.082, 0.033, 0.032), A2)
    capsule(bm, P2(0.02), P2(0.265), 0.04, 0.028)
    ellipsoid(bm, W + u2 * -0.01, (0.03, 0.026, 0.034), A2)


def build_torso_extras(bm):
    # trapezius slope from the neck to the shoulder, upper back, pecs, lats, serratus
    for s in (1, -1):
        neck = V((0.045 * s, 0.025, 1.49))
        sh = V((0.17 * s, 0.01, 1.445))
        ax = frame_from(sh - neck, V((0, 0, 1)))
        ellipsoid(bm, neck.lerp(sh, 0.45) + V((0, 0.0, -0.005)), ((sh - neck).length * 0.62, 0.036, 0.05), ax)
        ellipsoid(bm, V((0.072 * s, -0.082, 1.355)), (0.086, 0.064, 0.036), frame_from(V((s, 0, -0.18)), V((0, 0, 1))))
        ellipsoid(bm, V((0.125 * s, 0.03, 1.25)), (0.05, 0.11, 0.075), frame_from(V((0.1 * s, 0, 1)), V((s, 0, 0))))
        ellipsoid(bm, V((0.08 * s, 0.07, 1.38)), (0.07, 0.05, 0.05))  # upper back / rhomboids


def close_and_shrink(o, inset):
    """Watertight copy of the torso shirt, pulled in by `inset` along its normals."""
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.holes_fill(bm, edges=bm.edges, sides=0)
    bm.normal_update()
    for v in bm.verts:
        v.co -= v.normal * inset
    return bm


log("building the new upper body")
torso_src = obj("UpperTorso_Shirt")
bm = close_and_shrink(torso_src, 0.004)
arm_bm = bmesh.new()
build_left_arm(arm_bm)
# mirror the left arm into the right
mirror_bm = arm_bm.copy()
bmesh.ops.scale(mirror_bm, vec=V((-1, 1, 1)), verts=mirror_bm.verts)
bmesh.ops.reverse_faces(mirror_bm, faces=mirror_bm.faces)
build_torso_extras(bm)
me = bpy.data.meshes.new("BodySkin")
for extra in (arm_bm, mirror_bm):
    tmp = bpy.data.meshes.new("tmp")
    extra.to_mesh(tmp)
    bm.from_mesh(tmp)
    bpy.data.meshes.remove(tmp)
bm.to_mesh(me)
bm.free()
body = bpy.data.objects.new("Body_Skin", me)
scene.collection.objects.link(body)

select_only([body])
me.remesh_voxel_size = 0.0045 if not FAST else 0.008
me.remesh_voxel_adaptivity = 0.0
bpy.ops.object.voxel_remesh()
log("voxel body faces", len(me.polygons))


def add_mod(o, kind, **props):
    m = o.modifiers.new(kind.lower(), kind)
    for k, v in props.items():
        setattr(m, k, v)
    return m


def apply_mods(o):
    select_only([o])
    for m in list(o.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


add_mod(body, "SMOOTH", factor=0.75, iterations=9)
add_mod(body, "CORRECTIVE_SMOOTH", factor=0.5, iterations=6, smooth_type="SIMPLE")
apply_mods(body)

# =================================================================================================
# 4. Skin / shirt split, shirt shell, hem
# =================================================================================================
def seg_param(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return t, (a + ab * t - p).length


SLEEVE_T = 0.40  # fraction of the upper arm the sleeve covers (from the shoulder joint)


def region_of(p):
    """'torso', 'upper', 'fore' and the side for a body point."""
    best = None
    side = "L" if p.x >= 0 else "R"
    S, E, W = side_point("UpperArm", side), side_point("Forearm", side), side_point("Hand", side)
    tu, du = seg_param(p, S, E)
    tf, df = seg_param(p, E, W)
    # torso axis: a vertical segment through the chest
    tt, dt = seg_param(p, V((0, 0.0, 0.98)), V((0, 0.0, 1.5)))
    lateral = abs(p.x) - abs(S.x) * 0.92
    if df < du and df < 0.07:
        return "fore", side, tf
    if du < 0.085 and (lateral > -0.01 or tu > 0.15):
        return "upper", side, tu
    return "torso", side, 0.0


def build_shirt_from(body_obj):
    sh = body_obj.copy()
    sh.data = body_obj.data.copy()
    sh.name = "Shirt_Shirt"
    scene.collection.objects.link(sh)
    bm = bmesh.new()
    bm.from_mesh(sh.data)
    for side in ("L", "R"):
        S, E = side_point("UpperArm", side), side_point("Forearm", side)
        n = (E - S).normalized()
        # sleeves sit a little lower on the outside of the arm
        tilt = V((0.0, 0.0, 1.0)) * 0.25 if side == "L" else V((0.0, 0.0, 1.0)) * 0.25
        n = (n + tilt * 0.0).normalized()
        co = S + (E - S) * SLEEVE_T
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, dist=1e-5, plane_co=co, plane_no=n)
        kill = []
        for f in bm.faces:
            c = f.calc_center_median()
            reg, fside, t = region_of(c)
            if fside == side and reg in ("upper", "fore") and (c - co).dot(n) > 0:
                kill.append(f)
        bmesh.ops.delete(bm, geom=kill, context="FACES")
    # drop tiny islands left behind
    bm.to_mesh(sh.data)
    bm.free()
    add_mod(sh, "SMOOTH", factor=0.6, iterations=4)
    add_mod(sh, "DISPLACE", strength=0.0055, mid_level=0.0, direction="NORMAL")
    apply_mods(sh)
    return sh


def trim_hidden_skin(body_obj):
    """The torso skin under the shirt is never seen: delete it (keep a margin under the sleeves)."""
    bm = bmesh.new()
    bm.from_mesh(body_obj.data)
    kill = []
    for f in bm.faces:
        reg, side, t = region_of(f.calc_center_median())
        if reg == "torso" or (reg == "upper" and t < SLEEVE_T - 0.12):
            kill.append(f)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(body_obj.data)
    bm.free()


def hem_from_boundary(src, name, radius, keep):
    """A rib band: tube along the open boundary loops of `src` that pass `keep`."""
    bm = bmesh.new()
    bm.from_mesh(src.data)
    edges = [e for e in bm.edges if e.is_boundary]
    keep_e = set(e for e in edges if keep((e.verts[0].co + e.verts[1].co) / 2))
    log(name, "boundary edges", len(edges), "kept", len(keep_e))
    bmesh.ops.delete(bm, geom=[f for f in bm.faces], context="FACES_ONLY")
    bmesh.ops.delete(bm, geom=[e for e in bm.edges if e not in keep_e], context="EDGES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_edges], context="VERTS")
    me2 = bpy.data.meshes.new(name)
    bm.to_mesh(me2)
    bm.free()
    o = bpy.data.objects.new(name, me2)
    scene.collection.objects.link(o)
    select_only([o])
    bpy.ops.object.convert(target="CURVE")
    o.data.bevel_depth = radius
    o.data.bevel_resolution = 2
    o.data.fill_mode = "FULL"
    bpy.ops.object.convert(target="MESH")
    return o


# untrimmed, watertight copy: the weighting proxy for everything on the upper body
proxy = body.copy()
proxy.data = body.data.copy()
proxy.name = "WeightProxy"
scene.collection.objects.link(proxy)
shirt = build_shirt_from(body)
trim_hidden_skin(body)
# rib hem along the sleeve openings, then give the shirt its thickness
sleeve_hem = hem_from_boundary(shirt, "SleeveHem_ShirtRib", 0.0055, lambda p: abs(p.x) > 0.17 and p.z < 1.42)
add_mod(shirt, "SOLIDIFY", thickness=0.003, offset=-1.0, use_rim=True)
apply_mods(shirt)
log("shirt faces", len(shirt.data.polygons), "skin faces", len(body.data.polygons))

# =================================================================================================
# 5. Move the suspenders / buckles onto the new chest (keep their thickness)
# =================================================================================================
def bvh_of(o):
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bm.transform(o.matrix_world)
    t = BVHTree.FromBMesh(bm)
    bm.free()
    return t


old_bvh = bvh_of(torso_src)
new_bvh = bvh_of(shirt)
for name in ("UpperTorso_LeatherDark", "UpperTorso_Iron", "UpperTorso_LeatherBelt"):
    o = obj(name)
    if not o:
        continue
    vs = mesh_verts(o)
    out = vs.copy()
    for i, p in enumerate(vs):
        loc, nrm, _, d = old_bvh.find_nearest(V(p))
        if loc is None or d > 0.06:
            continue
        hit = new_bvh.ray_cast(loc - nrm * 0.03, nrm, 0.08)
        hit2 = new_bvh.ray_cast(loc + nrm * 0.05, -nrm, 0.08)
        cands = [h[0] for h in (hit, hit2) if h[0] is not None]
        if not cands:
            continue
        q = min(cands, key=lambda c: (c - loc).length)
        out[i] = p + np.array(q - loc) + np.array(nrm) * 0.0015
    set_verts(o, out)

# the old pieces the new body replaces
for name in ["UpperTorso_Shirt", "LeftUpperArm_Shirt", "LeftUpperArm_Skin", "LeftUpperArm_ShirtRib", "LeftLowerArm_Skin",
             "RightUpperArm_Shirt", "RightUpperArm_Skin", "RightUpperArm_ShirtRib", "RightLowerArm_Skin"]:
    o = obj(name)
    if o:
        bpy.data.objects.remove(o, do_unlink=True)

# materials for the new meshes
def mat_named(n):
    return bpy.data.materials.get(n)


for o, mn in ((body, "Skin"), (shirt, "Shirt"), (sleeve_hem, "ShirtRib")):
    o.data.materials.clear()
    if mat_named(mn):
        o.data.materials.append(mat_named(mn))

for o in (body, shirt, sleeve_hem):
    for poly in o.data.polygons:
        poly.use_smooth = True

if "--stage1" in sys.argv:
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "stage1.glb"), export_format="GLB", export_apply=True)
    log("stage1 written")
    sys.exit(0)

# =================================================================================================
# 6. Materials: realistic skin tone, no emissive "glow" on skin
# =================================================================================================
def srgb_to_lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def set_base(mat_name, rgb, rough=None, metal=None):
    m = mat_named(mat_name)
    if not m or not m.node_tree:
        return
    bsdf = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if not bsdf:
        return
    bsdf.inputs["Base Color"].default_value = (srgb_to_lin(rgb[0]), srgb_to_lin(rgb[1]), srgb_to_lin(rgb[2]), 1)
    if rough is not None:
        bsdf.inputs["Roughness"].default_value = rough
    if metal is not None:
        bsdf.inputs["Metallic"].default_value = metal
    for key in ("Emission Color", "Emission"):
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = (0, 0, 0, 1)
    if "Emission Strength" in bsdf.inputs:
        bsdf.inputs["Emission Strength"].default_value = 0.0


set_base("Skin", (214, 166, 132), rough=0.55)
set_base("SkinShade", (168, 116, 88))
set_base("Lips", (176, 112, 92))
set_base("Crease", (112, 66, 50))

# =================================================================================================
# 7. Merge pieces that share a region and a material; split the spare sabers and the scabbards
# =================================================================================================
def join(names, new_name):
    objs = [obj(n) for n in names if obj(n)]
    if not objs:
        return None
    select_only(objs, objs[0])
    if len(objs) > 1:
        bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    o.name = new_name
    o.data.name = new_name
    return o


join(["Head_Skin_1", "Head_Skin_2"], "Head_Skin")
join(["Head_Hair_1", "Head_Hair_2"], "Head_Hair")
obj("Head_Eyepatch").name = "Patch_Eyepatch"


def split_loose(o):
    select_only([o])
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="LOOSE")
    bpy.ops.object.mode_set(mode="OBJECT")
    return [x for x in bpy.context.selected_objects]


def centroid(o):
    return V(mesh_verts(o).mean(0))


# Scabbards: 4 sheathed sabers (two per hip). Each loose island goes to the nearest scabbard axis.
scab_parts = {}
for kind in ("Scabbard", "Brass", "Pupil", "LeatherDark", "Grip"):
    o = obj("Scabbards_" + kind)
    if o:
        scab_parts[kind] = split_loose(o)
scab_axes = []
for o in scab_parts.get("Scabbard", []):
    vs = mesh_verts(o)
    if len(vs) < 50:
        continue
    c = vs.mean(0)
    u, s_, vt = np.linalg.svd(vs - c, full_matrices=False)
    ax = vt[0] if vt[0][2] < 0 else -vt[0]
    top = c - ax * np.abs((vs - c) @ ax).max()
    scab_axes.append((V(c), V(ax), V(top)))
scab_axes.sort(key=lambda a: a[0].x)
log("scabbards found", len(scab_axes))


def nearest_scab(p):
    best, bi = 1e9, 0
    for i, (c, ax, top) in enumerate(scab_axes):
        d = (p - c) - ax * (p - c).dot(ax)
        if d.length < best:
            best, bi = d.length, i
    return bi


has_grip = {i: False for i in range(len(scab_axes))}
for o in scab_parts.get("Grip", []):
    has_grip[nearest_scab(centroid(o))] = True
SPARE_NAME = {}
for i, (c, ax, top) in enumerate(scab_axes):
    SPARE_NAME[i] = f"Spare{i + 1}"
groups = {}
for kind, parts in scab_parts.items():
    for o in parts:
        i = nearest_scab(centroid(o))
        # the hilts (grip + guard) are what the client hides when a spare is drawn
        is_hilt = kind == "Grip" or (kind == "Brass" and has_grip[i] and centroid(o).z > scab_axes[i][2].z - 0.01)
        key = (SPARE_NAME[i] + "_" + kind) if is_hilt else (("ScabL_" if scab_axes[i][0].x > 0 else "ScabR_") + kind)
        groups.setdefault(key, []).append(o.name)
for key, names in groups.items():
    join(names, key)

# hand sabers
for side, gl in (("L", "Left"), ("R", "Right")):
    for kind in ("Brass", "Grip", "Steel"):
        o = obj(f"{gl}Sword_{kind}")
        if o:
            o.name = f"Saber{side}_{kind}"

# the cape: everything of the coat goes in the Cape group
for kind in ("CoatBlue", "CoatLining", "Piping", "Gold", "Brass"):
    o = obj("Coat_" + kind)
    if o:
        o.name = "Cape_" + kind

# remaining objects: Region_Material naming (the scripts colour parts by the material suffix)
RENAME = {
    "UpperTorso_ShirtRib": "Collar_ShirtRib", "UpperTorso_LeatherDark": "Harness_LeatherDark", "UpperTorso_LeatherBelt": "Harness_LeatherBelt",
    "UpperTorso_Iron": "Harness_Iron", "LowerTorso_Trousers": "Pelvis_Trousers", "LowerTorso_LeatherBelt": "Belt_LeatherBelt",
    "LowerTorso_LeatherDark": "Belt_LeatherDark", "LowerTorso_Brass": "Belt_Brass", "LowerTorso_Iron": "Belt_Iron",
}
for a_, b_ in RENAME.items():
    if obj(a_):
        obj(a_).name = b_
for o in list(bpy.data.objects):
    n = o.name
    for side, gl in (("L", "Left"), ("R", "Right")):
        for part_ in ("LowerArm", "Hand", "UpperLeg", "LowerLeg", "Foot"):
            if n.startswith(gl + part_ + "_"):
                short = {"LowerArm": "Forearm", "Hand": "Hand", "UpperLeg": "Thigh", "LowerLeg": "Shin", "Foot": "Foot"}[part_]
                o.name = short + side + "_" + n.split("_", 1)[1]

# =================================================================================================
# 8. Armature: weighting pass with bones along the limbs, then every bone re-pointed straight up
# =================================================================================================
EYE = V((0.0333, -0.0947, 1.690))
grip_L = V((0.427, -0.031, 0.822))
_st = mesh_verts(obj("SaberL_Steel"))
tip_L = V(_st[np.argmax(((_st - np.array(grip_L)) ** 2).sum(1))])
cape_o = obj("Cape_CoatBlue")
cape_bvh = bvh_of(cape_o)
CAPE_COLS = [-72.0, -36.0, 0.0, 36.0, 72.0]
CAPE_ROWS = [1.42, 1.12, 0.84, 0.56]
CAPE_TIP = 0.30
CAPE_CENTER = V((0.0, 0.03, 0.0))


def cape_point(theta_deg, z):
    t = math.radians(theta_deg)
    d = V((math.sin(t), math.cos(t), 0.0))  # 0 deg = straight back (+Y)
    o = V((CAPE_CENTER.x, CAPE_CENTER.y, z))
    hit = cape_bvh.ray_cast(o + d * 1.2, -d, 1.5)
    if hit[0] is not None:
        return hit[0] - d * 0.012
    return o + d * 0.3


BONES = []  # (name, head, tail_for_weighting, parent, deform)


def bone(name, head, tail, parent, deform=True):
    BONES.append((name, V(head), V(tail), parent, deform))


bone("B_Hips", J["Hips"], J["Spine"], None)
bone("B_Spine", J["Spine"], J["Chest"], "B_Hips")
bone("B_Chest", J["Chest"], J["Neck"], "B_Spine")
bone("B_Neck", J["Neck"], J["Head"], "B_Chest")
bone("B_Head", J["Head"], J["Head"] + V((0, 0, 0.2)), "B_Neck")
bone("B_Patch", EYE + V((0, -0.012, 0)), EYE + V((0, -0.06, 0)), "B_Head")
bone("B_Facing", J["Hips"] + V((0, -0.35, 0)), J["Hips"] + V((0, -0.4, 0)), "B_Hips", deform=False)
for side in ("L", "R"):
    sp = lambda n: side_point(n, side)
    m = (lambda v: v) if side == "L" else mirror
    bone("B_Clavicle" + side, sp("Clavicle"), sp("UpperArm"), "B_Chest")
    bone("B_UpperArm" + side, sp("UpperArm"), sp("Forearm"), "B_Clavicle" + side)
    bone("B_Forearm" + side, sp("Forearm"), sp("Hand"), "B_UpperArm" + side)
    bone("B_Hand" + side, sp("Hand"), m(grip_L) + (m(grip_L) - sp("Hand")) * 0.6, "B_Forearm" + side)
    bone("B_Saber" + side, m(grip_L), m(grip_L) + V((0, 0, 0.05)), "B_Hand" + side)
    bone("B_SaberTip" + side, m(tip_L), m(tip_L) + V((0, 0, 0.05)), "B_Saber" + side, deform=False)
    bone("B_Thigh" + side, sp("Thigh"), sp("Shin"), "B_Hips")
    bone("B_Shin" + side, sp("Shin"), sp("Foot"), "B_Thigh" + side)
    bone("B_Foot" + side, sp("Foot"), sp("Toe"), "B_Shin" + side)
    bone("B_Toe" + side, sp("Toe"), sp("Toe") + V((0, -0.08, 0)), "B_Foot" + side)
    tops = [a[2] for a in scab_axes if (a[0].x > 0) == (side == "L")]
    hang = (sum(tops, V((0, 0, 0))) / len(tops)) if tops else V((0.2 * (1 if side == "L" else -1), -0.02, 1.0))
    bone("B_Scab" + side, hang, hang + V((0, 0, -0.3)), "B_Hips")
CAPE_POINTS = {}
for ci, th in enumerate(CAPE_COLS):
    for ri, z in enumerate(CAPE_ROWS + [CAPE_TIP]):
        CAPE_POINTS[(ci, ri)] = cape_point(th, z)
for ci in range(len(CAPE_COLS)):
    for ri in range(len(CAPE_ROWS)):
        parent = "B_Chest" if ri == 0 else f"B_Cape{ci + 1}_{ri}"
        bone(f"B_Cape{ci + 1}_{ri + 1}", CAPE_POINTS[(ci, ri)], CAPE_POINTS[(ci, ri + 1)], parent)

arm_data = bpy.data.armatures.new("KingBradley")
rig = bpy.data.objects.new("KingBradley", arm_data)
scene.collection.objects.link(rig)
select_only([rig])
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones
for name, head, tail, parent, deform in BONES:
    b = eb.new(name)
    b.head = head
    b.tail = tail if (tail - head).length > 1e-3 else head + V((0, 0, 0.05))
    b.roll = 0.0
    b.use_deform = deform
    if parent:
        b.parent = eb[parent]
        b.use_connect = False
bpy.ops.object.mode_set(mode="OBJECT")

# =================================================================================================
# 9. Skin weights
# =================================================================================================
def set_groups(o, weights):
    """weights: list per vertex of {bone: w}; keeps the 4 biggest, normalised (Roblox limit)."""
    o.vertex_groups.clear()
    vg = {}
    for i, wd in enumerate(weights):
        items = sorted(wd.items(), key=lambda kv: -kv[1])[:4]
        tot = sum(w for _, w in items) or 1.0
        for bn, w in items:
            if w / tot < 1e-3:
                continue
            g = vg.get(bn) or o.vertex_groups.new(name=bn)
            vg[bn] = g
            g.add([i], w / tot, "REPLACE")


def rigid(o, bone_name):
    set_groups(o, [{bone_name: 1.0}] * len(o.data.vertices))


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def leg_weights(p, side):
    sp = lambda n: side_point(n, side)
    hip, knee, ankle, toe = sp("Thigh"), sp("Shin"), sp("Foot"), sp("Toe")
    s = "L" if side == "L" else "R"
    w = {}
    z = p.z
    if z > knee.z:
        k = smoothstep(knee.z - 0.05, knee.z + 0.07, z)
        w["B_Thigh" + s] = k
        w["B_Shin" + s] = 1 - k
        h = smoothstep(hip.z - 0.12, hip.z + 0.03, z)
        if h > 0:
            for b_ in list(w):
                w[b_] *= 1 - h
            w["B_Hips"] = w.get("B_Hips", 0) + h
    elif z > ankle.z - 0.02:
        a = smoothstep(ankle.z - 0.01, ankle.z + 0.06, z)
        w["B_Shin" + s] = a
        w["B_Foot" + s] = 1 - a
        # toe region of the boot
    else:
        w["B_Foot" + s] = 1.0
    fy = toe.y + 0.04
    if p.y < fy and z < ankle.z + 0.02:
        t = smoothstep(fy, fy - 0.06, p.y)
        for b_ in list(w):
            w[b_] *= 1 - t
        w["B_Toe" + s] = w.get("B_Toe" + s, 0) + t
    return w


def weights_by(o, fn):
    vs = mesh_verts(o)
    set_groups(o, [fn(V(p)) for p in vs])


for o in list(bpy.data.objects):
    if o.type != "MESH":
        continue
    n = o.name
    side = "L" if n[len(n.split("_")[0]) - 1:len(n.split("_")[0])] == "L" else ("R" if n.split("_")[0].endswith("R") else None)
    if n.startswith(("Thigh", "Shin", "Foot")):
        s_ = n.split("_")[0][-1]
        weights_by(o, lambda p, s_=s_: leg_weights(p, s_))
    elif n.startswith("Pelvis_") or n.startswith("Belt_"):
        def f(p):
            sd = "L" if p.x >= 0 else "R"
            w = leg_weights(p, sd) if p.z < J["Thigh"].z + 0.04 and abs(p.x) > 0.02 else {"B_Hips": 1.0}
            up = smoothstep(1.03, 1.1, p.z)
            if up > 0:
                w = {k: v * (1 - up) for k, v in w.items()}
                w["B_Spine"] = up
            return w
        weights_by(o, f)
    elif n.startswith("Head_"):
        rigid(o, "B_Head")
    elif n.startswith("Patch_"):
        rigid(o, "B_Patch")
    elif n.startswith("Saber"):
        rigid(o, "B_Saber" + n[5])
    elif n.startswith("Hand"):
        rigid(o, "B_Hand" + n[4])
    elif n.startswith("Forearm"):
        s_ = n[7]
        def f(p, s_=s_):
            wr = side_point("Hand", s_)
            k = smoothstep(wr.z + 0.02, wr.z - 0.03, p.z)
            return {"B_Forearm" + s_: 1 - k, "B_Hand" + s_: k}
        weights_by(o, f)
    elif n.startswith(("Spare", "Scab")):
        i = int(n[5]) - 1 if n.startswith("Spare") else None
        sd = ("L" if scab_axes[i][0].x > 0 else "R") if i is not None else n[4]
        rigid(o, "B_Scab" + sd)
    elif n == "Collar_ShirtRib":
        weights_by(o, lambda p: {"B_Chest": 1 - smoothstep(1.5, 1.57, p.z), "B_Neck": smoothstep(1.5, 1.57, p.z)})

# the cape: bilinear over the cloth grid, the collar and epaulettes ride the chest/neck
def cape_weights(p):
    if p.z > CAPE_ROWS[0] + 0.03 or p.y < -0.02 and p.z > CAPE_ROWS[0] - 0.12:
        k = smoothstep(1.55, 1.65, p.z)
        return {"B_Chest": 1 - k * 0.6, "B_Neck": k * 0.6}
    th = math.degrees(math.atan2(p.x - CAPE_CENTER.x, p.y - CAPE_CENTER.y))
    th = max(CAPE_COLS[0], min(CAPE_COLS[-1], th))
    ci = 0
    while ci < len(CAPE_COLS) - 2 and th > CAPE_COLS[ci + 1]:
        ci += 1
    cu = (th - CAPE_COLS[ci]) / (CAPE_COLS[ci + 1] - CAPE_COLS[ci])
    rows = CAPE_ROWS + [CAPE_TIP]
    ri = 0
    while ri < len(rows) - 2 and p.z < rows[ri + 1]:
        ri += 1
    s_ = max(0.0, min(1.0, (rows[ri] - p.z) / (rows[ri] - rows[ri + 1])))
    # joint-centred blend: half the segment belongs to the bone above
    wr = {}
    if s_ < 0.5:
        wr[ri] = 0.5 + s_
        if ri == 0:
            wr["chest"] = 0.5 - s_
        else:
            wr[ri - 1] = 0.5 - s_
    else:
        wr[ri] = 1.5 - s_
        if ri + 1 < len(CAPE_ROWS):
            wr[ri + 1] = s_ - 0.5
        else:
            wr[ri] = 1.0
    out = {}
    for r, wv in wr.items():
        if r == "chest":
            out["B_Chest"] = out.get("B_Chest", 0) + wv
            continue
        for c, wc in ((ci, 1 - cu), (ci + 1, cu)):
            if wc > 1e-4:
                key = f"B_Cape{c + 1}_{r + 1}"
                out[key] = out.get(key, 0) + wv * wc
    return out


for kind in ("CoatBlue", "CoatLining", "Piping", "Gold", "Brass"):
    o = obj("Cape_" + kind)
    if o:
        weights_by(o, cape_weights)

def transfer_weights(src, dst):
    dst.vertex_groups.clear()
    for g in src.vertex_groups:
        dst.vertex_groups.new(name=g.name)
    mod = dst.modifiers.new("dt", "DATA_TRANSFER")
    mod.object = src
    mod.use_vert_data = True
    mod.data_types_verts = {"VGROUP_WEIGHTS"}
    mod.vert_mapping = "POLYINTERP_NEAREST"
    select_only([dst])
    bpy.ops.object.modifier_apply(modifier=mod.name)


# bone heat on the watertight body proxy, restricted to the upper-body bones (+ hips for the waist)
UPPER = {"B_Hips", "B_Spine", "B_Chest", "B_Neck"} | {f"B_{b}{s}" for b in ("Clavicle", "UpperArm", "Forearm", "Hand") for s in "LR"}
for b in arm_data.bones:
    b.use_deform = b.name in UPPER
select_only([proxy, rig], rig)
bpy.ops.object.parent_set(type="ARMATURE_AUTO")
for b in arm_data.bones:
    b.use_deform = not b.name.startswith(("B_Facing", "B_SaberTip"))
log("bone heat groups", [g.name for g in proxy.vertex_groups])
for n in ("Body_Skin", "Shirt_Shirt", "SleeveHem_ShirtRib", "Harness_LeatherDark", "Harness_LeatherBelt", "Harness_Iron"):
    o = obj(n)
    if o:
        transfer_weights(proxy, o)
bpy.data.objects.remove(proxy, do_unlink=True)


def limit_and_normalize(o):
    select_only([o])
    if not o.vertex_groups:
        return
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)


# =================================================================================================
# 10. Decimate to Roblox limits, parent everything to the rig
# =================================================================================================
TRI_LIMIT = 18500
targets = {"Head_Skin": 17000, "Head_Hair": 12000, "Shirt_Shirt": 16000, "Body_Skin": 16000, "Cape_CoatBlue": 14000,
           "Cape_CoatLining": 9000, "Belt_Iron": 2500, "Cape_Piping": 4000, "SleeveHem_ShirtRib": 3000}
for o in list(bpy.data.objects):
    if o.type != "MESH":
        continue
    tc = tri_count(o)
    want = targets.get(o.name, TRI_LIMIT)
    if tc > want:
        add_mod(o, "DECIMATE", ratio=want / tc, use_collapse_triangulate=True)
        apply_mods(o)
    limit_and_normalize(o)
    for poly in o.data.polygons:
        poly.use_smooth = True

for o in list(bpy.data.objects):
    if o.type != "MESH":
        continue
    mods = [m for m in o.modifiers if m.type == "ARMATURE"]
    for m in mods:
        o.modifiers.remove(m)
    o.parent = rig
    o.matrix_parent_inverse = rig.matrix_world.inverted()
    am = o.modifiers.new("Armature", "ARMATURE")
    am.object = rig

# every bone straight up with zero roll: rest frames = character frame (weights are by name, so
# re-pointing bones in the rest pose does not move a single vertex)
select_only([rig])
bpy.ops.object.mode_set(mode="EDIT")
for b in arm_data.edit_bones:
    b.tail = b.head + V((0, 0, 0.06))
    b.roll = 0.0
bpy.ops.object.mode_set(mode="OBJECT")

total = 0
for o in sorted(bpy.data.objects, key=lambda o: o.name):
    if o.type == "MESH":
        tc = tri_count(o)
        total += tc
        log(f"  {o.name:28s} {tc:6d} tris  groups={len(o.vertex_groups)}")
log("total triangles", total, "bones", len(arm_data.bones))

# =================================================================================================
# 11. Export
# =================================================================================================
select_only([o for o in bpy.data.objects], rig)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "KingBradley.glb"), export_format="GLB", use_selection=True,
                          export_skins=True, export_animations=False, export_apply=False, export_yup=True)
bpy.ops.export_scene.fbx(filepath=os.path.join(OUT, "KingBradley.fbx"), use_selection=True, object_types={"ARMATURE", "MESH"},
                         add_leaf_bones=False, primary_bone_axis="Y", secondary_bone_axis="X", axis_forward="-Z", axis_up="Y",
                         apply_unit_scale=True, apply_scale_options="FBX_SCALE_ALL", mesh_smooth_type="FACE", bake_anim=False,
                         use_armature_deform_only=False)
# rig description for the animation tools (glTF space: X = his left, Y = up, +Z = forward)
import json
desc = {"bones": []}
for b in arm_data.bones:
    h = b.head_local
    desc["bones"].append({"name": b.name, "parent": b.parent.name if b.parent else None, "head": [h.x, h.z, -h.y]})
desc["spares"] = {SPARE_NAME[i]: ("L" if a[0].x > 0 else "R") for i, a in enumerate(scab_axes)}
with open(os.path.join(OUT, "rig.json"), "w") as fh:
    json.dump(desc, fh, indent=1)
log("exported", OUT)
