--[[
	Pure tonemapping operators and 1024x32 (32^3) 3D LUT generator.

	Includes the exact Khronos PBR Neutral specification (`KhronosGroup/ToneMapping`,
	`PBR_Neutral/pbrNeutral.glsl`) alongside the reference operators Khronos compares it against
	(AgX, AgX Punchy, ACES Filmic, Uncharted 2 Hable, Extended Reinhard) plus an unmodified
	Identity LUT for verifying Roblox's `ColorLutContent` axis orientation in Studio.

	No Roblox services are touched here so `make test ONLY=shared` verifies every operator and LUT
	buffer invariant offline. See docs/tonemapping.md.
]]

local Shared = script:FindFirstAncestor("Shared")
local Config = require(Shared.core.Config)

local Tonemapper = {}

export type FallbackCorrection = {
	exposureCompensation: number,
	brightness: number,
	contrast: number,
	saturation: number,
	tintColor: Color3,
	bloomIntensity: number,
	bloomSize: number,
	bloomThreshold: number,
}

export type Preset = {
	id: string,
	label: string,
	source: string,
	summary: string,
	basePreset: "Default" | "Retro",
	operator: string,
	exposureScale: number,
	hdrWhite: number,
	lutFile: string?,
	fallbackCorrection: FallbackCorrection?,
}

-- Rec. 709 luminance weights (used by AgX Punchy saturation and Extended Reinhard).
local LUMA_R = 0.2126
local LUMA_G = 0.7152
local LUMA_B = 0.0722

-- Exact IEC 61966-2-1 sRGB <-> linear Rec. 709 transfer functions.
function Tonemapper.srgbToLinear(c: number): number
	if c <= 0.04045 then
		return c / 12.92
	end
	return ((c + 0.055) / 1.055) ^ 2.4
end

function Tonemapper.linearToSrgb(c: number): number
	local clamped = math.clamp(c, 0, 1)
	if clamped <= 0.0031308 then
		return clamped * 12.92
	end
	return 1.055 * (clamped ^ (1 / 2.4)) - 0.055
end

--=============================================================================
-- Linear HDR -> Linear [0, 1] operators
--=============================================================================

-- Exact port of `KhronosGroup/ToneMapping/PBR_Neutral/pbrNeutral.glsl`.
-- Preserves baseColor under neutral white lighting with zero hue shift across all intensities.
function Tonemapper.pbrNeutral(r: number, g: number, b: number): (number, number, number)
	local startCompression = 0.8 - 0.04
	local desaturation = 0.15

	local x = math.min(r, g, b)
	local offset = if x < 0.08 then x - 6.25 * x * x else 0.04
	r -= offset
	g -= offset
	b -= offset

	local peak = math.max(r, g, b)
	if peak < startCompression then
		return math.max(r, 0), math.max(g, 0), math.max(b, 0)
	end

	local d = 1 - startCompression
	local newPeak = 1 - (d * d) / (peak + d - startCompression)
	local scale = newPeak / peak
	r *= scale
	g *= scale
	b *= scale

	local f = 1 - 1 / (desaturation * (peak - newPeak) + 1)
	r = r + (newPeak - r) * f
	g = g + (newPeak - g) * f
	b = b + (newPeak - b) * f

	return math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1)
end

-- 6th-order polynomial sigmoid fit to Troy Sobotka's AgX default contrast curve (Benjamin Wrensch
-- / Three.js reference). Expects log2-encoded input in [0, 1] and outputs sRGB-encoded [0, 1].
local function agxSigmoid(x: number): number
	return (((((15.5 * x - 40.14) * x + 31.96) * x - 6.868) * x + 0.4298) * x + 0.1191) * x - 0.00232
end

