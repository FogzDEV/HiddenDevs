-- Services and variables
local serverStorage = game:GetService("ServerStorage")
local runService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris") 

local configs = serverStorage.Configs
local infoZombies = require(configs.ConfigZombies)
local MAX_UPDATE_TIME = 0.5 

-- Raycast Params
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
raycastParams.FilterDescendantsInstances = {workspace:WaitForChild("Map")} 

-- Hitbox Params
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = {workspace:WaitForChild("Enemies")}

-- Skin variation colors
local ZombieColors = {
	[1] = Color3.new(0.05, 0.7, 0.3),
	[2] = Color3.new(0.5, 0.9, 0.4),
	[3] = Color3.new(0.1, 0.3, 0.2),
	[4] = Color3.new(0.6, 0.2, 0.2),
	[5] = Color3.new(0.2, 0.1, 0.6),
}

local ZombieAI = {}
ZombieAI.__index = ZombieAI

-- Global table to track active zombies
local AliveZombies = {}

--- Checks if the zombie spawns as an "Elite" variant with buffed stats
function ZombieAI:CheckIsElite()
	local n = math.random()
	if n <= 0.01 then -- 1% chance
		local high = Instance.new("Highlight")
		high.FillColor = Color3.new(0.4, 0.16, 1)
		high.OutlineColor = Color3.new(1, 0.75, 0)
		high.FillTransparency = 0.5
		high.DepthMode = Enum.HighlightDepthMode.Occluded
		high.Parent = self.Model

		self.Model:ScaleTo(1.5)
		self.Humanoid.MaxHealth *= 3
		self.Humanoid.Health = self.Humanoid.MaxHealth
		self.Info.Damage *= 2
		self.Info.Speed *= 1.5
	end
end

--- Detects walls or obstacles in front of the zombie to trigger jumping
function ZombieAI:CheckForObstacles()
	local origin = self.PrimaryPart.Position + Vector3.new(0, -1, 0)
	local direction = self.PrimaryPart.CFrame.LookVector * 4 -- Checks 4 studs ahead

	local raycastResult = workspace:Raycast(origin, direction, raycastParams)
	return raycastResult ~= nil -- Returns true if a wall is detected
end

--- Handles the Ragdoll system and body cleanup upon death
function ZombieAI:Death()
	self.Humanoid.Died:Once(function()
		if self.HealthCon then
			self.HealthCon:Disconnect()
		end
		-- Disable states to prevent the physics engine from trying to "stand" the character up
		self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

		local function CreateSocket(part, c0, c1)
			local ballSocket = Instance.new("BallSocketConstraint")
			local att0 = Instance.new("Attachment", self.Model.Torso)
			local att1 = Instance.new("Attachment", part)

			att0.CFrame = c0
			att1.CFrame = c1
			ballSocket.Attachment0 = att0
			ballSocket.Attachment1 = att1
			ballSocket.LimitsEnabled = true
			ballSocket.Parent = self.Model.Torso
		end

		-- Replace Motor6D joints with BallSockets for the Ragdoll effect
		for _, v in self.Model:GetDescendants() do
			if v:IsA("Motor6D") and v.Name ~= "Neck" then
				CreateSocket(v.Part1, v.C0, v.C1)
				v:Destroy()
			end
		end

		self:PlaySound("Die")
		Debris:AddItem(self.Model, 10) -- Remove body after 10 seconds
	end)
end

--- Visual and sound feedback when the zombie takes damage
function ZombieAI:Damaged()
	self.HealthCon = self.Humanoid.HealthChanged:Connect(function(health)
		if health < self.CurrentHealth and health > 0 then
			if self.Animations["Damaged"] then self.Animations["Damaged"]:Play() end
			self:PlaySound("Damaged")
		end
		self.CurrentHealth = health
	end)
end

--- Preloads animations and manages state-based playback
function ZombieAI:SetupAnimations()
	local animator = self.Humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", self.Humanoid)

	for _, anim in script.Animations:GetChildren() do
		self.Animations[anim.Name] = animator:LoadAnimation(anim)
	end

	-- Automatically play/stop animations based on Humanoid State
	self.Humanoid.StateChanged:Connect(function(old, new)
		if self.Animations[new.Name] then
			self.Animations[new.Name]:Play()
		end
		if self.Animations[old.Name] then
			self.Animations[old.Name]:Stop()
		end
	end)
end

