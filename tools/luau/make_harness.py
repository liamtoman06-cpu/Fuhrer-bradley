"""
Builds a self-contained Luau program that runs the real src/Animator.lua (with src/Poses.lua and
src/Config.lua) under the Luau CLI and prints every bone Transform per frame as JSON.

    python3 tools/luau/make_harness.py rig.json scenario.json > harness.luau && luau harness.luau > frames.json

scenario.json: { "fps": 30, "clips": [ {"name": "run", "seconds": 2.0, "speed": 26, ...}, ... ] }
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rig = json.load(open(sys.argv[1]))
scen = json.load(open(sys.argv[2]))


def src(name):
    return open(os.path.join(ROOT, name), encoding="utf-8").read()


heads = {b["name"]: b["head"] for b in rig["bones"]}
hips = heads["B_Hips"]
lines = []
for b in rig["bones"]:
    h = b["head"]
    if b["parent"]:
        ph = heads[b["parent"]]
        rel = [h[0] - ph[0], h[1] - ph[1], h[2] - ph[2]]
        lines.append(f'{{ name = "{b["name"]}", parent = "{b["parent"]}", rest = CFrame.new({rel[0]:.6f}, {rel[1]:.6f}, {rel[2]:.6f}) }},')
    else:
        lines.append(f'{{ name = "{b["name"]}", rest = CFrame.new({h[0]:.6f}, {h[1]:.6f}, {h[2]:.6f}) }},')

out = []
out.append("--!nonstrict")
out.append("local __shim = (function()\n" + src("tools/luau/shim.luau") + "\nend)()")
out.append("local CFrame, Vector3 = __shim.CFrame, __shim.Vector3")
out.append("local math = setmetatable({ noise = __shim.noise }, { __index = math })")
out.append("local Config = (function()\n" + src("src/Config.lua") + "\nend)()")
out.append("local Poses = (function()\n" + src("src/Poses.lua") + "\nend)()")
out.append("local Animator = (function()\n" + src("src/Animator.lua") + "\nend)()")
out.append(f"local HIPS = Vector3.new({hips[0]}, {hips[1]}, {hips[2]})")
out.append("local DESC = { bones = {\n" + "\n".join(lines) + "\n} }")
def to_lua(v):
    """JSON value -> Luau table constructor."""
    if isinstance(v, dict):
        return "{" + ", ".join(f"[{json.dumps(k)}] = {to_lua(x)}" for k, x in v.items()) + "}"
    if isinstance(v, list):
        return "{" + ", ".join(to_lua(x) for x in v) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "nil"
    return json.dumps(v)


out.append("local SCEN = " + to_lua(scen))
out.append(src("tools/luau/driver.luau"))
print("\n".join(out))
