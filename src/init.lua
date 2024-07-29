--!strict
--!optimize 2

local RunService = game:GetService("RunService")

if RunService:IsServer() and not RunService:IsEdit() then
	error("CullThrottle is a client side effect and cannot be used on the server")
end

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
	_objects: { [Instance]: {
		voxelKey: Vector3,
		position: Vector3,
		lastUpdateClock: number,
	} },
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

function CullThrottle.new(): CullThrottle
	local self = setmetatable({}, CullThrottle)

	self._voxelSize = 75
	self._farRefreshRate = 1 / 10
	self._nearRefreshRate = 1 / 45
	self._refreshRateRange = self._farRefreshRate - self._nearRefreshRate
	self._renderDistance = 500
	self._halfRenderDistance = self._renderDistance / 2
	self._renderDistanceSq = self._renderDistance * self._renderDistance
	self._voxels = {}
	self._objects = {}
	self._visibleVoxels = {}

	return self
end

function CullThrottle._getPositionOfObject(self: CullThrottle, object: Instance): Vector3?
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return nil
	end

	if object:IsA("BasePart") then
		return object.Position
	elseif object:IsA("PVInstance") then
		return object:GetPivot().Position
	elseif object:IsA("Bone") then
		return object.TransformedWorldCFrame.Position
	elseif object:IsA("Attachment") then
		return object.WorldPosition
	elseif object:IsA("Beam") then
		-- Beams are roughly located between their attachments
		local attachment0, attachment1 = object.Attachment0, object.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return nil
		end
		return (attachment0.WorldPosition + attachment1.WorldPosition) / 2
	elseif object:IsA("Light") or object:IsA("Sound") or object:IsA("ParticleEmitter") then
		-- These effect objects are positioned based on their parent
		if not object.Parent then
			warn("Cannot determine position of " .. object.ClassName .. " since it is not parented")
			return nil
		end
		return self:_getPositionOfObject(object.Parent)
	end

	-- We don't know how to get the position of this,
	-- so let's assume it's at the parent position
	if not object.Parent then
		warn("Cannot determine position of " .. object.ClassName .. ", unknown class with no parent")
		return nil
	end

	local parentPosition = self:_getPositionOfObject(object.Parent)
	if not parentPosition then
		warn("Cannot determine position of " .. object:GetFullName() .. ", ancestry objects lack position info")
	end

	return parentPosition
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
	local position = self:_getPositionOfObject(object)
	if not position then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, position is unknown")
	end

	local objectData = {
		voxelKey = position // self._voxelSize,
		position = position,
		lastUpdateClock = os.clock(),
	}

	self._objects[object] = objectData

	self:_insertToVoxel(objectData.voxelKey, object)
end

function CullThrottle.remove(self: CullThrottle, object: Instance)
	local objectData = self._objects[object]
	if objectData then
		self._objects[object] = nil

		local voxel = self._voxels[objectData.voxelKey]
		local objectIndex = table.find(voxel, object)
		if objectIndex then
			local n = #voxel

			if n == 1 then
				-- Lets just cleanup this now empty voxel instead
				self._voxels[objectData.voxelKey] = nil
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
	end
end

