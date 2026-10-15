--!nocheck
-- Roblox Studio MCP bridge plugin.
-- Long-polls the local Node bridge (http://127.0.0.1:44755) for commands, executes them, posts results.
-- Install: copy this file to %LOCALAPPDATA%\Roblox\Plugins\RobloxStudioMCP.lua
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local LogService = game:GetService("LogService")
local CollectionService = game:GetService("CollectionService")

local DEFAULT_PORT = 44755
local PORT = tonumber(plugin:GetSetting("RSMCP_Port")) or DEFAULT_PORT
-- Set this to the same value as BRIDGE_SECRET on the server if you use one.
local SECRET_OVERRIDE = ""
local SECRET = (SECRET_OVERRIDE ~= "" and SECRET_OVERRIDE) or plugin:GetSetting("RSMCP_Secret") or ""
local BASE = "http://127.0.0.1:" .. PORT

------------------------------------------------------------------ context
local function getContext()
	if RunService:IsEdit() then
		return "edit"
	elseif RunService:IsServer() then
		return "server"
	else
		return "client"
	end
end
local CONTEXT = getContext()

------------------------------------------------------------------ output log
local LOG_MAX = 2000
local logBuf, logId = {}, 0
local function pushLog(msg, mtype)
	logId += 1
	table.insert(logBuf, { id = logId, t = os.time(), type = mtype and mtype.Name or "MessageOutput", message = msg })
	if #logBuf > LOG_MAX then
		table.remove(logBuf, 1)
	end
end
pcall(function()
	for _, e in ipairs(LogService:GetLogHistory()) do
		pushLog(e.message, e.messageType)
	end
end)
LogService.MessageOut:Connect(pushLog)

------------------------------------------------------------------ paths
local function escName(n)
	if string.find(n, "[%.%[%]\"]") then
		return '["' .. string.gsub(n, '"', '\\"') .. '"]'
	end
	return n
end

local function getPath(inst)
	if inst == nil then
		return nil
	end
	if inst == game then
		return "game"
	end
	local parts = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(parts, 1, escName(cur.Name))
		cur = cur.Parent
	end
	if cur == nil then
		return "<nil>." .. table.concat(parts, ".")
	end
	return "game." .. table.concat(parts, ".")
end

local function splitPath(p)
	local segs, i, n = {}, 1, #p
	while i <= n do
		local c = string.sub(p, i, i)
		if c == "." then
			i += 1
		elseif c == "[" then
			local q = string.sub(p, i + 1, i + 1)
			local close = string.find(p, q .. "]", i + 2, true)
			if (q == '"' or q == "'") and close then
				table.insert(segs, (string.gsub(string.sub(p, i + 2, close - 1), '\\"', '"')))
				i = close + 2
			else
				error("bad bracket in path: " .. p)
			end
		else
			local j = string.find(p, "[%.%[]", i) or (n + 1)
			table.insert(segs, string.sub(p, i, j - 1))
			i = j
		end
	end
	return segs
end

local function resolve(p, allowMissing)
	if p == nil or p == "" or p == "game" then
		return game
	end
	local segs = splitPath(p)
	local cur = game
	local start = 1
	if segs[1] == "game" then
		start = 2
	elseif segs[1] == "workspace" then
		cur = workspace
		start = 2
	end
	for k = start, #segs do
		local name = segs[k]
		local nxt = cur:FindFirstChild(name)
		if not nxt and cur == game then
			local ok, svc = pcall(game.GetService, game, name)
			if ok then
				nxt = svc
			end
		end
		if not nxt then
			if allowMissing then
				return nil
			end
			error("Instance not found: " .. p .. " (missing '" .. name .. "' under " .. getPath(cur) .. ")")
		end
		cur = nxt
	end
	return cur
end

------------------------------------------------------------------ serialization
local function round(x)
	return math.floor(x * 1e5 + 0.5) / 1e5
end

local function ser(v)
	local t = typeof(v)
	if t == "nil" or t == "boolean" or t == "string" then
		return v
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return { ["$type"] = "number", value = tostring(v) }
		end
		return v
	elseif t == "Vector3" then
		return { ["$type"] = "Vector3", value = { round(v.X), round(v.Y), round(v.Z) } }
	elseif t == "Vector2" then
		return { ["$type"] = "Vector2", value = { round(v.X), round(v.Y) } }
	elseif t == "CFrame" then
		local c = { v:GetComponents() }
		for i, x in ipairs(c) do
			c[i] = round(x)
		end
		local rx, ry, rz = v:ToOrientation()
		return { ["$type"] = "CFrame", value = c, orientationDeg = { round(math.deg(rx)), round(math.deg(ry)), round(math.deg(rz)) } }
	elseif t == "Color3" then
		return { ["$type"] = "Color3", value = { round(v.R), round(v.G), round(v.B) }, hex = "#" .. v:ToHex() }
	elseif t == "BrickColor" then
		return { ["$type"] = "BrickColor", value = v.Name }
	elseif t == "UDim" then
		return { ["$type"] = "UDim", value = { v.Scale, v.Offset } }
	elseif t == "UDim2" then
		return { ["$type"] = "UDim2", value = { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } }
	elseif t == "EnumItem" then
		return { ["$type"] = "Enum", enum = tostring(v.EnumType), value = v.Name }
	elseif t == "NumberRange" then
		return { ["$type"] = "NumberRange", value = { v.Min, v.Max } }
	elseif t == "Rect" then
		return { ["$type"] = "Rect", value = { v.Min.X, v.Min.Y, v.Max.X, v.Max.Y } }
	elseif t == "Instance" then
		return { ["$type"] = "Instance", path = getPath(v), className = v.ClassName }
	elseif t == "table" then
		local out = {}
		for k, x in pairs(v) do
			out[k] = ser(x)
		end
		return out
	else
		return { ["$type"] = t, string = tostring(v) }
	end
end

local function deser(v)
	if type(v) ~= "table" then
		return v
	end
	local ty = v["$type"]
	if ty == nil then
		local out = {}
		for k, x in pairs(v) do
			out[k] = deser(x)
		end
		return out
	end
	local a = v.value
	if ty == "Vector3" then
		return Vector3.new(a[1], a[2], a[3])
	elseif ty == "Vector2" then
		return Vector2.new(a[1], a[2])
	elseif ty == "CFrame" then
		if v.position then
			local pos = Vector3.new(v.position[1], v.position[2], v.position[3])
			if v.lookAt then
				return CFrame.lookAt(pos, Vector3.new(v.lookAt[1], v.lookAt[2], v.lookAt[3]))
			end
			local cf = CFrame.new(pos)
			if v.orientationDeg then
				local o = v.orientationDeg
				cf = cf * CFrame.fromOrientation(math.rad(o[1]), math.rad(o[2]), math.rad(o[3]))
			end
			return cf
		end
		if #a == 3 then
			return CFrame.new(a[1], a[2], a[3])
		end
		return CFrame.new(table.unpack(a, 1, 12))
	elseif ty == "Color3" then
		if v.hex then
			return Color3.fromHex(v.hex)
		elseif v.rgb255 then
			return Color3.fromRGB(v.rgb255[1], v.rgb255[2], v.rgb255[3])
		end
		return Color3.new(a[1], a[2], a[3])
	elseif ty == "BrickColor" then
		return BrickColor.new(a)
	elseif ty == "UDim" then
		return UDim.new(a[1], a[2])
	elseif ty == "UDim2" then
		return UDim2.new(a[1], a[2], a[3], a[4])
	elseif ty == "Enum" then
		local enumName = string.gsub(v.enum or "", "^Enum%.", "")
		return Enum[enumName][a]
	elseif ty == "NumberRange" then
		return NumberRange.new(a[1], a[2])
	elseif ty == "Rect" then
		return Rect.new(a[1], a[2], a[3], a[4])
	elseif ty == "Instance" then
		if v.path == nil then
			return nil
		end
		return resolve(v.path)
	elseif ty == "number" then
		return tonumber(a)
	end
	error("Unknown $type: " .. tostring(ty))
end

------------------------------------------------------------------ undo helpers
local function withUndo(name, fn)
	local rec
	if CONTEXT == "edit" then
		local ok, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "MCP: " .. name)
		if ok then
			rec = id
		end
	end
	local ok, res = pcall(fn)
	if rec then
		ChangeHistoryService:FinishRecording(rec, ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	elseif CONTEXT == "edit" then
		pcall(ChangeHistoryService.SetWaypoint, ChangeHistoryService, "MCP: " .. name)
	end
	if not ok then
		error(res, 0)
	end
	return res
end

local function setProps(inst, props)
	local errors = {}
	-- Parent last so properties apply before the object enters the world.
	local parentVal
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parentVal = v
		else
			local ok, err = pcall(function()
				inst[k] = deser(v)
			end)
			if not ok then
				errors[k] = tostring(err)
			end
		end
	end
	if parentVal ~= nil then
		local ok, err = pcall(function()
			local p = deser(parentVal)
			if type(p) == "string" then
				p = resolve(p)
			end
			inst.Parent = p
		end)
		if not ok then
			errors.Parent = tostring(err)
		end
	end
	return errors
end

------------------------------------------------------------------ commands
local COMMON_PROPS = {
	"Name", "ClassName", "Parent", "Archivable", "CFrame", "Position", "Orientation", "Size", "Color", "BrickColor",
	"Material", "Transparency", "Reflectance", "Anchored", "CanCollide", "CanQuery", "CanTouch", "CastShadow", "Massless",
	"Shape", "PrimaryPart", "WorldPivot", "Text", "TextColor3", "TextSize", "Font", "BackgroundColor3",
	"BackgroundTransparency", "AnchorPoint", "Visible", "ZIndex", "Image", "Enabled", "Disabled", "RunContext", "Value",
	"Brightness", "Range", "Texture", "Face", "MeshId", "TextureID", "Health", "MaxHealth", "WalkSpeed", "JumpPower",
	"SoundId", "Volume", "Playing", "Looped", "Adornee", "Part0", "Part1", "C0", "C1", "Attachment0", "Attachment1",
	"Gravity", "FieldOfView", "CameraType", "ClockTime", "Ambient", "Lighting",
}

local cmds = {}

function cmds.get_studio_state()
	local cam = workspace.CurrentCamera
	local sel = {}
	for _, s in ipairs(Selection:Get()) do
		table.insert(sel, getPath(s))
	end
	return {
		context = CONTEXT,
		isEdit = RunService:IsEdit(),
		isRunning = RunService:IsRunning(),
		isRunMode = RunService:IsRunMode(),
		isServer = RunService:IsServer(),
		isClient = RunService:IsClient(),
		placeId = game.PlaceId,
		gameId = game.GameId,
		placeName = game.Name,
		placeVersion = game.PlaceVersion,
		selection = sel,
		camera = cam and { cframe = ser(cam.CFrame), focus = ser(cam.Focus), fieldOfView = cam.FieldOfView } or nil,
		workspaceChildren = #workspace:GetChildren(),
		logCount = logId,
	}
end

function cmds.list_tree(a)
	local root = resolve(a.path)
	local maxDepth = a.depth or 2
	local maxNodes = a.maxNodes or 800
	local count, truncated = 0, false
	local function walk(inst, d)
		count += 1
		local node = { name = inst.Name, class = inst.ClassName }
		local ok, kids = pcall(inst.GetChildren, inst)
		kids = ok and kids or {}
		if #kids > 0 then
			if d < maxDepth then
				node.children = {}
				for _, c in ipairs(kids) do
					if count >= maxNodes then
						truncated = true
						node.more = #kids - #node.children
						break
					end
					table.insert(node.children, walk(c, d + 1))
				end
			else
				node.childCount = #kids
			end
		end
		return node
	end
	return { path = getPath(root), tree = walk(root, 0), nodes = count, truncated = truncated }
end

function cmds.get_properties(a)
	local inst = resolve(a.path)
	local props = {}
	local list = a.properties or COMMON_PROPS
	for _, name in ipairs(list) do
		local ok, val = pcall(function()
			return inst[name]
		end)
		if ok and typeof(val) ~= "RBXScriptSignal" and typeof(val) ~= "function" then
			props[name] = ser(val)
		elseif a.properties then
			props[name] = { ["$error"] = tostring(val) }
		end
	end
	local attrs = {}
	for k, v in pairs(inst:GetAttributes()) do
		attrs[k] = ser(v)
	end
	return { path = getPath(inst), className = inst.ClassName, properties = props, attributes = attrs, tags = CollectionService:GetTags(inst) }
end

function cmds.set_properties(a)
	local inst = resolve(a.path)
	return withUndo("Set properties on " .. inst.Name, function()
		local errors = setProps(inst, a.properties)
		for k, v in pairs(a.attributes or {}) do
			local ok, err = pcall(inst.SetAttribute, inst, k, deser(v))
			if not ok then
				errors["@" .. k] = tostring(err)
			end
		end
		return { path = getPath(inst), errors = errors }
	end)
end

function cmds.create_instance(a)
	local parent = resolve(a.parent or "Workspace")
	return withUndo("Create " .. a.className, function()
		local inst = Instance.new(a.className)
		if a.name then
			inst.Name = a.name
		end
		local props = a.properties or {}
		props.Parent = nil
		local errors = setProps(inst, props)
		inst.Parent = parent
		return { path = getPath(inst), errors = errors }
	end)
end

function cmds.delete_instance(a)
	local inst = resolve(a.path)
	local p = getPath(inst)
	return withUndo("Delete " .. inst.Name, function()
		-- Parent = nil instead of Destroy() keeps it undoable via ChangeHistoryService.
		inst.Parent = nil
		return { deleted = p }
	end)
end

function cmds.clone_instance(a)
	local inst = resolve(a.path)
	return withUndo("Clone " .. inst.Name, function()
		local c = inst:Clone()
		if not c then
			error("Instance is not Archivable; cannot clone")
		end
		if a.newName then
			c.Name = a.newName
		end
		c.Parent = a.newParent and resolve(a.newParent) or inst.Parent
		return { path = getPath(c) }
	end)
end

function cmds.move_instance(a)
	local inst = resolve(a.path)
	local np = resolve(a.newParent)
	return withUndo("Move " .. inst.Name, function()
		if a.newName then
			inst.Name = a.newName
		end
		inst.Parent = np
		return { path = getPath(inst) }
	end)
end

local function isScript(inst)
	return inst:IsA("LuaSourceContainer")
end

function cmds.get_script_source(a)
	local inst = resolve(a.path)
	if not isScript(inst) then
		error(getPath(inst) .. " is not a script")
	end
	local src
	local ok = pcall(function()
		src = game:GetService("ScriptEditorService"):GetEditorSource(inst)
	end)
	if not ok or src == nil then
		src = inst.Source
	end
	return { path = getPath(inst), className = inst.ClassName, source = src, lines = select(2, string.gsub(src, "\n", "")) + 1 }
end

function cmds.set_script_source(a)
	local inst = resolve(a.path)
	if not isScript(inst) then
		error(getPath(inst) .. " is not a script")
	end
	return withUndo("Edit source " .. inst.Name, function()
		local ok, err = pcall(function()
			game:GetService("ScriptEditorService"):UpdateSourceAsync(inst, function()
				return a.source
			end)
		end)
		if not ok then
			inst.Source = a.source
		end
		return { path = getPath(inst), method = ok and "ScriptEditorService" or ("Source property (" .. tostring(err) .. ")") }
	end)
end

function cmds.run_luau(a)
	local out = {}
	local function cap(kind)
		return function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			local line = table.concat(parts, " ")
			table.insert(out, (kind == "print" and "" or "[" .. kind .. "] ") .. line)
			if kind == "print" then
				print(...)
			else
				warn(...)
			end
		end
	end
	local fn, cerr = loadstring(a.code, "=mcp")
	if not fn then
		return { ok = false, error = "compile error: " .. tostring(cerr), output = out }
	end
	local env = setmetatable({ print = cap("print"), warn = cap("warn"), plugin = plugin }, { __index = getfenv(1) })
	setfenv(fn, env)
	local done, result = false, nil
	local rec
	if CONTEXT == "edit" then
		local okr, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "MCP: run_luau")
		rec = okr and id or nil
	end
	local thread = task.spawn(function()
		result = table.pack(xpcall(fn, function(e)
			return tostring(e) .. "\n" .. debug.traceback(nil, 2)
		end))
		done = true
	end)
	local deadline = os.clock() + (a.timeoutSec or 25)
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if rec then
		ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
	end
	if not done then
		pcall(task.cancel, thread)
		return { ok = false, error = "timeout after " .. tostring(a.timeoutSec or 25) .. "s (thread cancelled)", output = out }
	end
	if not result[1] then
		return { ok = false, error = result[2], output = out }
	end
	local rets = {}
	for i = 2, result.n do
		rets[i - 1] = ser(result[i])
	end
	return { ok = true, returns = rets, output = out }
