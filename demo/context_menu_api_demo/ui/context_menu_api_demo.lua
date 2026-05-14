-- context_menu_api_demo.lua
-- Demo: multi-level context menu via the Context Menu API Lua callback.
--
-- Demonstrates entry injection in all supported modes:
--   MapMenu:       info_context
--   PlayerInfoMenu: personnel, inventory, transactionlog
--
-- The custom sub-menu header shows context-specific info:
--   info_context  — NPC name/role (entity or person), or weapon / equipment /
--                   software / inventory ware macro string
--   personnel     — NPC name + role (resolved by the API: data.name, data.rolename)
--   inventory     — ware display name (data.name)
--   transactionlog — entry ID (data.entryid)
--
-- MENU TREE (appended to every supported vanilla mode):
--   [vanilla mode]
--     ─── (separator)
--     [Lua] Demo: Multi-Level Menu >   → cmt_lua_main
--     ─── (separator)
--     [Lua] Action 1   (menuItem, keepOpen, icon, textColor)
--     [Lua] Action 2   (menuItem)
--
--   [cmt_lua_main]   (custom mode)
--     <context header>        (see above for label logic)
--     < Back
--     [Lua] Item A  >         → cmt_lua_sub_a
--     [Lua] Item B  >         → cmt_lua_sub_b
--
--   [cmt_lua_sub_a]
--     [Lua] Sub-Menu A  (header)
--     < Back
--     [Lua] A - Action 1
--     [Lua] A - Action 2
--
--   [cmt_lua_sub_b]
--     [Lua] Sub-Menu B  (header)
--     < Back
--     [Lua] B - Action 1
--     [Lua] B - Action 2

-- *** NPC label helper ***
-- FFI references — all declarations come from vanilla helper.lua / menu_map.lua.
local ffi = require("ffi")
local C   = ffi.C

-- Human-readable display names for raw GetPersonRole strings.
local roleDisplayNames = {
  pilot         = "Pilot",
  engineer      = "Engineer",
  service       = "Service Crew",
  marine        = "Marine",
  trainee_group = "Trainee",
  unassigned    = "Unassigned",
}

--- Return a context-specific header label for the current open.
--- Covers all supported root modes:
---   info_context  — name/role for entity or person; macro string for weapon/equipment/software/ware
---   personnel     — name + role (already resolved by the API into data.name / data.rolename)
---   inventory     — ware display name (data.name)
---   transactionlog — entry ID (data.entryid)
local function getContextLabel(rootMode, data)
  if not data then return nil end
  if rootMode == "info_context" then
    if data.person and data.person ~= 0 then
      -- Crew NPC: resolve via NPCSeed + controllable component.
      local name    = ffi.string(C.GetPersonName(data.person, data.component))
      local roleStr = ffi.string(C.GetPersonRole(data.person, data.component))
      local role    = roleDisplayNames[roleStr] or roleStr
      return name .. " (" .. role .. ")"
    elseif data.entity then
      -- Instanced entity: pilot / captain / manager.
      local entity = ConvertStringTo64Bit(tostring(data.entity))
      local name   = ffi.string(C.GetComponentName(entity))
      local role
      if C.IsComponentClass(data.component, "ship_s") then
        role = "Pilot"
      elseif C.IsComponentClass(data.component, "ship") then
        role = "Captain"
      else
        role = "Manager"
      end
      return name .. " (" .. role .. ")"
    elseif data.weaponmacro then
      return "Weapon: " .. data.weaponmacro
    elseif data.equipmentmacro then
      return "Equipment: " .. data.equipmentmacro
    elseif data.software then
      return "Software: " .. data.software
    elseif data.inv_ware then
      return "Ware: " .. data.inv_ware
    end
  elseif rootMode == "personnel" then
    -- The API resolves name and rolename directly.
    if data.name and data.rolename then
      return data.name .. " (" .. data.rolename .. ")"
    elseif data.name then
      return data.name
    end
  elseif rootMode == "inventory" then
    -- data.name is the ware display name resolved by the API.
    return data.name
  elseif rootMode == "transactionlog" then
    if data.entryid then
      return "Entry #" .. tostring(data.entryid)
    end
  end
  return nil