-- AgX (Default or Blender Punchy look). Returns linear Rec. 709 in [0, 1].
local function agxCore(r: number, g: number, b: number, punchy: boolean): (number, number, number)
	-- Inset matrix (Rec. 709 linear -> AgX working space).
	local ir = 0.842479062253094 * r + 0.0784335999999992 * g + 0.0792237451477643 * b
	local ig = 0.0423282422610123 * r + 0.878468636469772 * g + 0.0791661274605434 * b
	local ib = 0.0423756549057051 * r + 0.0784336 * g + 0.879142973793104 * b

	-- Log2 encoding over [-12.47393, +4.026069] EV.
	local minEv = -12.47393
	local evSpan = 4.026069 - minEv
	local lr = math.clamp((math.log(math.max(ir, 1e-10), 2) - minEv) / evSpan, 0, 1)
	local lg = math.clamp((math.log(math.max(ig, 1e-10), 2) - minEv) / evSpan, 0, 1)
	local lb = math.clamp((math.log(math.max(ib, 1e-10), 2) - minEv) / evSpan, 0, 1)

	-- Sigmoid contrast curve.
	local sr = math.clamp(agxSigmoid(lr), 0, 1)
	local sg = math.clamp(agxSigmoid(lg), 0, 1)
	local sb = math.clamp(agxSigmoid(lb), 0, 1)

	if punchy then
		-- Blender AgX Punchy look: power 1.35 + 1.4x chroma boost around Rec. 709 luma.
		sr = sr ^ 1.35
		sg = sg ^ 1.35
		sb = sb ^ 1.35
		local luma = LUMA_R * sr + LUMA_G * sg + LUMA_B * sb
		sr = luma + 1.4 * (sr - luma)
		sg = luma + 1.4 * (sg - luma)
		sb = luma + 1.4 * (sb - luma)
	end

	-- Outset matrix (AgX working space -> display-referred sRGB-like space).
	local or_ = 1.19687900512017 * sr - 0.0980208811401368 * sg - 0.0990297440797205 * sb
	local og = -0.0528968517574562 * sr + 1.15190312990417 * sg - 0.0989611768448433 * sb
	local ob = -0.0529716355144438 * sr - 0.0980434501171241 * sg + 1.15107367264116 * sb

	-- AgX sigmoid bakes a ~2.2 display gamma; linearise so the caller's single sRGB encode is exact.
	return math.clamp(or_, 0, 1) ^ 2.2, math.clamp(og, 0, 1) ^ 2.2, math.clamp(ob, 0, 1) ^ 2.2
end

function Tonemapper.agx(r: number, g: number, b: number): (number, number, number)
	return agxCore(r, g, b, false)
end

function Tonemapper.agxPunchy(r: number, g: number, b: number): (number, number, number)
	return agxCore(r, g, b, true)
end

