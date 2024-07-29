--[[
    Reading properties from a datamodel object every frame is not
    negligible in terms of performance. This is why we have the CameraCache to cache
    the properties we're interested in. This way, we can avoid reading the properties
    every frame, especially the ones that don't update often.
--]]

local FOV_PADDING = 5

export type CameraCache = {
	Object: Camera,
	CFrame: CFrame,
	Position: Vector3,
	FieldOfView: number,
	HalfTanFOV: number,
	ViewportSize: Vector2,
	AspectRatio: number,
}

local CameraCache: CameraCache = {
	Object = workspace.CurrentCamera,
	CFrame = workspace.CurrentCamera.CFrame,
	Position = workspace.CurrentCamera.CFrame.Position,
	FieldOfView = workspace.CurrentCamera.FieldOfView + FOV_PADDING,
	HalfTanFOV = math.tan(math.rad((workspace.CurrentCamera.FieldOfView + FOV_PADDING) / 2)),
	ViewportSize = workspace.CurrentCamera.ViewportSize,
	AspectRatio = workspace.CurrentCamera.ViewportSize.X / workspace.CurrentCamera.ViewportSize.Y,
}

local cameraConnections: { [string]: RBXScriptConnection } = {}

local function initCamera(camera: Camera)
	for _, connection in cameraConnections do
		connection:Disconnect()
	end
	table.clear(cameraConnections)

	CameraCache.Object = camera
	CameraCache.CFrame = CameraCache.Object.CFrame
	CameraCache.ViewportSize = CameraCache.Object.ViewportSize
	CameraCache.FieldOfView = CameraCache.Object.FieldOfView + FOV_PADDING
	CameraCache.Position = CameraCache.CFrame.Position
	CameraCache.AspectRatio = CameraCache.ViewportSize.X / CameraCache.ViewportSize.Y
	CameraCache.HalfTanFOV = math.tan(math.rad(CameraCache.FieldOfView / 2))

	cameraConnections.CFrameChanged = CameraCache.Object:GetPropertyChangedSignal("CFrame"):Connect(function()
		CameraCache.CFrame = CameraCache.Object.CFrame
		CameraCache.Position = CameraCache.CFrame.Position
	end)
	cameraConnections.FieldOfViewChanged = CameraCache.Object:GetPropertyChangedSignal("FieldOfView"):Connect(function()
		CameraCache.FieldOfView = CameraCache.Object.FieldOfView + FOV_PADDING
		CameraCache.HalfTanFOV = math.tan(math.rad(CameraCache.FieldOfView / 2))
	end)
	cameraConnections.ViewportSizeChanged = CameraCache.Object
		:GetPropertyChangedSignal("ViewportSize")
		:Connect(function()
			CameraCache.ViewportSize = CameraCache.Object.ViewportSize
			CameraCache.AspectRatio = CameraCache.ViewportSize.X / CameraCache.ViewportSize.Y
		end)
end

initCamera(workspace.CurrentCamera)

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	initCamera(workspace.CurrentCamera)
end)

return CameraCache