end

function cmds.get_selection()
	local sel = {}
	for _, s in ipairs(Selection:Get()) do
		table.insert(sel, { path = getPath(s), className = s.ClassName })
	end
	return { selection = sel }
end

function cmds.set_selection(a)
	local list = {}
	for _, p in ipairs(a.paths or {}) do
		table.insert(list, resolve(p))
	end
	Selection:Set(list)
	return cmds.get_selection()
end

function cmds.set_camera(a)
	local cam = workspace.CurrentCamera
	if not cam then
		error("No CurrentCamera")
	end
	if a.fieldOfView then
		cam.FieldOfView = a.fieldOfView
	end
	if a.cframe then
		cam.CFrame = deser(a.cframe)
		cam.Focus = cam.CFrame * CFrame.new(0, 0, -20)
	elseif a.position then
		local pos = Vector3.new(a.position[1], a.position[2], a.position[3])
		if a.lookAt then
			local la = Vector3.new(a.lookAt[1], a.lookAt[2], a.lookAt[3])
			cam.CFrame = CFrame.lookAt(pos, la)
			cam.Focus = CFrame.new(la)
		else
			cam.CFrame = CFrame.new(pos) * cam.CFrame.Rotation
		end
	end
	if a.focus then
		local inst = resolve(a.focus)
		local cf, size
		if inst:IsA("BasePart") then
			cf, size = inst.CFrame, inst.Size
		elseif inst:IsA("Model") or inst:IsA("Folder") or inst == workspace then
			if not inst:IsA("Model") then
				-- bounding box of descendant parts
				local minV, maxV
				for _, d in ipairs(inst:GetDescendants()) do
					if d:IsA("BasePart") then
						local p, s = d.Position, d.Size / 2
						minV = minV and minV:Min(p - s) or (p - s)
						maxV = maxV and maxV:Max(p + s) or (p + s)
					end
				end
				if not minV then
					error("No parts to focus in " .. getPath(inst))
				end
				cf, size = CFrame.new((minV + maxV) / 2), maxV - minV
			else
				cf, size = inst:GetBoundingBox()
			end
		else
			error("Cannot focus " .. inst.ClassName)
		end
		local radius = math.max(size.Magnitude / 2, 1)
		local dist = radius / math.tan(math.rad(cam.FieldOfView / 2)) * 1.2
		local dir = cam.CFrame.LookVector
		cam.CFrame = CFrame.lookAt(cf.Position - dir * dist, cf.Position)
		cam.Focus = CFrame.new(cf.Position)
	end
	return { cframe = ser(cam.CFrame), focus = ser(cam.Focus) }
