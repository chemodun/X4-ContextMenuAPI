-- context_menu_api.lua
-- Context Menu API — internal implementation.
-- The cmAPI table is exposed via Register_Require_With_Init so consumers
-- can require("extensions.context_menu_api.ui.context_menu_api") to access it.
--
-- Flow:
--   menu.createContextFrame() intercepted
--     → fires AddUITriggeredEvent("Context_Menu_API", "onOpen", {menuName, mode, data})
--     → delays 2 onUpdate frames (MD has time to write temp entries to blackboard)
--     → calls real createContextFrame
--     → UIX createContextFrame_on_end fires → onCreateContextFrame()
--         → appends registered Lua entries  (vanillaEntries[mode])
--         → builds custom-mode table       (customModes[mode])
--         → injects any MD-provided entries (tempMdEntries)

local ffi = require("ffi")
local C = ffi.C

-- GetPlayerID is declared in vanilla menu_map.lua; safe to re-declare.
ffi.cdef [[
  typedef uint64_t UniverseID;
  UniverseID GetPlayerID(void);
]]


local cmAPI = {
  pendingCallbacks = {},

  -- registered entries for vanilla modes  { [modeString] = { {filter, build}, ... } }
  vanillaEntries = {},

  -- registered custom modes (blank frame)  { [modeId] = buildFn(builder, data) }
  customModes = {},

  -- nav stack: each entry = { mode = string, data = table }
  navStack = {},

  -- temp entries written by MD in response to the "onOpen" signal
  tempMdEntries = {},

  -- frame-delay state
  delaying    = false,
  pendingArgs = nil,

  -- set in Init()
  playerId = nil,
  menuMap  = nil,
}

-- *** Debug helpers ***

local debugLevel = "none" -- "none" | "debug" | "trace"

local function debug(msg)
  if debugLevel ~= "none" and type(DebugError) == "function" then
    DebugError("ContextMenuAPI: " .. msg)
  end
end

local function trace(msg)
  if debugLevel == "trace" then
    debug(msg)
  end
end

-- LuaJIT compat: prefer table.unpack, fall back to the Lua 5.1 global unpack
local tableUnpack = table.unpack or unpack

-- *** Frame-delay mechanism via menu.onUpdate ***

local function scheduleNextFrame(cb)
  table.insert(cmAPI.pendingCallbacks, cb)
end

-- *** Builder: append to an existing vanilla context table ***
-- Found via contextFrame.content[i].index == 1 (1-column table).

-- *** Builder factory ***
-- addRow(interactive, props)   — adds a row and returns it
-- addEmptyRow(height, props)   — adds a spacer row (no return value needed)
--
-- Builder methods accept an optional opts table:
--   opts.icon          — icon name to display on the entry widget
--   opts.text2         — secondary right-side text (subMenuButton defaults to ">")
--   opts.mouseOver     — mouseover tooltip text
--   opts.mouseOverIcon — icon name for the mouseover tooltip

