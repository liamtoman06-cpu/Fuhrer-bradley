#!/usr/bin/env python3
"""
King Bradley (Wrath) boss model generator.

Builds the whole boss out of Roblox primitives (no uploaded meshes or textures, so the file works
in any place without asset permissions) and writes KingBradley.rbxmx with the scripts from ../src.

Rig layout (same contract as the Gluttony boss):
  * every bone is an invisible part named B_*, nested under its parent bone (root: HumanoidRootPart)
  * visual parts are nested under the bone they ride on; BossServer welds them and builds Motor6Ds
  * toggled props carry a name prefix the client looks for: SaberR_, SaberL_, HiltR_, HiltL_,
    Spare1_..Spare4_ (the spare sabers' hilts), Cape_, Patch_

Run:  python3 tools/build_model.py            -> KingBradley.rbxmx (+ preview JSON with --preview)
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# =================================================================================================
# Small CFrame math (Roblox conventions: columns = Right, Up, Back; LookVector = -Back)
# =================================================================================================


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def length(a):
    return math.sqrt(dot(a, a))


def unit(a):
    m = length(a)
    return (a[0] / m, a[1] / m, a[2] / m) if m > 1e-9 else (0.0, 0.0, -1.0)


def lerp3(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


class CF:
    __slots__ = ("p", "R")

    def __init__(self, p=(0.0, 0.0, 0.0), R=None):
        self.p = tuple(float(x) for x in p)
        self.R = R or ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))

    def vec(self, v):
        R = self.R
        return (
            R[0][0] * v[0] + R[0][1] * v[1] + R[0][2] * v[2],
            R[1][0] * v[0] + R[1][1] * v[1] + R[1][2] * v[2],
            R[2][0] * v[0] + R[2][1] * v[1] + R[2][2] * v[2],
        )

    def pt(self, v):
        return add(self.vec(v), self.p)

    def __mul__(self, o):
        if isinstance(o, CF):
            A, B = self.R, o.R
            R = tuple(tuple(sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)) for i in range(3))
            return CF(self.pt(o.p), R)
        return self.pt(o)

    def inv(self):
        R = self.R
        Rt = tuple(tuple(R[j][i] for j in range(3)) for i in range(3))
        c = CF((0, 0, 0), Rt)
        return CF(mul(c.vec(self.p), -1), Rt)

    def col(self, i):
        return (self.R[0][i], self.R[1][i], self.R[2][i])

    def flat(self):
        R = self.R
        return list(self.p) + [R[0][0], R[0][1], R[0][2], R[1][0], R[1][1], R[1][2], R[2][0], R[2][1], R[2][2]]


def ang(rx=0.0, ry=0.0, rz=0.0, deg=True):
    if deg:
        rx, ry, rz = math.radians(rx), math.radians(ry), math.radians(rz)
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    Rx = CF((0, 0, 0), ((1, 0, 0), (0, cx, -sx), (0, sx, cx)))
    Ry = CF((0, 0, 0), ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy)))
    Rz = CF((0, 0, 0), ((cz, -sz, 0), (sz, cz, 0), (0, 0, 1)))
    return Rx * Ry * Rz


def at(p, rot=None):
    c = CF(p)
    if rot is not None:
        c = CF(p, rot.R)
    return c


def frame(pos, look, up=(0, 1, 0)):
    """CFrame at pos whose LookVector is `look`, Up as close to `up` as possible."""
    f = unit(look)
    r = cross(f, up)
    if length(r) < 1e-6:
        r = cross(f, (1, 0, 0) if abs(f[0]) < 0.9 else (0, 0, 1))
    r = unit(r)
    u = unit(cross(r, f))
    b = mul(f, -1)
    return CF(pos, ((r[0], u[0], b[0]), (r[1], u[1], b[1]), (r[2], u[2], b[2])))


def axes(pos, x, y):
    """CFrame from a right (x) and an up (y) hint (y is orthogonalised)."""
    x = unit(x)
    z = unit(cross(x, y))
    y = cross(z, x)
    return CF(pos, ((x[0], y[0], z[0]), (x[1], y[1], z[1]), (x[2], y[2], z[2])))


# =================================================================================================
# Colours and materials
# =================================================================================================
MAT = {"sp": 272, "neon": 288, "fabric": 1312, "metal": 1088, "glass": 1568, "foil": 1056}

C = {
    "skin": (232, 188, 150),
    "skin_sh": (206, 156, 120),
    "skin_dk": (178, 124, 94),
    "lip": (190, 128, 104),
    "ink": (64, 36, 30),
    "hair": (24, 25, 32),
    "hair_hi": (58, 62, 80),
    "brow": (20, 20, 24),
    "white": (242, 240, 234),
    "iris": (82, 84, 94),
    "pupil": (14, 14, 16),
    "navy": (44, 58, 98),
    "navy_dk": (30, 40, 70),
    "navy_hi": (58, 74, 120),
    "seam": (24, 31, 54),
    "gold": (226, 174, 62),
    "gold_dk": (166, 116, 34),
    "gold_hi": (250, 218, 130),
    "boot": (20, 20, 24),
    "boot_hi": (44, 44, 52),
    "sole": (40, 30, 24),
    "leather": (96, 60, 34),
    "leather_dk": (62, 38, 22),
    "steel": (206, 214, 228),
    "steel_dk": (128, 138, 156),
    "edge": (246, 250, 255),
    "grip": (28, 24, 22),
    "scabbard": (30, 32, 40),
    "patch": (14, 14, 16),
    "strap": (24, 24, 28),
    "sclera_ult": (226, 222, 216),
    "ult_red": (222, 22, 32),
    "cape": (32, 42, 74),
    "cape_in": (20, 26, 48),
    "button": (230, 184, 74),
}

# =================================================================================================
# Scene graph
# =================================================================================================
BONES = {}  # name -> dict(name, parent, pos)
BONE_ORDER = []
PARTS = []  # dicts


def bone(name, parent, pos):
    BONES[name] = {"name": name, "parent": parent, "pos": pos, "attachments": []}
    BONE_ORDER.append(name)


def bone_attachment(bone_name, name, world_cf):
    b = BONES[bone_name]
    local = CF(b["pos"]).inv() * world_cf
    b["attachments"].append((name, local))


MIN = 0.05


def part(bone_name, name, kind, size, cf, color, mat="sp", tr=0.0, refl=0.0, hit=False, shadow=True, extra=None):
    """kind: block | ell (ellipsoid) | cyl (axis = local X) | ball | wedge"""
    size = tuple(max(float(s), 0.004) for s in size)
    p = {
        "bone": bone_name,
        "name": name,
        "kind": kind,
        "size": size,
        "cf": cf,
        "color": C[color] if isinstance(color, str) else color,
        "mat": MAT[mat],
        "tr": tr,
        "refl": refl,
        "hit": hit,
        "shadow": shadow,
        "extra": extra or [],
    }
    PARTS.append(p)
    return p


def ell(bone_name, name, center, radii, color, rot=None, **kw):
    cf = at(center, rot)
    return part(bone_name, name, "ell", (radii[0] * 2, radii[1] * 2, radii[2] * 2), cf, color, **kw)


def box(bone_name, name, center, size, color, rot=None, **kw):
    return part(bone_name, name, "block", size, at(center, rot), color, **kw)


def cyl_between(bone_name, name, a, b, diameter, color, **kw):
    """Cylinder from a to b (Roblox cylinders run along local X)."""
    d = sub(b, a)
    L = length(d)
    x = unit(d)
    up = (0, 1, 0) if abs(x[1]) < 0.95 else (1, 0, 0)
    cf = axes(lerp3(a, b, 0.5), x, up)
    return part(bone_name, name, "cyl", (L, diameter, diameter), cf, color, **kw)


def ell_between(bone_name, name, a, b, w, d, color, up=(0, 0, -1), pad=0.0, **kw):
    """Ellipsoid whose long (Y) axis runs from a to b; w = X diameter, d = Z diameter."""
    v = sub(b, a)
    L = length(v) + pad
    y = unit(v)
    x = unit(cross(y, up))
    cf = axes(lerp3(a, b, 0.5), x, y)
    return part(bone_name, name, "ell", (w, L, d), cf, color, **kw)


def strip(bone_name, name, a, b, normal, width, thick, color, overlap=0.012, kind="ell", **kw):
    """Flat strip lying on a surface (thin along `normal`) from a to b."""
    d = sub(b, a)
    L = length(d)
    if L < 1e-5:
        return None
    back = unit(d)
    up = unit(sub(normal, mul(back, dot(normal, back))))
    right = cross(up, back)
    cf = CF(lerp3(a, b, 0.5), ((right[0], up[0], back[0]), (right[1], up[1], back[1]), (right[2], up[2], back[2])))
    extra_len = L * 0.75 + width * 0.6 if kind == "ell" else overlap
    return part(bone_name, name, kind, (width, thick, L + extra_len), cf, color, shadow=False, **kw)


def polyline(bone_name, name, pts, normals, width, thick, color, taper=None, kind="ell", **kw):
    n = len(pts) - 1
    for i in range(n):
        w = width
        if taper:
            u = (i + 0.5) / n
            w = width * (taper[0] + (taper[1] - taper[0]) * u)
        nrm = unit(add(normals[i], normals[i + 1]))
        strip(bone_name, f"{name}{i + 1}", pts[i], pts[i + 1], nrm, w, thick, color, kind=kind, **kw)


def ring(bone_name, name, center, rx, rz, height, thick, color, segs=16, y_axis_tilt=0.0, a0=0.0, a1=360.0, **kw):
    """A band of blocks around an ellipse in the XZ plane (belts, collars, cuffs)."""
    for i in range(segs):
        t0 = math.radians(a0 + (a1 - a0) * i / segs)
        t1 = math.radians(a0 + (a1 - a0) * (i + 1) / segs)
        p0 = (center[0] + rx * math.sin(t0), center[1], center[2] + rz * math.cos(t0))
        p1 = (center[0] + rx * math.sin(t1), center[1], center[2] + rz * math.cos(t1))
        mid = lerp3(p0, p1, 0.5)
        tangent = unit(sub(p1, p0))
        outward = unit((mid[0] - center[0], 0, mid[2] - center[2]))
        up = unit(add((0, 1, 0), mul(outward, -y_axis_tilt)))
        cf = axes(mid, tangent, up)
        part(bone_name, f"{name}{i + 1}", "block", (length(sub(p1, p0)) + 0.02, height, thick), cf, color, **kw)


# =================================================================================================
# Surface projection (to draw ink lines, brows, straps right on the face)
# =================================================================================================
class Ellipsoid:
    def __init__(self, center, radii, rot=None):
        self.cf = at(center, rot)
        self.inv = self.cf.inv()
        self.r = radii

    def hit(self, o, d):
        lo = self.inv.pt(o)
        ld = self.inv.vec(d)
        lo = (lo[0] / self.r[0], lo[1] / self.r[1], lo[2] / self.r[2])
        ld = (ld[0] / self.r[0], ld[1] / self.r[1], ld[2] / self.r[2])
        a = dot(ld, ld)
        b = 2 * dot(lo, ld)
        c = dot(lo, lo) - 1
        disc = b * b - 4 * a * c
        if disc < 0:
            return None
        s = math.sqrt(disc)
        return ((-b - s) / (2 * a), (-b + s) / (2 * a))

    def normal(self, p):
        lp = self.inv.pt(p)
        g = (lp[0] / self.r[0] ** 2, lp[1] / self.r[1] ** 2, lp[2] / self.r[2] ** 2)
        return unit(self.cf.vec(g))


class Surface:
    def __init__(self):
        self.items = []

    def add(self, center, radii, rot=None):
        self.items.append(Ellipsoid(center, radii, rot))

    def cast(self, o, d):
        best = None
        for e in self.items:
            h = e.hit(o, d)
            if h and h[0] > 0 and (best is None or h[0] < best[0]):
                best = (h[0], e)
        if not best:
            return None, None
        p = add(o, mul(d, best[0]))
        return p, best[1].normal(p)

    def front(self, x, y, lift=0.0):
        p, n = self.cast((x, y, -5.0), (0, 0, 1))
        k = 0
        while p is None and k < 40:
            k += 1
            x *= 0.97
            p, n = self.cast((x, y, -5.0), (0, 0, 1))
        if p is None:
            raise ValueError(f"no surface at {x},{y}")
        return add(p, mul(n, lift)), n

    def side(self, sign, y, z, lift=0.0):
        p, n = self.cast((5.0 * sign, y, z), (-sign, 0, 0))
        if p is None:
            raise ValueError(f"no side surface at {y},{z}")
        return add(p, mul(n, lift)), n

    def radial(self, origin, direction, lift=0.0):
        d = unit(direction)
        p, n = self.cast(add(origin, mul(d, 6.0)), mul(d, -1))
        if p is None:
            raise ValueError("no radial surface")
        return add(p, mul(n, lift)), n


def project_front(surf, xy_pts, lift):
    pts, nrm = [], []
    for x, y in xy_pts:
        p, n = surf.front(x, y, lift)
        pts.append(p)
        nrm.append(n)
    return pts, nrm


def smooth_curve(ctrl, n):
    """Catmull-Rom through 2D control points -> n+1 points."""
    out = []
    m = len(ctrl) - 1
    for i in range(n + 1):
        u = i / n * m
        k = min(int(u), m - 1)
        t = u - k
        p0 = ctrl[max(k - 1, 0)]
        p1 = ctrl[k]
        p2 = ctrl[k + 1]
        p3 = ctrl[min(k + 2, m)]
        t2, t3 = t * t, t * t * t
        out.append(
            tuple(
                0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3)
                for j in range(len(p1))
            )
        )
    return out


# =================================================================================================
# Skeleton (rest pose, feet on Y = 0, facing -Z). Bradley stands ~8.9 studs tall.
# =================================================================================================
HRP_POS = (0.0, 5.0, 0.0)
HRP_SIZE = (2.2, 2.0, 1.2)
HIP_HEIGHT = HRP_POS[1] - HRP_SIZE[1] / 2  # 4.0

bone("B_Hips", "HumanoidRootPart", (0.0, 4.72, 0.0))
bone("B_Spine", "B_Hips", (0.0, 5.3, 0.02))
bone("B_Chest", "B_Spine", (0.0, 6.05, 0.02))
bone("B_Neck", "B_Chest", (0.0, 7.32, -0.02))
bone("B_Head", "B_Neck", (0.0, 7.78, -0.06))
for s, n in ((1, "R"), (-1, "L")):
    bone("B_Shoulder" + n, "B_Chest", (1.08 * s, 7.0, 0.02))
    bone("B_Elbow" + n, "B_Shoulder" + n, (1.22 * s, 5.5, 0.06))
    bone("B_Hand" + n, "B_Elbow" + n, (1.28 * s, 4.18, 0.0))
    bone("B_Saber" + n, "B_Hand" + n, (1.29 * s, 3.88, -0.02))
    bone("B_Thigh" + n, "B_Hips", (0.48 * s, 4.45, 0.0))
    bone("B_Shin" + n, "B_Thigh" + n, (0.5 * s, 2.42, -0.05))
    bone("B_Foot" + n, "B_Shin" + n, (0.5 * s, 0.4, 0.02))

# Cape rows: each bone sits at the top-centre-back of its row and swings about its X axis.
CAPE_TOP = 7.16
CAPE_ROW = 1.42
CAPE_ROWS = 4


def cape_shape(y):
    """Half-ellipse of the cape at height y: rx, rz, centre z."""
    f = max(0.0, min(1.0, (CAPE_TOP - y) / (CAPE_ROW * CAPE_ROWS)))
    return 1.2 + 0.62 * f, 0.56 + 0.5 * f, 0.08 + 0.12 * f


for i in range(CAPE_ROWS):
    y = CAPE_TOP - CAPE_ROW * i
    rx, rz, cz = cape_shape(y)
    bone(f"B_Cape{i + 1}", "B_Chest" if i == 0 else f"B_Cape{i}", (0.0, y, cz + rz))

# =================================================================================================
# HEAD
# =================================================================================================
H = "B_Head"
SKULL_C, SKULL_R = (0.0, 8.22, -0.08), (0.42, 0.55, 0.5)
face = Surface()
face_parts = [
    ("Skull", SKULL_C, SKULL_R, None),
    ("Face", (0.0, 8.08, -0.2), (0.375, 0.36, 0.4), None),
    ("Jaw", (0.0, 7.88, -0.17), (0.33, 0.2, 0.38), None),
    ("JawCornerR", (0.22, 7.87, -0.05), (0.13, 0.15, 0.19), None),
    ("JawCornerL", (-0.22, 7.87, -0.05), (0.13, 0.15, 0.19), None),
    ("Chin", (0.0, 7.77, -0.42), (0.14, 0.09, 0.1), None),
    ("CheekR", (0.215, 8.1, -0.335), (0.12, 0.07, 0.12), None),
    ("CheekL", (-0.215, 8.1, -0.335), (0.12, 0.07, 0.12), None),
    ("BrowRidge", (0.0, 8.345, -0.465), (0.35, 0.066, 0.1), None),
    ("Temple R", (0.31, 8.3, -0.2), (0.08, 0.14, 0.18), None),
    ("Temple L", (-0.31, 8.3, -0.2), (0.08, 0.14, 0.18), None),
]
for name, c, r, rot in face_parts:
    face.add(c, r, rot)
    ell(H, name.replace(" ", ""), c, r, "skin", rot=rot, hit=(name == "Skull"))

# Nose: long, straight, strong bridge.
nose_top, nose_tip = (0.0, 8.3, -0.55), (0.0, 8.06, -0.665)
nose_rot = frame((0, 0, 0), sub(nose_tip, nose_top), (0, 0, -1))
mid = lerp3(nose_top, nose_tip, 0.5)
ell_between(H, "NoseBridge", nose_top, nose_tip, 0.066, 0.085, "skin", pad=0.06)
face.add(mid, (0.033, length(sub(nose_tip, nose_top)) / 2 + 0.03, 0.0425), axes(mid, (1, 0, 0), sub(nose_tip, nose_top)))
ell(H, "NoseTip", (0.0, 8.06, -0.643), (0.042, 0.04, 0.042), "skin")
face.add((0.0, 8.06, -0.643), (0.042, 0.04, 0.042))
for s, n in ((1, "R"), (-1, "L")):
    ell(H, "NoseWing" + n, (0.04 * s, 8.042, -0.6), (0.03, 0.028, 0.034), "skin")
    face.add((0.04 * s, 8.042, -0.6), (0.03, 0.028, 0.034))
    ell(H, "Nostril" + n, (0.028 * s, 8.015, -0.622), (0.016, 0.008, 0.014), "skin_dk", shadow=False)
    # ears
    ell(H, "Ear" + n, (0.425 * s, 8.2, -0.03), (0.065, 0.15, 0.105), "skin", rot=ang(0, 12 * s, 0))
    ell(H, "EarInner" + n, (0.462 * s, 8.2, -0.04), (0.03, 0.1, 0.06), "skin_dk", rot=ang(0, 12 * s, 0), shadow=False)
    ell(H, "EarLobe" + n, (0.43 * s, 8.07, -0.05), (0.05, 0.05, 0.05), "skin")

# Neck (under the collar) and throat
ell("B_Neck", "Neck", (0.0, 7.58, 0.0), (0.26, 0.34, 0.25), "skin", hit=True)
ell("B_Neck", "Throat", (0.0, 7.6, -0.18), (0.13, 0.2, 0.1), "skin_sh")

LINE_T = 0.012  # ink line thickness (along the normal)
LIFT = 0.004


def face_line(name, ctrl, width, taper=None, color="ink", n=None, lift=LIFT, bone_name=H, surf=None):
    pts2 = smooth_curve(ctrl, n or max(2, len(ctrl) * 2))
    pts, nrm = project_front(surf or face, pts2, lift)
    polyline(bone_name, name, pts, nrm, width, LINE_T, color, taper=taper)


# --- the visible (right, +X) eye: narrowed, a small hard pupil in a pale eye -------------------
EYE_Y = 8.235
EYE_X = 0.165
for s, n in ((1, "R"),):
    p, nrm = face.front(EYE_X * s, EYE_Y)
    look = frame(p, mul(nrm, -1))
    ell(H, "EyeWhite" + n, add(p, mul(nrm, -0.016)), (0.072, 0.022, 0.024), "white", rot=frame((0, 0, 0), mul(nrm, -1)), shadow=False)
    iris_c = add(p, mul(nrm, 0.006))
    iris_rot = frame((0, 0, 0), mul(nrm, -1))
    part(H, "Iris" + n, "cyl", (0.012, 0.05, 0.05), at(add(iris_c, (0.006 * s, -0.002, 0)), iris_rot * ang(0, 90, 0)), "iris", shadow=False)
    part(H, "Pupil" + n, "cyl", (0.014, 0.022, 0.022), at(add(iris_c, (0.006 * s, 0.0, -0.002)), iris_rot * ang(0, 90, 0)), "pupil", shadow=False)
    ell(H, "Catchlight" + n, add(iris_c, (0.016 * s, 0.008, -0.008)), (0.007, 0.007, 0.005), "white", mat="neon", shadow=False)
    # heavy upper lid line (thick, angled down toward the nose: the glare)
    face_line("UpperLid" + n, [(0.25 * s, 8.25), (0.2 * s, 8.266), (0.13 * s, 8.262), (0.088 * s, 8.246)], 0.034, taper=(0.55, 1.0), lift=0.012)
    face_line("LowerLid" + n, [(0.235 * s, 8.218), (0.17 * s, 8.204), (0.1 * s, 8.214)], 0.012, taper=(1.0, 0.5), lift=0.008)
    face_line("EyeBag" + n, [(0.21 * s, 8.175), (0.16 * s, 8.165), (0.115 * s, 8.172)], 0.008, lift=0.006)
    face_line("CrowsFoot" + n + "a", [(0.275 * s, 8.245), (0.305 * s, 8.258)], 0.007)
    face_line("CrowsFoot" + n + "b", [(0.272 * s, 8.222), (0.302 * s, 8.21)], 0.007)

# --- brows: thick, black, pulled down hard toward the nose (the permanent frown) ---------------
for s, n in ((1, "R"), (-1, "L")):
    ctrl = [(0.292 * s, 8.365), (0.23 * s, 8.38), (0.15 * s, 8.36), (0.07 * s, 8.315)]
    pts2 = smooth_curve(ctrl, 6)
    pts, nrm = project_front(face, pts2, 0.012)
    polyline(H, "Brow" + n, pts, nrm, 0.078, 0.045, "brow", taper=(0.55, 1.15))
    # bushy upper edge
    pts3, nrm3 = project_front(face, [(x, y + 0.025) for x, y in pts2[1:-1]], 0.012)
    polyline(H, "BrowTop" + n, pts3, nrm3, 0.035, 0.03, "brow", taper=(0.6, 1.0))

# frown creases between the brows, forehead lines
face_line("FrownR", [(0.042, 8.33), (0.034, 8.38), (0.036, 8.42)], 0.01)
face_line("FrownL", [(-0.042, 8.33), (-0.034, 8.38), (-0.036, 8.42)], 0.01)
face_line("Forehead", [(-0.12, 8.5), (0.0, 8.508), (0.12, 8.5)], 0.006)

# nose shading line and the long nasolabial folds past the mustache to the jaw
for s, n in ((1, "R"), (-1, "L")):
    face_line("Fold" + n, [(0.075 * s, 8.07), (0.15 * s, 8.01), (0.2 * s, 7.92), (0.215 * s, 7.82)], 0.012, taper=(1.0, 0.45))
face_line("ChinCrease", [(-0.045, 7.805), (0.0, 7.798), (0.045, 7.805)], 0.007)

# mouth: stern line, slight downturn at the corners, a hint of lower lip
face_line("Mouth", [(-0.13, 7.875), (-0.07, 7.885), (0.0, 7.888), (0.07, 7.885), (0.13, 7.875)], 0.016, lift=0.006)
p, nrm = face.front(0.0, 7.855)
ell(H, "LowerLip", add(p, mul(nrm, -0.01)), (0.07, 0.016, 0.016), "skin_sh", rot=frame((0, 0, 0), mul(nrm, -1)), shadow=False)

# --- the mustache: thick, black, squared chevron that falls past the mouth corners --------------
must_rows = [
    # (x, y) along the top edge from the centre outwards, thickness grows then tapers to a point
    (0.0, 7.988, 0.062), (0.07, 7.984, 0.066), (0.14, 7.962, 0.062),
    (0.2, 7.922, 0.05), (0.24, 7.87, 0.034), (0.262, 7.822, 0.016),
]
for s, n in ((1, "R"), (-1, "L")):
    for i in range(len(must_rows) - 1):
        x0, y0, h0 = must_rows[i]
        x1, y1, h1 = must_rows[i + 1]
        cx, cy = (x0 + x1) / 2 * s, (y0 + y1) / 2 - (h0 + h1) / 4
        p, nrm = face.front(cx, cy, 0.0)
        hh = (h0 + h1) / 2
        seg = length((x1 - x0, y1 - y0, 0))
        tangent = unit(((x1 - x0) * s, y1 - y0, 0))
        out = nrm
        up = unit(cross(mul(out, 1), tangent)) if s > 0 else unit(cross(tangent, mul(out, -1)))
        cf = axes(add(p, mul(nrm, 0.018)), tangent, up)
        part(H, f"Mustache{n}{i + 1}", "ell", (seg * (2.3 if i < len(must_rows) - 2 else 2.0), hh * 1.3, 0.08), cf, "hair")
    # glint on the mustache (anime highlight)
    p, nrm = face.front(0.09 * s, 7.97, 0.05)
    ell(H, "MustacheShine" + n, p, (0.04, 0.006, 0.01), "hair_hi", rot=frame((0, 0, 0), mul(nrm, -1)) * ang(0, 0, -12 * s), shadow=False)
p, nrm = face.front(0.0, 7.965, 0.012)
ell(H, "MustacheCore", p, (0.08, 0.035, 0.035), "hair", rot=frame((0, 0, 0), mul(nrm, -1)))

# --- hair: short, black, slicked straight back, hard hairline, short sideburns ------------------
HAIR_C, HAIR_R = (0.0, 8.42, 0.045), (0.452, 0.455, 0.525)
ell(H, "HairCap", HAIR_C, HAIR_R, "hair", hit=True)
hair = Surface()
hair.add(HAIR_C, HAIR_R)
hair.add((0.0, 8.6, 0.06), (0.44, 0.33, 0.52))
hair.add((0.05, 8.66, -0.02), (0.36, 0.25, 0.44), ang(-8, 0, 0))
ell(H, "HairNape", (0.0, 8.14, 0.24), (0.34, 0.24, 0.24), "hair")
ell(H, "HairVolume", (0.0, 8.6, 0.06), (0.44, 0.33, 0.52), "hair")
ell(H, "HairSweep", (0.05, 8.66, -0.02), (0.36, 0.25, 0.44), "hair", rot=ang(-8, 0, 0))
for s, n in ((1, "R"), (-1, "L")):
    ell(H, "HairSide" + n, (0.36 * s, 8.36, 0.05), (0.11, 0.17, 0.3), "hair")
    # sideburns in front of the ears
    pts, nrm = [], []
    for yd in (0.32, 0.12, -0.05, -0.18):
        p, nn = face.radial(HEAD_O if False else (0.0, 8.25, -0.02), (s * 0.93, yd, -0.36), 0.004)
        pts.append(p)
        nrm.append(nn)
    polyline(H, "Sideburn" + n, pts, nrm, 0.07, 0.022, "hair", taper=(1.0, 0.6))
# hard, slightly angular hairline in front (widow's-peak-ish)
hl = [(-0.335, 8.47), (-0.27, 8.59), (-0.14, 8.635), (0.0, 8.62), (0.12, 8.64), (0.26, 8.6), (0.335, 8.47)]
pts2 = smooth_curve(hl, 12)
pts, nrm = project_front(face, pts2, 0.004)
polyline(H, "Hairline", pts, nrm, 0.06, 0.05, "hair")
headsurf = Surface()
headsurf.items = face.items + hair.items
HEAD_O = (0.0, 8.25, -0.02)


def around_head(name, bone_name, y_dir, angles_deg, width, thick, color, lift=0.006, kind="block", side=-1):
    pts, nrm = [], []
    for a in angles_deg:
        t = math.radians(a)
        p, nn = headsurf.radial(HEAD_O, (side * math.sin(t), y_dir, -math.cos(t)), lift)
        pts.append(p)
        nrm.append(nn)
    polyline(bone_name, name, pts, nrm, width, thick, color, kind=kind)


# --- the EYEPATCH over his left eye (-X), with the strap across the forehead --------------------
PATCH_X = -EYE_X
p_c, n_c = face.front(PATCH_X, EYE_Y + 0.01)
bone("B_Patch", H, p_c)
patch_rot = frame((0, 0, 0), mul(n_c, -1))
ell("B_Patch", "Patch_Plate", add(p_c, mul(n_c, 0.018)), (0.148, 0.118, 0.042), "patch", rot=patch_rot)
ell("B_Patch", "Patch_Rim", add(p_c, mul(n_c, 0.006)), (0.158, 0.128, 0.03), "strap", rot=patch_rot, shadow=False)
ell("B_Patch", "Patch_Shine", add(p_c, add(mul(n_c, 0.056), (0.03, 0.04, 0))), (0.05, 0.016, 0.006), (70, 72, 82), rot=patch_rot * ang(0, 0, -20), shadow=False)
# strap 1: from the patch's upper inner corner, diagonally up across the forehead into the hair
s1 = smooth_curve([(-0.08, 8.33), (0.0, 8.42), (0.1, 8.53), (0.2, 8.62), (0.27, 8.7)], 16)
pts, nrm = project_front(face, s1, 0.006)
polyline("B_Patch", "Patch_StrapA", pts, nrm, 0.042, 0.018, "strap", kind="block")
# continues over the hair toward the back
pts, nrm = [], []
for j in range(6):
    u = j / 5
    d = (0.55 - 0.15 * u, 0.55 + 0.3 * u, -0.6 + 1.2 * u)
    p, nn = hair.radial(HAIR_C, d, 0.006)
    pts.append(p)
    nrm.append(nn)
polyline("B_Patch", "Patch_StrapB", pts, nrm, 0.042, 0.018, "strap", kind="block")
# strap 2: from the outer edge of the patch round the temple, above the ear, to the back
around_head("Patch_StrapC", "B_Patch", 0.07, [22, 32, 45, 60, 76, 92, 108, 124, 140, 156], 0.042, 0.018, "strap")

# --- the ULTIMATE EYE under the patch: pale sclera, the red Ouroboros mark ----------------------
ue_p, ue_n = face.front(PATCH_X, EYE_Y)
ue_rot = frame((0, 0, 0), mul(ue_n, -1))
ell(H, "UltimateEye", add(ue_p, mul(ue_n, -0.012)), (0.08, 0.036, 0.03), "sclera_ult", rot=ue_rot, shadow=False)
# the Ouroboros mark is drawn by a SurfaceGui on the Front face of a thin plate (Front = LookVector,
# so the plate looks OUT of the face)
ouro_cf = at(add(ue_p, mul(ue_n, 0.02)), frame((0, 0, 0), ue_n))
part(H, "UltimateMark", "block", (0.064, 0.064, 0.01), ouro_cf, "sclera_ult", tr=1.0, shadow=False, extra=[("ouroboros",)])
bone_attachment(H, "UltimateEyeAttachment", at(add(ue_p, mul(ue_n, 0.03)), ue_rot))
bone_attachment(H, "UltimateEyeTrailA", at(add(ue_p, add(mul(ue_n, 0.03), (0, 0.025, 0))), ue_rot))
bone_attachment(H, "UltimateEyeTrailB", at(add(ue_p, add(mul(ue_n, 0.03), (0, -0.025, 0))), ue_rot))
# the closed lid over it (swings up into the brow when the eye opens)
bone("B_UltLid", H, add(ue_p, mul(ue_n, -0.045)))
ell("B_UltLid", "UltLid", add(ue_p, mul(ue_n, -0.004)), (0.1, 0.062, 0.04), "skin", rot=ue_rot)
lid_pts = [(PATCH_X + 0.08, EYE_Y - 0.004), (PATCH_X, EYE_Y - 0.012), (PATCH_X - 0.08, EYE_Y - 0.002)]
lp, ln = project_front(face, smooth_curve(lid_pts, 4), 0.042)
polyline("B_UltLid", "UltLidLine", lp, ln, 0.018, LINE_T, "ink")
# scar lines across the lid (the patch hides an old wound)
face_line("ScarA", [(PATCH_X - 0.14, 8.37), (PATCH_X - 0.09, 8.31)], 0.008, color="skin_dk", lift=0.003)
face_line("ScarB", [(PATCH_X + 0.05, 8.19), (PATCH_X + 0.1, 8.13)], 0.008, color="skin_dk", lift=0.003)

bone_attachment(H, "HeadCenter", CF((0.0, 8.22, -0.1)))
bone_attachment(H, "MouthCenter", CF((0.0, 7.88, -0.55)))

# =================================================================================================
# TORSO: the Führer's uniform
# =================================================================================================
Ch, Sp, Hp = "B_Chest", "B_Spine", "B_Hips"
torso = Surface()


def tell(bone_name, name, c, r, color="navy", rot=None, hit=False, add_surface=True, **kw):
    if add_surface:
        torso.add(c, r, rot)
    return ell(bone_name, name, c, r, color, rot=rot, hit=hit, mat="fabric", **kw)


tell(Ch, "Chest", (0.0, 6.6, 0.02), (0.9, 0.76, 0.56), hit=True)
tell(Ch, "Traps", (0.0, 7.06, 0.06), (0.74, 0.27, 0.44))
tell(Ch, "Back", (0.0, 6.5, 0.22), (0.88, 0.72, 0.4))
for s, n in ((1, "R"), (-1, "L")):
    tell(Ch, "Pec" + n, (0.36 * s, 6.68, -0.27), (0.41, 0.32, 0.27))
    tell(Ch, "Lat" + n, (0.62 * s, 6.25, 0.06), (0.3, 0.58, 0.44))
tell(Sp, "Abdomen", (0.0, 5.66, 0.02), (0.72, 0.62, 0.47), hit=True)
tell(Sp, "Waist", (0.0, 5.2, 0.02), (0.71, 0.34, 0.46))
tell(Hp, "Pelvis", (0.0, 4.74, 0.03), (0.74, 0.42, 0.47), hit=True)

# Seams and the front closure (thin dark lines projected onto the jacket)


def torso_line(bone_name, name, xy, width, color="seam", lift=0.004, n=8):
    pts, nrm = project_front(torso, smooth_curve(xy, n), lift)
    polyline(bone_name, name, pts, nrm, width, 0.014, color)


torso_line(Ch, "Placket", [(0.0, 7.28), (0.0, 6.6), (0.0, 6.0)], 0.022)
torso_line(Sp, "PlacketLow", [(0.0, 6.02), (0.0, 5.5), (0.0, 5.28)], 0.022)
for s, n in ((1, "R"), (-1, "L")):
    # pocket flaps on the chest (Amestris officer's jacket)
    pts, nrm = project_front(torso, smooth_curve([(0.2 * s, 6.82), (0.4 * s, 6.84), (0.6 * s, 6.8)], 6), 0.01)
    polyline(Ch, "PocketFlap" + n, pts, nrm, 0.13, 0.03, "navy_dk")
    pts, nrm = project_front(torso, smooth_curve([(0.21 * s, 6.76), (0.4 * s, 6.775), (0.59 * s, 6.74)], 6), 0.02)
    polyline(Ch, "PocketEdge" + n, pts, nrm, 0.012, 0.012, "seam")
    p, nrm = torso.front(0.4 * s, 6.77, 0.03)
    ell(Ch, "PocketButton" + n, p, (0.03, 0.03, 0.015), "button", rot=frame((0, 0, 0), mul(nrm, -1)), refl=0.2)
    torso_line(Ch, "SideSeam" + n, [(0.76 * s, 6.9), (0.8 * s, 6.4), (0.74 * s, 6.0)], 0.014, n=6)
# gold buttons down the front
for k, y in enumerate((7.08, 6.72, 6.36, 6.02, 5.66)):
    bone_name = Ch if y > 6.05 else Sp
    p, nrm = torso.front(0.035, y, 0.02)
    ell(bone_name, f"Button{k + 1}", p, (0.038, 0.038, 0.02), "button", rot=frame((0, 0, 0), mul(nrm, -1)), refl=0.25)

# Standing collar (closed, with the rank tabs)
ring(Ch, "Collar", (0.0, 7.46, 0.0), 0.37, 0.34, 0.3, 0.07, "navy", segs=16, y_axis_tilt=-0.08, mat="fabric")
ring(Ch, "CollarTop", (0.0, 7.61, 0.0), 0.38, 0.35, 0.03, 0.08, "navy_dk", segs=16, mat="fabric")
ell(Ch, "CollarFill", (0.0, 7.4, 0.0), (0.35, 0.2, 0.32), "navy", mat="fabric")
for s, n in ((1, "R"), (-1, "L")):
    tab_c = (0.2 * s, 7.46, -0.31)
    tab_rot = frame((0, 0, 0), (0.45 * s, 0, -1))
    box(Ch, "CollarTab" + n, tab_c, (0.17, 0.2, 0.025), "gold", rot=tab_rot, refl=0.15)
    box(Ch, "CollarTabIn" + n, add(tab_c, mul(tab_rot.col(2), -0.008)), (0.12, 0.15, 0.02), "gold_dk", rot=tab_rot)
    ell(Ch, "CollarStar" + n, add(tab_c, mul(tab_rot.col(2), -0.02)), (0.035, 0.035, 0.01), "gold_hi", rot=tab_rot, mat="neon")
box(Ch, "CollarGap", (0.0, 7.46, -0.345), (0.016, 0.29, 0.03), "seam")

# Epaulettes: gold boards with the Führer's stars, gold rim, button by the collar
for s, n in ((1, "R"), (-1, "L")):
    base = (0.74 * s, 7.28, 0.03)
    rot = ang(0, 0, -16 * s)
    box(Ch, "Epaulette" + n, base, (0.74, 0.07, 0.46), "gold", rot=rot, refl=0.12)
    part(Ch, "EpauletteEnd" + n, "cyl", (0.07, 0.44, 0.44), at(add(base, rot.vec((0.37 * s, 0, 0))), rot * ang(0, 0, 90)), "gold", refl=0.12)
    box(Ch, "EpauletteInner" + n, add(base, rot.vec((0, 0.03, 0))), (0.6, 0.04, 0.32), "gold_dk", rot=rot)
    for k in range(3):
        sx = (-0.18 + 0.17 * k) * s
        part(Ch, f"EpauletteStar{n}{k + 1}", "block", (0.12, 0.012, 0.12), at(add(base, rot.vec((sx, 0.058, 0))), rot), "gold_dk",
             tr=1.0, shadow=False, extra=[("star",)])
    ell(Ch, "EpauletteButton" + n, add(base, rot.vec((-0.33 * s, 0.05, 0))), (0.045, 0.03, 0.045), "gold_hi", rot=rot, refl=0.3)
    # gold fringe stubs along the outer edge (the formal shoulder board)
    for k in range(7):
        a = math.radians(-70 + 140 * k / 6)
        off = (0.37 * s + 0.2 * math.cos(a) * s, -0.06, 0.2 * math.sin(a))
        ell(Ch, f"Fringe{n}{k + 1}", add(base, rot.vec(off)), (0.035, 0.08, 0.035), "gold_dk", rot=rot)

# Belt (brown leather), buckle, the sword hangers
ring(Sp, "Belt", (0.0, 5.13, 0.02), 0.735, 0.49, 0.2, 0.06, "leather", segs=18, mat="sp")
ring(Sp, "BeltEdge", (0.0, 5.035, 0.02), 0.745, 0.5, 0.02, 0.062, "leather_dk", segs=18)
box(Sp, "Buckle", (0.0, 5.13, -0.52), (0.3, 0.25, 0.04), "gold", refl=0.25)
box(Sp, "BuckleIn", (0.0, 5.13, -0.54), (0.2, 0.15, 0.02), "leather_dk")
box(Sp, "BucklePin", (0.0, 5.13, -0.552), (0.03, 0.17, 0.012), "gold_hi", refl=0.3)
for s, n in ((1, "R"), (-1, "L")):
    box(Sp, "BeltLoop" + n, (0.4 * s, 5.13, -0.45), (0.05, 0.24, 0.06), "leather_dk", rot=ang(0, 30 * s, 0))
    ell(Sp, "Ring" + n, (0.7 * s, 5.02, -0.2), (0.03, 0.06, 0.06), "gold", refl=0.2)

# Jacket skirt below the belt: a flared band of panels. Front/side panels ride the thighs (so the
# skirt opens with the stride), the back panels ride the hips.
SK_TOP, SK_BOT = 5.05, 3.92
SK_N = 16
for k in range(SK_N):
    t0 = math.radians(360 * k / SK_N - 180)
    t1 = math.radians(360 * (k + 1) / SK_N - 180)
    tm = (t0 + t1) / 2
    corners = []
    for y, rx, rz in ((SK_TOP, 0.745, 0.5), (SK_BOT, 0.9, 0.66)):
        for t in (t0, t1):
            corners.append((rx * math.sin(t), y, 0.02 + rz * -math.cos(t)))
    tl, tr_, bl, br = corners
    center = mul(add(add(tl, tr_), add(bl, br)), 0.25)
    across = sub(lerp3(tr_, br, 0.5), lerp3(tl, bl, 0.5))
    down = sub(lerp3(bl, br, 0.5), lerp3(tl, tr_, 0.5))
    cf = axes(center, across, mul(down, -1))
    deg = math.degrees(tm)  # 0 = front
    if abs(deg) < 112:
        bn = "B_ThighR" if deg > 0 else "B_ThighL"
    else:
        bn = Hp
    w, h = length(across) + 0.03, length(down)
    part(bn, f"Skirt{k + 1}", "block", (w, h, 0.06), cf, "navy", mat="fabric")
    part(bn, f"SkirtHem{k + 1}", "block", (w, 0.05, 0.068), at(add(center, mul(cf.col(1), -h / 2 + 0.03)), cf), "navy_dk", mat="fabric")
for s, n in ((1, "R"), (-1, "L")):
    box("B_Thigh" + n, "HipPocket" + n, (0.5 * s, 4.78, -0.5), (0.36, 0.1, 0.03), "navy_dk", rot=ang(-8, 28 * s, 0), mat="fabric")
box(Hp, "BackVent", (0.0, 4.25, 0.62), (0.02, 0.62, 0.02), "seam")

# =================================================================================================
# ARMS and HANDS
# =================================================================================================
for s, n in ((1, "R"), (-1, "L")):
    S_, E_, Hd = "B_Shoulder" + n, "B_Elbow" + n, "B_Hand" + n
    sh, el, wr = BONES[S_]["pos"], BONES[E_]["pos"], BONES[Hd]["pos"]
    ell(S_, "Deltoid" + n, (1.03 * s, 6.97, 0.02), (0.34, 0.33, 0.34), "navy", mat="fabric", hit=True)
    ell_between(S_, "UpperArm" + n, sh, el, 0.56, 0.58, "navy", pad=0.3, mat="fabric", hit=True)
    ell(S_, "Biceps" + n, (1.13 * s, 6.2, -0.06), (0.22, 0.42, 0.24), "navy", mat="fabric")
    ell(S_, "SleeveSeam" + n, (1.4 * s, 6.3, 0.04), (0.012, 0.55, 0.012), "seam", shadow=False)
    ell(E_, "ElbowCap" + n, (el[0], el[1], el[2] + 0.02), (0.215, 0.22, 0.22), "navy", mat="fabric")
    ell(E_, "ElbowCrease" + n, (el[0], el[1] + 0.02, el[2] - 0.2), (0.12, 0.012, 0.05), "seam", shadow=False)
    fa_top = (el[0] + 0.01 * s, el[1] - 0.05, el[2])
    fa_bot = (wr[0], wr[1] + 0.2, wr[2])
    ell_between(E_, "Forearm" + n, fa_top, fa_bot, 0.46, 0.48, "navy", pad=0.3, mat="fabric", hit=True)
    ell_between(E_, "ForearmTop" + n, fa_top, lerp3(fa_top, fa_bot, 0.55), 0.5, 0.5, "navy", pad=0.1, mat="fabric")
    cuff_a = (wr[0], wr[1] + 0.3, wr[2])
    cuff_b = (wr[0], wr[1] + 0.06, wr[2])
    cyl_between(E_, "Cuff" + n, cuff_a, cuff_b, 0.46, "navy_dk", mat="fabric")
    cyl_between(E_, "CuffPiping" + n, (wr[0], wr[1] + 0.31, wr[2]), (wr[0], wr[1] + 0.29, wr[2]), 0.475, "gold_dk")
    for k in range(2):
        ell(E_, f"CuffButton{n}{k + 1}", (wr[0] + 0.22 * s, wr[1] + 0.12 + 0.1 * k, wr[2] + 0.06), (0.018, 0.03, 0.03), "button", refl=0.2)

    # hand: a strong fist closed round a grip that runs along Z (blade forward)
    gx, gy, gz = 1.29 * s, 3.88, -0.02
    ell(Hd, "Wrist" + n, (wr[0], wr[1] - 0.05, wr[2]), (0.15, 0.13, 0.17), "skin")
    ell(Hd, "Palm" + n, (gx + 0.04 * s, gy + 0.06, gz), (0.15, 0.22, 0.2), "skin", hit=True)
    ell(Hd, "BackOfHand" + n, (gx + 0.1 * s, gy + 0.08, gz), (0.07, 0.2, 0.19), "skin")
    for k in range(4):
        z = gz - 0.12 + 0.08 * k
        ell(Hd, f"Knuckle{n}{k + 1}", (gx + 0.12 * s, gy - 0.06, z), (0.055, 0.06, 0.045), "skin")
        ell(Hd, f"Finger{n}{k + 1}", (gx + 0.02 * s, gy - 0.115, z), (0.11, 0.05, 0.042), "skin")
        ell(Hd, f"FingerTip{n}{k + 1}", (gx - 0.085 * s, gy - 0.06, z), (0.045, 0.07, 0.04), "skin")
        if k > 0:
            ell(Hd, f"FingerGap{n}{k}", (gx + 0.03 * s, gy - 0.12, z - 0.04), (0.1, 0.012, 0.006), "skin_dk", shadow=False)
    ell(Hd, "Thumb" + n, (gx - 0.04 * s, gy + 0.02, gz - 0.19), (0.065, 0.06, 0.11), "skin", rot=ang(-20, 0, 0))
    ell(Hd, "ThumbBase" + n, (gx - 0.02 * s, gy + 0.09, gz - 0.1), (0.08, 0.1, 0.1), "skin")
    ell(Hd, "Thumbnail" + n, (gx - 0.06 * s, gy + 0.05, gz - 0.27), (0.03, 0.02, 0.03), (238, 202, 176), shadow=False)
    ell(Hd, "Vein" + n, (gx + 0.165 * s, gy + 0.12, gz - 0.02), (0.008, 0.11, 0.012), "skin_sh", shadow=False)

# =================================================================================================
# LEGS and BOOTS
# =================================================================================================
for s, n in ((1, "R"), (-1, "L")):
    T_, K_, F_ = "B_Thigh" + n, "B_Shin" + n, "B_Foot" + n
    ell(T_, "HipJoint" + n, (0.44 * s, 4.3, 0.0), (0.36, 0.36, 0.4), "navy", mat="fabric")
    ell_between(T_, "Thigh" + n, (0.46 * s, 4.4, 0.0), (0.5 * s, 2.4, -0.04), 0.68, 0.72, "navy", pad=0.25, mat="fabric", hit=True)
    ell(T_, "Quad" + n, (0.5 * s, 3.5, -0.12), (0.27, 0.75, 0.26), "navy", mat="fabric")
    ell(T_, "TrouserCrease" + n, (0.5 * s, 3.3, -0.4), (0.012, 0.85, 0.012), "seam", shadow=False)
    ell(T_, "TrouserStripe" + n, (0.86 * s, 3.4, 0.0), (0.012, 0.95, 0.03), "gold_dk", shadow=False)
    ell(K_, "Knee" + n, (0.5 * s, 2.42, -0.07), (0.22, 0.24, 0.23), "navy", mat="fabric")
    ell_between(K_, "Bloused" + n, (0.5 * s, 2.55, -0.04), (0.5 * s, 1.68, 0.0), 0.52, 0.54, "navy", pad=0.25, mat="fabric", hit=True)
    ell(K_, "BlousedFold" + n, (0.5 * s, 1.8, 0.0), (0.275, 0.07, 0.285), "navy_dk", mat="fabric")
    # tall polished boots
    cyl_between(K_, "BootShaft" + n, (0.5 * s, 1.75, 0.02), (0.5 * s, 0.45, 0.02), 0.5, "boot", refl=0.08)
    ell(K_, "BootCalf" + n, (0.5 * s, 1.3, 0.07), (0.255, 0.45, 0.25), "boot", refl=0.08)
    ell(K_, "BootShine" + n, (0.62 * s, 1.25, -0.16), (0.03, 0.32, 0.03), "boot_hi", shadow=False)
    cyl_between(K_, "BootTop" + n, (0.5 * s, 1.78, 0.02), (0.5 * s, 1.7, 0.02), 0.535, "boot_hi")
    ell(F_, "Ankle" + n, (0.5 * s, 0.42, 0.02), (0.25, 0.22, 0.27), "boot", refl=0.08)
    ell(F_, "BootFoot" + n, (0.5 * s, 0.27, -0.27), (0.22, 0.2, 0.5), "boot", refl=0.08, hit=True)
    ell(F_, "BootToe" + n, (0.5 * s, 0.2, -0.64), (0.19, 0.15, 0.24), "boot", refl=0.1)
    ell(F_, "ToeShine" + n, (0.53 * s, 0.31, -0.66), (0.06, 0.02, 0.08), "boot_hi", shadow=False)
    box(F_, "Heel" + n, (0.5 * s, 0.1, 0.2), (0.36, 0.2, 0.3), "boot", refl=0.06)
    box(F_, "Sole" + n, (0.5 * s, 0.03, -0.25), (0.42, 0.06, 1.18), "sole")
    bone_attachment(F_, "FootPrint" + n, CF((0.5 * s, 0.0, -0.2)))

# =================================================================================================
# SABERS (Amestris officer's saber: gold shell guard and knuckle bow, black wire-bound grip)
# =================================================================================================


def saber(bone_name, prefix, grip_cf, blade=True, simple=False):
    """grip_cf: centre of the grip, -Z = toward the blade, +Y = spine side."""
    P = lambda x, y, z: grip_cf.pt((x, y, z))
    R = lambda rot: grip_cf * rot
    # grip and wire
    part(bone_name, prefix + "Grip", "cyl", (0.6, 0.11, 0.11), at(P(0, 0, 0.0), (grip_cf * ang(0, 90, 0))), "grip")
    if not simple:
        for k in range(5):
            part(bone_name, f"{prefix}Wire{k + 1}", "cyl", (0.022, 0.118, 0.118), at(P(0, 0, -0.22 + 0.11 * k), (grip_cf * ang(0, 90, 0))), "gold_dk", refl=0.2)
    # pommel and backstrap
    ell(bone_name, prefix + "Pommel", P(0, 0.015, 0.33), (0.07, 0.085, 0.08), "gold", rot=grip_cf, refl=0.25)
    ell(bone_name, prefix + "PommelCap", P(0, 0.07, 0.36), (0.045, 0.04, 0.045), "gold_hi", rot=grip_cf, refl=0.3)
    box(bone_name, prefix + "Backstrap", P(0, 0.055, 0.0), (0.06, 0.02, 0.62), "gold", rot=grip_cf, refl=0.2)
    # shell guard and quillon
    ell(bone_name, prefix + "Guard", P(0, -0.07, -0.35), (0.16, 0.2, 0.035), "gold", rot=grip_cf, refl=0.25)
    ell(bone_name, prefix + "GuardRim", P(0, -0.07, -0.33), (0.17, 0.21, 0.02), "gold_dk", rot=grip_cf, refl=0.1)
    cyl_between(bone_name, prefix + "Quillon", P(0, 0.06, -0.36), P(0, 0.2, -0.28), 0.05, "gold", refl=0.2)
    ell(bone_name, prefix + "QuillonTip", P(0, 0.21, -0.26), (0.035, 0.035, 0.035), "gold_hi", rot=grip_cf, refl=0.3)
    # knuckle bow (edge side, -Y), guard -> pommel
    bow = []
    for k in range(7):
        u = k / 6
        z = -0.33 + 0.64 * u
        y = -0.24 - 0.12 * math.sin(math.pi * u) + 0.2 * u * u
        bow.append(P(0, y, z))
    for k in range(len(bow) - 1):
        cyl_between(bone_name, f"{prefix}Bow{k + 1}", bow[k], bow[k + 1], 0.048, "gold", refl=0.2)
    if not blade:
        return
    # curved blade: segments rising toward the spine, a bright edge, a dark fuller, a clipped point
    seg_n = 6
    L = 3.7
    p = P(0, 0.0, -0.37)
    d = grip_cf.vec((0, 0, -1))
    upv = grip_cf.vec((0, 1, 0))
    rightv = grip_cf.vec((1, 0, 0))
    for k in range(seg_n):
        a = math.radians(1.1 * (k + 0.5))
        dir_ = unit(add(mul(d, math.cos(a)), mul(upv, math.sin(a))))
        seg_len = L / seg_n
        q = add(p, mul(dir_, seg_len))
        width = 0.135 - 0.03 * k / seg_n
        up_k = unit(cross(dir_, rightv)) if False else unit(sub(upv, mul(dir_, dot(upv, dir_))))
        cf = axes(lerp3(p, q, 0.5), rightv, up_k)
        part(bone_name, f"{prefix}Blade{k + 1}", "block", (0.036, width, seg_len + 0.01), cf, "steel", refl=0.35)
        part(bone_name, f"{prefix}Edge{k + 1}", "block", (0.02, 0.024, seg_len + 0.01), at(add(lerp3(p, q, 0.5), mul(up_k, -width / 2 - 0.004)), cf), "edge", refl=0.4)
        part(bone_name, f"{prefix}Fuller{k + 1}", "block", (0.04, 0.022, seg_len * 0.98), at(add(lerp3(p, q, 0.5), mul(up_k, 0.02)), cf), "steel_dk", refl=0.2)
        p = q
        last_dir, last_up, last_w = dir_, up_k, width
    # point: a wedge whose slope runs from the spine down to the edge
    tip_len = 0.42
    tip_c = add(p, mul(last_dir, tip_len / 2))
    cf = axes(tip_c, rightv, last_up)
    # WedgePart: full height at +Z (back), zero at -Z (front): slope faces forward/up. Flip so the
    # point keeps the edge line straight and the spine curves down into it.
    cf = cf * ang(180, 0, 0)
    cf = CF(cf.p, cf.R)
    part(bone_name, prefix + "Point", "wedge", (0.036, last_w, tip_len), at(add(tip_c, mul(last_up, 0.0)), cf), "steel", refl=0.35)
    # blade base ricasso and the trail attachments
    box(bone_name, prefix + "Ricasso", P(0, 0.0, -0.42), (0.05, 0.15, 0.1), "steel_dk", rot=grip_cf, refl=0.3)
    return p


def scabbard(bone_name, prefix, throat_cf, L=3.75):
    """throat_cf: at the scabbard mouth, -Z = down the scabbard, +Y = spine side."""
    P = lambda x, y, z: throat_cf.pt((x, y, z))
    d = throat_cf.vec((0, 0, -1))
    upv = throat_cf.vec((0, 1, 0))
    rightv = throat_cf.vec((1, 0, 0))
    p = P(0, 0, -0.02)
    seg_n = 6
    for k in range(seg_n):
        a = math.radians(1.1 * (k + 0.5))
        dir_ = unit(add(mul(d, math.cos(a)), mul(upv, math.sin(a))))
        q = add(p, mul(dir_, L / seg_n))
        up_k = unit(sub(upv, mul(dir_, dot(upv, dir_))))
        cf = axes(lerp3(p, q, 0.5), rightv, up_k)
        w = 0.19 - 0.04 * k / seg_n
        part(bone_name, f"{prefix}Scabbard{k + 1}", "block", (0.085, w, L / seg_n + 0.02), cf, "scabbard", refl=0.15)
        if k in (1, 3):
            part(bone_name, f"{prefix}Band{k + 1}", "block", (0.1, w + 0.02, 0.08), at(lerp3(p, q, 0.2), cf), "gold", refl=0.2)
            ell(bone_name, f"{prefix}BandRing{k + 1}", add(lerp3(p, q, 0.2), mul(up_k, w / 2 + 0.05)), (0.012, 0.05, 0.05), "gold", rot=cf, refl=0.2)
        p = q
        last_cf, last_w = cf, w
    ell(bone_name, prefix + "Chape", add(p, mul(last_cf.col(2), 0.06)), (0.05, last_w / 2 + 0.01, 0.13), "gold", rot=last_cf, refl=0.25)
    box(bone_name, prefix + "Throat", P(0, 0, -0.07), (0.11, 0.215, 0.16), "gold", rot=throat_cf, refl=0.25)


# drawn sabers in the hands (rest pose: arm hanging, blade straight forward)
for s, n in ((1, "R"), (-1, "L")):
    gcf = at((1.29 * s, 3.88, -0.02), ang(0, 0, 0))
    saber("B_Saber" + n, "Saber" + n + "_", gcf)
    bone_attachment("B_Saber" + n, "BladeBase", CF((1.29 * s, 3.88, -0.6)))
    bone_attachment("B_Saber" + n, "BladeTip", CF((1.29 * s, 3.88 + 0.07, -4.3)))
    bone_attachment("B_Saber" + n, "BladeMid", CF((1.29 * s, 3.88 + 0.03, -2.4)))

# scabbards on the hips: right-hand saber hangs on the left hip and vice versa
for s, n, other in ((1, "R", "L"), (-1, "L", "R")):
    throat = (-0.84 * s, 5.0, -0.3)
    d = unit((-0.06 * s, -0.92, 0.38))
    throat_cf = frame(throat, d, (0, 1, 0))
    scabbard("B_Hips", "Scab" + n + "_", throat_cf)
    # the sheathed hilt (shown while the saber is in its scabbard)
    hilt_cf = frame(add(throat, mul(d, -0.45)), d, (0, 1, 0))
    saber("B_Hips", "Hilt" + n + "_", hilt_cf, blade=False)
    bone_attachment("B_Hips", "HiltGrip" + n, hilt_cf)
    # hanger straps from the belt rings
    cyl_between("B_Hips", "Hanger" + n + "A", (-0.72 * s, 5.02, -0.2), add(throat, mul(d, 0.55)), 0.035, "leather_dk")
    cyl_between("B_Hips", "Hanger" + n + "B", (-0.76 * s, 5.02, 0.05), add(throat, mul(d, 1.35)), 0.035, "leather_dk")

# four spare sabers crossed behind the hips (hidden by the cape until he throws it off)
spares = [
    ((0.82, 5.1, 0.42), (-0.25, 2.2, 0.9)),
    ((0.9, 5.3, 0.3), (-0.1, 2.4, 0.98)),
    ((-0.82, 5.1, 0.42), (0.25, 2.2, 0.9)),
    ((-0.9, 5.3, 0.3), (0.1, 2.4, 0.98)),
]
for k, (top, bot) in enumerate(spares):
    d = unit(sub(bot, top))
    out = unit((top[0], 0.0, 0.2))
    up = unit(cross(d, (0, 0, 1))) if top[0] > 0 else unit(cross((0, 0, 1), d))
    throat_cf = frame(top, d, up)
    scabbard("B_Hips", f"SpareScab{k + 1}_", throat_cf, L=3.3)
    hilt_cf = frame(add(top, mul(d, -0.45)), d, up)
    saber("B_Hips", f"Spare{k + 1}_", hilt_cf, blade=False, simple=True)
    bone_attachment("B_Hips", f"SpareGrip{k + 1}", hilt_cf)

# =================================================================================================
# CAPE (the Führer's dress cape: navy outside, dark lining, gold trim, gold chain across the chest)
# =================================================================================================
PANELS = 11
A0, A1 = -102.0, 102.0
for i in range(CAPE_ROWS):
    b = f"B_Cape{i + 1}"
    y0 = CAPE_TOP - CAPE_ROW * i + (0.06 if i > 0 else 0.0)
    y1 = CAPE_TOP - CAPE_ROW * (i + 1) - 0.08
    for k in range(PANELS):
        t0 = math.radians(A0 + (A1 - A0) * k / PANELS)
        t1 = math.radians(A0 + (A1 - A0) * (k + 1) / PANELS)
        corners = []
        for y in (y0, y1):
            rx, rz, cz = cape_shape(y)
            for t in (t0, t1):
                corners.append((rx * math.sin(t), y, cz + rz * math.cos(t)))
        # quad (top-left, top-right, bottom-left, bottom-right) -> best-fit block
        tl, tr_, bl, br = corners
        center = mul(add(add(tl, tr_), add(bl, br)), 0.25)
        across = sub(lerp3(tr_, br, 0.5), lerp3(tl, bl, 0.5))
        down = sub(lerp3(bl, br, 0.5), lerp3(tl, tr_, 0.5))
        cf = axes(center, across, mul(down, -1))
        w = length(across) + 0.04
        h = length(down)
        part(b, f"Cape_Outer{i + 1}_{k + 1}", "block", (w, h, 0.06), cf, "cape", mat="fabric")
        inward = cf.col(2)  # +Z of the panel points outward (back); lining sits just inside
        part(b, f"Cape_Lining{i + 1}_{k + 1}", "block", (w, h, 0.03), at(add(center, mul(inward, -0.045)), cf), "cape_in", mat="fabric", shadow=False)
        if i == CAPE_ROWS - 1:
            hem = add(center, mul(cf.col(1), -h / 2 + 0.05))
            part(b, f"Cape_Hem{k + 1}", "block", (w, 0.08, 0.075), at(hem, cf), "gold_dk", refl=0.1)
        if k in (0, PANELS - 1):
            edge_x = -w / 2 + 0.03 if k == 0 else w / 2 - 0.03
            ep = add(center, mul(cf.col(0), edge_x))
            part(b, f"Cape_Edge{i + 1}_{k + 1}", "block", (0.06, h, 0.075), at(ep, cf), "gold_dk", refl=0.1)
# gathered top roll across the back of the shoulders
for k in range(9):
    t = math.radians(-100 + 200 * (k + 0.5) / 9)
    rx, rz, cz = cape_shape(CAPE_TOP)
    p = (rx * 1.02 * math.sin(t), CAPE_TOP + 0.04, cz + rz * 1.05 * math.cos(t))
    ell("B_Cape1", f"Cape_Roll{k + 1}", p, (0.24, 0.12, 0.14), "cape", rot=ang(0, math.degrees(t), 0), mat="fabric")
# clasps at the shoulders and the chain across the chest (part of the cape)
clasp = {}
for s, n in ((1, "R"), (-1, "L")):
    c = (0.8 * s, 7.06, -0.38)
    clasp[n] = c
    part(Ch, "Cape_Clasp" + n, "cyl", (0.06, 0.2, 0.2), at(c, frame((0, 0, 0), (0.3 * s, 0, -1)) * ang(0, 90, 0)), "gold", refl=0.25)
    ell(Ch, "Cape_ClaspGem" + n, add(c, (0.015 * s, 0, -0.04)), (0.05, 0.05, 0.03), "gold_hi", refl=0.3, rot=frame((0, 0, 0), (0.3 * s, 0, -1)))
    cyl_between(Ch, "Cape_Cord" + n, c, (0.95 * s, 7.2, 0.05), 0.07, "cape")
links = 9
prev = None
for k in range(links + 1):
    u = k / links
    x = clasp["L"][0] + (clasp["R"][0] - clasp["L"][0]) * u
    y = 7.06 - 0.3 * math.sin(math.pi * u)
    p, nrm = torso.front(x, y, 0.035)
    if prev is not None:
        cyl_between(Ch, f"Cape_Chain{k}", prev, p, 0.035, "gold", refl=0.25)
    prev = p

# =================================================================================================
# Attachments used by the scripts
# =================================================================================================
bone_attachment("B_Chest", "ChestCenter", CF((0.0, 6.6, -0.3)))
bone_attachment("B_Hips", "HipsCenter", CF((0.0, 4.72, 0.0)))
for s, n in ((1, "R"), (-1, "L")):
    bone_attachment("B_Hand" + n, "GripPoint", CF((1.29 * s, 3.88, -0.02)))

# =================================================================================================
# Writer
# =================================================================================================


def f(x):
    s = f"{x:.6f}".rstrip("0")
    return s + "0" if s.endswith(".") else s


def color_uint(c):
    return 0xFF000000 | (int(c[0]) << 16) | (int(c[1]) << 8) | int(c[2])


def xml_cf(name, cf):
    v = cf.flat()
    keys = ["X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22"]
    return f'<CoordinateFrame name="{name}">' + "".join(f"<{k}>{f(x)}</{k}>" for k, x in zip(keys, v)) + "</CoordinateFrame>"


def xml_v3(name, v):
    return f'<Vector3 name="{name}"><X>{f(v[0])}</X><Y>{f(v[1])}</Y><Z>{f(v[2])}</Z></Vector3>'


def xml_c3(name, c):
    return f'<Color3 name="{name}"><R>{f(c[0] / 255)}</R><G>{f(c[1] / 255)}</G><B>{f(c[2] / 255)}</B></Color3>'


def xml_udim2(name, xs, xo, ys, yo):
    return f'<UDim2 name="{name}"><XS>{f(xs)}</XS><XO>{int(xo)}</XO><YS>{f(ys)}</YS><YO>{int(yo)}</YO></UDim2>'


class Writer:
    def __init__(self):
        self.out = []
        self.ref = 0

    def nref(self):
        self.ref += 1
        return f"RBX{self.ref:06d}"

    def open(self, cls, props, ref=None):
        ref = ref or self.nref()
        self.out.append(f'<Item class="{cls}" referent="{ref}"><Properties>')
        self.out.extend(props)
        self.out.append("</Properties>")
        return ref

    def close(self):
        self.out.append("</Item>")

    def leaf(self, cls, props):
        self.open(cls, props)
        self.close()


def basepart_props(name, cf, size, color, mat, tr, refl, collide, touch, query, shadow, massless=True, anchored=True):
    return [
        f'<string name="Name">{name}</string>',
        xml_cf("CFrame", cf),
        xml_v3("size", size),
        f'<Color3uint8 name="Color3uint8">{color_uint(color)}</Color3uint8>',
        f'<token name="Material">{mat}</token>',
        f'<float name="Transparency">{f(tr)}</float>',
        f'<float name="Reflectance">{f(refl)}</float>',
        f'<bool name="Anchored">{"true" if anchored else "false"}</bool>',
        f'<bool name="CanCollide">{"true" if collide else "false"}</bool>',
        f'<bool name="CanTouch">{"true" if touch else "false"}</bool>',
        f'<bool name="CanQuery">{"true" if query else "false"}</bool>',
        f'<bool name="CastShadow">{"true" if shadow else "false"}</bool>',
        f'<bool name="Massless">{"true" if massless else "false"}</bool>',
        '<token name="TopSurface">0</token>',
        '<token name="BottomSurface">0</token>',
    ]


def write_gui_frame(w, name, pos, size, color, tr=0.0, rot=0.0, corner=None, stroke=None, anchor=(0.5, 0.5), z=1):
    w.open("Frame", [
        f'<string name="Name">{name}</string>',
        xml_udim2("Position", pos[0], 0, pos[1], 0),
        xml_udim2("Size", size[0], 0, size[1], 0),
        f'<Vector2 name="AnchorPoint"><X>{f(anchor[0])}</X><Y>{f(anchor[1])}</Y></Vector2>',
        xml_c3("BackgroundColor3", color),
        f'<float name="BackgroundTransparency">{f(tr)}</float>',
        '<int name="BorderSizePixel">0</int>',
        f'<float name="Rotation">{f(rot)}</float>',
        f'<int name="ZIndex">{z}</int>',
    ])
    if corner is not None:
        w.leaf("UICorner", ['<string name="Name">UICorner</string>', f'<UDim name="CornerRadius"><S>{f(corner)}</S><O>0</O></UDim>'])
    if stroke is not None:
        w.leaf("UIStroke", [
            '<string name="Name">UIStroke</string>',
            xml_c3("Color", stroke[0]),
            f'<float name="Thickness">{f(stroke[1])}</float>',
            '<token name="ApplyStrokeMode">1</token>',
        ])
    w.close()


def write_ouroboros(w):
    """The Ouroboros mark of the Ultimate Eye: double red ring, hexagram, slit pupil, snake head."""
    w.open("SurfaceGui", [
        '<string name="Name">Ouroboros</string>',
        '<token name="Face">5</token>',
        '<token name="SizingMode">0</token>',
        '<Vector2 name="CanvasSize"><X>256</X><Y>256</Y></Vector2>',
        '<float name="LightInfluence">0</float>',
        '<float name="Brightness">1.6</float>',
        '<bool name="AlwaysOnTop">false</bool>',
        '<token name="ZIndexBehavior">1</token>',
        '<bool name="ClipsDescendants">true</bool>',
    ])
    red = C["ult_red"]
    dark = (120, 6, 14)
    write_gui_frame(w, "Iris", (0.5, 0.5), (0.86, 0.86), (236, 226, 222), 0.0, corner=0.5, stroke=(dark, 4), z=1)
    write_gui_frame(w, "Ring", (0.5, 0.5), (0.82, 0.82), red, 1.0, corner=0.5, stroke=(red, 14), z=2)
    write_gui_frame(w, "RingInner", (0.5, 0.5), (0.6, 0.6), red, 1.0, corner=0.5, stroke=(red, 5), z=2)
    # scales on the snake body
    for k in range(16):
        a = 2 * math.pi * k / 16
        x, y = 0.5 + 0.41 * math.cos(a), 0.5 + 0.41 * math.sin(a)
        write_gui_frame(w, f"Scale{k + 1}", (x, y), (0.035, 0.035), dark, 0.0, rot=math.degrees(a) + 45, z=3)
    # hexagram: two triangles of lines
    R = 0.27
    for tri in (0, 1):
        pts = []
        for k in range(3):
            a = math.radians(-90 + 120 * k + 180 * tri)
            pts.append((0.5 + R * math.cos(a), 0.5 + R * math.sin(a)))
        for k in range(3):
            (x0, y0), (x1, y1) = pts[k], pts[(k + 1) % 3]
            L = math.hypot(x1 - x0, y1 - y0)
            rot = math.degrees(math.atan2(y1 - y0, x1 - x0))
            write_gui_frame(w, f"Hex{tri}{k}", ((x0 + x1) / 2, (y0 + y1) / 2), (L, 0.03), red, 0.0, rot=rot, z=4)
    # the snake's head biting its tail (top) and the wings of the mark
    write_gui_frame(w, "SnakeHead", (0.5, 0.075), (0.1, 0.1), red, 0.0, rot=45, z=5)
    write_gui_frame(w, "SnakeEye", (0.5, 0.075), (0.03, 0.03), (255, 230, 120), 0.0, corner=0.5, z=6)
    for s in (-1, 1):
        write_gui_frame(w, f"Wing{s}", (0.5 + 0.13 * s, 0.86), (0.16, 0.03), red, 0.0, rot=20 * s, z=4)
    write_gui_frame(w, "Pupil", (0.5, 0.5), (0.07, 0.16), (20, 0, 4), 0.0, corner=0.5, z=6)
    write_gui_frame(w, "PupilDot", (0.5, 0.5), (0.12, 0.12), red, 1.0, corner=0.5, stroke=(red, 3), z=5)
    w.close()


def write_star(w):
    w.open("SurfaceGui", [
        '<string name="Name">Star</string>',
        '<token name="Face">1</token>',
        '<token name="SizingMode">0</token>',
        '<Vector2 name="CanvasSize"><X>64</X><Y>64</Y></Vector2>',
        '<float name="LightInfluence">1</float>',
        '<token name="ZIndexBehavior">1</token>',
    ])
    w.leaf("TextLabel", [
        '<string name="Name">Glyph</string>',
        xml_udim2("Size", 1, 0, 1, 0),
        '<float name="BackgroundTransparency">1</float>',
        '<string name="Text">★</string>',
        '<bool name="TextScaled">true</bool>',
        xml_c3("TextColor3", C["gold_dk"]),
        '<float name="TextStrokeTransparency">0.6</float>',
        xml_c3("TextStrokeColor3", (90, 60, 10)),
        '<token name="Font">4</token>',
    ])
    w.close()


def write_part(w, p, parent_bone_pos):
    kind = p["kind"]
    size = list(p["size"])
    mesh = None
    shape = 1
    cls = "Part"
    if kind == "ell":
        mesh = (3, [1, 1, 1])
    elif kind == "cyl":
        shape = 2
    elif kind == "ball":
        shape = 0
    elif kind == "wedge":
        cls = "WedgePart"
    # parts thinner than MIN use a mesh to shrink the visible shape (works on every engine version)
    if kind in ("block", "ell") and min(size) < MIN:
        scale = [1.0, 1.0, 1.0]
        for i in range(3):
            if size[i] < MIN:
                scale[i] = size[i] / MIN
                size[i] = MIN
        mesh = (3 if kind == "ell" else 6, scale)
    elif min(size) < MIN:
        size = [max(s, MIN) for s in size]
    hit = p["hit"]
    if p["name"].startswith(("HiltR_", "HiltL_")):
        p = dict(p, tr=1.0)  # sheathed hilts start hidden: the boss starts with his sabers drawn
    props = basepart_props(p["name"], p["cf"], size, p["color"], p["mat"], p["tr"], p["refl"], False, hit, hit, p["shadow"])
    if cls == "Part":
        props.insert(3, f'<token name="shape">{shape}</token>')
    w.open(cls, props)
    if mesh:
        w.leaf("SpecialMesh", [
            '<string name="Name">Mesh</string>',
            f'<token name="MeshType">{mesh[0]}</token>',
            xml_v3("Scale", mesh[1]),
        ])
    for e in p["extra"]:
        if e[0] == "ouroboros":
            write_ouroboros(w)
        elif e[0] == "star":
            write_star(w)
    w.close()


def write_bone(w, name):
    b = BONES[name]
    cf = CF(b["pos"])
    w.open("Part", basepart_props(name, cf, (0.2, 0.2, 0.2), (163, 162, 165), 272, 1.0, 0.0, False, False, False, False))
    for an, lcf in b["attachments"]:
        w.leaf("Attachment", [f'<string name="Name">{an}</string>', xml_cf("CFrame", lcf)])
    for p in PARTS:
        if p["bone"] == name:
            write_part(w, p, b["pos"])
    for child in BONE_ORDER:
        if BONES[child]["parent"] == name:
            write_bone(w, child)
    w.close()


def read_src(fname):
    with open(os.path.join(ROOT, "src", fname), encoding="utf-8") as fh:
        return fh.read()


def write_model(path):
    w = Writer()
    w.out.append('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')
    w.out.append("<External>null</External><External>nil</External>")
    model_ref = w.nref()
    hrp_ref = w.nref()
    w.open("Model", ['<string name="Name">KingBradley</string>', f'<Ref name="PrimaryPart">{hrp_ref}</Ref>', '<token name="ModelStreamingMode">1</token>'], ref=model_ref)
    w.leaf("Humanoid", [
        '<string name="Name">Humanoid</string>',
        '<float name="MaxHealth">9000</float>',
        '<float name="Health_XML">9000</float>',
        f'<float name="HipHeight">{f(HIP_HEIGHT)}</float>',
        '<token name="RigType">1</token>',
        '<token name="DisplayDistanceType">2</token>',
        '<bool name="BreakJointsOnDeath">false</bool>',
        '<float name="WalkSpeed">13</float>',
    ])
    hrp_props = basepart_props("HumanoidRootPart", CF(HRP_POS), HRP_SIZE, (163, 162, 165), 272, 1.0, 0.0, True, True, True, False, massless=False)
    w.open("Part", hrp_props, ref=hrp_ref)
    w.leaf("Attachment", ['<string name="Name">RootAttachment</string>', xml_cf("CFrame", CF())])
    for child in BONE_ORDER:
        if BONES[child]["parent"] == "HumanoidRootPart":
            write_bone(w, child)
    w.close()
    scripts = [
        ("ModuleScript", "Config", "Config.lua", None),
        ("ModuleScript", "Motion", "Motion.lua", None),
        ("ModuleScript", "Poses", "Poses.lua", None),
        ("Script", "BossServer", "BossServer.server.lua", 1),
        ("Script", "BossClient", "BossClient.client.lua", 2),
    ]
    for cls, name, fname, ctx in scripts:
        src = read_src(fname)
        props = [f'<string name="Name">{name}</string>']
        if ctx is not None:
            props.append(f'<token name="RunContext">{ctx}</token>')
            props.append('<bool name="Disabled">false</bool>')
        props.append(f'<ProtectedString name="Source"><![CDATA[{src}]]></ProtectedString>')
        w.leaf(cls, props)
    w.close()
    w.out.append("</roblox>")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(w.out))


def write_preview(path):
    out = {"bones": {}, "parts": []}
    for name in BONE_ORDER:
        out["bones"][name] = {"parent": BONES[name]["parent"], "pos": BONES[name]["pos"]}
    for p in PARTS:
        out["parts"].append({
            "bone": p["bone"],
            "name": p["name"],
            "kind": p["kind"],
            "size": p["size"],
            "cf": p["cf"].flat(),
            "color": p["color"],
            "tr": p["tr"],
            "refl": p["refl"],
            "gui": [e[0] for e in p["extra"]],
        })
    with open(path, "w") as fh:
        json.dump(out, fh)


if __name__ == "__main__":
    write_model(os.path.join(ROOT, "KingBradley.rbxmx"))
    if "--preview" in sys.argv:
        i = sys.argv.index("--preview")
        write_preview(sys.argv[i + 1])
    hits = sum(1 for p in PARTS if p["hit"])
    print(f"bones: {len(BONES)}  parts: {len(PARTS)}  hit parts: {hits}")
