-- made by @zavenx
-- grappling hook with rope physics
-- honestly spent way too long tuning the swing feel lol

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

-- settings i tweaked until it felt right
local MAX_GRAPPLE_DIST = 300
local MIN_DIST = 10
local REEL_SPEED = 10
local GRAVITY = 196.2
local ROPE_SPRING = 1400 -- had to bump this up, was too loose before
local AIR_RESISTANCE = 0.994
local MAX_VELOCITY = 220
local PLAYER_CONTROL = 75
local SWING_MULTIPLIER = 2.8
local BOOST_ON_ATTACH = 1.08

-- visuals
local ROPE_THICKNESS = 0.22
local ROPE_COL = Color3.fromRGB(200, 220, 240)
local INDICATOR_COL = Color3.fromRGB(100, 255, 150)
local INDICATOR_SIZE = 1.2

local GrappleHook = {}
GrappleHook.__index = GrappleHook

function GrappleHook.new(char)
	local hook = setmetatable({}, GrappleHook)

	hook.character = char
	hook.humanoid = char:WaitForChild("Humanoid")
	hook.hrp = char:WaitForChild("HumanoidRootPart")

	hook.isGrappling = false
	hook.grapplePoint = nil
	hook.currentRopeLength = 0
	hook.desiredRopeLength = 0
	hook.vel = Vector3.new()

	-- constraints for controlling physics
	hook.bv = nil
	hook.bg = nil

	hook.ropePart = nil
	hook.targetIndicator = nil
	hook.targetPos = nil

	-- track inputs manually because humanoid.MoveDirection was inconsistent
	hook.keysDown = {w = false, a = false, s = false, d = false}
	hook.isReeling = false

	hook.connections = {}

	hook:makeIndicator()
	hook:bindInputs()

	return hook
end

function GrappleHook:makeIndicator()
	local ind = Instance.new("Part")
	ind.Name = "TargetIndicator"
	ind.Size = Vector3.new(INDICATOR_SIZE, INDICATOR_SIZE, INDICATOR_SIZE)
	ind.Shape = Enum.PartType.Ball
	ind.Material = Enum.Material.Neon
	ind.Color = INDICATOR_COL
	ind.Transparency = 0.4
	ind.Anchored = true
	ind.CanCollide = false
	ind.Parent = workspace
	self.targetIndicator = ind
end

function GrappleHook:updateIndicator()
	if self.isGrappling then
		self.targetIndicator.Transparency = 1
		return
	end

	local mouse = Players.LocalPlayer:GetMouse()
	local camera = workspace.CurrentCamera

	local screenRay = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local rayOrigin = screenRay.Origin
	local rayDir = screenRay.Direction * MAX_GRAPPLE_DIST

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {self.character, self.targetIndicator}
	params.FilterType = Enum.RaycastFilterType.Exclude

	local hit = workspace:Raycast(rayOrigin, rayDir, params)

	if hit then
		local distance = (hit.Position - self.hrp.Position).Magnitude

		if distance >= MIN_DIST and distance <= MAX_GRAPPLE_DIST then
			self.targetPos = hit.Position
			self.targetIndicator.Position = hit.Position
			self.targetIndicator.Transparency = 0.3

			-- little pulse effect
			local pulseAmount = 0.85 + math.sin(tick() * 8) * 0.15
			self.targetIndicator.Size = Vector3.new(INDICATOR_SIZE, INDICATOR_SIZE, INDICATOR_SIZE) * pulseAmount
		else
			self.targetIndicator.Transparency = 1
			self.targetPos = nil
		end
	else
		self.targetIndicator.Transparency = 1
		self.targetPos = nil
	end
end

