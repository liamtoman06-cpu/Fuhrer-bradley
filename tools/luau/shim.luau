--!nonstrict
-- Minimal Roblox math (Vector3, CFrame, math.noise) so the Animator module runs under the plain
-- Luau CLI for offline previews and tests. Only what the Animator uses is implemented.
local V = {}
V.__index = function(v, k)
	if k == "X" then return rawget(v, 1) elseif k == "Y" then return rawget(v, 2) elseif k == "Z" then return rawget(v, 3)
	elseif k == "Magnitude" then return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	elseif k == "Unit" then local m = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]); if m < 1e-12 then return setmetatable({ 0 / 0, 0 / 0, 0 / 0 }, V) end return setmetatable({ v[1] / m, v[2] / m, v[3] / m }, V) end
	return V[k]
end
local function vec(x, y, z) return setmetatable({ x or 0, y or 0, z or 0 }, V) end
V.__add = function(a, b) return vec(a[1] + b[1], a[2] + b[2], a[3] + b[3]) end
V.__sub = function(a, b) return vec(a[1] - b[1], a[2] - b[2], a[3] - b[3]) end
V.__mul = function(a, b)
	if type(a) == "number" then return vec(b[1] * a, b[2] * a, b[3] * a) end
	if type(b) == "number" then return vec(a[1] * b, a[2] * b, a[3] * b) end
	return vec(a[1] * b[1], a[2] * b[2], a[3] * b[3])
end
V.__div = function(a, b)
	if type(b) == "number" then return vec(a[1] / b, a[2] / b, a[3] / b) end
	return vec(a[1] / b[1], a[2] / b[2], a[3] / b[3])
end
V.__unm = function(a) return vec(-a[1], -a[2], -a[3]) end
V.__eq = function(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
V.__tostring = function(a) return string.format("%.3f, %.3f, %.3f", a[1], a[2], a[3]) end
function V.Dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
function V.Cross(a, b) return vec(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]) end
function V.Lerp(a, b, t) return vec(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t) end
function V.Min(a, b) return vec(math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3])) end
function V.Max(a, b) return vec(math.max(a[1], b[1]), math.max(a[2], b[2]), math.max(a[3], b[3])) end
function V.Abs(a) return vec(math.abs(a[1]), math.abs(a[2]), math.abs(a[3])) end
local Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1), xAxis = vec(1, 0, 0), yAxis = vec(0, 1, 0), zAxis = vec(0, 0, 1) }

-- CFrame: { p = {x,y,z}, r = {r00..r22} row-major }
local C = {}
local function cf(px, py, pz, m) return setmetatable({ px, py, pz, m }, C) end
local IDM = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function mulm(a, b)
	return {
		a[1] * b[1] + a[2] * b[4] + a[3] * b[7], a[1] * b[2] + a[2] * b[5] + a[3] * b[8], a[1] * b[3] + a[2] * b[6] + a[3] * b[9],
		a[4] * b[1] + a[5] * b[4] + a[6] * b[7], a[4] * b[2] + a[5] * b[5] + a[6] * b[8], a[4] * b[3] + a[5] * b[6] + a[6] * b[9],
		a[7] * b[1] + a[8] * b[4] + a[9] * b[7], a[7] * b[2] + a[8] * b[5] + a[9] * b[8], a[7] * b[3] + a[8] * b[6] + a[9] * b[9],
	}
end
local function rotv(m, x, y, z) return m[1] * x + m[2] * y + m[3] * z, m[4] * x + m[5] * y + m[6] * z, m[7] * x + m[8] * y + m[9] * z end
local function tr(m) return { m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9] } end
C.__index = function(c, k)
	local m = rawget(c, 4)
	if k == "Position" or k == "p" then return vec(c[1], c[2], c[3])
	elseif k == "X" then return c[1] elseif k == "Y" then return c[2] elseif k == "Z" then return c[3]
	elseif k == "Rotation" then return cf(0, 0, 0, m)
	elseif k == "LookVector" then return vec(-m[3], -m[6], -m[9])
	elseif k == "RightVector" or k == "XVector" then return vec(m[1], m[4], m[7])
	elseif k == "UpVector" or k == "YVector" then return vec(m[2], m[5], m[8])
	elseif k == "ZVector" then return vec(m[3], m[6], m[9]) end
	return C[k]
