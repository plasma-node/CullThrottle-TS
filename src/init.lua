--!strict
--!optimize 2

local RunService = game:GetService("RunService")

if RunService:IsServer() and not RunService:IsEdit() then
	error("CullThrottle is a client side effect and cannot be used on the server")
end

local PriorityQueue = require(script.PriorityQueue)
local CameraCache = require(script.CameraCache)

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type CullThrottleProto = {
	_farRefreshRate: number,
	_nearRefreshRate: number,
	_refreshRateRange: number,
	_renderDistance: number,
	_halfRenderDistance: number,
	_renderDistanceSq: number,
	_voxelSize: number,
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
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

function CullThrottle.new(): CullThrottle
	local self = setmetatable({}, CullThrottle)

	self._voxelSize = 75
	self._farRefreshRate = 1 / 15
	self._nearRefreshRate = 1 / 45
	self._refreshRateRange = self._farRefreshRate - self._nearRefreshRate
	self._renderDistance = 600
	self._halfRenderDistance = self._renderDistance / 2
	self._renderDistanceSq = self._renderDistance * self._renderDistance
	self._voxels = {}
	self._objects = {}
	self._objectRefreshQueue = PriorityQueue.new()

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

function CullThrottle._intersectTriangle(
	_self: CullThrottle,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	rayOrigin: Vector3,
	rayDirection: Vector3,
	rayLength: number
): (number?, Vector3?)
	local edge1 = v1 - v0
	local edge2 = v2 - v0

	local h = rayDirection:Cross(edge2)
	local a = h:Dot(edge1)

	if a > -1e-6 and a < 1e-6 then
		return -- The ray is parallel to the triangle
	end

	local f = 1.0 / a
	local s = rayOrigin - v0
	local u = f * s:Dot(h)

	local oneEpsilon = 1 + 1e-6

	if u < -1e-6 or u > oneEpsilon then
		return -- The intersection is outside of the triangle
	end

	local q = s:Cross(edge1)
	local v = f * rayDirection:Dot(q)

	if v < -1e-6 or u + v > oneEpsilon then
		return -- The intersection is outside of the triangle
	end

	local t = f * q:Dot(edge2)

	if t < -1e-6 or t > rayLength then
		return -- Intersection is behind ray or too far away
	end

	return t, rayOrigin + rayDirection * t
end

function CullThrottle._intersectRectangle(
	_self: CullThrottle,
	normal: Vector3,
	center: Vector3,
	halfSizeX: number,
	halfSizeY: number,
	rayOrigin: Vector3,
	rayDirection: Vector3,
	rayLength: number
): (number?, Vector3?)
	local denominator = normal:Dot(rayDirection)
	if denominator > -1e-6 and denominator < 1e-6 then
		return
	end

	local t = (center - rayOrigin):Dot(normal) / denominator
	if t < 1e-6 or t > rayLength then
		return
	end

	-- Now we know we've hit the plane, so now we test if it is within the rectangle
	local p = rayOrigin + t * rayDirection
	local relativeToCenter = p - center
	if
		relativeToCenter.X > halfSizeX
		or relativeToCenter.X < -halfSizeX
		or relativeToCenter.Y > halfSizeY
		or relativeToCenter.Y < -halfSizeY
	then
		return
	end

	return t, p
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

function CullThrottle._addVoxelsAroundVertex(_self: CullThrottle, vertex: Vector3, keyTable: { [Vector3]: true })
	keyTable[vertex] = true

	-- All the voxels that share this vertex
	-- must also visible (at least partially).
	local x, y, z = vertex.X, vertex.Y, vertex.Z
	keyTable[Vector3.new(x - 1, y, z)] = true
	keyTable[Vector3.new(x, y - 1, z)] = true
	keyTable[Vector3.new(x, y, z - 1)] = true
	keyTable[Vector3.new(x - 1, y - 1, z)] = true
	keyTable[Vector3.new(x - 1, y, z - 1)] = true
	keyTable[Vector3.new(x, y - 1, z - 1)] = true
	keyTable[Vector3.new(x - 1, y - 1, z - 1)] = true
end

function CullThrottle._edgeIntersectsMesh(
	self: CullThrottle,
	v0: Vector3,
	v1: Vector3,
	triangleVertices: { { Vector3 } }
)
	local direction = (v1 - v0).Unit
	local length = self._voxelSize

	for _, triangle in triangleVertices do
		if self:_intersectTriangle(triangle[1], triangle[2], triangle[3], v0, direction, length) then
			return true
		end
	end

	return false
end

function CullThrottle._distToTriangle(
	_self: CullThrottle,
	triV0: Vector3,
	triV1: Vector3,
	triV2: Vector3,
	normal: Vector3,
	position: Vector3,
	point: Vector3
)
	-- Projection of vector from planePoint to the given point onto the plane normal
	local projectionLength = (point - position):Dot(normal)
	local projectedPoint = point - normal * projectionLength

	-- Check if the projected point is within the triangle
	local v0 = triV2 - triV0
	local v1 = triV1 - triV0
	local v2 = projectedPoint - triV0

	local dot00 = v0:Dot(v0)
	local dot01 = v0:Dot(v1)
	local dot02 = v0:Dot(v2)
	local dot11 = v1:Dot(v1)
	local dot12 = v1:Dot(v2)

	local invDenom = 1 / (dot00 * dot11 - dot01 * dot01)
	local u = (dot11 * dot02 - dot01 * dot12) * invDenom
	local v = (dot00 * dot12 - dot01 * dot02) * invDenom

	if (u >= 0) and (v >= 0) and (u + v < 1) then
		return math.abs(projectionLength)
	end

	return math.huge
end

function CullThrottle._getVisibleVoxelKeys(self: CullThrottle): { [Vector3]: true }
	local visibleVoxelKeys = {}

	-- Make sure our voxels are up to date
	self:_processObjectRefreshQueue(0.0001)

	local voxelSize = self._voxelSize
	local renderDistance = self._renderDistance
	-- For smaller FOVs, we increase render distance
	if CameraCache.FieldOfView < 70 then
		renderDistance *= 2 - CameraCache.FieldOfView / 70
	end

	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position

	local farPlaneHeight2 = CameraCache.HalfTanFOV * renderDistance
	local farPlaneWidth2 = farPlaneHeight2 * CameraCache.AspectRatio
	local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -renderDistance)
	local farPlanePos = farPlaneCFrame.Position
	local farPlaneTopLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
	local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)

	local upVec, rightVec, lookVec = cameraCFrame.UpVector, cameraCFrame.RightVector, cameraCFrame.LookVector

	local rightNormal = upVec:Cross(cameraPos - farPlaneBottomRight).Unit
	local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
	local topNormal = rightVec:Cross(farPlaneTopRight - cameraPos).Unit
	local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

	local triangleVertices = {
		{ farPlaneTopLeft, farPlaneBottomLeft, cameraPos, leftNormal, cameraPos }, -- Left
		{ farPlaneTopRight, cameraPos, farPlaneBottomRight, rightNormal, cameraPos }, -- Right
		{ farPlaneTopLeft, cameraPos, farPlaneTopRight, topNormal, cameraPos }, -- Top
		{ farPlaneBottomRight, cameraPos, farPlaneBottomLeft, bottomNormal, cameraPos }, -- Bottom
		{ farPlaneTopLeft, farPlaneTopRight, farPlaneBottomLeft, lookVec, farPlanePos }, -- Front 1
		{ farPlaneBottomLeft, farPlaneTopRight, farPlaneBottomRight, lookVec, farPlanePos }, -- Front 2
	}

	local function isVoxelInFrustum(x: number, y: number, z: number): boolean
		local v0 = Vector3.new(x * voxelSize, y * voxelSize, z * voxelSize)
		if visibleVoxelKeys[v0] then
			return true
		end

		local v7 = Vector3.new((x + 1) * voxelSize, (y + 1) * voxelSize, (z + 1) * voxelSize)

		local vertices = {
			v0,
			Vector3.new(v0.X, v0.Y, v7.Z),
			Vector3.new(v0.X, v7.Y, v0.Z),
			Vector3.new(v0.X, v7.Y, v7.Z),
			Vector3.new(v7.X, v0.Y, v0.Z),
			Vector3.new(v7.X, v0.Y, v7.Z),
			Vector3.new(v7.X, v7.Y, v0.Z),
			v7,
		}

		debug.profilebegin("checkNormals")
		for _, vertex in vertices do
			-- Check if point lies outside a frustum plane
			local camToVoxel = vertex - cameraPos
			local insideTris = topNormal:Dot(camToVoxel) < -1e-6
				and leftNormal:Dot(camToVoxel) < -1e-6
				and rightNormal:Dot(camToVoxel) < -1e-6
				and bottomNormal:Dot(camToVoxel) < -1e-6

			if not insideTris then
				-- Don't bother computing the far plane, we're already outside
				continue
			end

			local farPlaneToVoxel = vertex - farPlanePos
			if lookVec:Dot(farPlaneToVoxel) < -1e-6 then
				debug.profileend()
				return true
			end
		end
		debug.profileend()

		debug.profilebegin("checkDistanceToTris")
		local center = Vector3.new((x + 0.5) * voxelSize, (y + 0.5) * voxelSize, (z + 0.5) * voxelSize)
		local shouldCheckEdges = false
		for _, triangle in triangleVertices do
			if
				self:_distToTriangle(triangle[1], triangle[2], triangle[3], triangle[4], triangle[5], center)
				< voxelSize
			then
				shouldCheckEdges = true
				break
			end
		end
		debug.profileend()

		if not shouldCheckEdges then
			-- We're too far from all planes to have an edge intersecting
			return false
		end

		debug.profilebegin("edgeIntersections")
		if
			self:_edgeIntersectsMesh(v0, vertices[2], triangleVertices)
			or self:_edgeIntersectsMesh(v0, vertices[3], triangleVertices)
			or self:_edgeIntersectsMesh(v0, vertices[5], triangleVertices)
			or self:_edgeIntersectsMesh(v7, vertices[4], triangleVertices)
			or self:_edgeIntersectsMesh(v7, vertices[6], triangleVertices)
			or self:_edgeIntersectsMesh(v7, vertices[7], triangleVertices)
			or self:_edgeIntersectsMesh(vertices[2], vertices[6], triangleVertices)
			or self:_edgeIntersectsMesh(vertices[2], vertices[4], triangleVertices)
			or self:_edgeIntersectsMesh(vertices[3], vertices[4], triangleVertices)
			or self:_edgeIntersectsMesh(vertices[5], vertices[6], triangleVertices)
			or self:_edgeIntersectsMesh(vertices[7], vertices[3], triangleVertices)
		then
			debug.profileend()
			return true
		end
		debug.profileend()
		return false
	end

	debug.profilebegin("FindVisibleVoxels")

	debug.profilebegin("SetCornerVoxels")
	-- The camera and corners should always be inside
	self:_addVoxelsAroundVertex(cameraPos // voxelSize + Vector3.one, visibleVoxelKeys)
	self:_addVoxelsAroundVertex(farPlaneTopLeft // voxelSize + Vector3.one, visibleVoxelKeys)
	self:_addVoxelsAroundVertex(farPlaneTopRight // voxelSize + Vector3.one, visibleVoxelKeys)
	self:_addVoxelsAroundVertex(farPlaneBottomLeft // voxelSize + Vector3.one, visibleVoxelKeys)
	self:_addVoxelsAroundVertex(farPlaneBottomRight // voxelSize + Vector3.one, visibleVoxelKeys)
	debug.profileend()

	local minX = math.min(
		cameraPos.X,
		farPlaneTopLeft.X,
		farPlaneTopRight.X,
		farPlaneBottomLeft.X,
		farPlaneBottomRight.X
	) // voxelSize
	local maxX = math.max(
		cameraPos.X,
		farPlaneTopLeft.X,
		farPlaneTopRight.X,
		farPlaneBottomLeft.X,
		farPlaneBottomRight.X
	) // voxelSize
	local minY = math.min(
		cameraPos.Y,
		farPlaneTopLeft.Y,
		farPlaneTopRight.Y,
		farPlaneBottomLeft.Y,
		farPlaneBottomRight.Y
	) // voxelSize
	local maxY = math.max(
		cameraPos.Y,
		farPlaneTopLeft.Y,
		farPlaneTopRight.Y,
		farPlaneBottomLeft.Y,
		farPlaneBottomRight.Y
	) // voxelSize
	local minZ = math.min(
		cameraPos.Z,
		farPlaneTopLeft.Z,
		farPlaneTopRight.Z,
		farPlaneBottomLeft.Z,
		farPlaneBottomRight.Z
	) // voxelSize
	local maxZ = math.max(
		cameraPos.Z,
		farPlaneTopLeft.Z,
		farPlaneTopRight.Z,
		farPlaneBottomLeft.Z,
		farPlaneBottomRight.Z
	) // voxelSize

	-- Now we need to check all voxels within the min and max bounds
	debug.profilebegin("BinarySearch")
	for x = minX, maxX do
		for y = minY, maxY do
			for searchZ = minZ, maxZ do
				-- We are looking for the first visible voxel in this row
				if not isVoxelInFrustum(x, y, searchZ) then
					continue
				end

				-- Now that we have the first visible voxel, we need to find the last visible voxel.
				-- Because the frustum is convex and contains no holes, we know that
				-- the remainder of the row is sorted- inside the frustum, then outside.
				-- This allows us to do a binary search to find the last voxel,
				-- and then all voxels from here to there are inside the frustum.
				local entry, exit = searchZ, minZ - 1
				local left = searchZ
				local right = maxZ

				while left <= right do
					local mid = (left + right) // 2

					if isVoxelInFrustum(x, y, mid) then
						exit = mid
						left = mid + 1
					else
						right = mid - 1
					end
				end

				-- Add all the voxels from the entry to the exit
				for z = entry, exit do
					self:_addVoxelsAroundVertex(Vector3.new(x, y, z), visibleVoxelKeys)
					-- visibleVoxelKeys[Vector3.new(x, y, z)] = true
				end

				-- This row is complete, we don't need to scan further
				break
			end
		end
	end
	debug.profileend()

	debug.profileend()

	return visibleVoxelKeys
end

function CullThrottle.setVoxelSize(self: CullThrottle, voxelSize: number)
	self._voxelSize = voxelSize

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
	self._halfRenderDistance = renderDistance / 2
	self._renderDistanceSq = renderDistance * renderDistance
end

function CullThrottle.setRefreshRates(self: CullThrottle, near: number, far: number)
	if near > 1 then
		near = 1 / near
	end
	if far > 1 then
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

function CullThrottle.getObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?)
	local visibleVoxelKeys = self:_getVisibleVoxelKeys()

	local now = os.clock()
	local cameraPos = CameraCache.Position
	local voxelSize = self._voxelSize
	local halfVoxelSizeVector = Vector3.new(voxelSize / 2, voxelSize / 2, voxelSize / 2)
	local nearRefreshRate = self._nearRefreshRate
	local refreshRateRange = self._refreshRateRange
	local renderDistance = self._renderDistance
	local renderDistanceSq = self._renderDistanceSq
	if CameraCache.FieldOfView < 70 then
		renderDistance *= 2 - CameraCache.FieldOfView / 70
		renderDistanceSq = renderDistance * renderDistance
	end

	local thread = coroutine.create(function()
		debug.profilebegin("UpdateObjects")
		for voxelKey in visibleVoxelKeys do
			local voxel = self._voxels[voxelKey]
			if not voxel then
				continue
			end

			-- Instead of throttling updates for each object by distance, we approximate by computing the distance
			-- to the voxel center. This gives us less precise throttling, but saves a ton of compute
			-- and scales on voxel size instead of object count.
			local voxelWorldPos = (voxelKey * voxelSize) + halfVoxelSizeVector
			local dx = cameraPos.X - voxelWorldPos.X
			local dy = cameraPos.Y - voxelWorldPos.Y
			local dz = cameraPos.Z - voxelWorldPos.Z
			local distSq = dx * dx + dy * dy + dz * dz
			local refreshDelay = nearRefreshRate + (refreshRateRange * math.min(distSq / renderDistanceSq, 1))

			for _, object in voxel do
				local objectData = self._objects[object]
				if not objectData then
					continue
				end

				-- We add jitter to the timings so we don't end up with
				-- every object in the voxel updating on the same frame
				local elapsed = now - objectData.lastUpdateClock
				local jitter = math.random() / 150
				if elapsed + jitter <= refreshDelay then
					-- It is not yet time to update this one
					continue
				end

				coroutine.yield(object, elapsed)
				objectData.lastUpdateClock = now
			end
		end

		debug.profileend()

		return
	end)

	return function()
		if coroutine.status(thread) == "dead" then
			return
		end

		local success, object, lastUpdateClock = coroutine.resume(thread)
		if not success then
			warn("CullThrottle.getObjectsToUpdate thread error: " .. tostring(object))
			return
		end

		return object, lastUpdateClock
	end
end

function CullThrottle.getObjectsInView(self: CullThrottle): () -> Instance?
	local visibleVoxelKeys = self:_getVisibleVoxelKeys()

	local thread = coroutine.create(function()
		for voxelKey in visibleVoxelKeys do
			local voxel = self._voxels[voxelKey]
			if not voxel then
				continue
			end

			for _, object in voxel do
				coroutine.yield(object)
			end
		end

		return
	end)

	return function()
		if coroutine.status(thread) == "dead" then
			return
		end

		local success, object = coroutine.resume(thread)
		if not success then
			warn("CullThrottle.getObjectsToUpdate thread error: " .. tostring(object))
			return
		end

		return object
	end
end

return CullThrottle
