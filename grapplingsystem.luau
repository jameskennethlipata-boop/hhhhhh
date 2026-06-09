-- made by @zavenx
-- grappling hook with rope physics
-- uses modern roblox constraint system with linearvelocity and alignorientation

-- services section
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

-- tuning settings section
-- these control how the grapple feels during gameplay
local MAX_GRAPPLE_DIST = 300 -- max distance you can shoot the hook
local MIN_DIST = 10 -- prevents grappling too close to yourself
local REEL_SPEED = 10 -- how fast space bar pulls you in
local GRAVITY = 196.2 -- studs/s² gravity acceleration (roblox default)
local ROPE_SPRING = 1400 -- spring constant for rope tension, higher = tighter rope that resists stretching
local AIR_RESISTANCE = 0.994 -- multiplier per frame, simulates air drag to prevent infinite acceleration
local MAX_VELOCITY = 220 -- velocity cap to prevent physics from breaking at extreme speeds
local PLAYER_CONTROL = 75 -- base force applied when pressing wasd mid-swing
local SWING_MULTIPLIER = 2.8 -- bonus multiplier when moving with the swing direction instead of against it
local BOOST_ON_ATTACH = 1.08 -- multiplies your current velocity when hook connects to give initial momentum

-- visual settings section
local ROPE_THICKNESS = 0.22
local ROPE_COL = Color3.fromRGB(200, 220, 240)
local INDICATOR_COL = Color3.fromRGB(100, 255, 150)
local INDICATOR_SIZE = 1.2

-- main class section
local GrappleHook = {}
GrappleHook.__index = GrappleHook

-- creates new grapple hook instance for a character
-- sets up all the physics objects and input tracking we need
function GrappleHook.new(char)
	local hook = setmetatable({}, GrappleHook)
	
	hook.character = char
	hook.humanoid = char:WaitForChild("Humanoid")
	hook.hrp = char:WaitForChild("HumanoidRootPart")
	
	hook.isGrappling = false
	hook.grapplePoint = nil
	hook.currentRopeLength = 0
	hook.desiredRopeLength = 0
	hook.vel = Vector3.new() -- tracks velocity manually because we override default physics
	
	-- modern physics constraints that replace deprecated bodyvelocity/bodygyro
	hook.linearVel = nil
	hook.alignOrientation = nil
	hook.attachment = nil -- needed for the new constraint system
	
	hook.ropePart = nil
	hook.targetIndicator = nil
	hook.targetPos = nil
	
	-- manual input tracking because humanoid.MoveDirection doesn't work well with platformstand
	hook.keysDown = {w = false, a = false, s = false, d = false}
	hook.isReeling = false
	
	hook.connections = {}
	
	hook:makeIndicator()
	hook:bindInputs()
	
	return hook
end

-- creates the visual indicator that shows where your hook will attach
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

-- updates indicator position and visibility based on mouse raycast
-- only shows indicator when aiming at valid grapple point
function GrappleHook:updateIndicator()
	if self.isGrappling then
		self.targetIndicator.Transparency = 1
		return
	end
	
	local mouse = Players.LocalPlayer:GetMouse()
	local camera = workspace.CurrentCamera
	
	-- raycast from camera through mouse position
	local screenRay = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local rayOrigin = screenRay.Origin
	local rayDir = screenRay.Direction * MAX_GRAPPLE_DIST
	
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {self.character, self.targetIndicator}
	params.FilterType = Enum.RaycastFilterType.Exclude
	
	local hit = workspace:Raycast(rayOrigin, rayDir, params)
	
	if hit then
		local distance = (hit.Position - self.hrp.Position).Magnitude
		
		-- only show indicator if hit is within valid range
		if distance >= MIN_DIST and distance <= MAX_GRAPPLE_DIST then
			self.targetPos = hit.Position
			self.targetIndicator.Position = hit.Position
			self.targetIndicator.Transparency = 0.3
			
			-- adds a pulsing effect so it's easier to see
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

-- binds all input controls for grappling and movement
-- tracks key states manually so we can read them during physics updates
function GrappleHook:bindInputs()
	local conn1 = UIS.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- left click toggles grapple on/off
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

