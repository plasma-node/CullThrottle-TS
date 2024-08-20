--!strict
--!optimize 2

local RunService = game:GetService("RunService")

if RunService:IsServer() and not RunService:IsEdit() then
	error("CullThrottle is a client side effect and cannot be used on the server")
end

local PriorityQueue = require(script.PriorityQueue)
local CameraCache = require(script.CameraCache)

local EPSILON = 1e-4
local LAST_VISIBILITY_GRACE_PERIOD = 0.15

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type CullThrottleProto = {
	_farRefreshRate: number,
	_nearRefreshRate: number,
	_refreshRateRange: number,
	_renderDistance: number,
	_voxelSize: number,
	_halfVoxelSizeVec: Vector3,
	_voxels: { [Vector3]: { Instance } },
	_objects: {
		[Instance]: {
			lastUpdateClock: number,
			voxelKey: Vector3,
			desiredVoxelKey: Vector3?,
			position: Vector3,
			positionChangeConnection: RBXScriptConnection?,
		},
	},
	_objectRefreshQueue: PriorityQueue.PriorityQueue,
	_vertexVisibilityCache: { [Vector3]: boolean },
	_lastVoxelVisibility: { [Vector3]: number },
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

function CullThrottle.new(): CullThrottle
	local self = setmetatable({}, CullThrottle)

	self._voxelSize = 75
	self._halfVoxelSizeVec = Vector3.one * (self._voxelSize / 2)
	self._farRefreshRate = 1 / 15
	self._nearRefreshRate = 1 / 45
	self._refreshRateRange = self._farRefreshRate - self._nearRefreshRate
	self._renderDistance = 450
	self._voxels = {}
	self._objects = {}
	self._objectRefreshQueue = PriorityQueue.new()
	self._vertexVisibilityCache = {}
	self._lastVoxelVisibility = {}

	return self
end

function CullThrottle._getPositionOfObject(
	self: CullThrottle,
	object: Instance,
	onChanged: (() -> ())?
): (Vector3?, RBXScriptConnection?)
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return nil, nil
	end

	local changeConnection = nil

	if object:IsA("BasePart") then
		if onChanged then
			-- Connect to CFrame, not Position, since BulkMoveTo only fires CFrame changed event
			changeConnection = object:GetPropertyChangedSignal("CFrame"):Connect(onChanged)
		end
		return object.Position, changeConnection
	elseif object:IsA("Model") then
		if onChanged then
			changeConnection = object:GetPropertyChangedSignal("WorldPivot"):Connect(onChanged)
		end
		return object:GetPivot().Position, changeConnection
	elseif object:IsA("Bone") then
		if onChanged then
			changeConnection = object:GetPropertyChangedSignal("TransformedWorldCFrame"):Connect(onChanged)
		end
		return object.TransformedWorldCFrame.Position, changeConnection
	elseif object:IsA("Attachment") then
		if onChanged then
			changeConnection = object:GetPropertyChangedSignal("WorldPosition"):Connect(onChanged)
		end
		return object.WorldPosition, changeConnection
	elseif object:IsA("Beam") then
		-- Beams are roughly located between their attachments
		local attachment0, attachment1 = object.Attachment0, object.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return nil, nil
		end
		if onChanged then
			-- We really should be listening to both attachments, but I don't care to support 2 change connections
			-- for a single object right now.
			changeConnection = attachment0:GetPropertyChangedSignal("WorldPosition"):Connect(onChanged)
		end
		return (attachment0.WorldPosition + attachment1.WorldPosition) / 2
	elseif object:IsA("Light") or object:IsA("Sound") or object:IsA("ParticleEmitter") then
		-- These effect objects are positioned based on their parent
		if not object.Parent then
			warn("Cannot determine position of " .. object.ClassName .. " since it is not parented")
			return nil, nil
		end
		return self:_getPositionOfObject(object.Parent, onChanged)
	end

	-- We don't know how to get the position of this,
	-- so let's assume it's at the parent position
	if not object.Parent then
		warn("Cannot determine position of " .. object.ClassName .. ", unknown class with no parent")
		return nil, nil
	end

	local parentPosition, parentChangeConnection = self:_getPositionOfObject(object.Parent, onChanged)
	if not parentPosition then
		warn("Cannot determine position of " .. object:GetFullName() .. ", ancestry objects lack position info")
	end

	return parentPosition, parentChangeConnection
end

function CullThrottle._insertToVoxel(self: CullThrottle, voxelKey: Vector3, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		-- New voxel, init the list with this object inside
		self._voxels[voxelKey] = { object }
	else
		-- Existing voxel, add this object to its list
		table.insert(voxel, object)
	end
end

function CullThrottle._removeFromVoxel(self: CullThrottle, voxelKey: Vector3, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		return
	end

	local objectIndex = table.find(voxel, object)
	if not objectIndex then
		return
	end

	local n = #voxel
	if n == 1 then
		-- Lets just cleanup this now empty voxel instead
		self._voxels[voxelKey] = nil
	elseif n == objectIndex then
		-- This object is at the end, so we can remove it without needing
		-- to shift anything or fill gaps
		voxel[objectIndex] = nil
	else
		-- To avoid shifting the whole array, we take the
		-- last object and move it to overwrite this one
		-- since order doesn't matter in this list
		local lastObject = voxel[n]
		voxel[n] = nil
		voxel[objectIndex] = lastObject
	end
end

function CullThrottle._processObjectRefreshQueue(self: CullThrottle, time_limit: number)
	debug.profilebegin("ObjectRefreshQueue")
	local now = os.clock()
	while (not self._objectRefreshQueue:empty()) and (os.clock() - now < time_limit) do
		local object = self._objectRefreshQueue:dequeue()
		local objectData = self._objects[object]
		if (not objectData) or not objectData.desiredVoxelKey then
			continue
		end

		self:_insertToVoxel(objectData.desiredVoxelKey, object)
		self:_removeFromVoxel(objectData.voxelKey, object)
		objectData.voxelKey = objectData.desiredVoxelKey
		objectData.desiredVoxelKey = nil
	end
	debug.profileend()
end

-- Function to check if a box is inside a frustum using SAT
local verticesToCheck = table.create(8)
function CullThrottle._isBoxInFrustum(
	self: CullThrottle,
	checkForCompletelyInside: boolean,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (boolean, boolean)
	debug.profilebegin("isBoxInFrustum")
	local voxelSize = self._voxelSize
	local vertexVisibilityCache = self._vertexVisibilityCache

	-- Convert the box bounds into the 8 corners of the box in world space
	local x0W, x1W = x0 * voxelSize, x1 * voxelSize
	local y0W, y1W = y0 * voxelSize, y1 * voxelSize
	local z0W, z1W = z0 * voxelSize, z1 * voxelSize
	-- Reuse the same table to avoid allocations and cleanup
	verticesToCheck[1] = Vector3.new(x0W, y0W, z0W)
	verticesToCheck[2] = Vector3.new(x1W, y0W, z0W)
	verticesToCheck[3] = Vector3.new(x0W, y1W, z0W)
	verticesToCheck[4] = Vector3.new(x1W, y1W, z0W)
	verticesToCheck[5] = Vector3.new(x0W, y0W, z1W)
	verticesToCheck[6] = Vector3.new(x1W, y0W, z1W)
	verticesToCheck[7] = Vector3.new(x0W, y1W, z1W)
	verticesToCheck[8] = Vector3.new(x1W, y1W, z1W)

	local isBoxInside = true
	local isBoxCompletelyInside = true

	for i = 1, #frustumPlanes, 2 do
		local pos, normal = frustumPlanes[i], frustumPlanes[i + 1]
		local allCornersOutside = true
		local allCornersInside = true

		-- Check the position of each corner relative to the plane
		for _, vertex in verticesToCheck do
			local isVertexInside = false
			if vertexVisibilityCache[vertex] ~= nil then
				isVertexInside = vertexVisibilityCache[vertex]
			else
				-- Check if corner lies outside the frustum plane
				if normal:Dot(vertex - pos) <= EPSILON then
					isVertexInside = true
					-- This corner is inside
				else
					isVertexInside = false
				end
				vertexVisibilityCache[vertex] = isVertexInside
			end

			if isVertexInside then
				allCornersOutside = false
				if not checkForCompletelyInside then
					-- We can early exit on the first inside corner
					debug.profileend()
					return true, true
				end
			else
				allCornersInside = false
			end
		end

		if allCornersOutside then
			-- If all corners are outside any plane, the box is outside the frustum
			isBoxInside = false
			isBoxCompletelyInside = false
			break -- No need to check the other planes
		end

		-- If any corner is outside this plane, the box is not completely inside
		if not allCornersInside then
			isBoxCompletelyInside = false
		end
	end

	debug.profileend()
	return isBoxInside, isBoxCompletelyInside
end

function CullThrottle._processVoxel(
	self: CullThrottle,
	now: number,
	shouldDistThrottle: boolean,
	updateLastVoxelVisiblity: boolean,
	voxelKey: Vector3,
	voxelSize: number,
	halfVoxelSizeVec: Vector3,
	cameraPos: Vector3,
	nearRefreshRate: number,
	refreshRateRange: number,
	renderDistance: number
)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		return
	end

	if updateLastVoxelVisiblity then
		self._lastVoxelVisibility[voxelKey] = now
	end

	if not shouldDistThrottle then
		debug.profilebegin("usersCode")
		for _, object in voxel do
			coroutine.yield(object)
		end
		debug.profileend()
		return
	end

	-- Instead of distance per object, we approximate by computing the distance
	-- to the voxel center. This gives us less precise throttling, but saves a ton of compute
	-- and scales on voxel size instead of object count.
	local voxelWorldPos = voxelKey * voxelSize + halfVoxelSizeVec
	local voxelDistance = (voxelWorldPos - cameraPos).Magnitude

	local refreshDelay = nearRefreshRate + (refreshRateRange * math.min(voxelDistance / renderDistance, 1))
	for _, object in voxel do
		local objectData = self._objects[object]
		if not objectData then
			continue
		end

		-- We add jitter to the timings so we don't end up with
		-- spikes of every object in the voxel updating on the same frame
		local elapsed = now - objectData.lastUpdateClock
		local jitter = math.random() / 150
		if elapsed + jitter <= refreshDelay then
			-- It is not yet time to update this one
			continue
		end

		debug.profilebegin("usersCode")
		coroutine.yield(object, elapsed)
		debug.profileend()

		objectData.lastUpdateClock = now
	end
end

function CullThrottle._getFrustumVoxelsInVolume(
	self: CullThrottle,
	now: number,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	callback: (Vector3, boolean) -> ()
)
	local isSingleVoxel = x1 - x0 == 1 and y1 - y0 == 1 and z1 - z0 == 1

	-- No need to check an empty voxel
	if isSingleVoxel and not self._voxels[Vector3.new(x0, y0, z0)] then
		return
	end

	debug.profilebegin("checkBoxVisibilityCache")
	local allVoxelsVisible = true
	local containsVoxels = false
	for x = x0, x1 - 1 do
		for y = y0, y1 - 1 do
			for z = z0, z1 - 1 do
				local voxelKey = Vector3.new(x, y, z)
				if self._voxels[voxelKey] then
					containsVoxels = true
					if now - (self._lastVoxelVisibility[voxelKey] or 0) >= LAST_VISIBILITY_GRACE_PERIOD then
						allVoxelsVisible = false
						break
					end
				end
			end
		end
	end
	debug.profileend()

	-- Don't bother checking further if this box doesn't contain any voxels
	if not containsVoxels then
		return
	end

	-- If all voxels in this box were visible a moment ago, just assume they still are
	if allVoxelsVisible then
		for x = x0, x1 - 1 do
			for y = y0, y1 - 1 do
				for z = z0, z1 - 1 do
					callback(Vector3.new(x, y, z), false)
				end
			end
		end
		return
	end

	-- Alright, we actually do need to check if this box is visible
	local isInside, isCompletelyInside =
		self:_isBoxInFrustum(isSingleVoxel == false, frustumPlanes, x0, y0, z0, x1, y1, z1)

	-- If the box is outside the frustum, stop checking now
	if not isInside then
		if isSingleVoxel then
			-- Remove voxel visibility
			self._lastVoxelVisibility[Vector3.new(x0, y0, z0)] = nil
		end
		return
	end

	-- If the box is a single voxel, it cannot be split further
	if isSingleVoxel then
		callback(Vector3.new(x0, y0, z0), true)
		return
	end

	-- If the box is entirely inside, then we know all voxels contained inside are in the frustum
	-- and we can process them now and not split further
	if isCompletelyInside then
		for x = x0, x1 - 1 do
			for y = y0, y1 - 1 do
				for z = z0, z1 - 1 do
					callback(Vector3.new(x, y, z), true)
				end
			end
		end
		return
	end

	-- We are partially inside, so we need to split this box up further
	-- to figure out which voxels within it are the ones inside

	-- Calculate the lengths of each axis
	local lengthX = x1 - x0
	local lengthY = y1 - y0
	local lengthZ = z1 - z0

	-- Split along the axis with the greatest length
	if lengthX >= lengthY and lengthX >= lengthZ then
		local splitCoord = (x0 + x1) // 2
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, z0, splitCoord, y1, z1, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, splitCoord, y0, z0, x1, y1, z1, callback)
	elseif lengthY >= lengthX and lengthY >= lengthZ then
		local splitCoord = (y0 + y1) // 2
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, z0, x1, splitCoord, z1, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, splitCoord, z0, x1, y1, z1, callback)
	else
		local splitCoord = (z0 + z1) // 2
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, z0, x1, y1, splitCoord, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, splitCoord, x1, y1, z1, callback)
	end
end

function CullThrottle._getPlanesAndBounds(
	_self: CullThrottle,
	renderDistance: number,
	voxelSize: number
): ({ Vector3 }, Vector3, Vector3)
	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position

	local farPlaneHeight2 = CameraCache.HalfTanFOV * renderDistance
	local farPlaneWidth2 = farPlaneHeight2 * CameraCache.AspectRatio
	local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -renderDistance)
	local farPlaneTopLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
	local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)

	local upVec, rightVec = cameraCFrame.UpVector, cameraCFrame.RightVector

	local rightNormal = upVec:Cross(cameraPos - farPlaneBottomRight).Unit
	local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
	local topNormal = rightVec:Cross(farPlaneTopRight - cameraPos).Unit
	local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

	local frustumPlanes: { Vector3 } = {
		cameraPos,
		leftNormal,
		cameraPos,
		rightNormal,
		cameraPos,
		topNormal,
		cameraPos,
		bottomNormal,
		farPlaneCFrame.Position,
		cameraCFrame.LookVector,
	}

	local minBound = Vector3.new(
		math.min(cameraPos.X, farPlaneTopLeft.X, farPlaneBottomLeft.X, farPlaneTopRight.X, farPlaneBottomRight.X)
			// voxelSize,
		math.min(cameraPos.Y, farPlaneTopLeft.Y, farPlaneBottomLeft.Y, farPlaneTopRight.Y, farPlaneBottomRight.Y)
			// voxelSize,
		math.min(cameraPos.Z, farPlaneTopLeft.Z, farPlaneBottomLeft.Z, farPlaneTopRight.Z, farPlaneBottomRight.Z)
			// voxelSize
	)
	local maxBound = Vector3.new(
		math.max(cameraPos.X, farPlaneTopLeft.X, farPlaneBottomLeft.X, farPlaneTopRight.X, farPlaneBottomRight.X)
			// voxelSize,
		math.max(cameraPos.Y, farPlaneTopLeft.Y, farPlaneBottomLeft.Y, farPlaneTopRight.Y, farPlaneBottomRight.Y)
			// voxelSize,
		math.max(cameraPos.Z, farPlaneTopLeft.Z, farPlaneBottomLeft.Z, farPlaneTopRight.Z, farPlaneBottomRight.Z)
			// voxelSize
	)

	return frustumPlanes, minBound, maxBound