end

function cmds.start_playtest(a)
	if CONTEXT ~= "edit" then
		error("start_playtest must run in the edit context")
	end
	if RunService:IsRunning() then
		error("A playtest/run is already active")
	end
	local sts = game:GetService("StudioTestService")
	local fnName = (a.mode == "run") and "ExecuteRunModeAsync" or "ExecutePlayModeAsync"
	task.spawn(function()
		local ok, res = pcall(sts[fnName], sts, {})
		pushLog("[MCP] playtest ended: " .. tostring(ok) .. " " .. tostring(res), Enum.MessageType.MessageInfo)
	end)
	return { started = a.mode or "play", api = "StudioTestService:" .. fnName, note = "Poll get_studio_state; server/client contexts connect once the test DataModels load." }
end

function cmds.stop_playtest()
	if CONTEXT == "edit" then
		error("No server context connected; stop the test from Studio (Shift+F5) or call this while the server context is connected")
	end
	local sts = game:GetService("StudioTestService")
	task.defer(function()
		sts:EndTest("stopped by MCP")
	end)
	return { stopping = true }
end

function cmds.get_output_log(a)
	local limit = a.limit or 200
	local since = a.sinceId or 0
	local res = {}
	for i = #logBuf, 1, -1 do
		local e = logBuf[i]
		if e.id <= since then
			break
		end
		if not a.filter or string.find(string.lower(e.message), string.lower(a.filter), 1, true) then
			table.insert(res, 1, e)
			if #res >= limit then
				break
			end
		end
	end
	return { context = CONTEXT, lastId = logId, messages = res }
