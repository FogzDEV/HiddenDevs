--// SERVICES
-- Services are cached once to avoid repeated global lookups which are slower.
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

--// MODULE CONFIG
-- Centralized zombie configuration table containing stats like
-- health, speed and damage for each zombie type.
local configs = ServerStorage.Configs
local infoZombies = require(configs.ConfigZombies)

-- AI update interval.
-- Instead of recalculating targets every frame (which would scale poorly),
-- zombies update their target every 0.5 seconds.
local MAXUPDATETIME = 0.5

-- Random object used instead of math.random()
-- This is the recommended Roblox approach for deterministic RNG.
local rng = Random.new()

--// RAYCAST PARAMETERS
-- Raycast only interacts with map geometry to detect obstacles
-- between the zombie and its target.
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
raycastParams.FilterDescendantsInstances = {workspace.Map}

--// OVERLAP PARAMETERS
-- Used for melee hit detection. We exclude enemies to prevent zombies
-- from damaging each other when their hitboxes overlap.
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = {workspace.Enemies}

--// ZOMBIE COLOR VARIATIONS
-- Cosmetic color randomization to add visual variety to zombies.
local ZombieColors = {
	Color3.new(0.05,0.7,0.3),
	Color3.new(0.5,0.9,0.4),
	Color3.new(0.1,0.3,0.2),
	Color3.new(0.6,0.2,0.2),
	Color3.new(0.2,0.1,0.6),
}

local ZombieAI = {}
ZombieAI.__index = ZombieAI

-- Cached tables to avoid expensive operations during runtime.
-- Player:GetPlayers() allocations are avoided entirely.
local AliveZombies = {}
local AlivePlayers = {}

--// ELITE ZOMBIE
-- Small chance for a zombie to spawn as an elite variant.
-- Elite zombies are stronger and visually highlighted.
function ZombieAI:IsElite()
	if rng:NextNumber() <= 0.1 then
		local highlight = Instance.new("Highlight")
		highlight.FillColor = Color3.new(0.4,0.16,1)
		highlight.OutlineColor = Color3.new(1,0.74,0)
		highlight.Parent = self.Model

		self.Model:ScaleTo(2)

		self.Humanoid.MaxHealth *= 2
		self.Humanoid.Health = self.Humanoid.MaxHealth

		self.Info.Damage *= 2
	end
end

--// OBSTACLE DETECTION
-- Detects if geometry is blocking the zombie's path toward the target.
-- If an obstacle is detected, the zombie attempts to jump.
function ZombieAI:Raycast()
	local origin = self.PrimaryPart.Position + Vector3.new(0,-1.5,0)
	local direction = (self.TargetPosition - origin).Unit

	local result = workspace:Raycast(origin, direction * 6, raycastParams)

	return result ~= nil
end

--// RAGDOLL SYSTEM
-- Converts Motor6D joints to BallSocketConstraints when the zombie dies.
-- This produces a physics-based ragdoll effect instead of Roblox's
-- default joint breaking behavior.
function ZombieAI:Death()

	self.Humanoid.Died:Once(function()

		local function createAttachment(part,cframe)
			local att = Instance.new("Attachment")
			att.CFrame = cframe
			att.Parent = part
			return att
		end

		local function createSocket(part,c0,c1)
			local socket = Instance.new("BallSocketConstraint")

			socket.Attachment0 = createAttachment(self.Model.Torso,c0)
			socket.Attachment1 = createAttachment(part,c1)

			socket.LimitsEnabled = true
			socket.Parent = self.Model.Torso
		end

		for _,motor in self.Model.Torso:GetChildren() do
			if motor:IsA("Motor6D") and motor.Name ~= "Neck" then
				createSocket(motor.Part1,motor.C0,motor.C1)
				motor:Destroy()
			end
		end

		self:PlaySound("Die")

		Debris:AddItem(self.Model,5)
	end)

end

--// DAMAGE REACTION
-- Tracks health changes to trigger damage animations and sounds.
function ZombieAI:Damaged()

	self.Humanoid.HealthChanged:Connect(function(health)

		if health < self.CurrentHealth then
			self.Animations["Damaged"]:Play()
			self:PlaySound("Damaged")
		end

		self.CurrentHealth = health

	end)

end

--// ANIMATION SETUP
-- Loads all animations once during initialization and stores them
-- in a lookup table for fast access during runtime.
function ZombieAI:SetupAnimations()

	local animator = self.Humanoid:FindFirstChildOfClass("Animator")

	for _,anim in script.Animations:GetChildren() do
		local track = animator:LoadAnimation(anim)
		self.Animations[anim.Name] = track
	end

	self.Humanoid.StateChanged:Connect(function(old,new)

		local newAnim = self.Animations[new.Name]
		if not newAnim then return end

		newAnim:Play()

		local oldAnim = self.Animations[old.Name]
		if oldAnim then
			oldAnim:Stop()
		end

	end)

end