-- Stephen Hill ACES RRT+ODT fit (Rec. 709 -> AP1 -> rational curve -> Rec. 709).
-- Divides by 0.6 prior to the input matrix so 18% mid-gray aligns with the other operators (matching
-- Three.js's `ACESFilmicToneMapping`).
local function acesRrtOdt(v: number): number
	local a = v * (v + 0.0245786) - 0.000090537
	local b = v * (0.983729 * v + 0.4329510) + 0.238081
	return a / b
end

function Tonemapper.aces(r: number, g: number, b: number): (number, number, number)
	local er = r / 0.6
	local eg = g / 0.6
	local eb = b / 0.6

	local ar = 0.59719 * er + 0.35458 * eg + 0.04823 * eb
	local ag = 0.07600 * er + 0.90834 * eg + 0.01566 * eb
	local ab = 0.02840 * er + 0.13383 * eg + 0.83777 * eb

	local fr = acesRrtOdt(ar)
	local fg = acesRrtOdt(ag)
	local fb = acesRrtOdt(ab)

	local outR = 1.60475 * fr - 0.53108 * fg - 0.07367 * fb
	local outG = -0.10208 * fr + 1.10813 * fg - 0.00605 * fb
	local outB = -0.00327 * fr - 0.07276 * fg + 1.07602 * fb

	return math.clamp(outR, 0, 1), math.clamp(outG, 0, 1), math.clamp(outB, 0, 1)
end

-- John Hable's Uncharted 2 filmic curve.
local function hablePartial(x: number): number
	local A = 0.15
	local B = 0.50
	local C = 0.10
	local D = 0.20
	local E = 0.02
	local F = 0.30
	return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F
end

local HABLE_WHITE_SCALE = 1 / hablePartial(11.2)

function Tonemapper.uncharted2(r: number, g: number, b: number): (number, number, number)
	local bias = 2.0
	return math.clamp(hablePartial(r * bias) * HABLE_WHITE_SCALE, 0, 1),
		math.clamp(hablePartial(g * bias) * HABLE_WHITE_SCALE, 0, 1),
		math.clamp(hablePartial(b * bias) * HABLE_WHITE_SCALE, 0, 1)
end

-- Luminance-preserving Extended Reinhard with configurable white point.
function Tonemapper.reinhard(r: number, g: number, b: number, whitePoint: number?): (number, number, number)
	local luma = LUMA_R * r + LUMA_G * g + LUMA_B * b
	if luma <= 1e-8 then
		return 0, 0, 0
	end
	local wp = whitePoint or Config.TONEMAPPER_HDR_WHITE
	local lumaOut = (luma * (1 + luma / (wp * wp))) / (1 + luma)
	local scale = lumaOut / luma
	return math.clamp(r * scale, 0, 1), math.clamp(g * scale, 0, 1), math.clamp(b * scale, 0, 1)
end

--=============================================================================
-- Display-referred SDR -> pseudo-HDR -> tonemapped SDR pipeline
--=============================================================================

-- Expands display-referred linear [0, 1] back into approximate scene-referred linear HDR [0, W]
-- by scaling along the max-channel peak. Scaling uniformly by peak preserves chromaticity/hue
-- strictly (so PBR Neutral's zero-hue-shift guarantee holds end to end) while giving every
-- operator real highlight headroom to compress.
function Tonemapper.decodePseudoHdr(
	rSrgb: number,
	gSrgb: number,
	bSrgb: number,
	exposure: number,
	hdrWhite: number
): (number, number, number)
	local rLin = Tonemapper.srgbToLinear(math.clamp(rSrgb, 0, 1))
	local gLin = Tonemapper.srgbToLinear(math.clamp(gSrgb, 0, 1))
	local bLin = Tonemapper.srgbToLinear(math.clamp(bSrgb, 0, 1))

	local scale = exposure
	if hdrWhite > 1 then
		local peak = math.max(rLin, gLin, bLin)
		local k = 1 - 1 / hdrWhite
		scale = exposure / math.max(1 - k * peak, 1e-5)
	end

	return rLin * scale, gLin * scale, bLin * scale
end

-- Evaluates one sRGB [0, 1] triple through the named operator and returns output sRGB [0, 1].
function Tonemapper.evaluateSrgb(
	operator: string,
	rSrgb: number,
	gSrgb: number,
	bSrgb: number,
	exposure: number?,
	hdrWhite: number?
): (number, number, number)
	if operator == "identity" or operator == "none" then
		return math.clamp(rSrgb, 0, 1), math.clamp(gSrgb, 0, 1), math.clamp(bSrgb, 0, 1)
	end
	if operator == "invert" then
		return 1 - math.clamp(rSrgb, 0, 1), 1 - math.clamp(gSrgb, 0, 1), 1 - math.clamp(bSrgb, 0, 1)
	end

	local exp = exposure or Config.TONEMAPPER_EXPOSURE
	local white = hdrWhite or Config.TONEMAPPER_HDR_WHITE
	local rHdr, gHdr, bHdr = Tonemapper.decodePseudoHdr(rSrgb, gSrgb, bSrgb, exp, white)

	local rOut, gOut, bOut
	if operator == "pbr-neutral" then
		rOut, gOut, bOut = Tonemapper.pbrNeutral(rHdr, gHdr, bHdr)
	elseif operator == "agx" then
		rOut, gOut, bOut = Tonemapper.agx(rHdr, gHdr, bHdr)
	elseif operator == "agx-punchy" then
		rOut, gOut, bOut = Tonemapper.agxPunchy(rHdr, gHdr, bHdr)
	elseif operator == "aces" then
		rOut, gOut, bOut = Tonemapper.aces(rHdr, gHdr, bHdr)
	elseif operator == "uncharted2" then
		rOut, gOut, bOut = Tonemapper.uncharted2(rHdr, gHdr, bHdr)
	elseif operator == "reinhard" then
		rOut, gOut, bOut = Tonemapper.reinhard(rHdr, gHdr, bHdr, white)
	else
		error(`unknown tonemapper operator "{operator}"`)
	end

	return Tonemapper.linearToSrgb(rOut), Tonemapper.linearToSrgb(gOut), Tonemapper.linearToSrgb(bOut)
end

--=============================================================================
-- Preset catalogue helpers
--=============================================================================

function Tonemapper.findPreset(id: string): Preset?
	for _, preset in ipairs(Config.TONEMAPPER_PRESETS) do
		if preset.id == id then
			return preset
		end
	end
	return nil
end

function Tonemapper.indexOfPreset(id: string): number
	for i, preset in ipairs(Config.TONEMAPPER_PRESETS) do
		if preset.id == id then
			return i
		end
	end
	return 1
end

function Tonemapper.resolvePreset(id: string?): Preset
	if id then
		local found = Tonemapper.findPreset(id)
		if found then
			return found
		end
	end
	return Tonemapper.findPreset(Config.TONEMAPPER_DEFAULT) or Config.TONEMAPPER_PRESETS[1]
end

--=============================================================================
-- 1024x32 (size^2 x size) horizontal-strip RGBA LUT buffer
--=============================================================================

-- Builds a flat RGBA byte buffer of width `size * size` and height `size` (1024x32 for size = 32),
-- packed as `size` horizontal Blue tiles where X inside each tile is Red (0..size-1) and Y is
-- Green (0..size-1, top-down unless `flipGreen` is true). Compatible directly with
-- `EditableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), buf)`.
function Tonemapper.buildLutBuffer(
	operator: string,
	exposure: number?,
	hdrWhite: number?,
	size: number?,
	flipGreen: boolean?
): (buffer, number, number)
	local dim = size or Config.TONEMAPPER_LUT_SIZE
	local width = dim * dim
	local height = dim
	local denom = math.max(dim - 1, 1)
	local pixels = buffer.create(width * height * 4)

	for y = 0, dim - 1 do
		local g = if flipGreen then (denom - y) / denom else y / denom
		local rowBase = y * width
		for bIdx = 0, dim - 1 do
			local b = bIdx / denom
			local tileBase = rowBase + bIdx * dim
			for rIdx = 0, dim - 1 do
				local r = rIdx / denom
				local outR, outG, outB = Tonemapper.evaluateSrgb(operator, r, g, b, exposure, hdrWhite)
				local offset = (tileBase + rIdx) * 4
				buffer.writeu8(pixels, offset + 0, math.floor(math.clamp(outR, 0, 1) * 255 + 0.5))
				buffer.writeu8(pixels, offset + 1, math.floor(math.clamp(outG, 0, 1) * 255 + 0.5))
				buffer.writeu8(pixels, offset + 2, math.floor(math.clamp(outB, 0, 1) * 255 + 0.5))
				buffer.writeu8(pixels, offset + 3, 255)
			end
		end
	end

	return pixels, width, height
end

--=============================================================================
-- Offline self test (auto-discovered by `make test ONLY=shared`)
--=============================================================================

function Tonemapper.selfTest()
	-- 1. sRGB round-trip accuracy.
	for _, v in ipairs({ 0, 0.02, 0.04045, 0.18, 0.5, 0.85, 1.0 }) do
		local round = Tonemapper.linearToSrgb(Tonemapper.srgbToLinear(v))
		assert(math.abs(round - v) < 1e-5, `sRGB round-trip drift at {v}: got {round}`)
	end

	-- 2. Khronos PBR Neutral exact reference points (KhronosGroup/ToneMapping/PBR_Neutral/README.md):
	--    In the linear fidelity band [0.08, 0.80], c_out = c_in - 0.04 with zero hue shift.
	local nr, ng, nb = Tonemapper.pbrNeutral(0.50, 0.30, 0.10)
	assert(
		math.abs(nr - 0.46) < 1e-6 and math.abs(ng - 0.26) < 1e-6 and math.abs(nb - 0.06) < 1e-6,
		"PBR Neutral fidelity band mismatch"
	)

	-- Zero hue shift under heavy HDR highlight compression: red > green == blue stays green == blue.
	local hr, hg, hb = Tonemapper.pbrNeutral(4.0, 0.0, 0.0)
	assert(hr > hg and math.abs(hg - hb) < 1e-6 and hg > 0.2 and hr < 1.0, "PBR Neutral highlight desaturation failed")

	-- 3. Every preset in Config resolves to a valid operator and stays monotonic on the gray ramp.
	assert(#Config.TONEMAPPER_PRESETS >= 2, "Config.TONEMAPPER_PRESETS must not be empty")
	assert(Tonemapper.findPreset(Config.TONEMAPPER_DEFAULT) ~= nil, "Config.TONEMAPPER_DEFAULT must exist in presets")

	local seenIds: { [string]: boolean } = {}
	for _, preset in ipairs(Config.TONEMAPPER_PRESETS) do
		assert(not seenIds[preset.id], `duplicate tonemapper preset id: {preset.id}`)
		seenIds[preset.id] = true

		if preset.operator == "invert" then
			local ir, ig, ib = Tonemapper.evaluateSrgb("invert", 0, 0.25, 1)
			assert(
				math.abs(ir - 1) < 1e-6 and math.abs(ig - 0.75) < 1e-6 and math.abs(ib - 0) < 1e-6,
				"invert diagnostic failed"
			)
		else
			local prev = -1
			for step = 0, 8 do
				local v = step / 8
				local r, g, b = Tonemapper.evaluateSrgb(preset.operator, v, v, v, preset.exposureScale, preset.hdrWhite)
				assert(r == r and g == g and b == b, `{preset.id} produced NaN`)
				assert(r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1, `{preset.id} out of [0,1]`)
				assert(math.abs(r - g) < 1e-3 and math.abs(g - b) < 1e-3, `{preset.id} broke neutral gray balance`)
				assert(r + 1e-5 >= prev, `{preset.id} gray ramp is not monotonic`)
				prev = r
			end
		end
	end

	-- 4. Identity LUT packs exact (r, g, b, 255) bytes at corners and produces 1024x32 RGBA size.
	local smallBuf, sw, sh = Tonemapper.buildLutBuffer("identity", 1.0, 1.0, 4)
	assert(sw == 16 and sh == 4 and buffer.len(smallBuf) == 16 * 4 * 4, "small LUT dimensions mismatch")
	-- Corner (r=0, g=0, b=0) -> x=0, y=0
	assert(
		buffer.readu8(smallBuf, 0) == 0
			and buffer.readu8(smallBuf, 1) == 0
			and buffer.readu8(smallBuf, 2) == 0
			and buffer.readu8(smallBuf, 3) == 255
	)
	-- Corner (r=3, g=3, b=3) -> x=15, y=3
	local lastOffset = (3 * 16 + 15) * 4
	assert(
		buffer.readu8(smallBuf, lastOffset + 0) == 255
			and buffer.readu8(smallBuf, lastOffset + 1) == 255
			and buffer.readu8(smallBuf, lastOffset + 2) == 255
			and buffer.readu8(smallBuf, lastOffset + 3) == 255
	)

	-- Verify full 32^3 production dimensions (1024x32x4 = 131072 bytes).
	local fullBuf, fw, fh =
		Tonemapper.buildLutBuffer("pbr-neutral", 1.0, Config.TONEMAPPER_HDR_WHITE, Config.TONEMAPPER_LUT_SIZE)
	assert(fw == 1024 and fh == 32 and buffer.len(fullBuf) == 1024 * 32 * 4, "full LUT dimensions mismatch")
end

return Tonemapper
