# Context Menu API

An API mod for X4: Foundations that lets other mods register entries and
sub-menus inside map context frames (the panel that appears when you
right-click a ship, station, etc. on the map).

**Dependencies (required):**
- kuertee UI Extensions and HUD
- SirNukes Mod Support APIs

---

## Overview

The mod intercepts `createContextFrame` on the supported menus and fires a
signal before the frame is built. Consumers respond synchronously (within the
same MD tick / Lua call) by appending entries via the builder API.

Two integration paths exist, both with equivalent capabilities:

- **MD API** — for Mission Director scripts. Uses `Get_Actions` / `Add_Action` cue signals.
- **Lua API** — for Lua UI scripts. Direct access to `cmAPI.luaEntries` and `cmAPI.customModes`.

---

## API Description

### Flow

```
1. Your cue listens to  md.Context_Menu_API.Get_Actions
2. Check event.param.$mode (and other fields) to decide what to add
3. Call md.Context_Menu_API.Add_Action one or more times (synchronously)
4. The API builds the frame; user clicks trigger your $callback cue
```

### `Get_Actions` — event fields

- `$menuName` *(string)* — source menu (`"MapMenu"`)
- `$mode` *(string)* — context frame mode, e.g. `"info_context"`, `"trade"` (see Vanilla context menu modes below)
- `$data` *(table)* — mode-specific data (e.g. selected entity); structure varies by mode and may be `nil` for some modes

### `Add_Action` — entry fields

- `$type` — entry type: `"menuItem"` (default), `"subMenu"`, `"separator"`, `"header"`
- `$id` *(string)* — unique ID; required for `menuItem` / `subMenu` / `header`; for `menuItem` auto-derived from `$text` if omitted and `$callback` is set
- `$text` *(string)* — display label
- `$icon` *(string, optional)* — icon name (X4 icon set); prepended to `$text` as `\027[icon] text`
- `$text2` *(string, optional)* — right-side secondary text; for `subMenu` the API fills in `>` if omitted
- `$textColor` *(string, optional)* — Color key for the main text (e.g. `'text_positive'`); default: `'text_normal'`
- `$text2Color` *(string, optional)* — Color key for `$text2`; default: `'text_normal'`
- `$mouseOver` *(string, optional)* — tooltip text shown on hover
- `$mouseOverIcon` *(string, optional)* — icon prepended to the tooltip text
- `$callback` *(cue reference)* — cue to call when this `menuItem` is clicked
- `$echo` *(any, optional)* — arbitrary value passed back in `event.param.$echo` of the callback
- `$active` *(bool)* — whether the entry is clickable; default: `true` (auto-set to `false` when no `$callback`)
- `$keepOpen` *(bool, optional)* — if `true`, the context menu stays open after the click; default: menu closes

### Callback `event.param` fields

The callback cue receives all original `Get_Actions` fields **plus**:

- `$id` — the action ID that was clicked
- `$echo` — the value of `$echo` passed to `Add_Action` (if any)

### Minimal example — append to an existing mode

```xml
<cue name="On_CMA_Get_Actions" instantiate="true">
    <conditions>
        <event_cue_signalled cue="md.Context_Menu_API.Get_Actions" />
    </conditions>
    <actions>
        <do_if value="event.param.$mode == 'info_context' and event.param.$entity?">
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[
                    $type     = 'menuItem',
                    $text     = 'My Action',
                    $icon     = 'order_follow',
                    $callback = My_Callback,
                    $echo     = event.param.$entity,
                ]" />
        </do_if>
    </actions>
</cue>

<cue name="My_Callback" instantiate="true">
    <conditions>
        <event_cue_signalled />
    </conditions>
    <actions>
        <!-- event.param.$echo is the entity from above -->
        <debug_text text="'clicked on entity: %s'.[event.param.$echo]" />
    </actions>
</cue>
```

### Multi-level sub-menus (MD)

A `subMenu` entry navigates to a new blank frame identified by `$id`. The
API manages a navigation stack and injects a `< Back` button automatically.
Supply a `header` as the first entry of a custom mode to label the frame.