function GrappleHook:bindInputs()
	local conn1 = UIS.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if self.isGrappling then
				self:detachGrapple()
			else
				self:fireGrapple()
			end
		elseif input.KeyCode == Enum.KeyCode.W then
			self.keysDown.w = true
		elseif input.KeyCode == Enum.KeyCode.A then
			self.keysDown.a = true
		elseif input.KeyCode == Enum.KeyCode.S then
			self.keysDown.s = true
		elseif input.KeyCode == Enum.KeyCode.D then
			self.keysDown.d = true
		elseif input.KeyCode == Enum.KeyCode.Space and self.isGrappling then
			self.isReeling = true
		end
	end)

	local conn2 = UIS.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.W then
			self.keysDown.w = false
		elseif input.KeyCode == Enum.KeyCode.A then
			self.keysDown.a = false
		elseif input.KeyCode == Enum.KeyCode.S then
			self.keysDown.s = false
		elseif input.KeyCode == Enum.KeyCode.D then
			self.keysDown.d = false
		elseif input.KeyCode == Enum.KeyCode.Space then
			self.isReeling = false
		end
	end)

	table.insert(self.connections, conn1)
	table.insert(self.connections, conn2)
end

function GrappleHook:fireGrapple()
	if self.isGrappling or not self.targetPos then return end

	local dist = (self.targetPos - self.hrp.Position).Magnitude
	if dist < MIN_DIST or dist > MAX_GRAPPLE_DIST then return end

	self.isGrappling = true
	self.grapplePoint = self.targetPos
	self.currentRopeLength = dist
	self.desiredRopeLength = dist

	-- keep momentum from before grappling
	self.vel = self.hrp.AssemblyLinearVelocity * BOOST_ON_ATTACH

	self:startPhysics()
	self:makeRope()
end

function GrappleHook:detachGrapple()
	if not self.isGrappling then return end

	self.isGrappling = false
	self.grapplePoint = nil
	self.isReeling = false

	self:stopPhysics()
	self:destroyRope()
end

function GrappleHook:startPhysics()
	-- need bodyvelocity to override default physics
	self.bv = Instance.new("BodyVelocity")
	self.bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	self.bv.P = 10000
	self.bv.Velocity = self.vel
	self.bv.Parent = self.hrp

	-- bodygyro keeps player upright while swinging
	self.bg = Instance.new("BodyGyro")
	self.bg.MaxTorque = Vector3.new(9e5, 9e5, 9e5)
	self.bg.P = 3000
	self.bg.D = 500
	self.bg.CFrame = self.hrp.CFrame
	self.bg.Parent = self.hrp

	self.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	self.humanoid.PlatformStand = true
end

function GrappleHook:stopPhysics()
	if self.bv then
		-- keep velocity when letting go
		self.hrp.AssemblyLinearVelocity = self.vel
		self.bv:Destroy()
		self.bv = nil
	end

	if self.bg then
		self.bg:Destroy()
		self.bg = nil
	end

	self.humanoid.PlatformStand = false
	self.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
end

-- figure out where player wants to move based on camera
function GrappleHook:getInputDirection()
	local cam = workspace.CurrentCamera
	local camForward = cam.CFrame.LookVector
	local camRight = cam.CFrame.RightVector

	-- flatten to ground plane
	camForward = Vector3.new(camForward.X, 0, camForward.Z).Unit
	camRight = Vector3.new(camRight.X, 0, camRight.Z).Unit

	local moveVec = Vector3.new()

	if self.keysDown.w then moveVec = moveVec + camForward end
	if self.keysDown.s then moveVec = moveVec - camForward end
	if self.keysDown.a then moveVec = moveVec - camRight end
	if self.keysDown.d then moveVec = moveVec + camRight end

	if moveVec.Magnitude > 0 then
		return moveVec.Unit
	end
	return Vector3.new()
end

