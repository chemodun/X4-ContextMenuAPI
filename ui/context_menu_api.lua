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

  -- registered custom modes (blank frame)  { [modeId] = buildFn(builder, data) }
  customModes = {},

  -- registered Lua callbacks: each fn(menuName, mode, data) returns a list of entries
  luaCallbacks = {},

  -- Whitelisted modes per menu where entry injection is supported.
  -- Only these modes fire the onOpen event and accept entry injection.
  -- Modes not in this list are multi-column complex windows and bypass the API entirely.
  -- Custom modes (registered via registerCustomMode) are always accepted regardless.
  supportedModes = {
    MapMenu = {
      info_context = true,
    },
    -- PlayerInfoMenu: inventory / personnel / transactionlog are simple 1-column lists.
    PlayerInfoMenu = {
      inventory      = true,
      personnel      = true,
      transactionlog = true,
    },
  },

  -- nav stack: each entry = { mode = string, data = table }
  navStack = {},

  -- the original vanilla mode that opened the current context menu;
  -- preserved across sub-menu navigation so consumers can always identify the root context
  rootMode = nil,

  -- temp entries written by MD in response to the "onOpen" signal
  tempMdEntries = {},

  -- frame-delay state
  delaying    = false,
  pendingArgs = nil,

  -- set in Init()
  playerId    = nil,
  menuMap     = nil,   -- MapMenu reference (kept for backward compat)
  activeMenu  = nil,   -- whichever menu last opened a context frame
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
    -- auto-register the target as a custom mode if not already known
    if not cmAPI.customModes[modeId] then
      cmAPI.customModes[modeId] = true
    end
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

function cmAPI.getContextMenuData(menu)
  local menu = menu or cmAPI.activeMenu
  if not menu then return nil end
  if menu.name == "PlayerInfoMenu" then
    -- Custom logic for PlayerInfoMenu personnel mode
    if cmAPI.rootMode == "personnel" then
      return cmAPI.pendingArgs and cmAPI.pendingArgs[1] or {}
    elseif cmAPI.rootMode == "inventory" then
      return {
        curEntry = menu.inventoryData.curEntry or {},
        selectedWares = menu.inventoryData.selectedWares or {},
        inventoryMode = menu.inventoryData.mode or "",
      }
    elseif cmAPI.rootMode == "transactionlog" then
      if cmAPI.pendingArgs and cmAPI.pendingArgs[1] then
        local rowdata = cmAPI.pendingArgs[1]
        local entryIdx = nil
        local showPartnerSecondary = nil
        if (type(rowdata) == "table") then
          entryIdx = Helper.transactionLogData.transactionsByIDUnfiltered[rowdata[1]]
          showPartnerSecondary = rowdata[2]
        else
          entryIdx = Helper.transactionLogData.transactionsByIDUnfiltered[rowdata]
        end

        local entry = Helper.transactionLogData.accountLogUnfiltered[entryIdx]
        local contextObject = {
          id =  showPartnerSecondary and entry.partner_secondary or entry.partner,
          name = showPartnerSecondary and entry.partnername_secondary or entry.partnername,
        }
        local active = (contextObject.id ~= 0) and C.IsComponentOperational(contextObject.id)
        return {
          curEntry = entry or {},
          contextObject = contextObject,
          active = active,
        }
      end
    end
  end
  return menu.contextMenuData
end

function cmAPI.push(modeId)
  local menu = cmAPI.activeMenu
  if not menu then return end
  table.insert(cmAPI.navStack, {
    mode = menu.contextMenuMode,
  })
  menu.contextMenuMode = modeId
  menu.createContextFrame(tableUnpack(cmAPI.pendingArgs))
end

function cmAPI.goBack()
  local menu = cmAPI.activeMenu
  if not menu then return end
  if #cmAPI.navStack == 0 then
    menu.closeContextMenu()
    return
  end
  local prev = table.remove(cmAPI.navStack)
  menu.contextMenuMode = prev.mode
  menu.createContextFrame(tableUnpack(cmAPI.pendingArgs))
end

-- Register a Lua callback that provides entries for context menu opens.
-- fn(menuName, mode, data) must return a list of entry tables.
-- Entry fields mirror the MD Add_Action fields plus an optional onClick function:
--   { type="menuItem", id="...", text="...", onClick=function(data, mode) ... end }
--   { type="subMenu",  id="...", text="..." }
--   { type="separator" }
--   { type="header",   text="..." }
-- menuItem and subMenu entries without an id are silently skipped.
function cmAPI.registerLuaCallback(fn)
  table.insert(cmAPI.luaCallbacks, fn)
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