local function makeBuilder(addRow, addEmptyRow)
  local b = {}
  local lastWasBack = false

  local function doSeparator()
    addEmptyRow(math.floor(Helper.standardTextHeight / 2), { fixed = true })
  end

  local function flushBack()
    if lastWasBack then
      lastWasBack = false
      doSeparator()
    end
  end

  function b.header(text)
    flushBack()
    local row = addRow(false, { fixed = true })
    row[1]:createText(text or "", Helper.headerRowCenteredProperties)
  end

  function b.separator()
    -- explicit separator after back: absorb the pending auto-separator
    lastWasBack = false
    doSeparator()
  end

  function b.entryButton(text, onClick, opts)
    flushBack()
    opts = opts or {}
    -- active defaults to true; MD delivers booleans as integers (0/1)
    local active = not (opts.active == false or opts.active == 0)
    -- mouseOverIcon is embedded inline using the X4 icon escape sequence
    local mouseOverText = nil
    if opts.mouseOver and opts.mouseOver ~= "" then
      if opts.mouseOverIcon and opts.mouseOverIcon ~= "" then
        mouseOverText = "\027[" .. opts.mouseOverIcon .. "] " .. opts.mouseOver
      else
        mouseOverText = opts.mouseOver
      end
    end
    -- icon embedded inline via X4 escape sequence
    local displayText = (opts.icon and opts.icon ~= "") and ("\027[" .. opts.icon .. "] " .. text) or text
    local rowId = opts.id or ("cma_" .. tostring(text))
    local row = addRow(rowId, { fixed = true })
    local cell = row[1]:createButton({
      bgColor        = Color["button_background_hidden"],
      highlightColor = Color["button_highlight_default"],
      height         = Helper.standardTextHeight,
      mouseOverText  = mouseOverText,
      active         = active,
    }):setText(displayText, { color = rawget(Color, opts.textColor) or Color["text_normal"] })
    if opts.text2 and opts.text2 ~= "" then
      cell:setText2(opts.text2, { halign = "right", color = rawget(Color, opts.text2Color) or Color["text_normal"] })
    end
    if active and onClick then
      row[1].handlers.onClick = onClick
    end
  end

  function b.subMenuButton(text, modeId, opts)
    local o = {
      id            = modeId,
      icon          = opts and opts.icon,
      text2         = (opts and opts.text2) or "\027[table_arrow_inv_right]",
      textColor     = opts and opts.textColor,
      text2Color    = opts and opts.text2Color,
      mouseOver     = opts and opts.mouseOver,
      mouseOverIcon = opts and opts.mouseOverIcon,
    }
    b.entryButton(text, function() cmAPI.push(modeId) end, o)
  end

  function b.back(text)
    text = (text and text ~= "") and ("\027[table_arrow_inv_left] " .. text) or "\027[table_arrow_inv_left] Back"
    b.entryButton(text, function() cmAPI.goBack() end)
    lastWasBack = true
  end

  return b
end

-- Append into a vanilla 1-column table (uses metatable dispatch)
local function makeAppendBuilder(menuTable)
  local idx = getmetatable(menuTable).__index
  return makeBuilder(
    function(interactive, props) return idx.addRow(menuTable, interactive, props) end,
    function(height, props)      idx.addEmptyRow(menuTable, height, props) end
  )
end

-- Fill a new table in a custom-mode blank frame (uses normal method calls)
local function makeTableBuilder(ftable)
  return makeBuilder(
    function(interactive, props) return ftable:addRow(interactive, props) end,
    function(height, props)
      local row = ftable:addRow(false, props)
      row[1]:createText(" ", { fontsize = 1, minRowHeight = height })
    end
  )
end

-- *** Navigation ***