```xml
<cue name="On_CMA_Get_Actions" instantiate="true">
    <conditions>
        <event_cue_signalled cue="md.Context_Menu_API.Get_Actions" />
    </conditions>
    <actions>

        <!-- Append sub-menu trigger to the vanilla frame -->
        <do_if value="event.param.$mode == 'info_context'">
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'separator']" />
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'subMenu', $text = 'My Tool', $id = 'mytool_main']" />
        </do_if>

        <!-- Define the custom mode contents (header + items) -->
        <do_elseif value="event.param.$mode == 'mytool_main'">
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'header', $text = 'My Tool']" />
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'menuItem', $text = 'Do Something', $id = 'mytool_do', $callback = My_Action]" />
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'subMenu', $text = 'More Options', $id = 'mytool_sub']" />
        </do_elseif>

        <do_elseif value="event.param.$mode == 'mytool_sub'">
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'header', $text = 'More Options']" />
            <signal_cue_instantly cue="md.Context_Menu_API.Add_Action"
                param="table[$type = 'menuItem', $text = 'Option A', $id = 'mytool_a', $callback = My_Action]" />
        </do_elseif>

    </actions>
</cue>
```

Note: Do NOT add a `back` entry manually — the API inserts it automatically for every custom mode, right after the leading `header` (if present).

---

## Supported game Menus and Modes

These are the two Menus(screens) are supported by the API: `MapMenu` (the main map screen) and `PlayerInfoMenu`. Each menu has a set of supported modes (context frame types).

### Supported modes per Menu

These modes use a single-column frame and are whitelisted in the API. The `Get_Actions` event fires only for these modes. Entry injection and custom sub-menus work fully.

#### MapMenu

**`info_context`** — the most useful entry point. Opens when the player right-clicks a crew member, pilot, manager, or ship trader in the info panel.
`$data` fields:
- `$component` *(string)* — UniverseID of the controllable (ship or station) as decimal string
- `$entity` *(string)* — UniverseID of the pilot or manager NPC; nil if not applicable
- `$person` *(string)* — NPCSeed of the crew NPC (uint64 decimal string); nil if not applicable
- `$instance` *(string)* — `"left"` or `"right"` for dual-panel frames; nil otherwise
- `$inv_ware` *(string)* — ware macro string when an inventory item row was clicked; nil otherwise
- `$weaponmacro` *(string)* — weapon macro string when a weapon row was clicked; nil otherwise
- `$equipmentmacro` *(string)* — equipment/deploy macro string when an equipment row was clicked; nil otherwise
- `$software` *(string)* — software macro string when a software row was clicked; nil otherwise

#### PlayerInfoMenu

> **Note:** Temporarily excluded due to technical limitations; support may be added in the near future.

**`inventory`** — context actions for a selected ware in the player's inventory.
`$data`: first argument to `createContextFrame`; contains the selected ware info (component, ware macro).

**`personnel`** — context actions for a selected crew member or NPC in the personnel list.
`$data`: first argument to `createContextFrame`; contains the selected person's info (container, entity/person ID, role).

**`transactionlog`** — context actions for a selected transaction log entry.
`$data`: first argument to `createContextFrame`; contains the transaction entry reference.

### Excluded modes

These modes currently does not supported by the API. Mostly because they are complex windows with a lot of UI elements, i.e. they are a far beyond the scope of a simple context menu.
It's support can be added in the future if there's demand, but for now they are listed here for reference.
No `Get_Actions` event is fired for these modes; the API passes through transparently and does not interfere with them.

#### MapMenu excluded modes

These modes are not in the whitelist. No `Get_Actions` event is fired; the API passes through transparently. They are documented here for reference.

**`neworder`** — order selection list when assigning a new order to a ship (1-column).
`$data` fields: `$instance` (string, which panel side)

**`set_orderparam_formationshape`** — formation shape picker for an order parameter (1-column).
`$data` fields: `$index` (number, parameter index), `$instance` (string)

**`searchfield`** — search input overlay (1-column). No meaningful data fields.

**`select`** — generic single-component selection picker (1-column).
`$data` fields: `$component` (string, UniverseID of the pre-selected component)

**`set_orderparam_sector`** — sector picker for an order parameter (3-column table).
`$data` fields: `$index` (number, parameter index in the order), `$instance` (string)

**`set_orderparam_ware`** — ware picker for an order parameter (3-column table).
`$data` fields: `$index` (number, parameter index), `$instance` (string)