end

function CullThrottle._getObjects(self: CullThrottle, shouldDistThrottle: boolean): () -> (Instance?, number?)
	local now = os.clock()

	table.clear(self._vertexVisibilityCache)

	-- Make sure our voxels are up to date
	-- for up to 0.1 ms
	self:_processObjectRefreshQueue(1e-4)

	local voxelSize = self._voxelSize
	local halfVoxelSizeVec = self._halfVoxelSizeVec

	local nearRefreshRate = self._nearRefreshRate
	local refreshRateRange = self._refreshRateRange
	local renderDistance = self._renderDistance
	-- For smaller FOVs, we increase render distance
	if CameraCache.FieldOfView < 60 then
		renderDistance *= 2 - CameraCache.FieldOfView / 60
	end

	local cameraPos = CameraCache.Position
	local frustumPlanes, minBound, maxBound = self:_getPlanesAndBounds(renderDistance, voxelSize)

	local minX = minBound.X
	local minY = minBound.Y
	local minZ = minBound.Z
	local maxX = maxBound.X + 1
	local maxY = maxBound.Y + 1
	local maxZ = maxBound.Z + 1

	local thread = coroutine.create(function()
		local function callback(voxelKey: Vector3, updateLastVoxelVisiblity: boolean)
			self:_processVoxel(
				now,
				shouldDistThrottle,
				updateLastVoxelVisiblity,
				voxelKey,
				voxelSize,
				halfVoxelSizeVec,
				cameraPos,
				nearRefreshRate,
				refreshRateRange,
				renderDistance
			)
		end

		-- Split into smaller boxes to start off since the frustum bounding volume
		-- obviously intersects the frustum planes

		-- However if the bounds are not divisible then don't split early
		if minX == maxX or minY == maxY or minZ == maxZ then
			self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, minY, minZ, maxX, maxY, maxZ, callback)
			return
		end

		local midBound = (minBound + maxBound) // 2
		local midX = midBound.X
		local midY = midBound.Y
		local midZ = midBound.Z

		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, minY, minZ, midX, midY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, minY, minZ, maxX, midY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, minY, midZ, midX, midY, maxZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, minY, midZ, maxX, midY, maxZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, midY, minZ, midX, maxY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, midY, minZ, maxX, maxY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, midY, midZ, midX, maxY, maxZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, midY, midZ, maxX, maxY, maxZ, callback)
	end)

	return function()
		if coroutine.status(thread) == "dead" then
			return
		end

		local success, object, elapsed = coroutine.resume(thread)
		if not success then
			warn("CullThrottle._getObjects thread error: " .. tostring(object))
			return
		end

		return object, elapsed
	end
