--[[
	Dynamic per-wave arena atmosphere controller.

	Watches `workspace.World`'s `Wave` and `RoomState` attributes (replicated by WaveDirector)
	and smoothly tweens ComplexArena's neon accents, PointLights, and Lighting ambient tint to
	the matching palette in `Config.WAVE_THEMES` / `Config.CLEARED_THEME`.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local ArenaTheme = {}

type Accents = {
	primaryParts: { BasePart },
	secondaryParts: { BasePart },
	primaryLights: { PointLight },
	secondaryLights: { PointLight },
}

local activeTweens: { Tween } = {}
local currentKey: string? = nil

local function cancelTweens()
	for _, tw in ipairs(activeTweens) do
		tw:Cancel()
	end
	table.clear(activeTweens)
end

local function collectAccents(arena: Instance): Accents
	local out: Accents = {
		primaryParts = {},
		secondaryParts = {},
		primaryLights = {},
		secondaryLights = {},
	}
	for _, desc in ipairs(arena:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Material == Enum.Material.Neon and desc.Transparency < 1 then
			-- Preserve two-tone contrast: originally cool/cyan accents track `primary`; originally
			-- warm/amber accents track `secondary`.
			if desc.Color.B >= desc.Color.R then
				table.insert(out.primaryParts, desc)
			else
				table.insert(out.secondaryParts, desc)
			end
		elseif desc:IsA("PointLight") then
			if desc.Color.B >= desc.Color.R then
				table.insert(out.primaryLights, desc)
			else
				table.insert(out.secondaryLights, desc)
			end
		end
	end
	return out
end

local function resolveTheme(world: Instance): (string, Config.WaveTheme)
	local roomState = world:GetAttribute("RoomState")
	if roomState == "cleared" then
		return "cleared", Config.CLEARED_THEME
	end
	local rawWave = world:GetAttribute("Wave")
	local wave = if type(rawWave) == "number" and rawWave >= 1 then math.floor(rawWave) else 1
	local themes = Config.WAVE_THEMES
	local count = #themes
	local idx = ((wave - 1) % math.max(count, 1)) + 1
	return `wave_{idx}`, themes[idx] or themes[1]
end

local function applyTheme(world: Instance, accents: Accents, instant: boolean)
	local key, theme = resolveTheme(world)
	if key == currentKey and not instant then
		return
	end
	currentKey = key
	cancelTweens()

	local dur = if instant then 0 else (Config.WAVE_THEME_TRANSITION_SECONDS or 1.0)
	if dur <= 0 then
		for _, p in ipairs(accents.primaryParts) do
			if p.Parent then
				p.Color = theme.primary
			end
		end
		for _, p in ipairs(accents.secondaryParts) do
			if p.Parent then
				p.Color = theme.secondary
			end
		end
		for _, l in ipairs(accents.primaryLights) do
			if l.Parent then
				l.Color = theme.primary
			end
		end
		for _, l in ipairs(accents.secondaryLights) do
			if l.Parent then
				l.Color = theme.secondary
			end
		end
		Lighting.Ambient = theme.ambient
		Lighting.OutdoorAmbient = theme.outdoorAmbient
		Lighting.ColorShift_Top = theme.shiftTop
		return
	end

	local info = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local function play(inst: Instance, props: { [string]: any })
		local tw = TweenService:Create(inst, info, props)
		table.insert(activeTweens, tw)
		tw:Play()
	end

	for _, p in ipairs(accents.primaryParts) do
		if p.Parent then
			play(p, { Color = theme.primary })
		end
	end
	for _, p in ipairs(accents.secondaryParts) do
		if p.Parent then
			play(p, { Color = theme.secondary })
		end
	end
	for _, l in ipairs(accents.primaryLights) do
		if l.Parent then
			play(l, { Color = theme.primary })
		end
	end
	for _, l in ipairs(accents.secondaryLights) do
		if l.Parent then
			play(l, { Color = theme.secondary })
		end
	end
	play(Lighting, {
		Ambient = theme.ambient,
		OutdoorAmbient = theme.outdoorAmbient,
		ColorShift_Top = theme.shiftTop,
	})
end

local function watchWorld(world: Instance)
	task.spawn(function()
		local arena = world:WaitForChild(Config.ARENA_MODEL, 10)
		if not arena or not world.Parent then
			return
		end
		-- Wait briefly for children of the cloned arena model to finish replicating.
		task.wait(0.2)
		if not arena.Parent then
			return
		end
		local accents = collectAccents(arena)
		currentKey = nil
		applyTheme(world, accents, true)

		local function refresh()
			if arena.Parent and world.Parent then
				applyTheme(world, accents, false)
			end
		end
		world:GetAttributeChangedSignal("Wave"):Connect(refresh)
		world:GetAttributeChangedSignal("RoomState"):Connect(refresh)
	end)
end

function ArenaTheme.start()
	task.spawn(function()
		local world = workspace:WaitForChild("World")
		watchWorld(world)
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "World" then
				watchWorld(child)
			end
		end)
	end)
end

return ArenaTheme
