-- made by @zavenx | discord: zavenxd | roblox: nevazal
-- grappling hook with rope physics

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

-- physics configuration
-- these values were tuned through testing to feel responsive but not overpowered
local maxDistance = 300  -- how far you can shoot the hook
local minDistance = 10   -- prevents attaching to things too close
local reelSpeed = 100     -- how fast space bar pulls you in
local gravity = 196.2     -- standard roblox gravity
local ropeSpring = 1400  -- how strongly the rope pulls when stretched, higher = snappier
local airDrag = 0.994    -- gradual slowdown per frame to prevent infinite swinging
local maxSpeed = 220     -- speed cap to prevent physics breaking at extreme velocities
local controlForce = 75  -- strength of wasd movement while grappling
local swingBonus = 2.8   -- multiplier when moving with momentum, rewards skillful swinging
local velocityBoost = 1.08  -- small boost when initially attaching to preserve momentum
local ropeStretchDamping = 1.2  -- reduces bouncing when rope goes taut
local ropeLengthLerp = 0.35  -- smooths rope length changes, prevents jarring transitions
local swingThreshold = 5  -- minimum speed needed before swing bonus kicks in
local quadraticDrag = 0.0003  -- extra drag at high speeds, prevents going too fast
local minRotateSpeed = 2  -- character only rotates when moving faster than this

-- visual configuration
local ropeThickness = 0.22
local ropeColor = Color3.fromRGB(200, 220, 240)
local indicatorColor = Color3.fromRGB(100, 255, 150)
local indicatorSize = 1.2
local pulseSpeed = 8  -- how fast the target indicator pulses

-- edge case thresholds
-- these prevent division by zero and other math errors with very small numbers
local minVectorMagnitude = 0.01
local minRopeLength = 3

-- cached constants to avoid allocations
-- creating new vector3s every frame is expensive, so we reuse these
local vectorZero = Vector3.zero
local vectorOne = Vector3.one
local ropeOffset = Vector3.new(0, 2, 0)  -- rope attaches slightly above character center
local gravityVector = Vector3.new(0, -gravity, 0)
local fallbackForward = Vector3.new(0, 0, -1)  -- used when camera is pointing straight down
local fallbackRight = Vector3.new(1, 0, 0)

-- utility functions

-- normalizes a vector but returns a fallback if it's too small
-- prevents errors when trying to normalize zero-length vectors
local function safeNormalize(vector, fallback)
	local magnitude = vector.Magnitude
	return magnitude > minVectorMagnitude and vector / magnitude or fallback
end

-- removes the y component to get horizontal direction only
-- useful for camera-relative movement and character rotation
local function flattenToHorizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

-- limits a vector's length without changing direction
-- more efficient than normalizing then multiplying
local function clampMagnitude(vector, maxMagnitude)
	local magnitude = vector.Magnitude
	return magnitude > maxMagnitude and vector / magnitude * maxMagnitude or vector
end

-- main grapple hook class
local GrappleHook = {}
GrappleHook.__index = GrappleHook

function GrappleHook.new(character)
	local self = setmetatable({}, GrappleHook)

	self.character = character
	self.humanoid = character:WaitForChild("Humanoid")
	self.rootPart = character:WaitForChild("HumanoidRootPart")

	-- state tracking
	self.isActive = false
	self.anchorPoint = nil
	self.ropeLength = 0
	self.desiredLength = 0  -- what the rope length is lerping towards
	self.velocity = vectorZero  -- we manually handle physics instead of using roblox's
	self.keys = {w = false, a = false, s = false, d = false}
	self.isReeling = false
	self.connections = {}

	-- cache expensive references so we don't keep calling getservice
	self.player = Players.LocalPlayer
	self.mouse = self.player:GetMouse()
	self.raycastParams = self:createRaycastParams()

	self:createIndicator()
	self:bindInput()
	self:startUpdateLoop()

	return self