-- shoots the grapple hook to current target position
-- initializes rope physics and takes over character movement
function GrappleHook:fireGrapple()
	if self.isGrappling or not self.targetPos then return end
	
	local dist = (self.targetPos - self.hrp.Position).Magnitude
	if dist < MIN_DIST or dist > MAX_GRAPPLE_DIST then return end
	
	self.isGrappling = true
	self.grapplePoint = self.targetPos
	self.currentRopeLength = dist
	self.desiredRopeLength = dist
	
	-- preserve current velocity and boost it slightly for better feel
	self.vel = self.hrp.AssemblyLinearVelocity * BOOST_ON_ATTACH
	
	self:startPhysics()
	self:makeRope()
end

-- releases the grapple and returns control to normal character physics
function GrappleHook:detachGrapple()
	if not self.isGrappling then return end
	
	self.isGrappling = false
	self.grapplePoint = nil
	self.isReeling = false
	
	self:stopPhysics()
	self:destroyRope()
end

-- enables custom physics mode using modern constraint system
-- we need linearvelocity to control movement and alignorientation to keep player upright
function GrappleHook:startPhysics()
	-- create attachment point on hrp for constraints to use
	self.attachment = Instance.new("Attachment")
	self.attachment.Parent = self.hrp
	
	-- linearvelocity replaces the old deprecated bodyvelocity
	-- it applies velocity relative to world space through the attachment
	self.linearVel = Instance.new("LinearVelocity")
	self.linearVel.Attachment0 = self.attachment
	self.linearVel.MaxForce = math.huge
	self.linearVel.VectorVelocity = self.vel
	self.linearVel.RelativeTo = Enum.ActuatorRelativeTo.World
	self.linearVel.Parent = self.hrp
	
	-- alignorientation replaces the old deprecated bodygyro
	-- keeps the character facing forward and upright during swing
	self.alignOrientation = Instance.new("AlignOrientation")
	self.alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	self.alignOrientation.Attachment0 = self.attachment
	self.alignOrientation.MaxTorque = 9e5
	self.alignOrientation.Responsiveness = 50
	self.alignOrientation.CFrame = self.hrp.CFrame
	self.alignOrientation.RigidityEnabled = false
	self.alignOrientation.Parent = self.hrp
	
	-- physics state prevents normal humanoid movement from interfering
	self.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	self.humanoid.PlatformStand = true
end

-- disables custom physics and returns to normal humanoid control
-- preserves velocity so you keep momentum after releasing hook
function GrappleHook:stopPhysics()
	if self.linearVel then
		-- apply our calculated velocity to the character before destroying constraints
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

-- converts wasd input to world space direction vector based on camera orientation
-- this lets you swing in the direction you're looking instead of relative to character
function GrappleHook:getInputDirection()
	local cam = workspace.CurrentCamera
	local camForward = cam.CFrame.LookVector
	local camRight = cam.CFrame.RightVector
	
	-- flatten vectors to horizontal plane so input doesn't affect vertical movement
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