**`orderqueuesetting`** — order queue settings panel (2-column table). No meaningful data fields.

**`filter_multiselectlist`** — multi-select filter picker inside the order queue (3-column table).
`$data` fields: `$id` (string, filter setting ID), `$value` (any scalar, current value)

**`trade`** — direct trade dialog between ship and station (9-column table).
`$data` fields: `$component` (string, station UniverseID), `$currentShip` (string, ship UniverseID), `$shadyOnly` (bool), `$wareexchange` (bool)

**`tradeloop`** — trade loop configuration (3-column table).
`$data` fields: `$component` (string, station UniverseID), `$currentShip` (string, ship UniverseID), `$loop` (string, loop type)

**`mission`** — mission briefing / accept context frame (3-column table).
`$data` fields: `$missionid` (string, uint64 mission ID), `$isoffer` (bool), `$name` (string), `$type` (string, main mission type), `$subtype` (string), `$threadtype` (string), `$difficulty` (number), `$rewardmoney` (number, credits × 100), `$rewardtext` (string), `$timeout` (number, seconds, -1 if none), `$abortable` (bool), `$onlinechapter` (string), `$onlineID` (string), `$groupID` (string)

**`sellships`** — sell ships dialog at a shipyard (2-column table).
`$data` fields: `$shipyard` (string, shipyard UniverseID)

**`dropwares`** — drop / jettison wares from a pilot's inventory (3-column table).
`$data` fields: `$mode` (string, sub-mode e.g. `"inventory"`), `$entity` (string, pilot UniverseID)

**`weaponconfig`** — weapon loadout configuration for a ship (2-column table).
`$data` fields: `$component` (string, ship UniverseID), `$orderidx` (number), `$usedefault` (bool), `$instance` (string)

**`boardingcontext`** — boarding operation targeting dialog (9-column table).
`$data` fields: `$target` (string, target UniverseID), `$boarders` (string, boarding ship UniverseID)

**`crewtransfer`** — crew transfer between two ships (11-column table).
`$data` fields: `$leftShip` (string, UniverseID), `$rightShip` (string, UniverseID)

**`hire`** — hire a crew member or captain (2-column table).
`$data` fields: `$hireObject` (string, UniverseID of the object being hired for)

**`rename`** — rename a ship, station, or fleet (2-column table).
`$data` fields: `$component` (string, UniverseID), `$fleetrename` (bool, true when renaming a fleet)

**`changelogo`** — change hull decal / logo on a ship or station (5-column table).
`$data` fields: `$component` (string, UniverseID)

**`userquestion`** — yes/no confirmation dialog; used for many different actions (5-7 columns depending on sub-mode). The `$mode` field indicates which question is being asked:
- `$mode = "discardplanneddefaultbehaviour"` — discard planned order
- `$mode = "removeplot"` — destroy build plot; also has `$station` (string, UniverseID)
- `$mode = "clearlogbook"` — clear logbook entries; also has `$instance` (string)
- `$mode = "markashostile"` — mark target as hostile; also has `$controllable` (string, UniverseID)
- `$mode = "removebuildstorage"` — remove build storage; also has `$buildstorage` (string, UniverseID)
- `$mode = "fireindividual"` — fire a specific crew member; also has `$controllable` (string), `$entity` (string), `$person` (string), `$instance` (string)
- `$mode = "fireall"` — fire all crew; also has `$controllable` (string, UniverseID), `$instance` (string)

**`userquestion_multiverse`** — multiverse-specific yes/no confirmation. No meaningful data fields.

> **Note:** Venture and multiplayer modes (`onlinemode`, `onlinereward`, `ventureconfig`, `venturecreateparty`, `venturepatron`, `venturereport`, `ventureteammembercontext`, `venturecontactcontext`, `venturefriendlist`, `ventureoutcome`, `ventureshipselection`) are not accessible when the game is modded and are listed here for completeness only.

### PlayerInfoMenu excluded modes

**`dropwares`** — drop / jettison wares from a pilot's inventory (3-column table via `Helper.createDropWaresContext`).

> **Note:** Venture modes (`venturecontactcontext`, `venturefriendlist`, `venturereport`) are not accessible when the game is modded.


