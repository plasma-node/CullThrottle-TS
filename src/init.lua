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
	_visibleVoxels: { [Vector3]: boolean },
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
	self._renderDistance = 400
	self._halfRenderDistance = self._renderDistance / 2
	self._renderDistanceSq = self._renderDistance * self._renderDistance
	self._voxels = {}
	self._visibleVoxels = {}
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

function CullThrottle._setVoxelKeyVisible(self: CullThrottle, voxelKey: Vector3)
	local visibleVoxels = self._visibleVoxels

	visibleVoxels[voxelKey] = true

	-- All the voxels that share this vertex
	-- must also visible (at least partially).
	local x, y, z = voxelKey.X, voxelKey.Y, voxelKey.Z
	visibleVoxels[Vector3.new(x - 1, y, z)] = true
	visibleVoxels[Vector3.new(x, y - 1, z)] = true
	visibleVoxels[Vector3.new(x, y, z - 1)] = true
	visibleVoxels[Vector3.new(x - 1, y - 1, z)] = true
	visibleVoxels[Vector3.new(x - 1, y, z - 1)] = true
	visibleVoxels[Vector3.new(x, y - 1, z - 1)] = true
	visibleVoxels[Vector3.new(x - 1, y - 1, z - 1)] = true
end

function CullThrottle._setVoxelsInLineToVisible(self: CullThrottle, startVoxel: Vector3, endVoxel: Vector3): ()
	local x0, y0, z0 = startVoxel.X, startVoxel.Y, startVoxel.Z
	local x1, y1, z1 = endVoxel.X, endVoxel.Y, endVoxel.Z

	local dx = math.abs(x1 - x0)
	local dy = math.abs(y1 - y0)
	local dz = math.abs(z1 - z0)
	local stepX = (x0 < x1) and 1 or -1
	local stepY = (y0 < y1) and 1 or -1
	local stepZ = (z0 < z1) and 1 or -1
	local hypotenuse = math.sqrt(dx * dx + dy * dy + dz * dz)
	local tMaxX = hypotenuse * 0.5 / dx
	local tMaxY = hypotenuse * 0.5 / dy
	local tMaxZ = hypotenuse * 0.5 / dz
	local tDeltaX = hypotenuse / dx
	local tDeltaY = hypotenuse / dy
	local tDeltaZ = hypotenuse / dz

	while x0 ~= x1 or y0 ~= y1 or z0 ~= z1 do
		if tMaxX < tMaxY then
			if tMaxX < tMaxZ then
				x0 = x0 + stepX
				tMaxX = tMaxX + tDeltaX
			elseif tMaxX > tMaxZ then
				z0 = z0 + stepZ
				tMaxZ = tMaxZ + tDeltaZ
			else
				x0 = x0 + stepX
				tMaxX = tMaxX + tDeltaX
				z0 = z0 + stepZ
				tMaxZ = tMaxZ + tDeltaZ
			end
		elseif tMaxX > tMaxY then
			if tMaxY < tMaxZ then
				y0 = y0 + stepY
				tMaxY = tMaxY + tDeltaY
			elseif tMaxY > tMaxZ then
				z0 = z0 + stepZ
				tMaxZ = tMaxZ + tDeltaZ
			else
				y0 = y0 + stepY
				tMaxY = tMaxY + tDeltaY
				z0 = z0 + stepZ
				tMaxZ = tMaxZ + tDeltaZ
			end
		else
			if tMaxY < tMaxZ then
				y0 = y0 + stepY
				tMaxY = tMaxY + tDeltaY
				x0 = x0 + stepX
				tMaxX = tMaxX + tDeltaX
			elseif tMaxY > tMaxZ then
				z0 = z0 + stepZ
				tMaxZ = tMaxZ + tDeltaZ
			else
				x0 = x0 + stepX
				tMaxX = tMaxX + tDeltaX
				y0 = y0 + stepY
				tMaxY = tMaxY + tDeltaY
				z0 = z0 + stepZ
				tMaxZ = tMaxZ + tDeltaZ
			end
		end
		self:_setVoxelKeyVisible(Vector3.new(x0, y0, z0))
	end
end

