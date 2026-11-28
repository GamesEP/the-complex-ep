--!strict
--[[
	Isolated Hub & Co-op Party screen (`plans/gdd/ui.md`, `plans/roadmap.md HS-26`).

	Visible while `workspace.World:GetAttribute("ServerMode") == "hub"`:
	  - Left/Top panel: Squad Roster (1-4 slots), Open/Private privacy toggle, Leader Kick controls,
	    Difficulty selector (`Fácil`, `Normal`, `Difícil`, `Zona Muerta`), and bold **INICIAR RUN**
	    button (solo or leader).
	  - Right/Bottom panel: Live scrollable Hub player list (`Active = true` for input sinking) with
	    one-click **UNIRSE** (to open parties) or **INVITAR** (creates/invites to party).
	  - Top-center toast: Private party invitation banner with live countdown bar (`PARTY_INVITE_SECONDS`)
	    and **ACEPTAR** / **RECHAZAR** buttons, plus status notices.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Difficulty = require(Shared.features.enemies.Difficulty)
local Remotes = require(Shared.core.Net.Remotes)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")
local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local PartyStore = require(script.Parent.Parent.stores.PartyStore)

local localPlayer = Players.LocalPlayer

type PlayerSnapshot = {
	player: Player,
	userId: number,
	name: string,
	partyId: string,
	partyRole: string,
	partyPrivacy: string,
	partyDifficulty: string,
	partyLocked: boolean,
	partyOrder: number,
}

local function snapshotPlayers(): { PlayerSnapshot }
	local list: { PlayerSnapshot } = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local pid = p:GetAttribute("PartyId")
		local role = p:GetAttribute("PartyRole")
		local priv = p:GetAttribute("PartyPrivacy")
		local diff = p:GetAttribute("PartyDifficulty")
		local locked = p:GetAttribute("PartyLocked") == true
		local order = p:GetAttribute("PartyOrder")
		table.insert(list, {
			player = p,
			userId = p.UserId,
			name = p.DisplayName,
			partyId = if type(pid) == "string" then pid else "",
			partyRole = if type(role) == "string" then role else "",
			partyPrivacy = if type(priv) == "string" then priv else "",
			partyDifficulty = if Difficulty.isValid(diff) then diff :: string else Config.DEFAULT_DIFFICULTY,
			partyLocked = locked,
			partyOrder = if type(order) == "number" then order else 0,
		})
	end
	table.sort(list, function(a, b)
		if a.userId == b.userId then
			return false
		end
		if a.userId == localPlayer.UserId then
			return true
		end
		if b.userId == localPlayer.UserId then
			return false
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.userId < b.userId
	end)
	return list
end

local function useHubRoster(): { PlayerSnapshot }
	local roster, setRoster = React.useState(snapshotPlayers)

	React.useEffect(function()
		local conns: { RBXScriptConnection } = {}
		local playerConns: { [Player]: { RBXScriptConnection } } = {}

		local function refresh()
			setRoster(snapshotPlayers())
		end

		local function watchPlayer(p: Player)
			local list: { RBXScriptConnection } = {}
			playerConns[p] = list
			for _, attr in ipairs({ "PartyId", "PartyRole", "PartyPrivacy", "PartyDifficulty", "PartyLocked", "PartyOrder" }) do
				table.insert(list, p:GetAttributeChangedSignal(attr):Connect(refresh))
			end
		end

		for _, p in ipairs(Players:GetPlayers()) do
			watchPlayer(p)
		end
		table.insert(conns, Players.PlayerAdded:Connect(function(p)
			watchPlayer(p)
			refresh()
		end))
		table.insert(conns, Players.PlayerRemoving:Connect(function(p)
			local list = playerConns[p]
			if list then
				for _, c in ipairs(list) do
					c:Disconnect()
				end
				playerConns[p] = nil
			end
			task.defer(refresh)
		end))
		refresh()

		return function()
			for _, c in ipairs(conns) do
				c:Disconnect()
			end
			for _, list in pairs(playerConns) do
				for _, c in ipairs(list) do
					c:Disconnect()
				end
			end
		end
	end, {})

	return roster
end

local function HubPartyUi(props)
	local metrics = Scaled.useLayout()
	local serverMode = hooks.useAttribute(props.world, "ServerMode")
	local roster = useHubRoster()
	local invites = hooks.useAtom(PartyStore.invites)
	local notice = hooks.useAtom(PartyStore.notice)
	local launching = hooks.useAtom(PartyStore.launching)
	local clockNow, setClockNow = React.useState(function()
		return workspace:GetServerTimeNow()
	end)

	React.useEffect(function()
		if serverMode ~= "hub" then
			PartyStore.setLaunching(false)
			return
		end
		local acc = 0
		local conn = RunService.Heartbeat:Connect(function(dt: number)
			acc += dt
			if acc >= 0.2 then
				acc = 0
				if #PartyStore.invites() > 0 or PartyStore.notice() ~= nil then
					local t = workspace:GetServerTimeNow()
					PartyStore.pruneExpired(t)
					setClockNow(t)
				end
			end
		end)
		return function()
			conn:Disconnect()
		end
	end, { serverMode })

	if serverMode ~= "hub" then
		return nil
	end

	-- Resolve local player snapshot and party counts.
	local me: PlayerSnapshot? = nil
	local partyCounts: { [string]: number } = {}
	for _, entry in ipairs(roster) do
		if entry.userId == localPlayer.UserId then
			me = entry
		end
		if entry.partyId ~= "" then
			partyCounts[entry.partyId] = (partyCounts[entry.partyId] or 0) + 1
		end
	end

	local myPartyId = if me then me.partyId else ""
	local inParty = myPartyId ~= ""
	local isLeader = not inParty or (me ~= nil and me.partyRole == "leader")
	local myPrivacy = if me and me.partyPrivacy ~= "" then me.partyPrivacy else "open"
	local myDifficulty = if me then me.partyDifficulty else Config.DEFAULT_DIFFICULTY
	local isLocked = (me ~= nil and me.partyLocked) or launching
	local diffDef = Difficulty.get(myDifficulty)

	local squadMembers: { PlayerSnapshot } = {}
	if inParty then
		for _, entry in ipairs(roster) do
			if entry.partyId == myPartyId then
				table.insert(squadMembers, entry)
			end
		end
		table.sort(squadMembers, function(a, b)
			return a.partyOrder < b.partyOrder
		end)
	elseif me then
		table.insert(squadMembers, me)
	end

	local compact = metrics.compact
	local topOffset = ui.MARGIN + Layout.inset()
	local availableW = metrics.room.X - 2 * ui.MARGIN
	local twoColumn = not compact and availableW >= 780
	local leftW = if twoColumn then math.min(math.floor(availableW * 0.56), 540) else math.min(availableW, 560)
	local rightW = if twoColumn then math.min(availableW - leftW - 14, 380) else leftW

	-- Build difficulty buttons.
	local diffButtons: { [string]: any } = {
		List = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local diffBtnW = math.floor((leftW - 44) / math.max(#Config.DIFFICULTY_ORDER, 1))
	for idx, diffId in ipairs(Config.DIFFICULTY_ORDER) do
		local d = Config.DIFFICULTIES[diffId]
		if d then
			local selected = diffId == myDifficulty
			diffButtons[diffId] = React.createElement("TextButton", {
				LayoutOrder = idx,
				Size = UDim2.fromOffset(diffBtnW, 34),
				BackgroundColor3 = if selected then d.color else ui.STEEL,
				BackgroundTransparency = if not isLeader and not selected then 0.45 else 0,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Font = ui.DISPLAY_FONT,
				TextSize = if compact then 10 else 12,
				TextColor3 = if selected then ui.INK else ui.TEXT,
				Text = d.shortName,
				[React.Event.Activated] = function()
					if isLeader and not isLocked then
						Remotes.ChooseDifficulty:FireServer(diffId)
					end
				end,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				Stroke = React.createElement(ui.Outline, {
					color = if selected then ui.TEXT else d.color,
					thickness = if selected then 2 else 1,
				}),
			})
		end
	end

	-- Build 4 squad slots.
	local squadSlots: { [string]: any } = {
		Stack = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for slotIdx = 1, Config.PARTY_MAX_PLAYERS do
		local member = squadMembers[slotIdx]
		local canKick = inParty and isLeader and not isLocked and member ~= nil and member.userId ~= localPlayer.UserId
		squadSlots[`Slot{slotIdx}`] = React.createElement("Frame", {
			LayoutOrder = slotIdx,
			Size = UDim2.new(1, 0, 0, 32),
			BackgroundColor3 = if member then ui.STEEL else ui.INK,
			BackgroundTransparency = if member then 0.2 else 0.55,
			BorderSizePixel = 0,
		}, {
			Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
			Stroke = React.createElement(ui.Outline, {
				color = if member and member.partyRole == "leader" then ui.HAZARD else ui.BORDER,
				thickness = 1,
			}),
			Pad = React.createElement("UIPadding", {
				PaddingLeft = UDim.new(0, 10),
				PaddingRight = UDim.new(0, 8),
			}),
			NameLabel = React.createElement("TextLabel", {
				Size = UDim2.new(1, -90, 1, 0),
				BackgroundTransparency = 1,
				Font = if member then ui.DISPLAY_FONT else ui.MONO_FONT,
				TextSize = 12,
				TextColor3 = if member then ui.TEXT else ui.MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = if member
					then (if member.userId == localPlayer.UserId then `{member.name} (TÚ)` else member.name)
					else `RANURA 0{slotIdx}  ·  LIBRE`,
			}),
			RoleBadge = if member and not canKick
				then React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, 0, 0.5, 0),
					Size = UDim2.fromOffset(82, 20),
					BackgroundTransparency = 1,
					Font = ui.MONO_FONT,
					TextSize = 10,
					TextColor3 = if member.partyRole == "leader" or not inParty then ui.HAZARD else ui.KINETIC,
					TextXAlignment = Enum.TextXAlignment.Right,
					Text = if not inParty then "SOLO" elseif member.partyRole == "leader" then "LÍDER" else "MIEMBRO",
				})
				else nil,
			KickBtn = if canKick and member
				then React.createElement("TextButton", {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, 0, 0.5, 0),
					Size = UDim2.fromOffset(74, 22),
					BackgroundColor3 = ui.STRIKE,
					BorderSizePixel = 0,
					Font = ui.MONO_FONT,
					TextSize = 10,
					TextColor3 = ui.INK,
					Text = "EXPULSAR",
					[React.Event.Activated] = function()
						Remotes.KickMember:FireServer(member.userId)
					end,
				}, {
					Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				})
				else nil,
		})
	end

	-- Build Hub server player list rows (`Active = true` for touch/mouse scroll sinking).
	local playerRows: { [string]: any } = {
		Stack = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local otherCount = 0
	for idx, entry in ipairs(roster) do
		if entry.userId ~= localPlayer.UserId then
			otherCount += 1
			local sameParty = inParty and entry.partyId == myPartyId
			local targetCount = if entry.partyId ~= "" then (partyCounts[entry.partyId] or 1) else 0
			local canJoinOpen = entry.partyId ~= ""
				and not sameParty
				and entry.partyPrivacy == "open"
				and not entry.partyLocked
				and targetCount < Config.PARTY_MAX_PLAYERS
				and not isLocked
			local canInvite = not sameParty
				and isLeader
				and #squadMembers < Config.PARTY_MAX_PLAYERS
				and not entry.partyLocked
				and not isLocked

			local statusText = if sameParty
				then "EN TU GRUPO"
				elseif entry.partyId == "" then "SOLO EN HUB"
				elseif entry.partyPrivacy == "open" then `ABIERTO ({targetCount}/{Config.PARTY_MAX_PLAYERS})`
				else `PRIVADO ({targetCount}/{Config.PARTY_MAX_PLAYERS})`

			playerRows[`P_{entry.userId}`] = React.createElement("Frame", {
				LayoutOrder = idx,
				Size = UDim2.new(1, 0, 0, 44),
				BackgroundColor3 = ui.STEEL,
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				Stroke = React.createElement(ui.Outline, { color = ui.BORDER, thickness = 1 }),
				Pad = React.createElement("UIPadding", {
					PaddingLeft = UDim.new(0, 10),
					PaddingRight = UDim.new(0, 8),
				}),
				Info = React.createElement("Frame", {
					Size = UDim2.new(1, -138, 1, 0),
					BackgroundTransparency = 1,
				}, {
					Name = React.createElement("TextLabel", {
						Position = UDim2.fromOffset(0, 5),
						Size = UDim2.new(1, 0, 0, 16),
						BackgroundTransparency = 1,
						Font = ui.DISPLAY_FONT,
						TextSize = 12,
						TextColor3 = ui.TEXT,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
						Text = entry.name,
					}),
					Status = React.createElement("TextLabel", {
						Position = UDim2.fromOffset(0, 22),
						Size = UDim2.new(1, 0, 0, 14),
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 10,
						TextColor3 = if sameParty then ui.VITAL elseif canJoinOpen then ui.KINETIC else ui.MUTED,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = statusText,
					}),
				}),
				Actions = React.createElement("Frame", {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, 0, 0.5, 0),
					Size = UDim2.fromOffset(132, 26),
					BackgroundTransparency = 1,
				}, {
					Row = React.createElement("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Right,
						Padding = UDim.new(0, 5),
					}),
					JoinBtn = if canJoinOpen
						then React.createElement("TextButton", {
							LayoutOrder = 1,
							Size = UDim2.fromOffset(62, 26),
							BackgroundColor3 = ui.VITAL,
							BorderSizePixel = 0,
							Font = ui.MONO_FONT,
							TextSize = 10,
							TextColor3 = ui.INK,
							Text = "UNIRSE",
							[React.Event.Activated] = function()
								Remotes.JoinParty:FireServer(entry.partyId)
							end,
						}, {
							Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
						})
						else nil,
					InviteBtn = if canInvite
						then React.createElement("TextButton", {
							LayoutOrder = 2,
							Size = UDim2.fromOffset(64, 26),
							BackgroundColor3 = ui.KINETIC,
							BorderSizePixel = 0,
							Font = ui.MONO_FONT,
							TextSize = 10,
							TextColor3 = ui.INK,
							Text = "INVITAR",
							[React.Event.Activated] = function()
								Remotes.InvitePlayer:FireServer(entry.userId)
							end,
						}, {
							Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
						})
						else nil,
				}),
			})
		end
	end
	if otherCount == 0 then
		playerRows.Empty = React.createElement("TextLabel", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundTransparency = 1,
			Font = ui.BODY_FONT,
			TextSize = 12,
			TextColor3 = ui.MUTED,
			TextWrapped = true,
			Text = "No hay otros agentes en este Hub todavía. Puedes iniciar en solitario o crear un grupo abierto.",
		})
	end

	-- Active invite toast (top-center).
	local activeInvite = invites[1]
	local inviteRemain = if activeInvite then math.max(activeInvite.expiresAt - clockNow, 0) else 0
	local inviteRatio = math.clamp(inviteRemain / math.max(Config.PARTY_INVITE_SECONDS, 1), 0, 1)

	local squadPanel = React.createElement(ui.Panel, {
		name = "SquadPanel",
		order = 1,
		size = UDim2.new(0, leftW, 0, 0),
		padding = 14,
		accentColor = diffDef.color,
		accent = "left",
		strokeColor = diffDef.color,
	}, {
		Stack = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		HeaderRow = React.createElement("Frame", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
		}, {
			Title = React.createElement("TextLabel", {
				Size = UDim2.new(0.55, 0, 1, 0),
				BackgroundTransparency = 1,
				Font = ui.DISPLAY_FONT,
				TextSize = 14,
				TextColor3 = ui.TEXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = if inParty
					then `ESCUADRÓN ({#squadMembers}/{Config.PARTY_MAX_PLAYERS})`
					else "DESPLIEGUE EN SOLITARIO",
			}),
			Controls = React.createElement("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0.45, 0, 1, 0),
				BackgroundTransparency = 1,
			}, {
				Row = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					Padding = UDim.new(0, 6),
				}),
				PrivacyBtn = if not inParty
					then React.createElement("TextButton", {
						LayoutOrder = 1,
						Size = UDim2.fromOffset(108, 26),
						BackgroundColor3 = ui.KINETIC,
						BorderSizePixel = 0,
						Font = ui.MONO_FONT,
						TextSize = 10,
						TextColor3 = ui.INK,
						Text = "CREAR GRUPO",
						[React.Event.Activated] = function()
							if not isLocked then
								Remotes.CreateParty:FireServer("open")
							end
						end,
					}, { Corner = React.createElement(ui.Round, { radius = ui.CORNER }) })
					elseif isLeader then React.createElement("TextButton", {
						LayoutOrder = 1,
						Size = UDim2.fromOffset(92, 26),
						BackgroundColor3 = if myPrivacy == "open" then ui.VITAL else ui.HAZARD,
						BorderSizePixel = 0,
						Font = ui.MONO_FONT,
						TextSize = 10,
						TextColor3 = ui.INK,
						Text = if myPrivacy == "open" then "ABIERTO" else "PRIVADO",
						[React.Event.Activated] = function()
							if not isLocked then
								Remotes.SetPartyPrivacy:FireServer(if myPrivacy == "open" then "private" else "open")
							end
						end,
					}, { Corner = React.createElement(ui.Round, { radius = ui.CORNER }) })
					else nil,
				LeaveBtn = if inParty
					then React.createElement("TextButton", {
						LayoutOrder = 2,
						Size = UDim2.fromOffset(68, 26),
						BackgroundColor3 = ui.STEEL,
						BorderSizePixel = 0,
						Font = ui.MONO_FONT,
						TextSize = 10,
						TextColor3 = ui.STRIKE,
						Text = "SALIR",
						[React.Event.Activated] = function()
							if not isLocked then
								Remotes.LeaveParty:FireServer()
							end
						end,
					}, {
						Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
						Stroke = React.createElement(ui.Outline, { color = ui.STRIKE, thickness = 1 }),
					})
					else nil,
			}),
		}),
		SquadList = React.createElement("Frame", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, squadSlots),
		DiffHeader = React.createElement("TextLabel", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = ui.MUTED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = `DIFICULTAD  ·  {Config.FLOORS_PER_RUN} PLANTAS ({Config.FLOORS_PER_RUN * Config.ROOMS_PER_FLOOR} SALAS)`,
		}),
		DiffRow = React.createElement("Frame", {
			LayoutOrder = 4,
			Size = UDim2.new(1, 0, 0, 36),
			BackgroundTransparency = 1,
		}, diffButtons),
		DiffDesc = React.createElement("TextLabel", {
			LayoutOrder = 5,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = diffDef.color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			Text = string.format(
				"%s  ·  Enemigos ×%.2g  ·  Daño ×%.2g  ·  Vida ×%.2g",
				diffDef.description,
				diffDef.countMultiplier,
				diffDef.damageMultiplier,
				diffDef.healthMultiplier
			),
		}),
		LaunchButton = React.createElement("TextButton", {
			Name = "HubStartRunButton",
			LayoutOrder = 6,
			Size = UDim2.new(1, 0, 0, 46),
			BackgroundColor3 = if isLeader then diffDef.color else ui.STEEL,
			BorderSizePixel = 0,
			Font = ui.DISPLAY_FONT,
			TextSize = 16,
			TextColor3 = if isLeader then ui.INK else ui.MUTED,
			Text = if isLocked
				then "DESPLEGANDO ESCUADRÓN..."
				elseif not isLeader then "ESPERANDO AL LÍDER..."
				elseif inParty then `INICIAR RUN ({#squadMembers} JUG.)`
				else "INICIAR RUN EN SOLITARIO",
			[React.Event.Activated] = function()
				if isLeader and not isLocked then
					PartyStore.setLaunching(true)
					Remotes.StartRun:FireServer()
				end
			end,
		}, {
			Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
			Stroke = React.createElement(ui.Outline, { color = ui.TEXT, thickness = 1.5 }),
		}),
	})

	local playersPanel = React.createElement(ui.Panel, {
		name = "HubPlayersPanel",
		order = 2,
		size = UDim2.new(0, rightW, 0, 0),
		padding = 14,
		accentColor = ui.KINETIC,
		accent = "left",
	}, {
		Stack = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Header = React.createElement("TextLabel", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			Font = ui.DISPLAY_FONT,
			TextSize = 13,
			TextColor3 = ui.KINETIC,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = `AGENTES EN EL HUB ({#roster}/{Config.HUB_MAX_PLAYERS})`,
		}),
		Scroll = React.createElement("ScrollingFrame", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, if twoColumn then 280 else 190),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = true,
			ScrollBarThickness = 4,
			CanvasSize = UDim2.fromScale(0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, playerRows),
	})

	return React.createElement(Scaled.Frame, nil, {
		-- Subtle dark top header banner leaving the 3D Hub visible behind the side/bottom cards.
		TopBanner = React.createElement("Frame", {
			Name = "HubHeader",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, topOffset),
			Size = UDim2.new(1, -2 * ui.MARGIN, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, {
			Stack = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 6),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			TitlePill = React.createElement(ui.Panel, {
				name = "HubTitlePill",
				order = 1,
				size = UDim2.fromOffset(0, 0),
				automaticSize = Enum.AutomaticSize.XY,
				padding = 8,
				accentColor = ui.KINETIC,
				accent = "left",
			}, {
				Text = React.createElement("TextLabel", {
					Size = UDim2.fromOffset(0, 18),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundTransparency = 1,
					Font = ui.MONO_FONT,
					TextSize = if compact then 12 else 14,
					TextColor3 = ui.TEXT,
					Text = "EL COMPLEJO  //  VESTÍBULO AISLADO DE DESPLIEGUE",
				}),
			}),
			InviteToast = if activeInvite
				then React.createElement(ui.Panel, {
					name = "InviteToast",
					order = 2,
					width = math.min(availableW, 420),
					padding = 10,
					accentColor = ui.HAZARD,
					accent = "left",
					strokeColor = ui.HAZARD,
					strokeThickness = 2,
				}, {
					Stack = React.createElement("UIListLayout", {
						Padding = UDim.new(0, 6),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					Label = React.createElement("TextLabel", {
						LayoutOrder = 1,
						Size = UDim2.new(1, 0, 0, 18),
						BackgroundTransparency = 1,
						Font = ui.DISPLAY_FONT,
						TextSize = 13,
						TextColor3 = ui.TEXT,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = `{activeInvite.fromName} te invita a su escuadrón ({math.ceil(inviteRemain)}s)`,
					}),
					TimerTrack = React.createElement("Frame", {
						LayoutOrder = 2,
						Size = UDim2.new(1, 0, 0, 4),
						BackgroundColor3 = ui.INK,
						BorderSizePixel = 0,
					}, {
						Fill = React.createElement("Frame", {
							Size = UDim2.fromScale(inviteRatio, 1),
							BackgroundColor3 = ui.HAZARD,
							BorderSizePixel = 0,
						}),
					}),
					Btns = React.createElement("Frame", {
						LayoutOrder = 3,
						Size = UDim2.new(1, 0, 0, 28),
						BackgroundTransparency = 1,
					}, {
						Row = React.createElement("UIListLayout", {
							FillDirection = Enum.FillDirection.Horizontal,
							Padding = UDim.new(0, 8),
						}),
						Accept = React.createElement("TextButton", {
							LayoutOrder = 1,
							Size = UDim2.new(0.5, -4, 1, 0),
							BackgroundColor3 = ui.VITAL,
							BorderSizePixel = 0,
							Font = ui.DISPLAY_FONT,
							TextSize = 12,
							TextColor3 = ui.INK,
							Text = "ACEPTAR",
							[React.Event.Activated] = function()
								Remotes.RespondInvite:FireServer(activeInvite.partyId, true)
							end,
						}, { Corner = React.createElement(ui.Round, { radius = ui.CORNER }) }),
						Decline = React.createElement("TextButton", {
							LayoutOrder = 2,
							Size = UDim2.new(0.5, -4, 1, 0),
							BackgroundColor3 = ui.STEEL,
							BorderSizePixel = 0,
							Font = ui.DISPLAY_FONT,
							TextSize = 12,
							TextColor3 = ui.TEXT,
							Text = "RECHAZAR",
							[React.Event.Activated] = function()
								Remotes.RespondInvite:FireServer(activeInvite.partyId, false)
							end,
						}, { Corner = React.createElement(ui.Round, { radius = ui.CORNER }) }),
					}),
				})
				else nil,
			NoticeBar = if notice
				then React.createElement(ui.Panel, {
					name = "HubNoticeBar",
					order = 3,
					size = UDim2.fromOffset(0, 0),
					automaticSize = Enum.AutomaticSize.XY,
					padding = 7,
					accentColor = if notice.tone == "error"
						then ui.STRIKE
						elseif notice.tone == "warn" then ui.HAZARD
						else ui.VITAL,
					accent = "left",
				}, {
					Text = React.createElement("TextLabel", {
						Size = UDim2.fromOffset(0, 16),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 12,
						TextColor3 = ui.TEXT,
						Text = notice.text,
					}),
				})
				else nil,
		}),

		Body = if twoColumn
			then React.createElement("Frame", {
				Name = "HubBody",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, math.floor((topOffset + 32) * 0.5)),
				Size = UDim2.new(1, -2 * ui.MARGIN, 1, -(topOffset + 64 + ui.MARGIN)),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, {
				Layout = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 14),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Squad = squadPanel,
				Players = playersPanel,
			})
			else React.createElement("ScrollingFrame", {
				Name = "HubBody",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -ui.MARGIN),
				Size = UDim2.new(1, -2 * ui.MARGIN, 1, -(topOffset + 64 + ui.MARGIN)),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Active = true,
				ScrollBarThickness = 4,
				CanvasSize = UDim2.fromScale(0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
			}, {
				Layout = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Top,
					Padding = UDim.new(0, 14),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Squad = squadPanel,
				Players = playersPanel,
			}),
	})
end

local screen = {}

function screen.start()
	local world = workspace:WaitForChild("World")

	Remotes.PartyEvent.OnClientEvent:Connect(function(kind: string, payload: any)
		local t = workspace:GetServerTimeNow()
		if kind == "invite" and type(payload) == "table" and type(payload.partyId) == "string" then
			PartyStore.addInvite({
				partyId = payload.partyId,
				fromUserId = payload.fromUserId or 0,
				fromName = tostring(payload.fromName or "Agente"),
				expiresAt = if type(payload.expiresAt) == "number" then payload.expiresAt else t + Config.PARTY_INVITE_SECONDS,
			})
		elseif kind == "inviteCleared" and type(payload) == "table" and type(payload.partyId) == "string" then
			PartyStore.removeInvite(payload.partyId)
		elseif kind == "notice" and type(payload) == "table" and type(payload.text) == "string" then
			local tone: "info" | "warn" | "error" = if payload.tone == "error"
				then "error"
				elseif payload.tone == "warn" then "warn"
				else "info"
			PartyStore.showNotice(tone, payload.text, t)
		elseif kind == "launchFailed" then
			PartyStore.setLaunching(false)
			local msg = if type(payload) == "table" and type(payload.text) == "string"
				then payload.text
				else "No se pudo iniciar la run."
			PartyStore.showNotice("error", msg, t, 6)
		end
	end)

	ContextActionService:BindActionAtPriority("HubStartRunConfirm", function(_, inputState: Enum.UserInputState)
		if world:GetAttribute("ServerMode") ~= "hub" then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin and not PartyStore.launching() then
			local role = localPlayer:GetAttribute("PartyRole")
			local pid = localPlayer:GetAttribute("PartyId")
			if (pid == nil or pid == "" or role == "leader") and localPlayer:GetAttribute("PartyLocked") ~= true then
				PartyStore.setLaunching(true)
				Remotes.StartRun:FireServer()
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 55, Enum.KeyCode.Return, Enum.KeyCode.ButtonA)

	return UI.mount("HubPartyUi", function()
		return React.createElement(HubPartyUi, { world = world })
	end, { displayOrder = 48 })
end

return screen