end

function GrappleHook:createRaycastParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	return params
end

-- creates the green ball that shows where you're aiming
function GrappleHook:createIndicator()
	local indicator = Instance.new("Part")
	indicator.Name = "GrappleTarget"
	indicator.Size = vectorOne * indicatorSize
	indicator.Shape = Enum.PartType.Ball
	indicator.Material = Enum.Material.Neon
	indicator.Color = indicatorColor
	indicator.Transparency = 1  -- starts hidden
	indicator.Anchored = true
	indicator.CanCollide = false
	indicator.Parent = workspace

	self.indicator = indicator
end

-- raycasts from camera to mouse position to find valid grapple points
function GrappleHook:findTarget()
	local camera = workspace.CurrentCamera
	local screenRay = camera:ScreenPointToRay(self.mouse.X, self.mouse.Y)

	-- update filter list without recreating params (optimization)
	self.raycastParams.FilterDescendantsInstances = {self.character, self.indicator}

	local result = workspace:Raycast(
		screenRay.Origin,
		screenRay.Direction * maxDistance,
		self.raycastParams
	)

	if not result then return nil end

	-- validate distance constraints
	local distance = (result.Position - self.rootPart.Position).Magnitude
	if distance < minDistance or distance > maxDistance then
		return nil
	end

	return result.Position
end

-- shows the indicator when aiming at valid surfaces
function GrappleHook:updateIndicator()
	local target = self:findTarget()

	if target then
		self.indicator.Position = target
		self.indicator.Transparency = 0.3

		-- pulsing animation makes it easier to see
		local pulse = 0.85 + math.sin(tick() * pulseSpeed) * 0.15
		self.indicator.Size = vectorOne * (indicatorSize * pulse)
	else
		self.indicator.Transparency = 1
	end
end

-- sets up all input handling
function GrappleHook:bindInput()
	local conn1 = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- left click toggles grapple
			if self.isActive then
				self:detach()
			else
				self:attach()
			end
		elseif input.KeyCode == Enum.KeyCode.Space then
			self.isReeling = self.isActive
		else
			-- track wasd state for movement
			local keyName = input.KeyCode.Name:lower()
			if self.keys[keyName] ~= nil then
				self.keys[keyName] = true
			end
		end
	end)

	local conn2 = UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Space then
			self.isReeling = false
		else
			local keyName = input.KeyCode.Name:lower()
			if self.keys[keyName] ~= nil then
				self.keys[keyName] = false
			end
		end
	end)

	table.insert(self.connections, conn1)
	table.insert(self.connections, conn2)
end

-- starts the grapple when you click on a valid surface
function GrappleHook:attach()
	if self.isActive then return end

	local target = self:findTarget()
	if not target then return end

	local distance = (target - self.rootPart.Position).Magnitude

	self.isActive = true
	self.anchorPoint = target
	self.ropeLength = distance
	self.desiredLength = distance
	self.velocity = self.rootPart.AssemblyLinearVelocity * velocityBoost  -- preserve momentum

	self:enablePhysics()
	self:createRope()
	self.indicator.Transparency = 1
end

-- releases the grapple and returns control to normal humanoid
function GrappleHook:detach()
	if not self.isActive then return end

	-- apply our custom velocity back to the character
	self.rootPart.AssemblyLinearVelocity = self.velocity

	self:disablePhysics()
	self:destroyRope()

	self.isActive = false
	self.anchorPoint = nil
	self.isReeling = false
end