end
C.__mul = function(a, b)
	local m = rawget(a, 4)
	if getmetatable(b) == V then
		local x, y, z = rotv(m, b[1], b[2], b[3]); return vec(x + a[1], y + a[2], z + a[3])
	end
	local x, y, z = rotv(m, b[1], b[2], b[3])
	return cf(x + a[1], y + a[2], z + a[3], mulm(m, rawget(b, 4)))
end
C.__add = function(a, v) return cf(a[1] + v[1], a[2] + v[2], a[3] + v[3], rawget(a, 4)) end
C.__sub = function(a, v) return cf(a[1] - v[1], a[2] - v[2], a[3] - v[3], rawget(a, 4)) end
function C.Inverse(a)
	local t = tr(rawget(a, 4)); local x, y, z = rotv(t, a[1], a[2], a[3]); return cf(-x, -y, -z, t)
end
function C.PointToObjectSpace(a, v)
	local t = tr(rawget(a, 4)); local x, y, z = rotv(t, v[1] - a[1], v[2] - a[2], v[3] - a[3]); return vec(x, y, z)
end
function C.PointToWorldSpace(a, v) return a * v end
function C.VectorToObjectSpace(a, v) local x, y, z = rotv(tr(rawget(a, 4)), v[1], v[2], v[3]); return vec(x, y, z) end
function C.VectorToWorldSpace(a, v) local x, y, z = rotv(rawget(a, 4), v[1], v[2], v[3]); return vec(x, y, z) end
function C.ToObjectSpace(a, b) return a:Inverse() * b end
function C.ToWorldSpace(a, b) return a * b end
function C.GetComponents(a) local m = rawget(a, 4); return a[1], a[2], a[3], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9] end
local function toQuat(m)
	local tr_ = m[1] + m[5] + m[9]
	local w, x, y, z
	if tr_ > 0 then local s = math.sqrt(tr_ + 1) * 2; w = 0.25 * s; x = (m[8] - m[6]) / s; y = (m[3] - m[7]) / s; z = (m[4] - m[2]) / s
	elseif m[1] > m[5] and m[1] > m[9] then local s = math.sqrt(1 + m[1] - m[5] - m[9]) * 2; w = (m[8] - m[6]) / s; x = 0.25 * s; y = (m[2] + m[4]) / s; z = (m[3] + m[7]) / s
	elseif m[5] > m[9] then local s = math.sqrt(1 + m[5] - m[1] - m[9]) * 2; w = (m[3] - m[7]) / s; x = (m[2] + m[4]) / s; y = 0.25 * s; z = (m[6] + m[8]) / s
	else local s = math.sqrt(1 + m[9] - m[1] - m[5]) * 2; w = (m[4] - m[2]) / s; x = (m[3] + m[7]) / s; y = (m[6] + m[8]) / s; z = 0.25 * s end
	return w, x, y, z
end
local function fromQuat(w, x, y, z)
	local n = math.sqrt(w * w + x * x + y * y + z * z); w, x, y, z = w / n, x / n, y / n, z / n
	return { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) }
end
function C.ToAxisAngle(a)
	local w, x, y, z = toQuat(rawget(a, 4))
	if w < 0 then w, x, y, z = -w, -x, -y, -z end
	local ang = 2 * math.acos(math.min(1, w)); local s = math.sqrt(math.max(0, 1 - w * w))
	if s < 1e-8 then return vec(1, 0, 0), 0 end
	return vec(x / s, y / s, z / s), ang
end
function C.Lerp(a, b, t)
	local w1, x1, y1, z1 = toQuat(rawget(a, 4)); local w2, x2, y2, z2 = toQuat(rawget(b, 4))
	local d = w1 * w2 + x1 * x2 + y1 * y2 + z1 * z2
	if d < 0 then w2, x2, y2, z2, d = -w2, -x2, -y2, -z2, -d end
	local k1, k2
	if d > 0.9995 then k1, k2 = 1 - t, t else local th = math.acos(d); local s = math.sin(th); k1, k2 = math.sin((1 - t) * th) / s, math.sin(t * th) / s end
	return cf(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, fromQuat(w1 * k1 + w2 * k2, x1 * k1 + x2 * k2, y1 * k1 + y2 * k2, z1 * k1 + z2 * k2))
