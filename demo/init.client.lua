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
		part.Color = Color3.fromHSV(math.random(), 0.5, 1)
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

-- Each frame, we'll ask CullThrottle for all the objects that should be updated this frame,
-- and then rotate them accordingly with BulkMoveTo.
local ROT_SPEED = math.rad(90)
local MOVE_AMOUNT = 10
RunService.RenderStepped:Connect(function(frameDeltaTime)
	local blocks, cframes = {}, {}
	local now = os.clock() / 2
	local movement = math.sin(now) * MOVE_AMOUNT
	for block, objectDeltaTime in FloatingBlocksUpdater:getObjectsToUpdate() do
		if objectDeltaTime > 0.4 then
			-- This object hasn't been updated in a while, so if we were to animate
			-- it based on the objectDT, it would jump to where it "should" be now.
			-- For our purposes, we'd rather it just pick up from where it is and avoid popping
			objectDeltaTime = frameDeltaTime
		end

		table.insert(blocks, block)
		table.insert(
			cframes,
			block.CFrame
				* CFrame.new(0, movement * objectDeltaTime, 0)
				* CFrame.Angles(0, ROT_SPEED * objectDeltaTime, 0)
		)
	end

	workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)