-- switches to manual physics mode so we can handle everything ourselves
function GrappleHook:enablePhysics()
	local attachment = Instance.new("Attachment", self.rootPart)

	-- linearvelocity lets us directly control the character's velocity
	local linearVel = Instance.new("LinearVelocity")
	linearVel.Attachment0 = attachment
	linearVel.MaxForce = math.huge
	linearVel.VectorVelocity = self.velocity
	linearVel.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVel.Parent = self.rootPart

	-- alignorientation keeps the character upright and facing movement direction
	local alignOrient = Instance.new("AlignOrientation")
	alignOrient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrient.Attachment0 = attachment
	alignOrient.MaxTorque = 9e5
	alignOrient.Responsiveness = 50
	alignOrient.CFrame = self.rootPart.CFrame
	alignOrient.RigidityEnabled = false
	alignOrient.Parent = self.rootPart

	self.attachment = attachment
	self.linearVel = linearVel
	self.alignOrient = alignOrient

	-- physics state disables normal humanoid movement
	self.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	self.humanoid.PlatformStand = true
end

-- cleans up physics constraints and returns to normal movement
function GrappleHook:disablePhysics()
	self.linearVel:Destroy()
	self.alignOrient:Destroy()
	self.attachment:Destroy()

	self.linearVel = nil
	self.alignOrient = nil
	self.attachment = nil

	self.humanoid.PlatformStand = false
	self.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
end

-- converts wasd input to world-space movement relative to camera
function GrappleHook:getCameraRelativeInput()
	local camera = workspace.CurrentCamera

	-- get camera directions but only on horizontal plane
	local forward = flattenToHorizontal(camera.CFrame.LookVector)
	local right = flattenToHorizontal(camera.CFrame.RightVector)

	-- normalize with fallback in case camera is looking straight up/down
	forward = safeNormalize(forward, fallbackForward)
	right = safeNormalize(right, fallbackRight)

	-- combine input into a single direction
	local direction = vectorZero
	if self.keys.w then direction += forward end
	if self.keys.s then direction -= forward end
	if self.keys.a then direction -= right end
	if self.keys.d then direction += right end

	return safeNormalize(direction, vectorZero)
end

-- handles space bar reeling and smooth length transitions
function GrappleHook:updateRopeLength(dt)
	if self.isReeling then
		-- multiply by dt so reel speed is consistent regardless of framerate
		self.desiredLength = math.max(self.desiredLength - reelSpeed * dt, minRopeLength)
	end
	-- lerp actual length towards desired for smoothness
	self.ropeLength += (self.desiredLength - self.ropeLength) * ropeLengthLerp
end

-- applies downward acceleration every frame
function GrappleHook:applyGravity(dt)
	self.velocity += gravityVector * dt
end

-- this is the core rope physics - keeps you at rope distance from anchor
function GrappleHook:applyRopeConstraint(ropeDir, distance, dt)
	if distance <= self.ropeLength then return end

	-- rope is stretched, apply spring force to pull back
	local stretch = distance - self.ropeLength
	self.velocity += ropeDir * stretch * ropeSpring * dt

	-- damp velocity along the rope to reduce bouncing
	local radialVel = self.velocity:Dot(ropeDir)
	if radialVel < 0 then
		self.velocity -= ropeDir * radialVel * ropeStretchDamping
	end

	-- centripetal acceleration for circular motion around anchor point
	-- this is what makes swinging feel smooth and natural
	local tangentVel = self.velocity - (radialVel * ropeDir)
	local tangentSpeed = tangentVel.Magnitude
	if tangentSpeed > minVectorMagnitude then
		local centripetalAccel = tangentSpeed * tangentSpeed / self.ropeLength
		self.velocity += ropeDir * centripetalAccel * dt
	end
end

-- wasd control while swinging, with momentum-based bonus
function GrappleHook:applyPlayerControl(ropeDir, moveDir, dt)
	if moveDir == vectorZero then return end

	-- get velocity perpendicular to rope (tangent to swing arc)
	local tangent = self.velocity - (self.velocity:Dot(ropeDir) * ropeDir)
	local force = moveDir * controlForce

	-- reward moving with swing momentum instead of against it
	-- this encourages skillful directional control
	local tangentSpeed = tangent.Magnitude
	if tangentSpeed > swingThreshold then
		local alignment = math.abs(moveDir:Dot(tangent / tangentSpeed))
		force *= (1 + alignment * swingBonus)
	end

	self.velocity += force * dt
