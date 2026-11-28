--[[
	Server-authoritative 1-of-3 run upgrade service (plans/gdd/systems.md, plans/roadmap.md VS-17).

	Maintains each player's `UpgradePool.PlayerBuild`, replicates active ability slots (`AbilitySlot1..3`),
	levels (`AbilityLevel1..3`), stat modifiers, and movement passives (`HasDoubleJump`, `HasDoubleDash`)
	as Player attributes, and pushes the active 1-of-3 offer + queue depth (`+N`) to the owning client
	via `Remotes.UpgradeOffer`. Never pauses enemies or movement.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local UpgradePool = require(Shared.features.upgrades.UpgradePool)

local UpgradeService = {}

local builds: { [Player]: UpgradePool.PlayerBuild } = {}
local onUpgradesChanged: ((Player, number) -> ())? = nil

local function serializeOffer(offer: UpgradePool.Offer?): { [string]: any }?
	if not offer then
		return nil
	end
	local cards = {}
	for _, card in ipairs(offer.cards) do
		table.insert(cards, {
			id = card.id,
			kind = card.kind,
			title = card.title,
			effect = card.effect,
			category = card.category,
			abilityId = card.abilityId,
			nextLevel = card.nextLevel,
			color = card.color,
		})
	end
	return {
		offerId = offer.offerId,
		isStarter = offer.isStarter,
		cards = cards,
	}
end

local function syncAttributes(player: Player, build: UpgradePool.PlayerBuild)
	for slot = 1, Config.ABILITY_SLOTS do
		local id = build.slots[slot] or ""
		local level = if id ~= "" then (build.levels[id] or 1) else 0
		player:SetAttribute(`AbilitySlot{slot}`, id)
		player:SetAttribute(`AbilityLevel{slot}`, level)
	end
	player:SetAttribute("UpgradeMaxHealthBonus", build.maxHealthBonus)
	player:SetAttribute("UpgradeDamageMult", 1 + build.damageBonus)
	player:SetAttribute("UpgradeSpeedMult", 1 + build.speedBonus)
	player:SetAttribute("UpgradeCooldownMult", build.cooldownMult)
	player:SetAttribute("UpgradeCritChance", build.critChance)
	player:SetAttribute("UpgradeLifeOnKill", build.lifeOnKill)
	player:SetAttribute("UpgradeHeavyChargeMult", build.heavyChargeMult)
	player:SetAttribute("UpgradeParryBonus", build.parryBonus)
	player:SetAttribute("HasDoubleJump", build.hasDoubleJump)
	player:SetAttribute("HasDoubleDash", build.hasDoubleDash)
	player:SetAttribute("HasDashBoost", build.hasDashBoost)
	player:SetAttribute("HasSwiftDash", build.hasSwiftDash)
end

local function pushOffer(player: Player, build: UpgradePool.PlayerBuild)
	local current = UpgradePool.currentOffer(build)
	Remotes.UpgradeOffer:FireClient(player, {
		offer = serializeOffer(current),
		pending = UpgradePool.pendingBehind(build),
	})
end

local function ensureBuild(player: Player): UpgradePool.PlayerBuild
	local build = builds[player]
	if not build then
		build = UpgradePool.initial()
		builds[player] = build
		syncAttributes(player, build)
	end
	return build
end

function UpgradeService.resetPlayer(player: Player)
	local build = UpgradePool.initial()
	builds[player] = build
	syncAttributes(player, build)
	pushOffer(player, build)
	if onUpgradesChanged then
		onUpgradesChanged(player, 0)
	end
end

function UpgradeService.resetAll()
	for _, player in ipairs(Players:GetPlayers()) do
		UpgradeService.resetPlayer(player)
	end
end

function UpgradeService.offerStarterAll()
	for _, player in ipairs(Players:GetPlayers()) do
		local build = ensureBuild(player)
		local offer = UpgradePool.rollStarter(build)
		UpgradePool.enqueue(build, offer)
		pushOffer(player, build)
	end
end

function UpgradeService.offerRoomClearAll()
	for _, player in ipairs(Players:GetPlayers()) do
		local build = ensureBuild(player)
		local offer = UpgradePool.rollRoomOffer(build)
		UpgradePool.enqueue(build, offer)
		pushOffer(player, build)
	end
end

function UpgradeService.autoResolveAll()
	for _, player in ipairs(Players:GetPlayers()) do
		local build = builds[player]
		if build and #build.queue > 0 then
			local heal = UpgradePool.autoResolveAll(build)
			syncAttributes(player, build)
			pushOffer(player, build)
			if onUpgradesChanged then
				onUpgradesChanged(player, heal)
			end
		end
	end
end

local function handlePick(player: Player, offerId: number, cardIndex: number, replaceSlot: number?)
	local build = builds[player]
	if not build then
		return
	end
	local ok, healDelta = UpgradePool.applyPick(build, offerId, cardIndex, replaceSlot)
	if not ok then
		-- Resync current offer in case client state drifted.
		pushOffer(player, build)
		return
	end
	syncAttributes(player, build)
	pushOffer(player, build)
	if onUpgradesChanged then
		onUpgradesChanged(player, healDelta)
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		Remotes.CombatSfx:FireClient(player, "upgradePick", root.Position)
	end
end

-- Remote "PickUpgrade(offerId, cardIndex)".
function UpgradeService.onPickUpgrade(player: Player, offerId: number, cardIndex: number)
	handlePick(player, offerId, cardIndex, nil)
end

-- Remote "ReplaceAbility(offerId, cardIndex, slotIndex)".
function UpgradeService.onReplaceAbility(player: Player, offerId: number, cardIndex: number, slotIndex: number)
	handlePick(player, offerId, cardIndex, slotIndex)
end

function UpgradeService.forget(player: Player)
	builds[player] = nil
end

function UpgradeService.start(dependencies: { onUpgradesChanged: ((Player, number) -> ())? })
	onUpgradesChanged = dependencies.onUpgradesChanged
	Players.PlayerAdded:Connect(function(player)
		ensureBuild(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		ensureBuild(player)
	end
end

return UpgradeService