--- Plays a random sound from a specific state folder
function ZombieAI:PlaySound(state)
	local folder = serverStorage.Sounds:FindFirstChild(state)
	if not folder then return end

	local sounds = folder:GetChildren()
	local sound = sounds[math.random(1, #sounds)]:Clone()
	sound.Parent = self.PrimaryPart
	sound:Play()
	Debris:AddItem(sound, sound.TimeLength + 0.5)
end

--- Initial configuration of attributes and appearance
function ZombieAI:Setup()
	if not self.Humanoid or not self.Model.PrimaryPart then return end
	self.Humanoid.MaxHealth = self.Info.Health
	self.Humanoid.Health = self.Info.Health
	self.Humanoid.WalkSpeed = self.Info.Speed	
	self.Humanoid.BreakJointsOnDeath = false

	-- Apply random colors to specific body parts
	local bodyColors = self.Model:FindFirstChildOfClass("BodyColors")
	if bodyColors then
		local color = ZombieColors[math.random(1, #ZombieColors)]
		for _, partName in {"HeadColor3", "LeftArmColor3", "RightArmColor3", "LeftLegColor3", "RightLegColor3"} do
			bodyColors[partName] = color
		end
	end

	self:SetupAnimations()
	self:Death()
	self:Damaged()
	self:CheckIsElite()
	self:PlaySound("Spawn")

	table.insert(AliveZombies, self) -- Add to the tracking table
end

--- Iterates through players to find the closest valid target
function ZombieAI:FindTarget()
	local nearestTarget = nil
	local shortestDistance = math.huge

	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		if not char or not char:FindFirstChild("HumanoidRootPart") then continue end

		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			local dist = (char.HumanoidRootPart.Position - self.PrimaryPart.Position).Magnitude
			if dist < shortestDistance then
				shortestDistance = dist
				nearestTarget = char.HumanoidRootPart
			end
		end
	end

	if nearestTarget then
		self.Target = nearestTarget
		self.Distance = shortestDistance

		-- Add a slight random offset to movement for a more natural look
		local offset = Vector3.new(math.random(-2, 2), 0, math.random(-2, 2))
		self.TargetPosition = nearestTarget.Position + offset

		self:MoveToTarget()
	end
end

--- Handles area-of-effect (AoE) attack logic
function ZombieAI:Attack()
	if os.clock() - self.LastAttack < 1.5 then return end -- Attack debounce

	self.LastAttack = os.clock()
	self:PlaySound("Attack")
	if self.Animations["Attack"] then self.Animations["Attack"]:Play() end

	-- Delay the damage logic to sync with the animation's "impact" frame
	task.delay(0.3, function()
		local hitBoxPos = self.PrimaryPart.CFrame * CFrame.new(0, 0, -2)
		local parts = workspace:GetPartBoundsInBox(hitBoxPos, Vector3.new(4, 5, 4), overlapParams)
		local damagedUnits = {}

		for _, part in parts do
			local hum = part.Parent:FindFirstChildOfClass("Humanoid")
			if hum and not damagedUnits[hum] and hum.Health > 0 then
				damagedUnits[hum] = true
				hum:TakeDamage(self.Info.Damage or 10)
			end
		end
	end)
end

--- Commands the Humanoid to move and triggers jump/attack logic
function ZombieAI:MoveToTarget()
	if not self.Target:IsDescendantOf(workspace) then 
		self.Humanoid:MoveTo(self.PrimaryPart.Position)
		self.Animations["Idle"]:Play()
		self.Animations["Running"]:Stop()
		return
	end
	
	self.Humanoid:MoveTo(self.TargetPosition)

	-- Jump if an obstacle is in front
	if self:CheckForObstacles() then
		self.Humanoid.Jump = true
	end

	-- Trigger attack if within range
	if self.Distance <= 6 then
		self:Attack()
	end
end

--- Constructor: Initializes a new Zombie AI instance
function ZombieAI.New(zombie)
	local self = setmetatable({}, ZombieAI)

	self.Model = zombie
	self.PrimaryPart = zombie.PrimaryPart
	self.Humanoid = zombie:FindFirstChildOfClass("Humanoid")
	self.Info = table.clone(infoZombies[zombie.Name])

	self.LastPathUpdate = 0
	self.LastAttack = 0
	self.CurrentHealth = self.Humanoid.Health
	self.Animations = {}

	self:Setup()
	return self
end

-- Main Update Loop (Heartbeat runs every frame on the server)
runService.Heartbeat:Connect(function()
	local currentTime = os.clock()

	for i = #AliveZombies, 1, -1 do
		local zombie = AliveZombies[i]

		-- Clean up tracking table if zombie is destroyed or dead
		if not zombie.Model or not zombie.Model.Parent or zombie.Humanoid.Health <= 0 then
			table.remove(AliveZombies, i)
			continue
		end

		-- Periodic pathfinding update
		if currentTime - zombie.LastPathUpdate >= MAX_UPDATE_TIME then
			zombie:FindTarget()
			zombie.LastPathUpdate = currentTime
		end
	end
end)

return ZombieAI