-- main physics update that runs every frame while grappling
-- handles gravity, rope constraint, swinging mechanics, and player control
function GrappleHook:physicsStep(dt)
	if not self.isGrappling or not self.grapplePoint then return end
	
	local pos = self.hrp.Position
	local toGrapple = self.grapplePoint - pos
	local ropeDir = toGrapple.Unit
	local dist = toGrapple.Magnitude
	
	-- reeling mechanic shortens rope when holding space
	if self.isReeling then
		self.desiredRopeLength = math.max(self.desiredRopeLength - REEL_SPEED, 3)
	end
	
	-- smooth interpolation to desired length instead of instant change
	self.currentRopeLength = self.currentRopeLength + (self.desiredRopeLength - self.currentRopeLength) * 0.15
	
	-- apply gravity acceleration
	self.vel = self.vel + Vector3.new(0, -GRAVITY, 0) * dt
	
	-- rope constraint section
	-- if player is farther than rope length, pull them back with spring force
	if dist > self.currentRopeLength then
		local stretch = dist - self.currentRopeLength
		
		-- hooke's law: F = kx where k is spring constant and x is displacement
		local springForce = ropeDir * stretch * ROPE_SPRING
		self.vel = self.vel + springForce * dt
		
		-- if velocity is pulling away from anchor point, cancel it out
		-- this prevents the rope from stretching infinitely
		local velocityToward = self.vel:Dot(ropeDir)
		if velocityToward < 0 then
			self.vel = self.vel - ropeDir * velocityToward * 1.2
		end
		
		-- centripetal acceleration for circular motion
		-- decompose velocity into radial (toward anchor) and tangential (perpendicular)
		local perpVel = self.vel - (self.vel:Dot(ropeDir) * ropeDir)
		-- F = mv²/r but we're calculating acceleration so it's just v²/r
		local centripetal = perpVel.Magnitude * perpVel.Magnitude / self.currentRopeLength
		-- apply force toward anchor to maintain arc trajectory
		self.vel = self.vel + ropeDir * centripetal * dt
	end
	
	-- player control section
	-- lets you influence swing direction with wasd
	local inputDir = self:getInputDirection()
	if inputDir.Magnitude > 0 then
		-- separate velocity into radial and tangential components
		local radial = self.vel:Dot(ropeDir) * ropeDir
		local tangent = self.vel - radial
		
		local controlForce = inputDir * PLAYER_CONTROL
		
		-- boost control force when moving with the swing instead of against it
		-- makes it easier to build momentum in the natural swing direction
		if tangent.Magnitude > 5 then
			local swingDir = tangent.Unit
			local matchAmount = math.abs(inputDir:Dot(swingDir))
			controlForce = controlForce * (1 + matchAmount * SWING_MULTIPLIER)
		end
		
		self.vel = self.vel + controlForce * dt
	end
	
	-- air resistance section
	-- applies quadratic drag (proportional to v²) which is more realistic than linear
	local speed = self.vel.Magnitude
	if speed > 0 then
		local dragAmount = speed * speed * 0.0003
		self.vel = self.vel - self.vel.Unit * dragAmount * dt
	end
	
	-- also apply constant drag factor
	self.vel = self.vel * AIR_RESISTANCE
	
	-- velocity cap to prevent physics from breaking
	if self.vel.Magnitude > MAX_VELOCITY then
		self.vel = self.vel.Unit * MAX_VELOCITY
	end
	
	-- apply calculated velocity to the linearvelocity constraint
	self.linearVel.VectorVelocity = self.vel
	
	-- update character rotation to face movement direction
	-- only uses horizontal velocity so character doesn't tilt up/down
	local flatVel = Vector3.new(self.vel.X, 0, self.vel.Z)
	if flatVel.Magnitude > 2 then
		self.alignOrientation.CFrame = CFrame.lookAt(pos, pos + flatVel)
	end
end

-- creates the visual rope part that connects player to grapple point
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

-- updates rope visual to stretch between player and grapple point
-- called every frame while grappling
function GrappleHook:updateRope()
	if not self.isGrappling or not self.ropePart or not self.grapplePoint then return end
	
	-- offset start point slightly above character for better visual
	local startPt = self.hrp.Position + Vector3.new(0, 2, 0)
	local endPt = self.grapplePoint
	local length = (endPt - startPt).Magnitude
	
	-- position rope at midpoint between start and end, rotated to connect them
	local ropeCF = CFrame.lookAt(startPt, endPt)
	self.ropePart.CFrame = ropeCF * CFrame.new(0, 0, -length / 2)
	self.ropePart.Size = Vector3.new(ROPE_THICKNESS, ROPE_THICKNESS, length)
end

-- destroys rope visual when grapple is released
function GrappleHook:destroyRope()
	if self.ropePart then
		self.ropePart:Destroy()
		self.ropePart = nil
	end
end

-- main update function called every frame
-- routes to appropriate update logic based on grapple state
function GrappleHook:tick(dt)
	if self.isGrappling then
		self:physicsStep(dt)
		self:updateRope()
	else
		self:updateIndicator()
	end
end

-- starts the heartbeat loop that drives all updates
function GrappleHook:init()
	local tickConn = RunService.Heartbeat:Connect(function(dt)
		self:tick(dt)
	end)
	
	table.insert(self.connections, tickConn)
end

-- cleanup function to disconnect everything and restore normal state
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

-- initialization section
-- waits for player character and creates grapple hook instance
local plr = Players.LocalPlayer
local char = plr.Character or plr.CharacterAdded:Wait()
local hum = char:WaitForChild("Humanoid")

task.wait(0.2)

local hook = GrappleHook.new(char)
hook:init()

-- cleanup and recreate hook when player dies
hum.Died:Connect(function()
	hook:destroy()
end)

-- recreate hook when player respawns
plr.CharacterAdded:Connect(function(newChar)
	task.wait(0.2)
	char = newChar
	hum = newChar:WaitForChild("Humanoid")
	hook = GrappleHook.new(newChar)
	hook:init()
end)

return GrappleHook