function CullThrottle._intersectPlane(
	self: CullThrottle,
	normal: Vector3,
	center: Vector3,
	origin: Vector3,
	direction: Vector3,
	length: number
): number?
	local denominator = normal:Dot(direction)
	if math.abs(denominator) <= 1e-6 then
		return nil
	end

	local t = (center - origin):Dot(normal) / denominator
	if t >= 1e-7 and t <= length then
		return t
	end

	return nil
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
	table.clear(self._visibleVoxels)
	local now = os.clock()

	-- We'll start by spending up to 0.1 milliseconds processing the queued object refreshes
	debug.profilebegin("ObjectRefreshQueue")
	while (not self._objectRefreshQueue:empty()) and (os.clock() - now < 0.0001) do
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

	local thread = coroutine.create(function()
		local voxelSize = self._voxelSize
		local renderDistance = self._renderDistance
		-- For smaller FOVs, we increase render distance
		if CameraCache.FieldOfView < 70 then
			renderDistance *= 2 - CameraCache.FieldOfView / 70
		end
		local distance2 = renderDistance / 2

		local renderDistanceSq = renderDistance * renderDistance
		local nearRefreshRate = self._nearRefreshRate
		local refreshRateRange = self._refreshRateRange
		local halfVoxelSizeVector = Vector3.one * (voxelSize / 2)
		local cameraCFrame = CameraCache.CFrame
		local cameraPos = CameraCache.Position
		local rightVec, upVec = cameraCFrame.RightVector, cameraCFrame.UpVector

		local farPlaneHeight2 = CameraCache.HalfTanFOV * renderDistance
		local farPlaneWidth2 = farPlaneHeight2 * CameraCache.AspectRatio
		local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -renderDistance)
		local farPlaneTopLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, farPlaneHeight2, 0)
		local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
		local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
		local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)
		local frustumCFrameInverse = (cameraCFrame * CFrame.new(0, 0, -distance2)):Inverse()

		local rightNormal = upVec:Cross(cameraPos - farPlaneBottomRight).Unit
		local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
		local topNormal = rightVec:Cross(farPlaneTopRight - cameraPos).Unit
		local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

		local normals = {
			rightNormal,
			cameraPos,
			leftNormal,
			cameraPos,
			cameraCFrame.LookVector,
			farPlaneCFrame.Position,
			topNormal,
			cameraPos,
			bottomNormal,
			cameraPos,
		}

		local minBound = cameraPos
			:Min(farPlaneTopLeft)
			:Min(farPlaneTopRight)
			:Min(farPlaneBottomLeft)
			:Min(farPlaneBottomRight) // voxelSize
		local maxBound = cameraPos
			:Max(farPlaneTopLeft)
			:Max(farPlaneTopRight)
			:Max(farPlaneBottomLeft)
			:Max(farPlaneBottomRight) // voxelSize

		debug.profilebegin("FindVisibleVoxels")

		debug.profilebegin("SetCornerVoxels")
		-- The camera and corners should always be inside
		local cameraVoxelKey = cameraPos // voxelSize
		self:_setVoxelKeyVisible(cameraVoxelKey)
		self:_setVoxelKeyVisible(farPlaneTopLeft // voxelSize)
		self:_setVoxelKeyVisible(farPlaneTopRight // voxelSize)
		self:_setVoxelKeyVisible(farPlaneBottomLeft // voxelSize)
		self:_setVoxelKeyVisible(farPlaneBottomRight // voxelSize)
		debug.profileend()

		-- Now we raycast and find where the ray enters and exits the frustum
		-- and set all the voxels in between to visible
		debug.profilebegin("RaycastFrustum")
		local widthEpsilon = farPlaneWidth2 + 1e-4
		local heightEpsilon = farPlaneHeight2 + 1e-4
		local depthEpsilon = distance2 + 1e-4
		local rayLength = (maxBound.Z - minBound.Z + 1) * voxelSize
		local rayDirection = Vector3.zAxis

		for x = minBound.X, maxBound.X do
			for y = minBound.Y, maxBound.Y do
				local rayOrigin = Vector3.new(x * voxelSize, y * voxelSize, minBound.Z * voxelSize)

				local nearestHitDist, secondNearestHitDist = math.huge, math.huge
				local nearestPoint, secondNearestPoint = nil, nil
				for i = 1, 10, 2 do
					local normal, center = normals[i], normals[i + 1]
					local dist = self:_intersectPlane(normal, center, rayOrigin, rayDirection, rayLength)
					if dist then
						local point = rayOrigin + rayDirection * dist

						-- Check if point lies outside frustum OBB
						local relativeToOBB = frustumCFrameInverse * point
						if
							relativeToOBB.X > widthEpsilon
							or relativeToOBB.X < -widthEpsilon
							or relativeToOBB.Y > heightEpsilon
							or relativeToOBB.Y < -heightEpsilon
							or relativeToOBB.Z > depthEpsilon
							or relativeToOBB.Z < -depthEpsilon
						then
							continue
						end

						-- Check if point lies outside a frustum plane
						local lookToCell = point - cameraPos
						if
							topNormal:Dot(lookToCell) > 1e-3
							or leftNormal:Dot(lookToCell) > 1e-3
							or rightNormal:Dot(lookToCell) > 1e-3
							or bottomNormal:Dot(lookToCell) > 1e-3
						then
							continue
						end

						if dist < nearestHitDist then
							secondNearestHitDist = nearestHitDist
							secondNearestPoint = nearestPoint
							nearestHitDist = dist
							nearestPoint = point
						elseif dist < secondNearestHitDist then
							secondNearestHitDist = dist
							secondNearestPoint = point
						end
					end
				end

				if nearestPoint and secondNearestPoint then
					local startVoxel = nearestPoint // voxelSize
					local endVoxel = secondNearestPoint // voxelSize

					-- Now we can set all the voxels between the start and end voxel keys to visible
					for z = startVoxel.Z, endVoxel.Z do
						self:_setVoxelKeyVisible(Vector3.new(x, y, z))
					end
				end
			end
		end
		debug.profileend()

		debug.profileend()

		debug.profilebegin("UpdateObjects")
		for voxelKey in self._visibleVoxels do
			local voxel = self._voxels[voxelKey]
			if not voxel then
				continue
			end

			-- Instead of throttling updates for each object by distance, we approximate by computing the distance
			-- to the voxel center. This gives us less precise throttling, but saves a ton of compute
			-- and scales on voxel size instead of object count.
			debug.profilebegin("DistanceThrottling")
			local voxelWorldPos = (voxelKey * voxelSize) + halfVoxelSizeVector
			local dx = cameraPos.X - voxelWorldPos.X
			local dy = cameraPos.Y - voxelWorldPos.Y
			local dz = cameraPos.Z - voxelWorldPos.Z
			local distSq = dx * dx + dy * dy + dz * dz
			local refreshDelay = nearRefreshRate + (refreshRateRange * math.min(distSq / renderDistanceSq, 1))
			debug.profileend()

			debug.profilebegin("IterVoxelUpdates")
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
			debug.profileend()
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

return CullThrottle
