--[[
	Zero-pause top-center 1-of-3 UpgradeChoice banner (plans/gdd/ui.md, plans/roadmap.md VS-21).

	Drops cleanly underneath `SectorBar` without dimming the arena or blocking movement, camera,
	or attacks. Players pick by:
	- PC hotkeys: Q (card 1), E (card 2), F (card 3), bound at priority above CombatInput only
	  while an offer is active (so LeftShift Dash, LMB Attack, RMB Block, WASD, Space, 1/2/3 all
	  continue uninterrupted mid-fight). Escape cancels 3-slot replace mode.
	- Click / tap directly on any ticket card.
	- Gamepad: D-pad / thumbstick focus + ButtonA, or direct card activation.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")
local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local UpgradeStore = require(script.Parent.Parent.stores.UpgradeStore)

local HOTKEY_PRIORITY = Enum.ContextActionPriority.High.Value + 50
local CARD_KEYS = { "Q", "E", "F" }
-- Brief grace delay when a brand-new offer opens so a mid-combat reflex press of E (Ability) or
-- F (Block) never picks card 2 or 3 accidentally. Clicking or tapping a ticket works immediately.
local OFFER_INPUT_GRACE_SECONDS = 0.35

local offerOpenedAt = 0
local lastOfferId: number? = nil

local function isRunActive(world: Instance?): boolean
	local rs = if world then world:GetAttribute("RunState") else nil
	return rs == "fighting" or rs == "transition"
end

local function readOwnedSlots(player: Player): ({ string }, { number })
	local slots: { string } = {}
	local levels: { number } = {}
	for i = 1, Config.ABILITY_SLOTS do
		local id = player:GetAttribute(`AbilitySlot{i}`)
		local lv = player:GetAttribute(`AbilityLevel{i}`)
		slots[i] = if type(id) == "string" then id else ""
		levels[i] = if type(lv) == "number" then math.floor(lv) else 0
	end
	return slots, levels
end

local function needsSlotReplacement(player: Player, card: UpgradeStore.CardData): boolean
	return UpgradeStore.needsSlotReplacement(card, readOwnedSlots(player))
end

local function triggerCard(cardIndex: number)
	local offer = UpgradeStore.offer()
	if not offer then
		return
	end
	local player = Players.LocalPlayer
	local replacing = UpgradeStore.replacingCardIndex()

	if replacing then
		if cardIndex >= 1 and cardIndex <= Config.ABILITY_SLOTS then
			Remotes.ReplaceAbility:FireServer(offer.offerId, replacing, cardIndex)
			UpgradeStore.cancelReplace()
		end
		return
	end

	local card = offer.cards[cardIndex]
	if not card then
		return
	end
	if needsSlotReplacement(player, card) then
		UpgradeStore.beginReplace(cardIndex)
		return
	end
	Remotes.PickUpgrade:FireServer(offer.offerId, cardIndex)
end

local function UpgradeTicket(props)
	local accent: Color3 = props.accent or ui.HAZARD
	local compact: boolean = props.compact == true
	local touch: boolean = props.touch == true

	return React.createElement("TextButton", {
		Name = props.name,
		LayoutOrder = props.order,
		Size = UDim2.fromOffset(props.width, if compact then 68 else 78),
		BackgroundColor3 = ui.PANEL,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Text = "",
		Active = true,
		[React.Event.Activated] = props.onActivate,
	}, {
		Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
		Stroke = React.createElement(ui.Outline, { color = accent, thickness = 1.6 }),
		Accent = React.createElement("Frame", {
			Size = UDim2.new(0, 4, 1, 0),
			BackgroundColor3 = accent,
			BorderSizePixel = 0,
			ZIndex = 2,
		}),
		Body = React.createElement("Frame", {
			Position = UDim2.fromOffset(10, 5),
			Size = UDim2.new(1, -16, 1, -10),
			BackgroundTransparency = 1,
		}, {
			TopRow = React.createElement("Frame", {
				Size = UDim2.new(1, 0, 0, 15),
				BackgroundTransparency = 1,
			}, {
				Category = React.createElement("TextLabel", {
					Size = UDim2.new(1, if touch then 0 else -28, 1, 0),
					BackgroundTransparency = 1,
					Font = ui.MONO_FONT,
					TextSize = if compact then 9 else 10,
					TextColor3 = accent,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Text = props.category,
				}),
				Keycap = if not touch
					then React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(1, 0, 0.5, 0),
						Size = UDim2.fromOffset(22, 15),
						BackgroundColor3 = ui.STEEL,
						BorderSizePixel = 0,
						Font = ui.MONO_FONT,
						TextSize = 11,
						TextColor3 = ui.TEXT,
						Text = props.keycap,
					}, {
						Corner = React.createElement(ui.Round, { radius = 3 }),
						Stroke = React.createElement(ui.Outline, { color = accent, thickness = 1 }),
					})
					else nil,
			}),
			Title = React.createElement("TextLabel", {
				Position = UDim2.fromOffset(0, 17),
				Size = UDim2.new(1, 0, 0, if compact then 18 else 21),
				BackgroundTransparency = 1,
				Font = ui.DISPLAY_FONT,
				TextSize = if compact then 13 else 15,
				TextColor3 = ui.TEXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = props.title,
			}),
			Effect = React.createElement("TextLabel", {
				Position = UDim2.fromOffset(0, if compact then 36 else 40),
				Size = UDim2.new(1, 0, 0, if compact then 22 else 26),
				BackgroundTransparency = 1,
				Font = ui.BODY_FONT,
				TextSize = if compact then 10 else 11,
				TextColor3 = ui.MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				Text = props.effect,
			}),
		}),
	})