function cmAPI.push(modeId)
  local menu = cmAPI.menuMap
  if not menu then return end
  table.insert(cmAPI.navStack, {
    mode = menu.contextMenuMode,
    data = menu.contextMenuData,
  })
  local saved = cmAPI.navStack[#cmAPI.navStack].data
  menu.contextMenuMode = modeId
  menu.contextMenuData = {
    xoffset = saved.xoffset,
    yoffset = saved.yoffset,
    width   = saved.width,
  }
  menu.createContextFrame()
end

function cmAPI.goBack()
  local menu = cmAPI.menuMap
  if not menu then return end
  if #cmAPI.navStack == 0 then
    menu.closeContextMenu()
    return
  end
  local prev = table.remove(cmAPI.navStack)
  menu.contextMenuMode = prev.mode
  menu.contextMenuData = prev.data
  menu.createContextFrame()
end

-- *** Find the vanilla 1-column table inside a contextFrame ***

local function findVanillaTable(contextFrame)
  if type(contextFrame.content) ~= "table" then return nil end
  for _, item in ipairs(contextFrame.content) do
    if type(item) == "table" and item.index == 1 then
      return item
    end
  end
  return nil
end

-- *** UIX createContextFrame_on_end / refreshContextFrame_on_end callback ***

local function onCreateContextFrame(contextFrame, contextMenuData, contextMenuMode)
  local isCustom = cmAPI.customModes[contextMenuMode] ~= nil

  -- Any fresh non-custom open clears stale nav stack (e.g. after ESC)
  if not isCustom then
    cmAPI.navStack = {}
  end

  -- 1. Append Lua-registered entries for vanilla modes
  local entries = cmAPI.vanillaEntries[contextMenuMode]
  if entries then
    local menuTable = findVanillaTable(contextFrame)
    if menuTable then
      local builder = makeAppendBuilder(menuTable)
      for _, spec in ipairs(entries) do
        local ok, err = pcall(function()
          if (not spec.filter) or spec.filter(contextMenuData) then
            spec.build(builder, contextMenuData)
          end
        end)
        if not ok then
          debug("error in vanilla entry for '" .. tostring(contextMenuMode) .. "': " .. tostring(err))
        end
      end
    end
  end

  -- 2. Build a custom mode (blank frame — no vanilla table exists)
  if isCustom then
    local buildFn = cmAPI.customModes[contextMenuMode]
    local width   = (contextMenuData and contextMenuData.width) or Helper.scaleX(200)
    local ftable  = contextFrame:addTable(1, {
      tabOrder                 = 1,
      x                        = Helper.borderSize,
      y                        = Helper.borderSize,
      width                    = width - 2 * Helper.borderSize,
      defaultInteractiveObject = true,
    })
    ftable:setColWidthPercent(1, 100)
    local builder = makeTableBuilder(ftable)
    local ok, err = pcall(buildFn, builder, contextMenuData)
    if not ok then
      debug("error in custom mode '" .. tostring(contextMenuMode) .. "': " .. tostring(err))
    end
  end

  -- 3. Inject MD-provided temp entries (collected during the 2-frame delay)
  if #cmAPI.tempMdEntries > 0 then
    local menuTable = findVanillaTable(contextFrame)
    if menuTable then
      local builder = makeAppendBuilder(menuTable)
      local startIdx = 1
      -- For custom modes: auto-inject back after any leading header.
      -- MD consumers must NOT send an explicit 'back' entry (it is skipped).
      if isCustom then
        local first = cmAPI.tempMdEntries[1]
        if first and first.type == "header" then
          builder.header(first.text or "")
          startIdx = 2
        end
        builder.back()
      end
      for i = startIdx, #cmAPI.tempMdEntries do
        local entry = cmAPI.tempMdEntries[i]
        local t = entry.type
        local opts = {
          id            = entry.id,
          icon          = entry.icon,
          text2         = entry.text2,
          textColor     = entry.textColor,
          text2Color    = entry.text2Color,
          mouseOver     = entry.mouseOver,
          mouseOverIcon = entry.mouseOverIcon,
        }
        if t == "separator" then
          builder.separator()
        elseif t == "menuItem" then
          -- active: MD sends boolean as integer (0/1); normalize to real bool
          local active = not (entry.active == false or entry.active == 0)
          local id = entry.id or ""
          local onClick = nil
          if active and id ~= "" then
            local keepOpen = entry.keepOpen == true or entry.keepOpen == 1
            onClick = function()
              AddUITriggeredEvent("Context_Menu_API", "action", id)
              if not keepOpen then
                cmAPI.menuMap.closeContextMenu()
              end
            end
          end
          opts.active = active
          builder.entryButton(entry.text or "", onClick, opts)
        elseif t == "subMenu" then
          builder.subMenuButton(entry.text or "", entry.id or "", opts)
        elseif t == "header" then
          builder.header(entry.text or "")
          -- 'back' is silently skipped — auto-injected above for custom modes
        end
      end
    end
    cmAPI.tempMdEntries = {}
  end
end

-- *** MD signal helpers ***

-- Serialize contextMenuData to a table safe for AddUITriggeredEvent
-- (strips cdata and nested tables; keeps scalars only)
local function sanitizeForMD(data)
  if type(data) ~= "table" then return {} end
  local out = {}
  for k, v in pairs(data) do
    local t = type(v)
    if t == "string" or t == "boolean" or t == "number" then
      out[k] = v
    elseif t == "cdata" then
      out[k] = tostring(v)
    end
  end
  return out
end

-- Read MD-provided entries from the blackboard into impl.tempMdEntries.
-- Called in the 2-frame delay callback, after MD has had a full tick to process
-- the "onOpen" event and write its entries synchronously via signal_cue_instantly.
local function readMdEntries()
  local entries = GetNPCBlackboard(cmAPI.playerId, "$cma_temp_entries")
  if entries == nil then return end
  SetNPCBlackboard(cmAPI.playerId, "$cma_temp_entries", nil)
  for _, entry in ipairs(entries) do
    table.insert(cmAPI.tempMdEntries, entry)
  end
end

-- *** Menu patch ***

local egoMenuMapCreateContextFrame = {}
local egoMenuMapOnUpdate = {}

local function patchMenu(menuToPatch)
  local menu = menuToPatch
  if not menu then
    debug("could not find menu to patch: " .. tostring(menuToPatch))
    return
  end
  -- Wrap onUpdate: fire pending 1-frame callbacks before the original handler
  egoMenuMapOnUpdate[menu.name] = menu.onUpdate
  menu.onUpdate = function(...)
    if #cmAPI.pendingCallbacks > 0 then
      local cbs        = cmAPI.pendingCallbacks
      cmAPI.pendingCallbacks = {}
      for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb)
        if not ok then
          debug("frame callback error: " .. tostring(err))
        end
      end
    end
    egoMenuMapOnUpdate[menu.name](...)
  end

  -- Intercept createContextFrame for MD signal + 2-frame delay
  egoMenuMapCreateContextFrame[menu.name] = menu.createContextFrame
  menu.createContextFrame = function(...)
    local args = { ... }

    -- If already waiting, just update the args (e.g. rapid re-open)
    if cmAPI.delaying then
      cmAPI.pendingArgs = args
      return
    end

    cmAPI.delaying      = true
    cmAPI.pendingArgs   = args
    cmAPI.tempMdEntries = {}
    SetNPCBlackboard(cmAPI.playerId, "$cma_register_modes", nil)
    trace("createContextFrame intercepted, mode = " .. tostring(menu.contextMenuMode) .. " - firing onOpen event for MD")

    -- Signal MD: includes menu.name so MD conditions can distinguish menus
    AddUITriggeredEvent("Context_Menu_API", "onOpen", {
      menuName = menu.name,
      mode     = menu.contextMenuMode or "",
      data     = sanitizeForMD(menu.contextMenuData),
    })

    -- Delay 2 frames. AddUITriggeredEvent queues the MD event for the MD
    -- update that runs AFTER the current Lua onUpdate completes. So after
    -- frame 1 MD has written its entries; frame 2 is when we safely read them.
    scheduleNextFrame(function()
      -- Frame 1: MD is processing the onOpen event this tick. Wait one more.
      scheduleNextFrame(function()
        cmAPI.delaying = false
        trace("2-frame delay over, calling real createContextFrame and injecting MD entries")
        readMdEntries()
        egoMenuMapCreateContextFrame[menu.name](tableUnpack(cmAPI.pendingArgs))
      end)
    end)
  end
