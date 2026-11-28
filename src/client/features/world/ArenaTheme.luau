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

local HUB_THEME: Config.WaveTheme = {
	primary = Color3.fromRGB(72, 220, 255),
	secondary = Color3.fromRGB(255, 168, 58),
	ambient = Color3.fromRGB(62, 72, 86),
	outdoorAmbient = Color3.fromRGB(78, 88, 102),
	shiftTop = Color3.fromRGB(140, 190, 230),
}

local function resolveTheme(world: Instance): (string, Config.WaveTheme)
	if world:GetAttribute("ServerMode") == "hub" then
		return "hub", HUB_THEME
	end
	local runState = world:GetAttribute("RunState")
	local roomState = world:GetAttribute("RoomState")
	if runState == "victory" or runState == "transition" or roomState == "cleared" then
		return "cleared", Config.CLEARED_THEME
	end
	local rawFloor = world:GetAttribute("Floor")
	local floor = if type(rawFloor) == "number" and rawFloor >= 1 then math.floor(rawFloor) else 1
	local rawRoom = world:GetAttribute("Room")
	local roomCount = world:GetAttribute("RoomCount")
	local isBossRoom = world:GetAttribute("IsBossRoom") == true
		or (floor >= 2 and type(rawRoom) == "number" and type(roomCount) == "number" and rawRoom >= roomCount)

	local floorThemes = Config.FLOOR_THEMES
	local floorSpec = floorThemes and (floorThemes[floor] or floorThemes[1])
	if floorSpec then
		if isBossRoom then
			return `floor_{floor}_boss`, floorSpec.boss
		end
		-- Gently modulate intensity across rooms 1..4 within the floor's signature palette.
		local room = if type(rawRoom) == "number" and rawRoom >= 1 then math.floor(rawRoom) else 1
		return `floor_{floor}_room_{room}`, floorSpec.normal
	end

	local themes = Config.WAVE_THEMES
	local count = #themes
	local rawWave = world:GetAttribute("Wave")
	local wave = if type(rawWave) == "number" and rawWave >= 1 then math.floor(rawWave) else 1
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

local function findArenaModel(world: Instance): Model?
	local activeName = world:GetAttribute("ArenaModel")
	if type(activeName) == "string" and activeName ~= "" then
		local named = world:FindFirstChild(activeName)
		if named and named:IsA("Model") then
			return named
		end
	end
	for _, child in ipairs(world:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChild("Floor") then
			return child
		end
	end
	local defaultArena = world:FindFirstChild(Config.ARENA_MODEL)
	return if defaultArena and defaultArena:IsA("Model") then defaultArena else nil
end

local function watchWorld(world: Instance)
	local accents: Accents = { primaryParts = {}, secondaryParts = {}, primaryLights = {}, secondaryLights = {} }
	local currentArena: Model? = nil

	local function bindArena(arena: Model, instant: boolean)
		if currentArena == arena then
			return
		end
		currentArena = arena
		task.spawn(function()
			-- Wait briefly for descendants of a newly swapped arena model to replicate.
			task.wait(0.15)
			if currentArena ~= arena or not arena.Parent or not world.Parent then
				return
			end
			accents = collectAccents(arena)
			currentKey = nil
			applyTheme(world, accents, instant)
		end)
	end

	local function refresh()
		if not world.Parent then
			return
		end
		local found = findArenaModel(world)
		if found and found ~= currentArena then
			bindArena(found, true)
			return
		end
		if currentArena and currentArena.Parent then
			applyTheme(world, accents, false)
		end
	end

	local initial = findArenaModel(world)
	if initial then
		bindArena(initial, true)
	end

	world.ChildAdded:Connect(function(child)
		if child:IsA("Model") and (child.Name:sub(1, 12) == "ComplexArena" or child:FindFirstChild("Floor")) then
			bindArena(child, true)
		end
	end)
	world:GetAttributeChangedSignal("ArenaModel"):Connect(refresh)
	world:GetAttributeChangedSignal("ServerMode"):Connect(refresh)
	world:GetAttributeChangedSignal("Floor"):Connect(refresh)
	world:GetAttributeChangedSignal("IsBossRoom"):Connect(refresh)
	world:GetAttributeChangedSignal("Wave"):Connect(refresh)
	world:GetAttributeChangedSignal("Room"):Connect(refresh)
	world:GetAttributeChangedSignal("RoomState"):Connect(refresh)
	world:GetAttributeChangedSignal("RunState"):Connect(refresh)
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