end

local function UpgradeChoice(props)
	local player = Players.LocalPlayer
	local metrics = Scaled.useLayout()
	local runState = hooks.useAttribute(props.world, "RunState")
	local offer = hooks.useAtom(UpgradeStore.offer)
	local pending = hooks.useAtom(UpgradeStore.pending)
	local replacingIndex = hooks.useAtom(UpgradeStore.replacingCardIndex)

	-- Subscribe to slot attributes so replace-mode labels always reflect the live build.
	local slot1 = hooks.useAttribute(player, "AbilitySlot1")
	local slot2 = hooks.useAttribute(player, "AbilitySlot2")
	local slot3 = hooks.useAttribute(player, "AbilitySlot3")
	local level1 = hooks.useAttribute(player, "AbilityLevel1")
	local level2 = hooks.useAttribute(player, "AbilityLevel2")
	local level3 = hooks.useAttribute(player, "AbilityLevel3")

	if (runState ~= "fighting" and runState ~= "transition") or not offer or #offer.cards == 0 then
		return nil
	end

	local topOffset = ui.MARGIN + Layout.inset() + 42
	local gap = if metrics.compact then 6 else 10
	local maxRowWidth = math.min(if metrics.compact then 420 else 610, metrics.room.X - 2 * ui.MARGIN)
	local cardCount = if replacingIndex then Config.ABILITY_SLOTS else #offer.cards
	local cardWidth = math.max(math.floor((maxRowWidth - gap * math.max(cardCount - 1, 0)) / math.max(cardCount, 1)), 100)

	local cards: { [string]: any } = {
		List = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, gap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}

	local ownedSlots = {
		if type(slot1) == "string" then slot1 else "",
		if type(slot2) == "string" then slot2 else "",
		if type(slot3) == "string" then slot3 else "",
	}
	local headerTitle: string
	local headerAccent = ui.HAZARD
	if replacingIndex then
		local chosen = offer.cards[replacingIndex]
		local chosenAbility = if chosen and chosen.abilityId then Config.ABILITIES[chosen.abilityId] else nil
		local chosenName = if chosenAbility then chosenAbility.name elseif chosen then chosen.title else "Habilidad"
		headerTitle = `3/3 LLENAS — REEMPLAZAR PARA {string.upper(chosenName)}`
		headerAccent = ui.STRIKE
		local slotLevels = { level1, level2, level3 }
		for s = 1, Config.ABILITY_SLOTS do
			local abilityId = ownedSlots[s]
			local ability = Config.ABILITIES[abilityId]
			local lv = if type(slotLevels[s]) == "number" and slotLevels[s] > 0 then math.floor(slotLevels[s]) else 1
			cards[`Slot_{s}`] = React.createElement(UpgradeTicket, {
				name = `ReplaceSlot{s}`,
				order = s,
				width = cardWidth,
				compact = metrics.compact,
				touch = metrics.touch,
				accent = if ability and ability.color then ability.color else ui.STRIKE,
				category = `RANURA {s}  ·  NV.{lv}`,
				keycap = CARD_KEYS[s] or tostring(s),
				title = if ability then ability.name else abilityId,
				effect = "Reemplazar esta habilidad",
				onActivate = function()
					triggerCard(s)
				end,
			})
		end
	else
		headerTitle = if offer.isStarter then "ELIGE TU HABILIDAD INICIAL" else "MEJORA DE SALA — ELIGE 1"
		headerAccent = if offer.isStarter then ui.KINETIC else ui.HAZARD
		for idx, card in ipairs(offer.cards) do
			local willReplace = UpgradeStore.needsSlotReplacement(card, ownedSlots)
			local accent = if typeof(card.color) == "Color3" then card.color else ui.HAZARD
			cards[`Card_{idx}`] = React.createElement(UpgradeTicket, {
				name = `UpgradeCard{idx}`,
				order = idx,
				width = cardWidth,
				compact = metrics.compact,
				touch = metrics.touch,
				accent = accent,
				category = UpgradeStore.categoryLabel(card, willReplace),
				keycap = CARD_KEYS[idx] or tostring(idx),
				title = card.title,
				effect = card.effect,
				onActivate = function()
					triggerCard(idx)
				end,
			})
		end
	end

	return React.createElement(Scaled.Frame, nil, {
		Banner = React.createElement("Frame", {
			Name = "UpgradeBanner",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, topOffset),
			Size = UDim2.fromOffset(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 5),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			HeaderRow = React.createElement("Frame", {
				LayoutOrder = 1,
				Size = UDim2.fromOffset(0, 22),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
			}, {
				RowLayout = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 6),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				TitlePill = React.createElement("Frame", {
					LayoutOrder = 1,
					Size = UDim2.fromOffset(0, 20),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundColor3 = ui.INK,
					BackgroundTransparency = 0.12,
					BorderSizePixel = 0,
				}, {
					Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
					Stroke = React.createElement(ui.Outline, { color = headerAccent, thickness = 1 }),
					Pad = React.createElement("UIPadding", {
						PaddingLeft = UDim.new(0, 8),
						PaddingRight = UDim.new(0, 8),
					}),
					Text = React.createElement("TextLabel", {
						Size = UDim2.fromOffset(0, 20),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = if metrics.compact then 10 else 11,
						TextColor3 = headerAccent,
						Text = if not metrics.touch then `{headerTitle}  [Q / E / F]` else headerTitle,
					}),
				}),
				QueueChip = if pending > 0
					then React.createElement("Frame", {
						LayoutOrder = 2,
						Size = UDim2.fromOffset(0, 20),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundColor3 = ui.HAZARD,
						BorderSizePixel = 0,
					}, {
						Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
						Pad = React.createElement("UIPadding", {
							PaddingLeft = UDim.new(0, 6),
							PaddingRight = UDim.new(0, 6),
						}),
						Text = React.createElement("TextLabel", {
							Size = UDim2.fromOffset(0, 20),
							AutomaticSize = Enum.AutomaticSize.X,
							BackgroundTransparency = 1,
							Font = ui.DISPLAY_FONT,
							TextSize = 11,
							TextColor3 = ui.INK,
							Text = `+{pending}`,
						}),
					})
					else nil,
				CancelReplace = if replacingIndex
					then React.createElement("TextButton", {
						LayoutOrder = 3,
						Size = UDim2.fromOffset(64, 20),
						BackgroundColor3 = ui.STEEL,
						BorderSizePixel = 0,
						Font = ui.MONO_FONT,
						TextSize = 10,
						TextColor3 = ui.TEXT,
						Text = "VOLVER",
						[React.Event.Activated] = function()
							UpgradeStore.cancelReplace()
						end,
					}, {
						Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
						Stroke = React.createElement(ui.Outline, { color = ui.BORDER, thickness = 1 }),
					})
					else nil,
			}),
			CardsRow = React.createElement("Frame", {
				LayoutOrder = 2,
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
			}, cards),
		}),
	})