-- *** Entry list renderer ***
-- Appends entries to builder, handling auto-injection of back/header for custom
-- modes (once per open, tracked by backInjected).
-- menuItem and subMenu entries without an id are silently skipped.
-- Returns the updated backInjected flag.
local function buildEntryList(entries, builder, data, mode, isCustom, backInjected)
  if #entries == 0 then return backInjected end

  local startIdx = 1
  if isCustom and not backInjected then
    local first = entries[1]
    if first and first.type == "header" then
      builder.header(first.text or "")
      startIdx = 2
    end
    builder.back()
    backInjected = true
  end

  for i = startIdx, #entries do
    local entry = entries[i]
    local t     = entry.type or "menuItem"
    local opts  = {
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
    elseif t == "header" then
      builder.header(entry.text or "")
    elseif t == "menuItem" and entry.id ~= nil then
      -- active: MD delivers booleans as integers (0/1); normalize to real bool
      local active  = not (entry.active == false or entry.active == 0)
      local id      = entry.id
      local onClick = nil
      if active then
        local keepOpen = entry.keepOpen == true or entry.keepOpen == 1
        if type(entry.onClick) == "function" then
          -- Lua entry: call the provided function with context data
          local fn = entry.onClick
          onClick = function()
            fn(data, mode)
            if not keepOpen then cmAPI.activeMenu.closeContextMenu() end
          end
        else
          -- MD entry: fire the action event for MD-side dispatch
          onClick = function()
            AddUITriggeredEvent("Context_Menu_API", "action", id)
            if not keepOpen then cmAPI.activeMenu.closeContextMenu() end
          end
        end
      end
      opts.active = active
      builder.entryButton(entry.text or "", onClick, opts)
    elseif t == "subMenu" and entry.id ~= nil then
      builder.subMenuButton(entry.text or "", entry.id, opts)
    end
    -- menuItem / subMenu without id: no matching branch → silently skipped
  end

  return backInjected
end

-- *** UIX createContextFrame_on_end / refreshContextFrame_on_end callback ***

local function prepareData(menuName, mode, data)
  local result = {}
  if data == nil then
    return result
  end
  if menuName == 'PlayerInfoMenu' then
    if mode == 'personnel' then
      if #data == 2 then
        result.subMode = data[1]
        for k, v in pairs(data[2]) do
          result[k] = v
        end
        if result.id then
          if result.type == "person" then
            result.person = C.ConvertStringTo64Bit(tostring(result.id))
            result.id = nil
          elseif result.type == "entity" then
            result.entity = result.id
            result.id = nil
          end
        end
        if result.container and result.container ~= 0 then
          result.component = ConvertStringTo64Bit(tostring(result.container))
        end
      end
    end
  else
    result = data
  end
  return result
end


local function onCreateContextFrame(contextFrame, contextMenuData, contextMenuMode)
  debug("onCreateContextFrame: menu = " .. tostring(contextFrame.menu.name))
  local menu = contextFrame.menu
  if not menu then
    debug("contextFrame missing menu reference")
    return
  end

  trace("onCreateContextFrame: rootMode = " .. tostring(cmAPI.rootMode) .. ", mode = " .. tostring(contextMenuMode) .. ", data = " .. tostring(cmAPI.currentData))

  local isCustom = cmAPI.customModes[contextMenuMode] == true

  -- Any fresh non-custom open clears stale nav stack (e.g. after ESC)
  if not isCustom then
    cmAPI.navStack = {}
  end

  -- 1. Build a custom mode (blank frame — no vanilla table exists)
  if isCustom then
    local menuTable = findVanillaTable(contextFrame)
    if menuTable then
    else
      local width   = contextFrame.properties.width
      menuTable  = contextFrame:addTable(1, {
        tabOrder                 = 1,
        x                        = Helper.borderSize,
        y                        = Helper.borderSize,
        width                    = width - 2 * Helper.borderSize,
        defaultInteractiveObject = true,
      })
      menuTable:setColWidthPercent(1, 100)
    end
  end

  local backInjected = false

  -- 2. Inject Lua-callback entries (synchronous — no delay needed)
  if #cmAPI.luaCallbacks > 0 then
    local menuTable = findVanillaTable(contextFrame)
    if menuTable then
      local builder = makeAppendBuilder(menuTable)
      for _, cb in ipairs(cmAPI.luaCallbacks) do
        local ok, result = pcall(cb, menu.name, contextMenuMode, cmAPI.rootMode, cmAPI.currentData)
        if ok then
          if type(result) == "table" then
            backInjected = buildEntryList(result, builder, contextMenuData, contextMenuMode, isCustom, backInjected)
          end
        else
          debug("Lua callback error: " .. tostring(result))
        end
      end
    end
  end

  -- 3. Inject MD-provided temp entries (collected during the 2-frame delay)
  if #cmAPI.tempMdEntries > 0 then
    local menuTable = findVanillaTable(contextFrame)
    if menuTable then
      local builder = makeAppendBuilder(menuTable)
      backInjected = buildEntryList(cmAPI.tempMdEntries, builder, nil, contextMenuMode, isCustom, backInjected)
    end
    cmAPI.tempMdEntries = {}
  end

  if menu.name == "MapMenu" then
    local height = contextFrame:getUsedHeight()
    if contextFrame.properties.y + height + Helper.frameBorder > Helper.viewHeight then
      contextFrame.properties.y = Helper.viewHeight - height - Helper.frameBorder
    end
  end
end

-- *** MD signal helpers ***

local function getOrCreateEntity(person, controllable)
  local entity = C.GetInstantiatedPerson(person, controllable)
  trace("Retrieved entity for person: " .. tostring(entity))
  if entity == 0 or entity == nil then
    entity = C.CreateNPCFromPerson(person, controllable)
    trace("Created entity for person: " .. tostring(entity))
  end
  return entity
end

local function sanitizeForMD(params, data)
  if type(data) ~= "table" then return {} end
  for k, v in pairs(data) do
    if k == "person" and v and v ~= 0 and (data.component and data.component ~= 0) then
      -- convert person to entity data type to pass to MD.
      debug("Resolving person to entity for MD: person=" .. tostring(v) .. ", type " .. tostring(type(v)) .. " controllable=" .. tostring(data.component))
      params[k] = ConvertStringTo64Bit(tostring(getOrCreateEntity(v, data.component)))
      -- params[k] = v
    else
      -- For other fields, only pass scalars and cdata fields that we know are IDs.
      local t = type(v)
      if t == "string" or t == "boolean" or t == "number" then
        params[k] = v
      elseif t == "cdata" or t == "userdata" then
        params[k] = ConvertStringTo64Bit(tostring(v))
      end
    end
  end
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
    cmAPI.activeMenu = menu
    local args = { ... }

    -- Only intercept for whitelisted modes and registered custom modes.
    -- All other modes (multi-column complex windows) bypass the API entirely.
    local mode = menu.contextMenuMode
    local isSupported = cmAPI.customModes[mode] == true
    if not isSupported then
      local whitelist = cmAPI.supportedModes[menu.name]
      isSupported = whitelist ~= nil and whitelist[mode] == true
    end
    if not isSupported then
      trace("createContextFrame bypass: mode '" .. tostring(mode) .. "' not in whitelist")
      egoMenuMapCreateContextFrame[menu.name](...)
      return
    end

    -- Track the original vanilla mode; preserved through sub-menu navigation.
    if cmAPI.customModes[mode] ~= true then
      cmAPI.rootMode = mode
    end

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
    local param = {
      menuName = menu.name,
      mode     = menu.contextMenuMode or "",
      rootMode = cmAPI.rootMode or menu.contextMenuMode,
    }
    local data = cmAPI.getContextMenuData(menu)
    cmAPI.currentData = prepareData(menu.name, cmAPI.rootMode, data)
    sanitizeForMD(param, cmAPI.currentData)
    -- Signal MD: includes menu.name so MD conditions can distinguish menus
    AddUITriggeredEvent("Context_Menu_API", "onOpen", param)

    -- Delay 2 frames. AddUITriggeredEvent queues the MD event for the MD
    -- update that runs AFTER the current Lua onUpdate completes. So after
    -- frame 1 MD has written its entries; frame 2 is when we safely read them.
    scheduleNextFrame(function()
      -- Frame 1: MD is processing the onOpen event this tick. Wait one more.
      scheduleNextFrame(function()
        cmAPI.delaying = false
        trace("2-frame delay over, calling real createContextFrame and injecting MD entries")
        readMdEntries()
        -- Save the current mouseOutBox so we can expand the new (possibly smaller)
        -- box to the union after the real call, preventing premature menu closure.
        local prevMouseOutBox = menu.mouseOutBox
        egoMenuMapCreateContextFrame[menu.name](tableUnpack(cmAPI.pendingArgs))

        -- Adjust the new mouseOutBox if it's smaller than the context frame height,
        -- to prevent premature closure when navigating into a taller sub-menu.
        if menu.mouseOutBox then
          local config = menu.uix_getConfig()
          if config and config.mouseOutRange then
            local calculatedHeight = (menu.mouseOutBox.y1 - menu.mouseOutBox.y2) - 2 * config.mouseOutRange
            local height = menu.contextFrame:getUsedHeight()
            if calculatedHeight < height then
              trace("calculated mouseOutBox height " .. tostring(calculatedHeight) .. " is smaller than context frame height " .. tostring(height) .. " - expanding mouseOutBox")
              menu.mouseOutBox.y1 = 0 - menu.contextFrame.properties.y + Helper.viewHeight / 2 + config.mouseOutRange
              menu.mouseOutBox.y2 = 0 - menu.contextFrame.properties.y + Helper.viewHeight / 2 - height - config.mouseOutRange
            end
          end
        end
        -- Expand the new mouseOutBox to the union with the previous level's box.
        -- When sub-menu navigation produces a smaller frame, the cursor can fall
        -- outside the freshly-computed box and trigger immediate closure.  Taking
        -- the union ensures the safe zone never shrinks during a menu session.
        if prevMouseOutBox and menu.mouseOutBox then
          local old = prevMouseOutBox
          local new = menu.mouseOutBox
          menu.mouseOutBox = {
            x1 = math.min(old.x1, new.x1),
            x2 = math.max(old.x2, new.x2),
            y1 = math.max(old.y1, new.y1),
            y2 = math.min(old.y2, new.y2),
          }
          trace("mouseOutBox expanded to union: x1=" .. menu.mouseOutBox.x1 .. " x2=" .. menu.mouseOutBox.x2 .. " y1=" .. menu.mouseOutBox.y1 .. " y2=" .. menu.mouseOutBox.y2)
        end
      end)
    end)
  end
end

-- *** Init ***

local function Init()
  cmAPI.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

  local Lib = require("extensions.sn_mod_support_apis.ui.Library")

  -- Keep menuMap as the MapMenu reference for backward compatibility
  cmAPI.menuMap = Lib.Get_Egosoft_Menu("MapMenu")

  -- Patch all menus that support context frames
  local menuNames = { "MapMenu" , "PlayerInfoMenu" }
  for _, mname in ipairs(menuNames) do
    local m = Lib.Get_Egosoft_Menu(mname)
    if m then
      patchMenu(m)
      if type(m.registerCallback) == "function" then
        m.registerCallback("createContextFrame_on_end", onCreateContextFrame)
        m.registerCallback("refreshContextFrame_on_end", onCreateContextFrame)
      else
        DebugError("CMA: kuertee UI Extensions missing for " .. mname .. " — UIX callbacks not registered")
      end
    else
      debug("menu not found (may not be loaded yet): " .. mname)
    end
  end

  -- Read debug level directly from the saved config on startup
  local savedConfig = GetNPCBlackboard(cmAPI.playerId, "$contextMenuAPIConfig")
  if type(savedConfig) == "table" and savedConfig.debugMode ~= nil then
    debugLevel = savedConfig.debugMode
  end

  RegisterEvent("Context_Menu_API.ConfigChanged", function(_, param)
    -- Read debug level directly from the saved config on startup
    local savedConfig = GetNPCBlackboard(cmAPI.playerId, "$contextMenuAPIConfig")
    if type(savedConfig) == "table" and savedConfig.debugMode ~= nil then
      debugLevel = savedConfig.debugMode
      debug("debug mode set to: " .. tostring(debugLevel))
    end
  end)

  AddUITriggeredEvent("Context_Menu_API", "reloaded")
end

Register_Require_With_Init("extensions.context_menu_api.ui.context_menu_api", cmAPI, Init)