end

------------------------------------------------------------------ poll loop
local running = false
local status = "idle"
local function setStatus(s)
	if s ~= status then
		status = s
		print("[MCP] " .. CONTEXT .. " bridge: " .. s)
	end
end

local function request(method, path, body)
	local headers = { ["Content-Type"] = "application/json" }
	if SECRET ~= "" then
		headers["X-Bridge-Secret"] = SECRET
	end
	return HttpService:RequestAsync({ Url = BASE .. path, Method = method, Headers = headers, Body = body })
end

local function handle(msg)
	local f = cmds[msg.cmd]
	local ok, res
	if not f then
		ok, res = false, "Unknown command: " .. tostring(msg.cmd)
	else
		ok, res = pcall(f, msg.args or {})
	end
	local payload = { id = msg.id, ok = ok }
	if ok then
		payload.result = res
	else
		payload.error = tostring(res)
	end
	local encOk, body = pcall(HttpService.JSONEncode, HttpService, payload)
	if not encOk then
		body = HttpService:JSONEncode({ id = msg.id, ok = false, error = "Could not encode result: " .. tostring(body) })
	end
	pcall(request, "POST", "/result?context=" .. CONTEXT, body)
end

local function loop()
	local backoff = 1
	while running do
		local info = HttpService:UrlEncode(HttpService:JSONEncode({ placeName = game.Name, placeId = game.PlaceId }))
		local ok, res = pcall(request, "GET", "/poll?context=" .. CONTEXT .. "&info=" .. info)
		if ok and res.StatusCode == 200 then
			backoff = 1
			setStatus("connected")
			local dOk, msg = pcall(HttpService.JSONDecode, HttpService, res.Body)
			if dOk then
				task.spawn(handle, msg)
			end
		elseif ok and res.StatusCode == 204 then
			backoff = 1
			setStatus("connected")
		else
			setStatus("disconnected")
			task.wait(backoff)
			backoff = math.min(backoff * 2, 10)
		end
	end
end

local function start()
	if running then
		return
	end
	running = true
	task.spawn(loop)
end
local function stop()
	running = false
	setStatus("idle")
end

if CONTEXT == "edit" then
	local toolbar = plugin:CreateToolbar("MCP")
	local btn = toolbar:CreateButton("MCP Bridge", "Connect/disconnect Studio from the local MCP server", "rbxasset://textures/ui/GuiImagePlaceholder.png")
	btn.ClickableWhenViewportHidden = true
	local enabled = plugin:GetSetting("RSMCP_Enabled")
	if enabled == nil then
		enabled = true
	end
	btn:SetActive(enabled)
	btn.Click:Connect(function()
		enabled = not enabled
		plugin:SetSetting("RSMCP_Enabled", enabled)
		btn:SetActive(enabled)
		if enabled then
			start()
		else
			stop()
		end
		print("[MCP] bridge " .. (enabled and "enabled" or "disabled") .. " (" .. BASE .. ")")
	end)
	if enabled then
		start()
	end
else
	-- Playtest DataModels (server / client): connect automatically if enabled.
	if plugin:GetSetting("RSMCP_Enabled") ~= false then
		start()
	end
end

plugin.Unloading:Connect(stop)