end

local screen = {}

function screen.start()
	local world = workspace:WaitForChild("World")

	Remotes.UpgradeOffer.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			lastOfferId = nil
			UpgradeStore.reset()
			return
		end
		local nextOffer = payload.offer
		local nextId = if type(nextOffer) == "table" and type(nextOffer.offerId) == "number" then nextOffer.offerId else nil
		if nextId ~= lastOfferId then
			lastOfferId = nextId
			if nextId ~= nil then
				offerOpenedAt = os.clock()
			end
		end
		UpgradeStore.setServerState(nextOffer, if type(payload.pending) == "number" then payload.pending else 0)
	end)

	-- Bind PC Q / E / F and Gamepad DPad Left / Up / Right above CombatInput while an offer is
	-- open during an active run; passes through during the initial 0.35 s grace window so a
	-- mid-combat reflex press of E or F never picks a card accidentally.
	local function bindHotkey(actionName: string, index: number, ...: Enum.KeyCode)
		ContextActionService:BindActionAtPriority(actionName, function(_, state: Enum.UserInputState)
			if not isRunActive(world) or not UpgradeStore.hasOffer() then
				return Enum.ContextActionResult.Pass
			end
			if os.clock() - offerOpenedAt < OFFER_INPUT_GRACE_SECONDS then
				return Enum.ContextActionResult.Pass
			end
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			triggerCard(index)
			return Enum.ContextActionResult.Sink
		end, false, HOTKEY_PRIORITY, ...)
	end

	bindHotkey("UpgradePick1", 1, Enum.KeyCode.Q, Enum.KeyCode.DPadLeft)
	bindHotkey("UpgradePick2", 2, Enum.KeyCode.E, Enum.KeyCode.DPadUp)
	bindHotkey("UpgradePick3", 3, Enum.KeyCode.F, Enum.KeyCode.DPadRight)

	ContextActionService:BindActionAtPriority("UpgradeCancelReplace", function(_, state: Enum.UserInputState)
		if not isRunActive(world) or not UpgradeStore.replacingCardIndex() then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			UpgradeStore.cancelReplace()
		end
		return Enum.ContextActionResult.Sink
	end, false, HOTKEY_PRIORITY, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB, Enum.KeyCode.DPadDown)

	return UI.mount("UpgradeChoice", function()
		return React.createElement(UpgradeChoice, { world = world })
	end, { displayOrder = 30 })
end

return screen
