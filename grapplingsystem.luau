-- made by @zavenx
-- grappling hook with rope physics using modern constraint system

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

-- tuning constants - exposed here so I can tweak feel without digging through code
local MAX_GRAPPLE_DIST = 300
local MIN_DIST = 10
local REEL_SPEED = 10
local GRAVITY = 196.2
local ROPE_SPRING = 1400 -- went with spring-based rope over rigid constraint because slight stretch feels more natural
local AIR_RESISTANCE = 0.994 -- prevents infinite acceleration on repeated swings
local MAX_VELOCITY = 220 -- roblox physics breaks above ~250 studs/s
local PLAYER_CONTROL = 75 -- balance between responsive and physics-driven
local SWING_MULTIPLIER = 2.8 -- rewards building momentum in one direction
local BOOST_ON_ATTACH = 1.08 -- preserves running speed when you grapple, feels way better than zeroing velocity

local ROPE_THICKNESS = 0.22
local ROPE_COL = Color3.fromRGB(200, 220, 240)
local INDICATOR_COL = Color3.fromRGB(100, 255, 150)
local INDICATOR_SIZE = 1.2

local GrappleHook = {}
GrappleHook.__index = GrappleHook

-- using OOP because each player needs independent grapple state, makes respawns cleaner
function GrappleHook.new(char)
	local hook = setmetatable({}, GrappleHook)

	hook.character = char
	hook.humanoid = char:WaitForChild("Humanoid")
	hook.hrp = char:WaitForChild("HumanoidRootPart")
	hook.isGrappling = false
	hook.grapplePoint = nil
	hook.currentRopeLength = 0 -- smoothly interpolates toward desired length instead of instant changes
	hook.desiredRopeLength = 0
	hook.vel = Vector3.new() -- tracking velocity manually because we need to apply custom forces, can't just read AssemblyLinearVelocity
	hook.linearVel = nil -- modern replacement for deprecated BodyVelocity, better replication
	hook.alignOrientation = nil -- keeps character upright during swings
	hook.attachment = nil
	hook.ropePart = nil
	hook.targetIndicator = nil
	hook.targetPos = nil
	hook.keysDown = {w = false, a = false, s = false, d = false} -- manual tracking because Humanoid.MoveDirection doesn't work in PlatformStand
	hook.isReeling = false
	hook.connections = {}

	hook:makeIndicator()
	hook:bindInputs()

	return hook
end

-- visual indicator so players can see where they're aiming before shooting
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

-- raycasts from camera through mouse to find valid grapple points
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
			local pulseAmount = 0.85 + math.sin(tick() * 8) * 0.15 -- pulsing makes target more visible
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

-- tracks input states manually for reliable simultaneous key detection
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

-- initiates grapple and transitions to custom physics mode
function GrappleHook:fireGrapple()
	if self.isGrappling or not self.targetPos then return end

	local dist = (self.targetPos - self.hrp.Position).Magnitude
	if dist < MIN_DIST or dist > MAX_GRAPPLE_DIST then return end

	self.isGrappling = true
	self.grapplePoint = self.targetPos
	self.currentRopeLength = dist
	self.desiredRopeLength = dist
	self.vel = self.hrp.AssemblyLinearVelocity * BOOST_ON_ATTACH -- preserves momentum instead of killing your speed

	self:startPhysics()
	self:makeRope()
end

-- releases grapple and returns to normal humanoid physics
function GrappleHook:detachGrapple()
	if not self.isGrappling then return end

	self.isGrappling = false
	self.grapplePoint = nil
	self.isReeling = false

	self:stopPhysics()
	self:destroyRope()
end

-- enables custom physics using modern constraints, overrides humanoid movement
function GrappleHook:startPhysics()
	self.attachment = Instance.new("Attachment")
	self.attachment.Parent = self.hrp

	self.linearVel = Instance.new("LinearVelocity") -- modern API requires attachment anchor point
	self.linearVel.Attachment0 = self.attachment
	self.linearVel.MaxForce = math.huge
	self.linearVel.VectorVelocity = self.vel
	self.linearVel.RelativeTo = Enum.ActuatorRelativeTo.World
	self.linearVel.Parent = self.hrp

	self.alignOrientation = Instance.new("AlignOrientation") -- prevents character from tumbling during swings
	self.alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	self.alignOrientation.Attachment0 = self.attachment
	self.alignOrientation.MaxTorque = 9e5
	self.alignOrientation.Responsiveness = 50
	self.alignOrientation.CFrame = self.hrp.CFrame
	self.alignOrientation.RigidityEnabled = false
	self.alignOrientation.Parent = self.hrp

	self.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	self.humanoid.PlatformStand = true -- disables default humanoid physics so it doesn't fight our forces
end

-- restores normal physics and preserves velocity for momentum chaining
function GrappleHook:stopPhysics()
	if self.linearVel then
		self.hrp.AssemblyLinearVelocity = self.vel -- apply velocity before destroying constraint
		self.linearVel:Destroy()
		self.linearVel = nil
	end

	if self.alignOrientation then
		self.alignOrientation:Destroy()
		self.alignOrientation = nil
	end

	if self.attachment then
		self.attachment:Destroy()
		self.attachment = nil
	end

	self.humanoid.PlatformStand = false
	self.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
