--[[
	Applies the configured tonemapper preset (`Config.TONEMAPPER_DEFAULT`) to `Lighting` on the
	client.

	Manages three dedicated post-processing instances under `Lighting` (`ComplexTonemapGrading`,
	`ComplexTonemapLut`, and `ComplexTonemapBloom`) so it never interferes with anything else in
	the scene. Supports both `"approx"` mode (`ColorGradingEffect` + `ExposureCompensation` +
	`ColorCorrectionEffect` + `BloomEffect`, active by default while Studio's `ColorLutContent`
	renderer pass is disabled) and `"auto"` 1024x32 3D LUT mode (uploaded PNG -> baked DataModel
	content -> EditableImage -> approx fallback). See docs/tonemapping.md.
]]

local AssetService = game:GetService("AssetService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared.core.Assets)
local Config = require(Shared.core.Config)
local Tonemapper = require(Shared.features.tonemapping.Tonemapper)

local Client = script:FindFirstAncestor("Client")
local Diagnostics = require(Client.core.Diagnostics)

local TonemapperController = {}

local GRADING_NAME = "ComplexTonemapGrading"
local LUT_NAME = "ComplexTonemapLut"
local BLOOM_NAME = "ComplexTonemapBloom"

local started = false
local baseExposureCompensation = 0
local applyToken = 0

-- One reusable 1024x32 EditableImage kept alive for the session when LUT mode is active: never
-- allocate per preset switch or per respawn (CLAUDE.md, "Engine gotchas").
local lutImage: EditableImage? = nil
local lastBufferKey: string? = nil
local bakedCache: { [string]: Content } = {}

local function ensureGrading(): ColorGradingEffect
	local existing = Lighting:FindFirstChild(GRADING_NAME)
	if existing and existing:IsA("ColorGradingEffect") then
		return existing
	end
	local effect = Instance.new("ColorGradingEffect")
	effect.Name = GRADING_NAME
	effect.Enabled = true
	effect.Parent = Lighting
	return effect
end

local function ensureCorrection(): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild(LUT_NAME)
	if existing and existing:IsA("ColorCorrectionEffect") then
		return existing
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = LUT_NAME
	effect.Enabled = false
	effect.Parent = Lighting
	return effect
end

local function ensureBloom(): BloomEffect
	local existing = Lighting:FindFirstChild(BLOOM_NAME)
	if existing and existing:IsA("BloomEffect") then
		return existing
	end
	local effect = Instance.new("BloomEffect")
	effect.Name = BLOOM_NAME
	effect.Enabled = false
	effect.Parent = Lighting
	return effect
end

local function resetLinearCorrection(effect: ColorCorrectionEffect)
	effect.Brightness = 0
	effect.Contrast = 0
	effect.Saturation = 0
	effect.TintColor = Color3.new(1, 1, 1)
	Lighting.ExposureCompensation = baseExposureCompensation
	local bloom = Lighting:FindFirstChild(BLOOM_NAME)
	if bloom and bloom:IsA("BloomEffect") then
		bloom.Enabled = false
	end
end

local function clearLut(effect: ColorCorrectionEffect)
	pcall(function()
		effect.ColorLutContent = Content.none
		effect.ColorLutIntensity = 0
	end)
end

local function bindLutContent(
	effect: ColorCorrectionEffect,
	content: Content,
	intensity: number,
	presetId: string,
	kind: string
): boolean
	local ok, sourceType = pcall(function(): Enum.ContentSourceType?
		effect.ColorLutContent = Content.none
		effect.ColorLutContent = content
		effect.ColorLutIntensity = intensity
		local applied = effect.ColorLutContent
		if applied.SourceType == Enum.ContentSourceType.None then
			return nil
		end
		return applied.SourceType
	end)
	if not ok or not sourceType then
		Diagnostics.fault("tonemapping", `lut-bind-{kind}-failed`, `ColorLutContent ({kind}) could not be applied`, {
			preset = presetId,
			err = if not ok then tostring(sourceType) else "ContentSourceType.None",
		})
		return false
	end
	resetLinearCorrection(effect)
	effect.Enabled = intensity > 0
	return true
end

local function acquireLutImage(width: number, height: number): EditableImage?
	if lutImage then
		return lutImage
	end
	local ok, created = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if not ok or not created then
		Diagnostics.fault(
			"tonemapping",
			"editable-image-unavailable",
			"Could not allocate 1024x32 EditableImage for runtime LUT",
			{ err = if not ok then tostring(created) else "nil" }
		)
		return nil
	end
	lutImage = created
	return created
end

local function bufferKeyFor(preset: Tonemapper.Preset, exposure: number): string
	local dim = Config.TONEMAPPER_LUT_SIZE
	return string.format("%s:%.3f:%.3f:%d", preset.operator, exposure * preset.exposureScale, preset.hdrWhite, dim)
end

local function populateLutImage(preset: Tonemapper.Preset, exposure: number): (EditableImage?, string?)
	local dim = Config.TONEMAPPER_LUT_SIZE
	local width = dim * dim
	local height = dim
	local image = acquireLutImage(width, height)
	if not image then
		return nil, nil
	end

	local key = bufferKeyFor(preset, exposure)
	if lastBufferKey ~= key then
		local pixels = Tonemapper.buildLutBuffer(preset.operator, exposure * preset.exposureScale, preset.hdrWhite, dim)
		local writeOk, writeErr = pcall(function()
			image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), pixels)
		end)
		if not writeOk then
			Diagnostics.fault("tonemapping", "lut-write-failed", "WritePixelsBuffer failed for LUT EditableImage", {
				preset = preset.id,
				err = tostring(writeErr),
			})
			return nil, nil
		end
		lastBufferKey = key
	end
	return image, key