end
function C.ToEulerAnglesXYZ(a)
	local m = rawget(a, 4)
	local y = math.asin(math.clamp(m[3], -1, 1))
	return math.atan2(-m[6], m[9]), y, math.atan2(-m[2], m[1])
end
function C.ToEulerAnglesYXZ(a)
	local m = rawget(a, 4)
	local x = math.asin(math.clamp(-m[6], -1, 1))
	return x, math.atan2(m[3], m[9]), math.atan2(m[4], m[5])
end
local CFrame = {}
CFrame.identity = cf(0, 0, 0, IDM)
function CFrame.new(a, b, c, ...)
	if a == nil then return cf(0, 0, 0, IDM) end
	if type(a) == "table" then return cf(a[1], a[2], a[3], IDM) end
	local r = { ... }
	if #r == 9 then return cf(a, b, c, r) end
	return cf(a, b, c, IDM)
end
local function angles(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local Rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local Ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local Rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	return cf(0, 0, 0, mulm(mulm(Rx, Ry), Rz))
end
CFrame.Angles = angles
CFrame.fromEulerAnglesXYZ = angles
function CFrame.fromEulerAnglesYXZ(rx, ry, rz)
	local a = angles(0, ry, 0) * angles(rx, 0, 0) * angles(0, 0, rz); return a
end
function CFrame.fromAxisAngle(axis, ang)
	local u = axis.Unit; local s = math.sin(ang / 2)
	return cf(0, 0, 0, fromQuat(math.cos(ang / 2), u[1] * s, u[2] * s, u[3] * s))
end
function CFrame.fromMatrix(p, x, y, z)
	z = z or x:Cross(y)
	return cf(p[1], p[2], p[3], { x[1], y[1], z[1], x[2], y[2], z[2], x[3], y[3], z[3] })
end
function CFrame.lookAt(at, target, up)
	up = up or vec(0, 1, 0)
	local f = (target - at).Unit; local r = f:Cross(up).Unit; local u = r:Cross(f)
	return CFrame.fromMatrix(at, r, u, -f)
end

-- Perlin noise (Ken Perlin's improved noise), same range/feel as math.noise
local perm = {}
do
	local p = { 151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180 }
	for i = 0, 511 do perm[i] = p[(i % 256) + 1] end
end
local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
local function grad(h, x, y, z)
	h = h % 16; local u = if h < 8 then x else y; local v = if h < 4 then y elseif h == 12 or h == 14 then x else z
	return (if h % 2 == 0 then u else -u) + (if math.floor(h / 2) % 2 == 0 then v else -v)
end
local function noise(x, y, z)
	y, z = y or 0, z or 0
	local X, Y, Z = math.floor(x) % 256, math.floor(y) % 256, math.floor(z) % 256
	x, y, z = x - math.floor(x), y - math.floor(y), z - math.floor(z)
	local u, v, w = fade(x), fade(y), fade(z)
	local A = perm[X] + Y; local AA = perm[A] + Z; local AB = perm[A + 1] + Z; local B = perm[X + 1] + Y; local BA = perm[B] + Z; local BB = perm[B + 1] + Z
	local l = function(t, a, b) return a + t * (b - a) end
	return 0.5 * l(w, l(v, l(u, grad(perm[AA], x, y, z), grad(perm[BA], x - 1, y, z)), l(u, grad(perm[AB], x, y - 1, z), grad(perm[BB], x - 1, y - 1, z))),
		l(v, l(u, grad(perm[AA + 1], x, y, z - 1), grad(perm[BA + 1], x - 1, y, z - 1)), l(u, grad(perm[AB + 1], x, y - 1, z - 1), grad(perm[BB + 1], x - 1, y - 1, z - 1))))
end

return { Vector3 = Vector3, CFrame = CFrame, noise = noise }
