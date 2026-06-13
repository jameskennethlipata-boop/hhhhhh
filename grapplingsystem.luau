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
local PLAYER_CONTROL = 75
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
	
	-- smooth interpolation toward desired length instead of instant changes
	hook.currentRopeLength = 0
	hook.desiredRopeLength = 0
	
	-- tracking velocity manually because we need to apply custom forces
	hook.vel = Vector3.new()
	
	-- modern constraint objects, replacing deprecated BodyVelocity/BodyGyro
	hook.linearVel = nil
	hook.alignOrientation = nil
	hook.attachment = nil
	
	hook.ropePart = nil
	hook.targetIndicator = nil
	hook.targetPos = nil
	
	-- manual input tracking because Humanoid.MoveDirection doesn't work in PlatformStand
	hook.keysDown = {w = false, a = false, s = false, d = false}
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
			
			-- pulsing effect makes target more visible
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

-- tracks input states manually for reliable simultaneous key detection
function GrappleHook:bindInputs()
	local conn1 = UIS.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- toggle grapple on click
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
	
	-- preserve current velocity with slight boost instead of killing momentum
	self.vel = self.hrp.AssemblyLinearVelocity * BOOST_ON_ATTACH
	
	self:startPhysics()
	self:makeRope()
end

-- releases grapple and returns control to humanoid
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
	
	-- LinearVelocity replaces deprecated BodyVelocity
	self.linearVel = Instance.new("LinearVelocity")
	self.linearVel.Attachment0 = self.attachment
	self.linearVel.MaxForce = math.huge
	self.linearVel.VectorVelocity = self.vel
	self.linearVel.RelativeTo = Enum.ActuatorRelativeTo.World
	self.linearVel.Parent = self.hrp
	
	-- keeps character upright during swings instead of tumbling
	self.alignOrientation = Instance.new("AlignOrientation")
	self.alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	self.alignOrientation.Attachment0 = self.attachment
	self.alignOrientation.MaxTorque = 9e5
	self.alignOrientation.Responsiveness = 50
	self.alignOrientation.CFrame = self.hrp.CFrame
	self.alignOrientation.RigidityEnabled = false
	self.alignOrientation.Parent = self.hrp
	
	-- disables humanoid physics so it doesn't fight our custom forces
	self.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	self.humanoid.PlatformStand = true
end

-- restores normal physics and preserves velocity for momentum chaining
function GrappleHook:stopPhysics()
	if self.linearVel then
		self.hrp.AssemblyLinearVelocity = self.vel
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

-- converts WASD to camera-relative direction, flattened to horizontal plane
function GrappleHook:getInputDirection()
	local cam = workspace.CurrentCamera
	local camForward = cam.CFrame.LookVector
	local camRight = cam.CFrame.RightVector
	
	local flatForward = Vector3.new(camForward.X, 0, camForward.Z)
	local flatRight = Vector3.new(camRight.X, 0, camRight.Z)
	
	-- safe normalization - if looking straight up/down, use fallback direction to prevent errors
	if flatForward.Magnitude < 0.01 then
		flatForward = Vector3.new(0, 0, -1)
	else
		flatForward = flatForward.Unit
	end
	
	if flatRight.Magnitude < 0.01 then
		flatRight = Vector3.new(1, 0, 0)
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

-- main physics loop. doing custom physics instead of RopeConstraint because I need precise control over feel
function GrappleHook:physicsStep(dt)
	if not self.isGrappling or not self.grapplePoint then return end
	
	local pos = self.hrp.Position
	local toGrapple = self.grapplePoint - pos
	local ropeDir = toGrapple.Unit
	local dist = toGrapple.Magnitude
	
	-- reeling mechanic
	if self.isReeling then
		self.desiredRopeLength = math.max(self.desiredRopeLength - REEL_SPEED, 3)
	end
	
	-- smooth interpolation toward desired length instead of instant change
	self.currentRopeLength = self.currentRopeLength + (self.desiredRopeLength - self.currentRopeLength) * 0.15
	
	-- gravity
	self.vel = self.vel + Vector3.new(0, -GRAVITY, 0) * dt
	
	-- rope constraint using spring physics
	if dist > self.currentRopeLength then
		local stretch = dist - self.currentRopeLength
		
		-- hooke's law (F = kx)
		local springForce = ropeDir * stretch * ROPE_SPRING
		self.vel = self.vel + springForce * dt
		
		-- cancel velocity moving away from anchor to prevent infinite stretching
		local velocityToward = self.vel:Dot(ropeDir)
		if velocityToward < 0 then
			self.vel = self.vel - ropeDir * velocityToward * 1.2
		end
		
		-- centripetal acceleration for circular motion (v²/r)
		local perpVel = self.vel - (self.vel:Dot(ropeDir) * ropeDir)
		local centripetal = perpVel.Magnitude * perpVel.Magnitude / self.currentRopeLength
		self.vel = self.vel + ropeDir * centripetal * dt
	end
	
	-- player control - WASD applies force mid-swing
	local inputDir = self:getInputDirection()
	if inputDir.Magnitude > 0 then
		local radial = self.vel:Dot(ropeDir) * ropeDir
		local tangent = self.vel - radial
		local controlForce = inputDir * PLAYER_CONTROL
		
		-- boost control when moving with the swing instead of against it
		if tangent.Magnitude > 5 then
			local swingDir = tangent.Unit
			local matchAmount = math.abs(inputDir:Dot(swingDir))
			controlForce = controlForce * (1 + matchAmount * SWING_MULTIPLIER)
		end
		
		self.vel = self.vel + controlForce * dt
	end
	
	-- quadratic air drag
	local speed = self.vel.Magnitude
	if speed > 0 then
		local dragAmount = speed * speed * 0.0003
		self.vel = self.vel - self.vel.Unit * dragAmount * dt
	end
	
	self.vel = self.vel * AIR_RESISTANCE
	
	-- velocity cap to prevent physics instability
	if self.vel.Magnitude > MAX_VELOCITY then
		self.vel = self.vel.Unit * MAX_VELOCITY
	end
	
	self.linearVel.VectorVelocity = self.vel
	
	-- face movement direction
	local flatVel = Vector3.new(self.vel.X, 0, self.vel.Z)
	if flatVel.Magnitude > 2 then
		self.alignOrientation.CFrame = CFrame.lookAt(pos, pos + flatVel)
	end
end

-- creates rope visual
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

-- stretches rope part between player and anchor point. using Part instead of Beam for performance
function GrappleHook:updateRope()
	if not self.isGrappling or not self.ropePart or not self.grapplePoint then return end
	
	local startPt = self.hrp.Position + Vector3.new(0, 2, 0)
	local endPt = self.grapplePoint
	local length = (endPt - startPt).Magnitude
	local ropeCF = CFrame.lookAt(startPt, endPt)
	self.ropePart.CFrame = ropeCF * CFrame.new(0, 0, -length / 2)
	self.ropePart.Size = Vector3.new(ROPE_THICKNESS, ROPE_THICKNESS, length)
end

-- cleans up rope visual
function GrappleHook:destroyRope()
	if self.ropePart then
		self.ropePart:Destroy()
		self.ropePart = nil
	end
end

-- routes updates to physics or indicator depending on state
function GrappleHook:tick(dt)
	if self.isGrappling then
		self:physicsStep(dt)
		self:updateRope()
	else
		self:updateIndicator()
	end
end

-- connects heartbeat loop
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
