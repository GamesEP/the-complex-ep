--!strict
--[[
	Generates lossless 1024x32 (32^3) RGBA PNG LUTs for every custom tonemapper preset defined in
	`src/shared/core/Config/Tonemapping.luau`, using the exact same `Tonemapper.buildLutBuffer`
	math the game runs at runtime.

	Run from the repo root:
		lune run scripts/generate-luts.luau             # writes to temp/luts/
		lune run scripts/generate-luts.luau --assets    # writes to assets/ ready for `make sync-assets`

	Use static PNG LUTs when shipping a chosen tonemapper to production (so clients never spend
	runtime `EditableImage` budget or require Experience Mesh/Image APIs enabled). See
	docs/tonemapping.md.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Sandbox = require("./lib/sandbox")

--=============================================================================
-- Minimal lossless RGBA PNG encoder (CRC32 + zlib via @lune/serde)
--=============================================================================

local crcTable = table.create(256, 0)
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if bit32.band(c, 1) ~= 0 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	crcTable[n + 1] = c
end

local function crc32(data: string): number
	local c = 0xFFFFFFFF
	for i = 1, #data do
		local b = string.byte(data, i)
		c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, b), 0xFF) + 1], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function u32be(n: number): string
	return string.char(
		bit32.band(bit32.rshift(n, 24), 0xFF),
		bit32.band(bit32.rshift(n, 16), 0xFF),
		bit32.band(bit32.rshift(n, 8), 0xFF),
		bit32.band(n, 0xFF)
	)
end

local function chunk(chunkType: string, payload: string): string
	local body = chunkType .. payload
	return u32be(#payload) .. body .. u32be(crc32(body))
end

local function encodePngRgba(pixels: buffer, width: number, height: number): string
	-- PNG scanlines: 1 filter byte (0 = None) followed by width * 4 RGBA bytes per row.
	local rowBytes = width * 4
	local raw = buffer.create(height * (rowBytes + 1))
	for y = 0, height - 1 do
		local dstRow = y * (rowBytes + 1)
		buffer.writeu8(raw, dstRow, 0)
		buffer.copy(raw, dstRow + 1, pixels, y * rowBytes, rowBytes)
	end

	local compressed = serde.compress("zlib", buffer.tostring(raw))
	local ihdr = u32be(width) .. u32be(height) .. string.char(8, 6, 0, 0, 0) -- 8-bit RGBA

	return "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr) .. chunk("IDAT", compressed) .. chunk("IEND", "")
end

--=============================================================================
-- Load real Config and Tonemapper modules through the shared sandbox
--=============================================================================

local Config = Sandbox.config()

local Tonemapper = Sandbox.run("src/shared/features/tonemapping/Tonemapper.luau", {
	script = {
		FindFirstAncestor = function(_self: any, name: string): any
			if name == "Shared" then
				return { core = { Config = "Config" } }
			end
			error(`unexpected FindFirstAncestor({name}) in generate-luts`)
		end,
	},
	require = function(target: any): any
		if target == "Config" then
			return Config
		end
		error(`unexpected require in generate-luts: {tostring(target)}`)
	end,
})

--=============================================================================
-- Write one 1024x32 PNG per LUT preset
--=============================================================================

local toAssets = false
for _, arg in process.args do
	if arg == "--assets" then
		toAssets = true
	else
		error(`unknown argument "{arg}" — expected optional --assets`)
	end
end

local outDir = if toAssets then "assets" else "temp/luts"
fs.writeDir(outDir)

local count = 0
for _, preset in ipairs(Config.TONEMAPPER_PRESETS) do
	if preset.operator ~= "none" and preset.lutFile then
		local pixels, width, height = Tonemapper.buildLutBuffer(
			preset.operator,
			preset.exposureScale * Config.TONEMAPPER_EXPOSURE,
			preset.hdrWhite,
			Config.TONEMAPPER_LUT_SIZE
		)
		local png = encodePngRgba(pixels, width, height)
		local path = `{outDir}/{preset.lutFile}`
		fs.writeFile(path, png)
		print(`wrote {path} ({width}x{height}, {#png} bytes)`)
		count += 1
	end
end

print(`generated {count} LUT PNG(s) in {outDir}/`)