end

-- air resistance increases with speed squared (realistic drag model)
function GrappleHook:applyAirResistance(dt)
	local speed = self.velocity.Magnitude
	if speed <= minVectorMagnitude then return end

	-- quadratic drag (more realistic than linear)
	self.velocity -= self.velocity / speed * (speed * speed * quadraticDrag) * dt

	-- linear drag for consistent slowdown
	self.velocity *= airDrag
end

-- rotates character to face movement direction (looks better)
function GrappleHook:updateCharacterOrientation()
	local pos = self.rootPart.Position
	local flatVel = flattenToHorizontal(self.velocity)

	-- only rotate if moving fast enough to avoid jittering
	if flatVel.Magnitude > minRotateSpeed then
		self.alignOrient.CFrame = CFrame.lookAt(pos, pos + flatVel)
	end
end

-- main physics loop - runs every frame while grappling
function GrappleHook:simulate(dt)
	local pos = self.rootPart.Position
	local toAnchor = self.anchorPoint - pos
	local distance = toAnchor.Magnitude

	-- prevent division by zero if somehow at exact anchor point
	if distance < minVectorMagnitude then return end

	local ropeDir = toAnchor / distance

	-- apply all forces in order
	self:updateRopeLength(dt)  -- pass dt here
	self:applyGravity(dt)
	self:applyRopeConstraint(ropeDir, distance, dt)

	local moveDir = self:getCameraRelativeInput()
	self:applyPlayerControl(ropeDir, moveDir, dt)
	self:applyAirResistance(dt)

	-- enforce speed limit to prevent physics breaking
	self.velocity = clampMagnitude(self.velocity, maxSpeed)

	-- write our calculated velocity back to the constraint
	self.linearVel.VectorVelocity = self.velocity

	self:updateCharacterOrientation()
end

-- creates the visible rope part
function GrappleHook:createRope()
	local rope = Instance.new("Part")
	rope.Name = "GrappleRope"
	rope.Material = Enum.Material.Neon
	rope.Color = ropeColor
	rope.Anchored = true
	rope.CanCollide = false
	rope.CastShadow = false
	rope.Parent = workspace

	self.rope = rope
end

-- updates rope position and size to stretch between character and anchor
function GrappleHook:updateRope()
	local startPos = self.rootPart.Position + ropeOffset
	local endPos = self.anchorPoint
	local length = (endPos - startPos).Magnitude

	-- position at midpoint, oriented towards anchor, stretched to length
	self.rope.CFrame = CFrame.lookAt((startPos + endPos) * 0.5, endPos)
	self.rope.Size = Vector3.new(ropeThickness, ropeThickness, length)
end

function GrappleHook:destroyRope()
	if self.rope then
		self.rope:Destroy()
		self.rope = nil
	end
end

-- main update loop that runs every frame
function GrappleHook:startUpdateLoop()
	local conn = RunService.Heartbeat:Connect(function(dt)
		if self.isActive then
			self:simulate(dt)
			self:updateRope()
		else
			self:updateIndicator()
		end
	end)

	table.insert(self.connections, conn)
end

-- cleanup when character dies or script stops
function GrappleHook:destroy()
	for _, conn in ipairs(self.connections) do
		conn:Disconnect()
	end

	if self.isActive then
		self:detach()
	end

	if self.indicator then
		self.indicator:Destroy()
	end
end

-- initialization
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
task.wait(0.2)

local currentHook = GrappleHook.new(character)

-- recreate hook when character respawns
player.CharacterAdded:Connect(function(newChar)
	if currentHook then
		currentHook:destroy()
	end
	task.wait(0.2)
	currentHook = GrappleHook.new(newChar)
end)

return GrappleHook