--// SOUND PLAYER
-- Randomly selects a sound from a folder and plays it on the zombie.
function ZombieAI:PlaySound(state)

	local folder = ServerStorage.Sounds:FindFirstChild(state)
	if not folder then return end

	local sounds = folder:GetChildren()
	if #sounds == 0 then return end

	local sound = sounds[rng:NextInteger(1,#sounds)]:Clone()
	sound.Parent = self.PrimaryPart
	sound:Play()

	Debris:AddItem(sound,sound.TimeLength * 1.5)

end

--// INITIAL SETUP
function ZombieAI:Setup()

	self.Humanoid.MaxHealth = self.Info.Health
	self.Humanoid.Health = self.Info.Health
	self.Humanoid.WalkSpeed = self.Info.Speed

	self.Humanoid.BreakJointsOnDeath = false
	self.Humanoid.RequiresNeck = false

	local bodyColors = self.Model:FindFirstChildOfClass("BodyColors")
	local color = ZombieColors[rng:NextInteger(1,#ZombieColors)]

	for _,part in {"Head","LeftArm","RightArm"} do
		bodyColors[part.."Color3"] = color
	end

	self:SetupAnimations()
	self:Death()
	self:Damaged()

	self:PlaySound("Spawn")
	self:IsElite()

	table.insert(AliveZombies,self)

end

--// TARGET ACQUISITION
-- Searches for the nearest valid player humanoid.
-- Uses the cached AlivePlayers table instead of Players:GetPlayers()
-- which prevents frequent memory allocations.
function ZombieAI:FindTarget()

	local nearest
	local nearestDistance = math.huge
	local nearestPos

	for _,plr in AlivePlayers do

		local char = plr.Character
		if not char then continue end

		local hrp = char:FindFirstChild("HumanoidRootPart")
		local hum = char:FindFirstChildOfClass("Humanoid")

		if not hrp or not hum or hum.Health <= 0 then continue end

		local dist = (hrp.Position - self.PrimaryPart.Position).Magnitude

		if dist < nearestDistance then

			nearest = plr
			nearestDistance = dist

			local offset = 5 * (dist/10)

			nearestPos = hrp.Position + Vector3.new(
				rng:NextNumber(-offset,offset),
				0,
				rng:NextNumber(-offset,offset)
			)

		end
	end

	if nearest then
		self.Target = nearest
		self.TargetPosition = nearestPos
		self.Distance = nearestDistance
		self:MoveToTarget()
	end

end

--// ATTACK SYSTEM
-- Uses spatial queries instead of .Touched events.
-- This is more reliable and avoids physics event overhead.
function ZombieAI:Attack()

	if os.clock() - self.LastAttack <= 1 then
		return
	end

	self.LastAttack = os.clock()

	local origin = self.PrimaryPart.CFrame

	local parts = workspace:GetPartBoundsInBox(origin,Vector3.new(10,10,10),overlapParams)

	local victims = {}

	for _,part in parts do

		local hum = part.Parent:FindFirstChildOfClass("Humanoid")

		if not hum or hum.Health <= 0 or victims[hum] then continue end

		hum:TakeDamage(self.Info.Damage)

		victims[hum] = true

	end

	self:PlaySound("Attack")
	self.Animations["Attack"]:Play()

end

--// MOVEMENT
function ZombieAI:MoveToTarget()

	self.Humanoid:MoveTo(self.TargetPosition)

	if self:Raycast() then
		self.Humanoid.Jump = true
	end

	if self.Distance <= 5 then
		self:Attack()
	end

end

--// CONSTRUCTOR
function ZombieAI.New(zombie)

	local self = setmetatable({},ZombieAI)

	self.Model = zombie
	self.PrimaryPart = zombie.PrimaryPart
	self.Info = infoZombies[zombie.Name]

	self.Humanoid = zombie:FindFirstChildOfClass("Humanoid")

	self.LastPathUpdate = os.clock()
	self.LastAttack = os.clock()

	self.CurrentHealth = zombie.Humanoid.Health

	self.Animations = {}

	self:Setup()

	return self

end

--// MAIN AI LOOP
RunService.Heartbeat:Connect(function()

	for i = #AliveZombies,1,-1 do

		local zombie = AliveZombies[i]

		if not zombie.Model or zombie.Humanoid.Health <= 0 then
			table.remove(AliveZombies,i)
			continue
		end

		if os.clock() - zombie.LastPathUpdate >= MAXUPDATETIME then
			zombie:FindTarget()
			zombie.LastPathUpdate = os.clock()
		end

	end

end)

--// PLAYER CACHE SYSTEM
Players.PlayerAdded:Connect(function(plr)

	if not table.find(AlivePlayers,plr) then
		table.insert(AlivePlayers,plr)
	end

end)

Players.PlayerRemoving:Connect(function(plr)

	local index = table.find(AlivePlayers,plr)
	if index then
		table.remove(AlivePlayers,index)
	end

end)

return ZombieAI