end

function CullThrottle.setVoxelSize(self: CullThrottle, voxelSize: number)
	self._voxelSize = voxelSize
	self._halfVoxelSizeVec = Vector3.one * (voxelSize / 2)

	-- We need to move all the objects around to their new voxels
	table.clear(self._voxels)

	for object, objectData in self._objects do
		-- Seems like a fine time to refresh the positions too
		objectData.position = self:_getPositionOfObject(object) or objectData.position

		local voxelKey = objectData.position // voxelSize
		objectData.voxelKey = voxelKey

		self:_insertToVoxel(voxelKey, object)
	end
end

function CullThrottle.setRenderDistance(self: CullThrottle, renderDistance: number)
	self._renderDistance = renderDistance
end

function CullThrottle.setRefreshRates(self: CullThrottle, near: number, far: number)
	if near > 2 then
		near = 1 / near
	end
	if far > 2 then
		far = 1 / far
	end

	self._nearRefreshRate = near
	self._farRefreshRate = far
	self._refreshRateRange = far - near
end

function CullThrottle.add(self: CullThrottle, object: Instance)
	local position, positionChangeConnection = self:_getPositionOfObject(object, function()
		-- We aren't going to move voxels immediately, since having many parts jumping around voxels
		-- is very costly. Instead, we queue up this object to be refreshed, and prioritize objects
		-- that are moving around closer to the camera

		local objectData = self._objects[object]
		if not objectData then
			return
		end

		local newPosition = self:_getPositionOfObject(object)
		if not newPosition then
			-- Don't know where this should go anymore. Might need to be removed,
			-- but that's the user's responsibility
			return
		end

		objectData.position = newPosition

		local desiredVoxelKey = newPosition // self._voxelSize
		if desiredVoxelKey == objectData.voxelKey then
			-- Object moved within the same voxel, no need to refresh
			return
		end

		objectData.desiredVoxelKey = desiredVoxelKey

		-- Use a cheap manhattan distance check for priority
		local difference = newPosition - CameraCache.Position
		local priority = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)

		self._objectRefreshQueue:enqueue(object, priority)
	end)
	if not position then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, position is unknown")
	end

	local objectData = {
		lastUpdateClock = os.clock(),
		voxelKey = position // self._voxelSize,
		position = position,
		positionChangeConnection = positionChangeConnection,
	}

	self._objects[object] = objectData

	self:_insertToVoxel(objectData.voxelKey, object)
end

function CullThrottle.remove(self: CullThrottle, object: Instance)
	local objectData = self._objects[object]
	if not objectData then
		return
	end
	if objectData.positionChangeConnection then
		objectData.positionChangeConnection:Disconnect()
	end
	self._objects[object] = nil
	self:_removeFromVoxel(objectData.voxelKey, object)
end

function CullThrottle.getObjectsInView(self: CullThrottle): () -> (Instance?, number?)
	return self:_getObjects(false)
end

function CullThrottle.getObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?)
	return self:_getObjects(true)
end

return CullThrottle