end

local function applyBakedLutAsync(
	effect: ColorCorrectionEffect,
	preset: Tonemapper.Preset,
	exposure: number,
	intensity: number,
	token: number
): boolean
	local key = bufferKeyFor(preset, exposure)
	local cached = bakedCache[key]
	if cached then
		return bindLutContent(effect, cached, intensity, preset.id, "baked")
	end

	local image = populateLutImage(preset, exposure)
	if not image then
		return false
	end

	local ok, resOrErr, bakedContent = pcall(function()
		return AssetService:CreateDataModelContentAsync(Content.fromObject(image))
	end)
	if token ~= applyToken then
		return false
	end
	if not ok or resOrErr ~= Enum.CreateContentResult.Success or not bakedContent then
		Diagnostics.fault("tonemapping", "lut-bake-failed", "CreateDataModelContentAsync failed for LUT", {
			preset = preset.id,
			result = tostring(resOrErr),
		})
		return false
	end

	bakedCache[key] = bakedContent
	return bindLutContent(effect, bakedContent, intensity, preset.id, "baked")
end

local function applyEditableLut(
	effect: ColorCorrectionEffect,
	preset: Tonemapper.Preset,
	exposure: number,
	intensity: number
): boolean
	local image = populateLutImage(preset, exposure)
	if not image then
		return false
	end
	return bindLutContent(effect, Content.fromObject(image), intensity, preset.id, "editable")
end

local function applyAssetLut(effect: ColorCorrectionEffect, preset: Tonemapper.Preset, intensity: number): boolean
	if not preset.lutFile then
		return false
	end
	local assetId = Assets.id(preset.lutFile)
	if assetId <= 0 then
		return false
	end
	return bindLutContent(effect, Content.fromAssetId(assetId), intensity, preset.id, "asset")
end

local function applyApproxCorrection(
	effect: ColorCorrectionEffect,
	preset: Tonemapper.Preset,
	exposure: number,
	intensity: number
)
	clearLut(effect)
	local bloom = ensureBloom()
	local fb = preset.fallbackCorrection
	local sliderEv = math.log(math.max(exposure, 0.1), 2)
	if fb then
		Lighting.ExposureCompensation = baseExposureCompensation + (fb.exposureCompensation + sliderEv) * intensity
		effect.Brightness = fb.brightness * intensity
		effect.Contrast = fb.contrast * intensity
		effect.Saturation = fb.saturation * intensity
		effect.TintColor = Color3.new(1, 1, 1):Lerp(fb.tintColor, intensity)
		bloom.Intensity = fb.bloomIntensity * intensity
		bloom.Size = fb.bloomSize
		bloom.Threshold = fb.bloomThreshold
		bloom.Enabled = intensity > 0 and fb.bloomIntensity > 0
	else
		Lighting.ExposureCompensation = baseExposureCompensation + sliderEv * intensity
		effect.Brightness = 0
		effect.Contrast = 0
		effect.Saturation = 0
		effect.TintColor = Color3.new(1, 1, 1)
		bloom.Enabled = false
	end
	effect.Enabled = intensity > 0
end

-- Applies `presetId` (defaulting to `Config.TONEMAPPER_DEFAULT`) using `Config.TONEMAPPER_BACKEND_MODE`.
function TonemapperController.apply(presetId: string?)
	applyToken += 1
	local token = applyToken

	local preset = Tonemapper.resolvePreset(presetId or Config.TONEMAPPER_DEFAULT)
	local exposure = Config.TONEMAPPER_EXPOSURE
	local intensity = Config.TONEMAPPER_INTENSITY
	local mode = Config.TONEMAPPER_BACKEND_MODE

	local grading = ensureGrading()
	grading.Enabled = true
	grading.TonemapperPreset = if preset.basePreset == "Retro"
		then Enum.TonemapperPreset.Retro
		else Enum.TonemapperPreset.Default

	local correction = ensureCorrection()
	if preset.operator == "none" then
		clearLut(correction)
		resetLinearCorrection(correction)
		correction.Enabled = false
		return
	end

	if mode == "approx" then
		applyApproxCorrection(correction, preset, exposure, intensity)
		return
	end

	if math.abs(exposure - 1.0) < 1e-4 and applyAssetLut(correction, preset, intensity) then
		return
	end

	task.spawn(function()
		if applyBakedLutAsync(correction, preset, exposure, intensity, token) then
			return
		end
		if token ~= applyToken then
			return
		end
		if applyEditableLut(correction, preset, exposure, intensity) then
			return
		end
		if token ~= applyToken then
			return
		end
		applyApproxCorrection(correction, preset, exposure, intensity)
	end)
end

function TonemapperController.start()
	if started then
		return
	end
	started = true
	baseExposureCompensation = Lighting.ExposureCompensation
	TonemapperController.apply(Config.TONEMAPPER_DEFAULT)
end

return TonemapperController
