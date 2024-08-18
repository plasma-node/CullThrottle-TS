local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

-- Let's make some blocks to run effects on
local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"
for _ = 1, 100 do
	local groupOrigin = Vector3.new(math.random(-800, 800), math.random(60, 400), math.random(-800, 800))
	for _ = 1, 100 do
		local part = Instance.new("Part")
		part.Size = Vector3.new(5, 5, 5)
		part.Color = Color3.new() -- Color3.fromHSV(math.random(), 0.5, 1)
		part.CFrame = CFrame.new(
			groupOrigin + Vector3.new(math.random(-100, 100), math.random(-50, 50), math.random(-100, 100))
		) * CFrame.Angles(math.rad(math.random(360)), math.rad(math.random(360)), math.rad(math.random(360)))
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.CanTouch = false
		part.CanQuery = false
		part.Locked = true
		part:AddTag("FloatingBlock")
		part.Parent = BlocksFolder
	end
end

BlocksFolder.Parent = workspace

local FloatingBlocksUpdater = CullThrottle.new()

-- We need to tell CullThrottle about all the objects that we want it to manage.
for _, block in CollectionService:GetTagged("FloatingBlock") do
	FloatingBlocksUpdater:add(block)
end

CollectionService:GetInstanceAddedSignal("FloatingBlock"):Connect(function(block)
	FloatingBlocksUpdater:add(block)
end)

CollectionService:GetInstanceRemovedSignal("FloatingBlock"):Connect(function(block)
	FloatingBlocksUpdater:remove(block)
end)

local VISIBLE_COLOR = Color3.new(1, 1, 1)
local HIDDEN_COLOR = Color3.new(0, 0, 0)

local lastVisible = {}
RunService.RenderStepped:Connect(function()
	local newVisible = {}
	for block in FloatingBlocksUpdater:getObjectsInView() do
		newVisible[block] = true
		if block.Color ~= VISIBLE_COLOR then
			block.Color = VISIBLE_COLOR
		end
	end

	-- Get the objects that were visible last frame but not this frame
	for block in lastVisible do
		if not newVisible[block] then
			if block.Color ~= HIDDEN_COLOR then
				block.Color = HIDDEN_COLOR
			end
		end
	end

	lastVisible = newVisible
end)