end

-- *** Initialisation ***

local function Init()
  local cmAPI = require("extensions.context_menu_api.ui.context_menu_api")

  -- *** Entry builders per mode ***

  -- Entries appended to every supported vanilla mode.
  local function buildVanillaModeEntries(menuName, mode, rootMode, data)
    return {
      { type = "separator" },
      {
        type = "subMenu",
        id   = "cmt_lua_main",
        text = "[Lua] Demo: Multi-Level Menu",
      },
      { type = "separator" },
      {
        type      = "menuItem",
        id        = "cmt_lua_action_1",
        text      = "[Lua] Action 1",
        icon      = "order_follow",
        textColor = "text_positive",
        keepOpen  = true,
        onClick   = function(data, mode)
          DebugError("[CMAD-Lua] Action 1 triggered, mode=" .. tostring(mode))
        end,
      },
      {
        type      = "menuItem",
        id        = "cmt_lua_action_2",
        text      = "[Lua] Action 2",
        textColor = "text_negative",
        onClick   = function(data, mode)
          DebugError("[CMAD-Lua] Action 2 triggered, mode=" .. tostring(mode))
        end,
      },
    }
  end

  local function buildMainMenuEntries(menuName, mode, rootMode, data)
    return {
      { type = "header", text = getContextLabel(rootMode, data) or "[Lua] Demo: Multi-Level Menu" },
      {
        type = "subMenu",
        id   = "cmt_lua_sub_a",
        text = "[Lua] Item A",
      },
      {
        type = "subMenu",
        id   = "cmt_lua_sub_b",
        text = "[Lua] Item B",
      },
    }
  end

  local function buildSubMenuAEntries(menuName, mode, rootMode, data)
    return {
      { type = "header", text = "[Lua] Sub-Menu A" },
      {
        type    = "menuItem",
        id      = "cmt_lua_a_action_1",
        text    = "[Lua] A - Action 1",
        onClick = function(data, mode)
          DebugError("[CMAD-Lua] A - Action 1 triggered")
        end,
      },
      {
        type    = "menuItem",
        id      = "cmt_lua_a_action_2",
        text    = "[Lua] A - Action 2",
        onClick = function(data, mode)
          DebugError("[CMAD-Lua] A - Action 2 triggered")
        end,
      },
    }
  end

  local function buildSubMenuBEntries(menuName, mode, rootMode, data)
    return {
      { type = "header", text = "[Lua] Sub-Menu B" },
      {
        type    = "menuItem",
        id      = "cmt_lua_b_action_1",
        text    = "[Lua] B - Action 1",
        onClick = function(data, mode)
          DebugError("[CMAD-Lua] B - Action 1 triggered")
        end,
      },
      {
        type    = "menuItem",
        id      = "cmt_lua_b_action_2",
        text    = "[Lua] B - Action 2",
        onClick = function(data, mode)
          DebugError("[CMAD-Lua] B - Action 2 triggered")
        end,
      },
    }
  end

  -- *** Dispatch table keyed by mode ***

  local modeBuilders = {
    info_context   = buildVanillaModeEntries,
    personnel      = buildVanillaModeEntries,
    inventory      = buildVanillaModeEntries,
    transactionlog = buildVanillaModeEntries,
    cmt_lua_main   = buildMainMenuEntries,
    cmt_lua_sub_a  = buildSubMenuAEntries,
    cmt_lua_sub_b  = buildSubMenuBEntries,
  }

  -- *** Register as a Lua callback with the API ***

  cmAPI.registerLuaCallback(function(menuName, mode, rootMode, data)
    local builder = modeBuilders[mode]
    if not builder then return {} end
    return builder(menuName, mode, rootMode, data)
  end)
end

Register_OnLoad_Init(Init)