end

-- converts wasd to camera-relative direction, flattened to horizontal plane
function GrappleHook:getInputDirection()
	local cam = workspace.CurrentCamera
	local camForward = cam.CFrame.LookVector
	local camRight = cam.CFrame.RightVector

	-- flatten to horizontal plane
	local flatForward = Vector3.new(camForward.X, 0, camForward.Z)
	local flatRight = Vector3.new(camRight.X, 0, camRight.Z)

	-- safe normalization - if looking straight up/down, use fallback direction
	if flatForward.Magnitude < 0.01 then
		flatForward = Vector3.new(0, 0, -1) -- default to negative Z when camera is vertical
	else
		flatForward = flatForward.Unit
	end

	if flatRight.Magnitude < 0.01 then
		flatRight = Vector3.new(1, 0, 0) -- default to positive X
	else
		flatRight = flatRight.Unit
	end

	local moveVec = Vector3.new()
	if self.keysDown.w then moveVec = moveVec + flatForward end
	if self.keysDown.s then moveVec = moveVec - flatForward end
	if self.keysDown.a then moveVec = moveVec - flatRight end
	if self.keysDown.d then moveVec = moveVec + flatRight end

	if moveVec.Magnitude > 0 then
		return moveVec.Unit
	end
	return Vector3.new()
end

-- main physics loop, runs every frame while grappling. doing custom physics instead of RopeConstraint because I need precise control over feel
function GrappleHook:physicsStep(dt)
	if not self.isGrappling or not self.grapplePoint then return end

	local pos = self.hrp.Position
	local toGrapple = self.grapplePoint - pos
	local ropeDir = toGrapple.Unit
	local dist = toGrapple.Magnitude

	if self.isReeling then
		self.desiredRopeLength = math.max(self.desiredRopeLength - REEL_SPEED, 3)
	end

	self.currentRopeLength = self.currentRopeLength + (self.desiredRopeLength - self.currentRopeLength) * 0.15 -- smooth interpolation

	self.vel = self.vel + Vector3.new(0, -GRAVITY, 0) * dt -- gravity

	if dist > self.currentRopeLength then
		local stretch = dist - self.currentRopeLength
		local springForce = ropeDir * stretch * ROPE_SPRING -- hooke's law F=kx
		self.vel = self.vel + springForce * dt

		local velocityToward = self.vel:Dot(ropeDir)
		if velocityToward < 0 then
			self.vel = self.vel - ropeDir * velocityToward * 1.2 -- cancel outward velocity to prevent infinite stretch
		end

		local perpVel = self.vel - (self.vel:Dot(ropeDir) * ropeDir) -- tangential velocity component
		local centripetal = perpVel.Magnitude * perpVel.Magnitude / self.currentRopeLength -- v²/r for circular motion
		self.vel = self.vel + ropeDir * centripetal * dt
	end

	local inputDir = self:getInputDirection()
	if inputDir.Magnitude > 0 then
		local radial = self.vel:Dot(ropeDir) * ropeDir
		local tangent = self.vel - radial
		local controlForce = inputDir * PLAYER_CONTROL

		if tangent.Magnitude > 5 then
			local swingDir = tangent.Unit
			local matchAmount = math.abs(inputDir:Dot(swingDir))
			controlForce = controlForce * (1 + matchAmount * SWING_MULTIPLIER) -- bonus when moving with the swing
		end

		self.vel = self.vel + controlForce * dt
	end

	local speed = self.vel.Magnitude
	if speed > 0 then
		local dragAmount = speed * speed * 0.0003 -- quadratic drag
		self.vel = self.vel - self.vel.Unit * dragAmount * dt
	end

	self.vel = self.vel * AIR_RESISTANCE

	if self.vel.Magnitude > MAX_VELOCITY then
		self.vel = self.vel.Unit * MAX_VELOCITY -- cap to prevent physics breakage
	end

	self.linearVel.VectorVelocity = self.vel

	local flatVel = Vector3.new(self.vel.X, 0, self.vel.Z)
	if flatVel.Magnitude > 2 then
		self.alignOrientation.CFrame = CFrame.lookAt(pos, pos + flatVel) -- face movement direction
	end
end

-- creates visual rope part
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

-- updates rope to stretch between player and grapple point, using Part instead of Beam for performance
function GrappleHook:updateRope()
	if not self.isGrappling or not self.ropePart or not self.grapplePoint then return end

	local startPt = self.hrp.Position + Vector3.new(0, 2, 0) -- offset so it looks like it's from hand
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

-- main update loop
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

-- cleanup to prevent memory leaks on respawn
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

local plr = Players.LocalPlayer
local char = plr.Character or plr.CharacterAdded:Wait()
local hum = char:WaitForChild("Humanoid")

task.wait(0.2) -- small delay to ensure character is fully loaded

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