function CullThrottle.getObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?)
	table.clear(self._visibleVoxels)
	local now = os.clock()

	local thread = coroutine.create(function()
		local voxelSize = self._voxelSize
		local renderDistance = self._renderDistance
		-- For smaller FOVs, we increase render distance
		if CameraCache.FieldOfView < 70 then
			renderDistance *= 2 - CameraCache.FieldOfView / 70
		end

		local renderDistanceSq = renderDistance * renderDistance
		local nearRefreshRate = self._nearRefreshRate
		local refreshRateRange = self._refreshRateRange
		local cameraCFrame = CameraCache.CFrame
		local cameraPos = CameraCache.Position
		local rightVec, upVec = cameraCFrame.RightVector, cameraCFrame.UpVector

		local distance2 = self._halfRenderDistance
		local farPlaneHeight2 = CameraCache.HalfTanFOV * renderDistance
		local farPlaneWidth2 = farPlaneHeight2 * CameraCache.AspectRatio
		local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -renderDistance)
		local farPlaneTopLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, farPlaneHeight2, 0)
		local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
		local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
		local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)
		local frustumCFrameInverse = (cameraCFrame * CFrame.new(0, 0, -distance2)):Inverse()

		local rightNormal = upVec:Cross(farPlaneBottomRight - cameraPos).Unit
		local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
		local topNormal = rightVec:Cross(cameraPos - farPlaneTopRight).Unit
		local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

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

		local function isVoxelKeyInView(voxelKey: Vector3): boolean
			-- Check if we already know the answer
			if self._visibleVoxels[voxelKey] then
				return true
			end

			local point = voxelKey * voxelSize

			-- Check if point lies outside frustum OBB
			local relativeToOBB = frustumCFrameInverse * point
			if
				relativeToOBB.X > farPlaneWidth2
				or relativeToOBB.X < -farPlaneWidth2
				or relativeToOBB.Y > farPlaneHeight2
				or relativeToOBB.Y < -farPlaneHeight2
				or relativeToOBB.Z > distance2
				or relativeToOBB.Z < -distance2
			then
				return false
			end

			-- Check if point lies outside a frustum plane
			local lookToCell = point - cameraPos
			if
				topNormal:Dot(lookToCell) < 0
				or leftNormal:Dot(lookToCell) > 0
				or rightNormal:Dot(lookToCell) < 0
				or bottomNormal:Dot(lookToCell) > 0
			then
				return false
			end

			return true
		end

		debug.profilebegin("FindVisibleVoxels")

		local cameraVoxelKey = cameraPos // voxelSize
		local farPlaneVoxelKey = farPlaneCFrame.Position // voxelSize
		local topLeftVoxelKey = farPlaneTopLeft // voxelSize
		local topRightVoxelKey = farPlaneTopRight // voxelSize
		local bottomLeftVoxelKey = farPlaneBottomLeft // voxelSize
		local bottomRightVoxelKey = farPlaneBottomRight // voxelSize

		-- The camera should always be inside
		self:_setVoxelKeyVisible(cameraVoxelKey)

		-- We know the voxels in straight in front of us will all be visible, so
		-- we can skip expensive visiblity checks on them
		self:_setVoxelsInLineToVisible(cameraVoxelKey, farPlaneVoxelKey)
		-- We similarly know the voxels along the frustum edges are visible
		self:_setVoxelsInLineToVisible(cameraVoxelKey, topLeftVoxelKey)
		self:_setVoxelsInLineToVisible(cameraVoxelKey, topRightVoxelKey)
		self:_setVoxelsInLineToVisible(cameraVoxelKey, bottomLeftVoxelKey)
		self:_setVoxelsInLineToVisible(cameraVoxelKey, bottomRightVoxelKey)
		self:_setVoxelsInLineToVisible(topLeftVoxelKey, bottomRightVoxelKey)
		self:_setVoxelsInLineToVisible(topRightVoxelKey, bottomLeftVoxelKey)
		self:_setVoxelsInLineToVisible(topLeftVoxelKey, bottomLeftVoxelKey)
		self:_setVoxelsInLineToVisible(topRightVoxelKey, bottomRightVoxelKey)

		-- Now we have to actually search and fill in the frustum

		for x = minBound.X, maxBound.X do
			for y = minBound.Y, maxBound.Y do
				for searchZ = minBound.Z, maxBound.Z do
					-- We are looking for the first visible voxel in this row
					if not isVoxelKeyInView(Vector3.new(x, y, searchZ)) then
						continue
					end

					-- Now that we have the first visible voxel, we need to find the last visible voxel.
					-- Because the frustum is convex and contains no holes, we know that
					-- the remainder of the row is sorted- inside the frustum, then outside.
					-- This allows us to do a binary search to find the last voxel,
					-- and then all voxels from here to there are inside the frustum.
					local entry, exit = searchZ, minBound.Z - 1
					local left = searchZ
					local right = maxBound.Z

					while left <= right do
						local mid = (left + right) // 2
						local midVoxelKey = Vector3.new(x, y, mid)

						if isVoxelKeyInView(midVoxelKey) then
							exit = mid
							left = mid + 1
						else
							right = mid - 1
						end
					end

					-- Add all the voxels from the entry to the exit
					for z = entry, exit do
						self:_setVoxelKeyVisible(Vector3.new(x, y, z))
					end

					break
				end
			end
		end
		debug.profileend()

		debug.profilebegin("UpdateObjects")
		for voxelKey in self._visibleVoxels do
			local voxel = self._voxels[voxelKey]
			if not voxel then
				continue
			end

			for _, object in voxel do
				local objectData = self._objects[object]
				if not objectData then
					continue
				end

				-- Throttle object updates based on distance,
				-- so distant objects update less frequently
				debug.profilebegin("DistanceThrottling")
				local objectPos = objectData.position
				local dx = cameraPos.X - objectPos.X
				local dy = cameraPos.Y - objectPos.Y
				local dz = cameraPos.Z - objectPos.Z
				local distSq = dx * dx + dy * dy + dz * dz
				local refreshDelay = nearRefreshRate + (refreshRateRange * (distSq / renderDistanceSq))

				local elapsed = now - objectData.lastUpdateClock
				-- Add a bit of jitter to the timings so we don't get spikes
				-- of objects all updating on the same frame
				local jitter = math.random() / 200
				debug.profileend()
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

return CullThrottle