end

-- *** Init ***

local function Init()
  cmAPI.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

  local Lib = require("extensions.sn_mod_support_apis.ui.Library")
  cmAPI.menuMap = Lib.Get_Egosoft_Menu("MapMenu")

  patchMenu(cmAPI.menuMap)

  local menuMap = cmAPI.menuMap
  if type(menuMap.registerCallback) == "function" then
    menuMap.registerCallback("createContextFrame_on_end", onCreateContextFrame)
    menuMap.registerCallback("refreshContextFrame_on_end", onCreateContextFrame)
  else
    DebugError("CMA: kuertee UI Extensions missing — UIX callbacks not registered")
  end

  -- MD calls raise_lua_event("Context_Menu_API.RegisterMode") when a consumer
  -- registers an MD-owned custom mode during the Reloaded handler.
  -- We register an empty builder so Lua creates a blank frame for that mode;
  -- all entries come from MD via Get_Actions / Add_Action.
  RegisterEvent("Context_Menu_API.RegisterMode", function()
    local modes = GetNPCBlackboard(cmAPI.playerId, "$cma_register_modes")
    SetNPCBlackboard(cmAPI.playerId, "$cma_register_modes", nil)
    if type(modes) == "table" then
      for _, modeId in ipairs(modes) do
        if not cmAPI.customModes[modeId] then
          -- empty builder: blank frame, MD entries injected as step 3
          cmAPI.customModes[modeId] = function() end
        end
      end
    end
  end)

  RegisterEvent("Context_Menu_API.ConfigChanged", function(_, param)
    if param == nil then return end
    if param.debugMode ~= nil then
      debugLevel = param.debugMode
      debug("debug mode set to: " .. tostring(debugLevel))
    end
  end)

  AddUITriggeredEvent("Context_Menu_API", "reloaded")
end

Register_Require_With_Init("extensions.context_menu_api.ui.context_menu_api", cmAPI, Init)