function GrappleHook:physicsStep(dt)
	if not self.isGrappling or not self.grapplePoint then return end

	local pos = self.hrp.Position
	local toGrapple = self.grapplePoint - pos
	local ropeDir = toGrapple.Unit
	local dist = toGrapple.Magnitude

	-- pulling in rope
	if self.isReeling then
		self.desiredRopeLength = math.max(self.desiredRopeLength - REEL_SPEED, 3)
	end

	self.currentRopeLength = self.currentRopeLength + (self.desiredRopeLength - self.currentRopeLength) * 0.15

	-- gravity always pulling down
	self.vel = self.vel + Vector3.new(0, -GRAVITY, 0) * dt

	-- rope constraint keeps player from going past max length
	if dist > self.currentRopeLength then
		local stretch = dist - self.currentRopeLength

		-- spring force pulls back when rope stretches
		local springForce = ropeDir * stretch * ROPE_SPRING
		self.vel = self.vel + springForce * dt

		-- if moving away from anchor, cancel that velocity
		local velocityToward = self.vel:Dot(ropeDir)
		if velocityToward < 0 then
			self.vel = self.vel - ropeDir * velocityToward * 1.2
		end

		-- centripetal force - this is what makes it swing in an arc instead of falling straight
		-- basically F = mv²/r
		local perpVel = self.vel - (self.vel:Dot(ropeDir) * ropeDir)
		local centripetal = perpVel.Magnitude * perpVel.Magnitude / self.currentRopeLength
		self.vel = self.vel + ropeDir * centripetal * dt
	end

	-- player control
	local inputDir = self:getInputDirection()

	if inputDir.Magnitude > 0 then
		local radial = self.vel:Dot(ropeDir) * ropeDir
		local tangent = self.vel - radial

		local controlForce = inputDir * PLAYER_CONTROL

		-- boost when moving with the swing direction
		if tangent.Magnitude > 5 then
			local swingDir = tangent.Unit
			local matchAmount = math.abs(inputDir:Dot(swingDir))
			controlForce = controlForce * (1 + matchAmount * SWING_MULTIPLIER)
		end

		self.vel = self.vel + controlForce * dt
	end

	-- air drag slows you down over time (v² drag is more realistic)
	local speed = self.vel.Magnitude
	if speed > 0 then
		local dragAmount = speed * speed * 0.0003
		self.vel = self.vel - self.vel.Unit * dragAmount * dt
	end

	self.vel = self.vel * AIR_RESISTANCE

	-- cap speed
	if self.vel.Magnitude > MAX_VELOCITY then
		self.vel = self.vel.Unit * MAX_VELOCITY
	end

	self.bv.Velocity = self.vel

	-- rotate character to face where they're going
	local flatVel = Vector3.new(self.vel.X, 0, self.vel.Z)
	if flatVel.Magnitude > 2 then
		self.bg.CFrame = CFrame.lookAt(pos, pos + flatVel)
	end
end

function GrappleHook:makeRope()
	local rope = Instance.new("Part")
	rope.Name = "Rope"
	rope.Material = Enum.Material.Neon
	rope.Color = ROPE_COL
	rope.Anchored = true
	rope.CanCollide = false
	rope.CastShadow = false
	rope.Parent = workspace
	self.ropePart = rope
end

function GrappleHook:updateRope()
	if not self.isGrappling or not self.ropePart or not self.grapplePoint then return end

	local startPt = self.hrp.Position + Vector3.new(0, 2, 0)
	local endPt = self.grapplePoint
	local length = (endPt - startPt).Magnitude

	local ropeCF = CFrame.lookAt(startPt, endPt)
	self.ropePart.CFrame = ropeCF * CFrame.new(0, 0, -length / 2)
	self.ropePart.Size = Vector3.new(ROPE_THICKNESS, ROPE_THICKNESS, length)
end

function GrappleHook:destroyRope()
	if self.ropePart then
		self.ropePart:Destroy()
		self.ropePart = nil
	end
end

function GrappleHook:tick(dt)
	if self.isGrappling then
		self:physicsStep(dt)
		self:updateRope()
	else
		self:updateIndicator()
	end
end

function GrappleHook:init()
	local tickConn = RunService.Heartbeat:Connect(function(dt)
		self:tick(dt)
	end)
	table.insert(self.connections, tickConn)
end

function GrappleHook:destroy()
	for _, conn in ipairs(self.connections) do
		conn:Disconnect()
	end

	if self.isGrappling then
		self:detachGrapple()
	end

	if self.targetIndicator then
		self.targetIndicator:Destroy()
	end

	setmetatable(self, nil)
end

-- setup
local plr = Players.LocalPlayer
local char = plr.Character or plr.CharacterAdded:Wait()
local hum = char:WaitForChild("Humanoid")

task.wait(0.2)

local hook = GrappleHook.new(char)
hook:init()

hum.Died:Connect(function()
	hook:destroy()
end)

plr.CharacterAdded:Connect(function(newChar)
	task.wait(0.2)
	char = newChar
	hum = newChar:WaitForChild("Humanoid")
	hook = GrappleHook.new(newChar)
	hook:init()
end)

return GrappleHook
