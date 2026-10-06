-- KRQuickSave: experimental mid-level checkpoint support for Kingdom Rush (Steam, App 246420).
-- F5 stores resources, wave number, towers, supported combat-actor state, and spell-button availability. Re-enter the same level and double-press F9 before spawning.

local MOD_VERSION = 9
local COMBAT_UNIT_FORMAT = 5
local CHECKPOINT_FILE = "kr_midlevel_checkpoint.json"
local STATUS_FILE = "kr_quicksave_status.txt"
local NULL = {}
local json = {}

local function json_quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        local escapes = {
            ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b',
            ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'
        }
        return escapes[char] or string.format("\\u%04x", string.byte(char))
    end) .. '"'
end

local function is_array(value)
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
        count = count + 1
        if key > maximum then maximum = key end
    end
    return count == maximum
end

local function json_encode(value)
    local value_type = type(value)
    if value_type == "nil" then return "null" end
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.17g", value)
    end
    if value_type == "string" then return json_quote(value) end
    if value_type ~= "table" then return "null" end

    local parts = {}
    if is_array(value) then
        for index = 1, #value do parts[#parts + 1] = json_encode(value[index]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
        if type(key) == "string" then
            parts[#parts + 1] = json_quote(key) .. ":" .. json_encode(item)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function utf8_char(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    elseif codepoint < 0x10000 then
        return string.char(0xE0 + math.floor(codepoint / 0x1000), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
    end
    return string.char(0xF0 + math.floor(codepoint / 0x40000), 0x80 + (math.floor(codepoint / 0x1000) % 0x40), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
end

local function json_decode(source)
    local position, length = 1, #source
    local function skip_space()
        while position <= length and source:sub(position, position):match("%s") do position = position + 1 end
    end
    local function parse_string()
        position = position + 1 -- opening quote
        local parts = {}
        while position <= length do
            local char = source:sub(position, position)
            if char == '"' then
                position = position + 1
                return table.concat(parts)
            elseif char == "\\" then
                position = position + 1
                local escape = source:sub(position, position)
                local short = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
                if short[escape] then
                    parts[#parts + 1] = short[escape]
                    position = position + 1
                elseif escape == "u" then
                    local hex = source:sub(position + 1, position + 4)
                    local codepoint = tonumber(hex, 16)
                    if not codepoint then error("invalid JSON unicode escape") end
                    position = position + 5
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF and source:sub(position, position + 1) == "\\u" then
                        local low = tonumber(source:sub(position + 2, position + 5), 16)
                        if low and low >= 0xDC00 and low <= 0xDFFF then
                            codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
                            position = position + 6
                        end
                    end
                    parts[#parts + 1] = utf8_char(codepoint)
                else
                    error("invalid JSON escape")
                end
            else
                parts[#parts + 1] = char
                position = position + 1
            end
        end
        error("unterminated JSON string")
    end
    local parse_value
    local function parse_array()
        position = position + 1
        local result = {}
        skip_space()
        if source:sub(position, position) == "]" then position = position + 1; return result end
        while true do
            result[#result + 1] = parse_value()
            skip_space()
            local delimiter = source:sub(position, position)
            if delimiter == "]" then position = position + 1; return result end
            if delimiter ~= "," then error("invalid JSON array") end
            position = position + 1
        end
    end
    local function parse_object()
        position = position + 1
        local result = {}
        skip_space()
        if source:sub(position, position) == "}" then position = position + 1; return result end
        while true do
            skip_space()
            if source:sub(position, position) ~= '"' then error("invalid JSON object key") end
            local key = parse_string()
            skip_space()
            if source:sub(position, position) ~= ":" then error("missing JSON colon") end
            position = position + 1
            result[key] = parse_value()
            skip_space()
            local delimiter = source:sub(position, position)
            if delimiter == "}" then position = position + 1; return result end
            if delimiter ~= "," then error("invalid JSON object") end
            position = position + 1
        end
    end
    parse_value = function()
        skip_space()
        local char = source:sub(position, position)
        if char == '"' then return parse_string() end
        if char == "{" then return parse_object() end
        if char == "[" then return parse_array() end
        if source:sub(position, position + 3) == "true" then position = position + 4; return true end
        if source:sub(position, position + 4) == "false" then position = position + 5; return false end
        if source:sub(position, position + 3) == "null" then position = position + 4; return NULL end
        local rest = source:sub(position)
        local number = rest:match("^-?%d+%.?%d*[eE][%+%-]?%d+") or rest:match("^-?%d+%.?%d*")
        if number then position = position + #number; return tonumber(number) end
        error("invalid JSON value")
    end
    local result = parse_value()
    skip_space()
    if position <= length then error("trailing JSON content") end
    return result
end

json.encode = json_encode
json.decode = json_decode

local function choose_directory()
    local appdata = os.getenv("APPDATA")
    if appdata and appdata ~= "" then return appdata .. "\\kingdom_rush" end
    if love and love.filesystem and love.filesystem.getSaveDirectory then
        return love.filesystem.getSaveDirectory()
    end
    return "."
end

local data_directory = choose_directory()
local checkpoint_path = data_directory .. "\\" .. CHECKPOINT_FILE
local status_path = data_directory .. "\\" .. STATUS_FILE
local toast_text, toast_until = nil, 0
local restore_armed_at = nil
local pending_restore = nil
local pending_power_restore = nil
local RESTORE_STAGE_TIMEOUT = 12
local RESTORE_TOTAL_TIMEOUT = 180

local function write_status(message, toast)
    if toast then
        toast_text = toast
        toast_until = os.clock() + 5
    end
    local file = io.open(status_path, "ab")
    if file then
        file:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
        file:close()
    end
end

local function active_state()
    local current_game = rawget(_G, "game")
    if type(current_game) ~= "table" or type(current_game.store) ~= "table" then return nil, nil end
    return current_game, current_game.store
end

local function read_wave_cursor_locals(store)
    local thread = store.wave_spawn_thread
    local debug_lib = rawget(_G, "debug")
    if type(thread) ~= "thread" or coroutine.status(thread) ~= "suspended"
        or type(debug_lib) ~= "table" or type(debug_lib.getlocal) ~= "function"
        or type(debug_lib.setlocal) ~= "function" then
        return nil, "当前游戏的原生刷怪进度不可读取"
    end
    local ready_group = store.next_wave_group_ready
    if type(ready_group) ~= "table" or ready_group.group_idx ~= 1
        or store.current_wave_group ~= nil or store.send_next_wave == true
        or (type(store.waves_active) == "table" and next(store.waves_active) ~= nil) then
        return nil, "请在新关卡第一波尚未出兵时恢复"
    end

    local slots = {}
    for index = 1, 64 do
        local ok, name, value = pcall(debug_lib.getlocal, thread, 1, index)
        if not ok or name == nil then break end
        if name == "i" then slots.i = {index = index, value = value} end
        if name == "group" then slots.group = {index = index, value = value} end
    end
    if not slots.i or slots.i.value ~= 1 or not slots.group
        or type(slots.group.value) ~= "table" or slots.group.value.group_idx ~= 1 then
        return nil, "无法安全定位游戏原生的第一波等待点"
    end
    return {
        thread = thread,
        debug = debug_lib,
        i_slot = slots.i.index,
        group_slot = slots.group.index,
        current_group = slots.group.value,
    }
end

local function get_wave_group(group_index)
    if type(group_index) ~= "number" or group_index < 1 or group_index % 1 ~= 0 then return nil end
    local ok_db, wave_db = pcall(require, "wave_db")
    if not ok_db or type(wave_db) ~= "table" or type(wave_db.get_group) ~= "function" then return nil end
    local ok_group, group = pcall(wave_db.get_group, wave_db, group_index)
    if not ok_group or type(group) ~= "table" then return nil end
    group.group_idx = group_index
    return group
end

local function snapshot_wave_progress(store)
    local wave = type(store.wave_group_number) == "number" and store.wave_group_number or 0
    local next_group_index
    local ready_group = store.next_wave_group_ready
    local current_group = store.current_wave_group
    if type(ready_group) == "table" and type(ready_group.group_idx) == "number" then
        next_group_index = ready_group.group_idx
    elseif type(current_group) == "table" and type(current_group.group_idx) == "number" then
        next_group_index = current_group.group_idx + 1
    else
        next_group_index = wave + 1
    end
    local finished = store.waves_finished == true
    if type(store.wave_group_total) == "number" and store.wave_group_total > 0
        and next_group_index > store.wave_group_total then
        finished = true
    end
    if finished then next_group_index = nil end
    return {
        wave_group_number = wave,
        next_wave_group_idx = next_group_index,
        waves_finished = finished,
    }
end

local function set_next_wave_button(current_game, enabled)
    local game_gui = type(current_game) == "table" and current_game.game_gui or nil
    local button = type(game_gui) == "table" and game_gui.next_wave_button or nil
    if type(button) ~= "table" then return end
    pcall(function()
        if enabled and type(button.enable) == "function" then
            button:enable()
        elseif not enabled and type(button.disable) == "function" then
            button:disable()
        end
    end)
end

local function restore_wave_progress(current_game, store, wave, next_group_index, waves_finished)
    store.send_next_wave = false
    store.force_next_wave = false
    if type(wave) == "number" then store.wave_group_number = wave end
    store.current_wave_group = nil
    store.last_wave_ts = type(store.tick_ts) == "number" and store.tick_ts or 0
    store.waves_active = {}
    store.wave_signals = {}

    if waves_finished == true then
        store.wave_spawn_thread = nil
        store.next_wave_group_ready = nil
        store.waves_finished = true
        local game_gui = type(current_game) == "table" and current_game.game_gui or nil
        if type(game_gui) == "table" and type(game_gui.hide_wave_flags) == "function" then
            pcall(game_gui.hide_wave_flags, game_gui)
        end
        set_next_wave_button(current_game, false)
        return true
    end

    local group = get_wave_group(next_group_index)
    if not group then return false, "检查点对应的下一波不存在" end
    local cursor, cursor_error = read_wave_cursor_locals(store)
    if not cursor then return false, cursor_error end

    local group_set_ok, group_name = pcall(cursor.debug.setlocal, cursor.thread, 1, cursor.group_slot, group)
    if not group_set_ok or group_name ~= "group" then
        return false, "无法写入原生刷怪协程的波次数据"
    end
    local index_set_ok, index_name = pcall(cursor.debug.setlocal, cursor.thread, 1, cursor.i_slot, next_group_index)
    if not index_set_ok or index_name ~= "i" then
        pcall(cursor.debug.setlocal, cursor.thread, 1, cursor.group_slot, cursor.current_group)
        return false, "无法写入原生刷怪协程的下一波编号"
    end

    store.next_wave_group_ready = group
    store.waves_finished = false
    local ok_signal, signal = pcall(require, "hump.signal")
    if ok_signal and type(signal) == "table" and type(signal.emit) == "function" then
        pcall(signal.emit, "next-wave-ready", group)
    else
        return false, "无法刷新游戏的下一波提示"
    end
    return true
end

local function count_live_enemies(store)
    local count = 0
    for _, entity in pairs(store.entities or {}) do
        if type(entity) == "table" and entity.enemy ~= nil then
            local health = entity.health
            if type(health) ~= "table" or (health.dead ~= true and (type(health.hp) ~= "number" or health.hp > 0)) then
                count = count + 1
            end
        end
    end
    return count
end

local TOWER_PATHS = {
    tower_archer_1 = {build = "tower_build_archer", levels = {"tower_archer_1"}},
    tower_archer_2 = {build = "tower_build_archer", levels = {"tower_archer_1", "tower_archer_2"}},
    tower_archer_3 = {build = "tower_build_archer", levels = {"tower_archer_1", "tower_archer_2", "tower_archer_3"}},
    tower_ranger = {build = "tower_build_archer", levels = {"tower_archer_1", "tower_archer_2", "tower_archer_3", "tower_ranger"}},
    tower_musketeer = {build = "tower_build_archer", levels = {"tower_archer_1", "tower_archer_2", "tower_archer_3", "tower_musketeer"}},
    tower_barrack_1 = {build = "tower_build_barrack", levels = {"tower_barrack_1"}},
    tower_barrack_2 = {build = "tower_build_barrack", levels = {"tower_barrack_1", "tower_barrack_2"}},
    tower_barrack_3 = {build = "tower_build_barrack", levels = {"tower_barrack_1", "tower_barrack_2", "tower_barrack_3"}},
    tower_paladin = {build = "tower_build_barrack", levels = {"tower_barrack_1", "tower_barrack_2", "tower_barrack_3", "tower_paladin"}},
    tower_barbarian = {build = "tower_build_barrack", levels = {"tower_barrack_1", "tower_barrack_2", "tower_barrack_3", "tower_barbarian"}},
    tower_mage_1 = {build = "tower_build_mage", levels = {"tower_mage_1"}},
    tower_mage_2 = {build = "tower_build_mage", levels = {"tower_mage_1", "tower_mage_2"}},
    tower_mage_3 = {build = "tower_build_mage", levels = {"tower_mage_1", "tower_mage_2", "tower_mage_3"}},
    tower_arcane_wizard = {build = "tower_build_mage", levels = {"tower_mage_1", "tower_mage_2", "tower_mage_3", "tower_arcane_wizard"}},
    tower_sorcerer = {build = "tower_build_mage", levels = {"tower_mage_1", "tower_mage_2", "tower_mage_3", "tower_sorcerer"}},
    tower_engineer_1 = {build = "tower_build_engineer", levels = {"tower_engineer_1"}},
    tower_engineer_2 = {build = "tower_build_engineer", levels = {"tower_engineer_1", "tower_engineer_2"}},
    tower_engineer_3 = {build = "tower_build_engineer", levels = {"tower_engineer_1", "tower_engineer_2", "tower_engineer_3"}},
    tower_tesla = {build = "tower_build_engineer", levels = {"tower_engineer_1", "tower_engineer_2", "tower_engineer_3", "tower_tesla"}},
    tower_bfg = {build = "tower_build_engineer", levels = {"tower_engineer_1", "tower_engineer_2", "tower_engineer_3", "tower_bfg"}},
}

local function tower_slot_id(entity, tower)
    local holder_id = tonumber(tower.holder_id)
    if holder_id and holder_id > 0 then return holder_id end
    if type(entity.ui) == "table" then
        holder_id = tonumber(entity.ui.nav_mesh_id)
        if holder_id and holder_id > 0 then return holder_id end
    end
    return nil
end

local function saved_towers(store)
    local result, seen, skipped_unsupported, skipped_missing_id, detected = {}, {}, 0, 0, 0
    local unsupported_templates, missing_id_templates = {}, {}
    for _, entity in pairs(store.entities or {}) do
        local tower = type(entity) == "table" and entity.tower or nil
        local template = type(entity) == "table" and entity.template_name or nil
        if type(tower) == "table" and tower.type ~= "holder" and type(template) == "string"
            and template:sub(1, 6) == "tower_"
            and template:sub(1, 12) ~= "tower_build_" then
            local holder_id = tower_slot_id(entity, tower)
            if not holder_id then
                detected = detected + 1
                skipped_missing_id = skipped_missing_id + 1
                missing_id_templates[#missing_id_templates + 1] = template
            elseif not seen[holder_id] then
                seen[holder_id] = true
                detected = detected + 1
                if TOWER_PATHS[template] then
                    result[#result + 1] = {holder_id = holder_id, template = template}
                else
                    skipped_unsupported = skipped_unsupported + 1
                    unsupported_templates[#unsupported_templates + 1] = template
                end
            else
                -- More than one live tower entity reported the same slot; retain one entry.
            end
        end
    end
    table.sort(result, function(a, b) return a.holder_id < b.holder_id end)
    return result, skipped_unsupported, skipped_missing_id, detected, unsupported_templates, missing_id_templates
end

local function snapshot_point(point)
    if type(point) ~= "table" or type(point.x) ~= "number" or type(point.y) ~= "number" then
        return nil
    end
    return {x = point.x, y = point.y}
end

local function snapshot_enemy(entity)
    local health, nav_path = entity.health, entity.nav_path
    local pos = snapshot_point(entity.pos)
    if type(entity.template_name) ~= "string" or type(health) ~= "table"
        or type(health.hp) ~= "number" or not pos or type(nav_path) ~= "table"
        or type(nav_path.pi) ~= "number" or type(nav_path.spi) ~= "number"
        or type(nav_path.ni) ~= "number" then
        return nil
    end
    local result = {
        template = entity.template_name,
        hp = health.hp,
        pos = pos,
        nav_path = {pi = nav_path.pi, spi = nav_path.spi, ni = nav_path.ni},
    }
    if type(nav_path.dir) == "number" then result.nav_path.dir = nav_path.dir end
    if type(entity.heading) == "table" and type(entity.heading.angle) == "number" then
        result.heading_angle = entity.heading.angle
    end
    if type(entity.motion) == "table" and type(entity.motion.max_speed) == "number" then
        result.max_speed = entity.motion.max_speed
    end
    if type(entity.motion) == "table" and type(entity.motion.arrived) == "boolean" then
        result.motion_arrived = entity.motion.arrived
    end
    if type(entity.unit) == "table" then
        if type(entity.unit.level) == "number" then result.unit_level = entity.unit.level end
        if type(entity.unit.stun_count) == "number" then result.stun_count = entity.unit.stun_count end
    end
    return result
end

local function snapshot_hero(entity)
    local hero = entity.hero
    if type(hero) ~= "table" or type(entity.template_name) ~= "string" then return nil end
    local result = {template = entity.template_name}
    if type(entity.health) == "table" and type(entity.health.hp) == "number" then
        result.hp = entity.health.hp
    end
    if type(hero.level) == "number" then result.level = hero.level end
    if type(hero.xp) == "number" then result.xp = hero.xp end
    if type(hero.skills) == "table" then
        result.skills = {}
        for key, value in pairs(hero.skills) do
            local value_type = type(value)
            if type(key) == "string" and (value_type == "number" or value_type == "boolean" or value_type == "string") then
                result.skills[key] = value
            end
        end
    end
    result.pos = snapshot_point(entity.pos)
    if type(entity.nav_rally) == "table" then
        result.rally_pos = snapshot_point(entity.nav_rally.pos)
    end
    return result
end

local function snapshot_soldier(slot, soldier)
    if type(soldier) ~= "table" or type(soldier.soldier) ~= "table"
        or type(soldier.template_name) ~= "string"
        or type(soldier.health) ~= "table" or type(soldier.health.hp) ~= "number"
        or soldier.health.dead == true or soldier.health.hp <= 0 then
        return nil
    end
    local result = {slot = slot, template = soldier.template_name, hp = soldier.health.hp}
    if type(soldier.unit) == "table" and type(soldier.unit.level) == "number" then
        result.level = soldier.unit.level
    end
    return result
end

local function snapshot_units(store, towers)
    local units = {enemies = {}, heroes = {}, barracks = {}}
    local counts = {enemies = 0, skipped_enemies = 0, heroes = 0, soldiers = 0}
    local saved_holder_ids = {}
    for _, tower in ipairs(towers) do saved_holder_ids[tower.holder_id] = true end

    for _, entity in pairs(store.entities or {}) do
        if type(entity) == "table" and type(entity.enemy) == "table"
            and type(entity.health) == "table" and entity.health.dead ~= true
            and (type(entity.health.hp) ~= "number" or entity.health.hp > 0) then
            counts.enemies = counts.enemies + 1
            local snapshot = snapshot_enemy(entity)
            if snapshot then
                units.enemies[#units.enemies + 1] = snapshot
            else
                counts.skipped_enemies = counts.skipped_enemies + 1
            end
        end
        if type(entity) == "table" and type(entity.hero) == "table" then
            local snapshot = snapshot_hero(entity)
            if snapshot then
                units.heroes[#units.heroes + 1] = snapshot
                counts.heroes = counts.heroes + 1
            end
        end
        if type(entity) == "table" and type(entity.tower) == "table"
            and type(entity.barrack) == "table" and entity.tower.type ~= "holder" then
            local holder_id = tower_slot_id(entity, entity.tower)
            if holder_id and saved_holder_ids[holder_id] then
                local barrack = {holder_id = holder_id, soldiers = {}}
                barrack.rally_pos = snapshot_point(entity.barrack.rally_pos)
                for key, soldier in pairs(entity.barrack.soldiers or {}) do
                    local slot = tonumber(key)
                    if not slot then slot = #barrack.soldiers + 1 end
                    local snapshot = snapshot_soldier(slot, soldier)
                    if snapshot then
                        barrack.soldiers[#barrack.soldiers + 1] = snapshot
                        counts.soldiers = counts.soldiers + 1
                    end
                end
                table.sort(barrack.soldiers, function(a, b) return a.slot < b.slot end)
                if barrack.rally_pos or #barrack.soldiers > 0 then
                    units.barracks[#units.barracks + 1] = barrack
                end
            end
        end
    end
    table.sort(units.barracks, function(a, b) return a.holder_id < b.holder_id end)
    return units, counts
end

local POWER_MODES = {unlocked = true, default = true, cooldown = true, locked = true}

local function snapshot_power_modes(current_game)
    local result = {}
    local game_gui = type(current_game) == "table" and current_game.game_gui or nil
    for _, key in ipairs({"power_1", "power_2"}) do
        local button = type(game_gui) == "table" and game_gui[key] or nil
        if type(button) == "table" and type(button.mode) == "string" and POWER_MODES[button.mode] then
            local snapshot = {mode = button.mode}
            local cooldown_time = tonumber(button.cooldown_time)
            local cooldown_elapsed = tonumber(button.start_ts)
            if button.mode == "cooldown" and cooldown_time and cooldown_time > 0
                and cooldown_elapsed and cooldown_elapsed >= 0 then
                cooldown_elapsed = math.min(cooldown_elapsed, cooldown_time)
                snapshot.cooldown_time = cooldown_time
                snapshot.cooldown_elapsed = cooldown_elapsed
                snapshot.cooldown_remaining = math.max(0, cooldown_time - cooldown_elapsed)
            end
            result[key] = snapshot
        end
    end
    return result
end

local function power_mode_label(mode)
    local labels = {unlocked = "可用", default = "可用", ready = "可用", cooldown = "冷却中", locked = "锁定"}
    return labels[mode] or "未知"
end

local function power_snapshot_summary(powers, english)
    local labels = {}
    for _, item in ipairs({
        {key = "power_1", zh = "火雨", en = "Fire Rain"},
        {key = "power_2", zh = "增援", en = "Reinforcements"},
    }) do
        local record = powers[item.key]
        if type(record) == "table" then
            local label
            if record.mode == "cooldown" then
                if type(record.cooldown_remaining) == "number" then
                    local seconds = tostring(math.ceil(record.cooldown_remaining))
                    label = english and ("cooldown " .. seconds .. "s") or ("冷却约 " .. seconds .. " 秒")
                else
                    label = english and "cooldown timer unavailable" or "冷却剩余时间未读取"
                end
            else
                if english then
                    label = (record.mode == "unlocked" or record.mode == "default") and "ready" or tostring(record.mode)
                else
                    label = power_mode_label(record.mode)
                end
            end
            labels[#labels + 1] = (english and item.en or item.zh) .. " " .. label
        end
    end
    return table.concat(labels, english and ", " or "、")
end

local function saved_power_record(powers, key)
    local record = type(powers) == "table" and powers[key] or nil
    if type(record) == "string" then return {mode = record} end
    if type(record) == "table" and type(record.mode) == "string" and POWER_MODES[record.mode] then
        return record
    end
    return nil
end

local function set_power_mode(button, mode)
    if type(button.set_mode) == "function" then
        local ok = pcall(button.set_mode, button, mode)
        if ok then return true end
    end
    button.mode = mode
    return false
end

local function make_power_restore_target(button, saved)
    local target = {mode = "unlocked"}
    if type(saved) == "table" and saved.mode == "cooldown" then
        local cooldown_time = tonumber(button.cooldown_time) or tonumber(saved.cooldown_time)
        if cooldown_time and cooldown_time > 0 then
            local elapsed = tonumber(saved.cooldown_elapsed)
            local remaining = tonumber(saved.cooldown_remaining)
            if elapsed == nil and remaining ~= nil then elapsed = cooldown_time - remaining end
            -- Older checkpoints recorded the cooldown mode but not its timer. In that
            -- case, start a full cooldown so restore cannot grant an unintended cast.
            if elapsed == nil then elapsed = 0 end
            elapsed = math.max(0, math.min(cooldown_time, elapsed))
            remaining = math.max(0, cooldown_time - elapsed)
            if remaining > 0 then
                target = {
                    mode = "cooldown",
                    cooldown_time = cooldown_time,
                    cooldown_elapsed = elapsed,
                    cooldown_remaining = remaining,
                    approximate = saved.cooldown_elapsed == nil and saved.cooldown_remaining == nil,
                }
            end
        end
    end
    return target
end

local function apply_power_target(button, target)
    if target.mode == "cooldown" then
        local duration = tonumber(button.cooldown_time) or target.cooldown_time
        if duration and duration > 0 then
            button.start_ts = math.max(0, math.min(duration, target.cooldown_elapsed or 0))
            local native_setter = set_power_mode(button, "cooldown")
            -- set_mode refreshes the native button animation; retain its restored timer.
            button.start_ts = math.max(0, math.min(duration, target.cooldown_elapsed or 0))
            return native_setter
        end
        target.mode = "unlocked"
    end
    return set_power_mode(button, "unlocked")
end

local function restore_power_modes(current_game, saved_powers)
    local game_gui = type(current_game) == "table" and current_game.game_gui or nil
    if type(game_gui) ~= "table" then return "", "", {} end
    local targets = {}
    local summary, toast_summary = {}, {}
    for _, item in ipairs({
        {key = "power_1", label = "火雨", toast_label = "Fire Rain"},
        {key = "power_2", label = "增援", toast_label = "Reinforcements"},
    }) do
        local button = game_gui[item.key]
        if type(button) == "table" then
            local target = make_power_restore_target(button, saved_power_record(saved_powers, item.key))
            targets[item.key] = target
            local native_setter = apply_power_target(button, target)
            local actual_mode = button.mode
            local label, toast_label
            if actual_mode == "locked" then
                label, toast_label = "仍锁定（继续重试）", "still locked (retrying)"
            elseif target.mode == "cooldown" then
                label = power_mode_label("cooldown") .. "约 " .. tostring(math.ceil(target.cooldown_remaining)) .. " 秒"
                toast_label = "cooldown " .. tostring(math.ceil(target.cooldown_remaining)) .. "s"
                if target.approximate then toast_label = toast_label .. " (full; older checkpoint)" end
            else
                label, toast_label = power_mode_label(actual_mode or "unlocked"), "available"
            end
            if not native_setter then toast_label = toast_label .. " (native button setter unavailable)" end
            summary[#summary + 1] = item.label .. "=" .. label
            toast_summary[#toast_summary + 1] = item.toast_label .. "=" .. toast_label
        else
            summary[#summary + 1] = item.label .. "=按钮未找到"
            toast_summary[#toast_summary + 1] = item.toast_label .. "=button missing"
        end
    end
    return table.concat(summary, "，"), table.concat(toast_summary, ", "), targets
end

local function update_power_restore()
    if not pending_power_restore then return end
    local current_game = active_state()
    if not current_game then
        pending_power_restore = nil
        return
    end
    local modes = pending_power_restore.modes
    local game_gui = type(current_game.game_gui) == "table" and current_game.game_gui or nil
    if type(game_gui) ~= "table" then return end

    -- Use the game's native button setter, not a raw mode assignment. Keep correcting
    -- GUI refreshes until a ready spell is cast or a restored cooldown naturally ends.
    for _, key in ipairs({"power_1", "power_2"}) do
        local target = modes[key]
        if target then
            local button = game_gui[key]
            if type(button) ~= "table" then
                modes[key] = nil
            elseif target.mode == "cooldown" then
                if button.mode == "cooldown" then
                    -- The native button accepted the restored cooldown; let its own timer run.
                    modes[key] = nil
                else
                    apply_power_target(button, target)
                end
            elseif button.mode == "cooldown" then
                -- The player cast a spell that had been restored as ready.
                modes[key] = nil
            elseif button.mode == "locked" then
                apply_power_target(button, target)
            end
        end
    end
    if not modes.power_1 and not modes.power_2 then pending_power_restore = nil end
end

local function apply_point(target, source)
    if type(target) ~= "table" or type(source) ~= "table"
        or type(source.x) ~= "number" or type(source.y) ~= "number" then
        return false
    end
    target.x, target.y = source.x, source.y
    return true
end

local function apply_enemy_snapshot(entity, snapshot)
    if type(entity.enemy) ~= "table" or type(entity.health) ~= "table"
        or type(entity.pos) ~= "table" or type(entity.nav_path) ~= "table" then
        return false
    end
    entity.health.hp = snapshot.hp
    entity.health.dead = false
    apply_point(entity.pos, snapshot.pos)
    entity.nav_path.pi = snapshot.nav_path.pi
    entity.nav_path.spi = snapshot.nav_path.spi
    entity.nav_path.ni = snapshot.nav_path.ni
    if type(snapshot.nav_path.dir) == "number" then entity.nav_path.dir = snapshot.nav_path.dir end
    if type(snapshot.heading_angle) == "number" and type(entity.heading) == "table" then
        entity.heading.angle = snapshot.heading_angle
    end
    if type(snapshot.max_speed) == "number" and type(entity.motion) == "table" then
        entity.motion.max_speed = snapshot.max_speed
    end
    if type(snapshot.unit_level) == "number" and type(entity.unit) == "table" then
        entity.unit.level = snapshot.unit_level
    end
    if type(snapshot.stun_count) == "number" and type(entity.unit) == "table" then
        entity.unit.stun_count = snapshot.stun_count
    end
    if type(snapshot.motion_arrived) == "boolean" and type(entity.motion) == "table" then
        entity.motion.arrived = snapshot.motion_arrived
    end
    return true
end

local function find_hero(store, template)
    for _, entity in pairs(store.entities or {}) do
        if type(entity) == "table" and type(entity.hero) == "table"
            and entity.template_name == template then
            return entity
        end
    end
    return nil
end

local function apply_hero_snapshot(store, snapshot)
    local entity = find_hero(store, snapshot.template)
    if not entity then return false end
    if type(snapshot.hp) == "number" and type(entity.health) == "table" then
        entity.health.hp = snapshot.hp
    end
    if type(snapshot.level) == "number" then entity.hero.level = snapshot.level end
    if type(snapshot.xp) == "number" then entity.hero.xp = snapshot.xp end
    if type(snapshot.skills) == "table" and type(entity.hero.skills) == "table" then
        for key, value in pairs(snapshot.skills) do
            if entity.hero.skills[key] ~= nil and type(entity.hero.skills[key]) == type(value) then
                entity.hero.skills[key] = value
            end
        end
    end
    if snapshot.pos and entity.pos then apply_point(entity.pos, snapshot.pos) end
    if snapshot.rally_pos and type(entity.nav_rally) == "table" then
        if apply_point(entity.nav_rally.pos, snapshot.rally_pos) then
            entity.nav_rally.new = true
        end
    end
    return true
end

local function barrack_soldiers_by_slot(barrack)
    local result = {}
    local count = 0
    for key, soldier in pairs((type(barrack) == "table" and barrack.soldiers) or {}) do
        local slot = tonumber(key)
        if slot and type(soldier) == "table" and type(soldier.soldier) == "table" then
            result[slot] = soldier
            count = count + 1
        end
    end
    return result, count
end

local function save_checkpoint()
    local current_game, store = active_state()
    if not store then
        write_status("未保存：当前不在关卡中。", "F5 only works inside a level.")
        return
    end
    if pending_restore then
        write_status("未保存：正在恢复检查点，请稍候。", "Checkpoint restore is still running.")
        return
    end

    local towers, skipped_unsupported, skipped_missing_id, detected_towers, unsupported_templates, missing_id_templates = saved_towers(store)
    local skipped_towers = skipped_unsupported + skipped_missing_id
    if detected_towers > 0 and #towers == 0 then
        write_status(
            "保存失败：识别到 " .. tostring(detected_towers) .. " 座塔，但没有一座能映射到可恢复塔位；现有检查点未被覆盖。"
                .. (#unsupported_templates > 0 and " 不支持的塔型：" .. table.concat(unsupported_templates, "、") .. "。" or "")
                .. (#missing_id_templates > 0 and " 缺少编号的塔型：" .. table.concat(missing_id_templates, "、") .. "。" or ""),
            "Save blocked: 0/" .. tostring(detected_towers) .. " towers. Existing checkpoint kept."
        )
        return
    end
    local active_enemies = count_live_enemies(store)
    local units, unit_counts = snapshot_units(store, towers)
    local powers = snapshot_power_modes(current_game)
    local wave_progress = snapshot_wave_progress(store)
    local power_summary_zh = power_snapshot_summary(powers, false)
    local power_summary_en = power_snapshot_summary(powers, true)
    local metadata = {
        game = "Kingdom Rush",
        format = MOD_VERSION,
        level_idx = store.level_idx,
        level_name = store.level_name,
        level_mode = store.level_mode,
        difficulty = store.level_difficulty,
        wave = wave_progress.wave_group_number,
        next_wave_group = wave_progress.next_wave_group_idx,
        lives = store.lives,
        saved_at = os.date("%Y-%m-%d %H:%M:%S"),
        detected_towers = detected_towers,
        skipped_towers = skipped_towers,
        skipped_unsupported = skipped_unsupported,
        skipped_missing_id = skipped_missing_id,
        unsupported_templates = unsupported_templates,
        missing_id_templates = missing_id_templates,
        enemy_count = unit_counts.enemies,
        skipped_enemies = unit_counts.skipped_enemies,
        hero_count = unit_counts.heroes,
        barrack_soldier_count = unit_counts.soldiers,
    }
    local payload = {
        format = MOD_VERSION,
        metadata = metadata,
        state = {
            player_gold = store.player_gold,
            lives = store.lives,
            wave_group_number = wave_progress.wave_group_number,
            next_wave_group_idx = wave_progress.next_wave_group_idx,
            waves_finished = wave_progress.waves_finished,
            towers = towers,
            units = units,
            powers = powers,
        },
    }
    local encoded_ok, encoded = pcall(json.encode, payload)
    if not encoded_ok then
        write_status("保存失败：无法编码检查点。", "Checkpoint save failed.")
        return
    end

    local temp_path = checkpoint_path .. ".tmp"
    local file, err = io.open(temp_path, "wb")
    if not file then
        write_status("保存失败：无法创建文件（" .. tostring(err) .. "）。", "Could not write checkpoint file.")
        return
    end
    local write_ok, write_err = pcall(function()
        assert(file:write(encoded))
        assert(file:flush())
    end)
    file:close()
    if not write_ok then
        os.remove(temp_path)
        write_status("保存失败：" .. tostring(write_err), "Checkpoint save failed.")
        return
    end

    local previous_path = checkpoint_path .. ".previous"
    os.remove(previous_path)
    local had_previous = os.rename(checkpoint_path, previous_path)
    local renamed, rename_error = os.rename(temp_path, checkpoint_path)
    if not renamed then
        if had_previous then os.rename(previous_path, checkpoint_path) end
        os.remove(temp_path)
        write_status("保存失败：无法替换检查点（" .. tostring(rename_error) .. "）。", "Checkpoint save failed.")
        return
    end
    local warning = active_enemies > 0 and " Active enemies are recorded, but the remaining wave spawn queue and unit attack timers are not saved; between-wave saves are most reliable." or ""
    if skipped_unsupported > 0 then warning = warning .. " Unsupported tower templates skipped: " .. tostring(skipped_unsupported) .. "." end
    if skipped_missing_id > 0 then warning = warning .. " Towers without a usable slot ID skipped: " .. tostring(skipped_missing_id) .. "." end
    if #unsupported_templates > 0 then
        warning = warning .. " Unsupported templates: " .. table.concat(unsupported_templates, ", ") .. "."
    end
    if #missing_id_templates > 0 then
        warning = warning .. " Missing slot ID templates: " .. table.concat(missing_id_templates, ", ") .. "."
    end
    write_status(
        "中途检查点已保存：关卡 " .. tostring(metadata.level_name or metadata.level_idx or "?")
            .. "，第 " .. tostring(metadata.wave or "?") .. " 波；下一波 "
            .. (wave_progress.next_wave_group_idx and ("第 " .. tostring(wave_progress.next_wave_group_idx) .. " 波") or "已结束")
            .. "；已记录 " .. tostring(#towers) .. " 座塔（识别 " .. tostring(detected_towers) .. " 座）。"
            .. (active_enemies > 0 and " 当前怪物会记录，但本波后续刷怪队列、投射物、攻击动画、单位攻击冷却和限时效果不会保存；波间存档最稳妥。" or "")
            .. " 怪物 " .. tostring(#units.enemies) .. "/" .. tostring(unit_counts.enemies) .. "。"
            .. " 英雄 " .. tostring(#units.heroes) .. " 位；兵营士兵 " .. tostring(unit_counts.soldiers) .. " 名。"
            .. (power_summary_zh ~= "" and (" 技能状态：" .. power_summary_zh .. "。") or "")
            .. (unit_counts.skipped_enemies > 0 and " 有 " .. tostring(unit_counts.skipped_enemies) .. " 个怪物缺少可恢复路径数据。" or "")
            .. (skipped_unsupported > 0 and " 有 " .. tostring(skipped_unsupported) .. " 座塔型不支持。" or "")
            .. (skipped_missing_id > 0 and " 有 " .. tostring(skipped_missing_id) .. " 座塔缺少可用塔位编号。" or "")
            .. (#unsupported_templates > 0 and " 不支持的塔型：" .. table.concat(unsupported_templates, "、") .. "。" or "")
            .. (#missing_id_templates > 0 and " 缺少编号的塔型：" .. table.concat(missing_id_templates, "、") .. "。" or ""),
        "Saved " .. tostring(#towers) .. "/" .. tostring(detected_towers) .. " towers; enemies "
            .. tostring(#units.enemies) .. "/" .. tostring(unit_counts.enemies)
            .. "; next wave " .. (wave_progress.next_wave_group_idx and tostring(wave_progress.next_wave_group_idx) or "finished") .. "; heroes "
            .. tostring(#units.heroes) .. "; barrack soldiers " .. tostring(unit_counts.soldiers) .. "."
            .. (power_summary_en ~= "" and (" Powers: " .. power_summary_en .. ".") or "") .. warning
    )
end

local function find_tower_or_holder(store, holder_id)
    local holder, tower = nil, nil
    for _, entity in pairs(store.entities or {}) do
        if type(entity) == "table" and type(entity.tower) == "table" then
            local entity_holder_id = tower_slot_id(entity, entity.tower)
            if entity_holder_id == holder_id then
                if entity.tower.type == "holder" then holder = entity else tower = entity end
            end
        end
    end
    return holder, tower
end

local function finish_restore(partial, reason)
    if not pending_restore then return end
    local current_game, store = active_state()
    if not store then pending_restore = nil; return end

    if not partial and pending_restore.unit_warning then
        partial = true
        reason = pending_restore.unit_warning
    end
    if not partial then
        for _, wanted in ipairs(pending_restore.expected_towers or {}) do
            local _, tower = find_tower_or_holder(store, wanted.holder_id)
            if not tower or tower.template_name ~= wanted.template then
                partial = true
                reason = "塔位 " .. tostring(wanted.holder_id) .. " 未验证为 " .. tostring(wanted.template)
                break
            end
        end
    end

    local power_summary, power_toast_summary, power_modes = restore_power_modes(current_game, pending_restore.powers)
    pending_power_restore = {modes = power_modes}
    store.player_gold = pending_restore.player_gold
    store.lives = pending_restore.lives
    local wave_ok, wave_error = restore_wave_progress(current_game, store, pending_restore.wave,
        pending_restore.next_wave_group_idx, pending_restore.waves_finished)
    if not wave_ok then
        partial = true
        reason = reason or wave_error
        set_next_wave_button(current_game, false)
    end
    local tower_count = pending_restore.tower_count
    local skipped_towers = pending_restore.skipped_towers or 0
    local used_previous = pending_restore.used_previous == true
    local restored_enemies = pending_restore.restored_enemies or 0
    local restored_heroes = pending_restore.restored_heroes or 0
    local restored_soldiers = pending_restore.restored_soldiers or 0
    local skipped_enemies = pending_restore.skipped_enemies or 0
    local next_wave_group_idx = pending_restore.next_wave_group_idx
    local waves_finished = pending_restore.waves_finished == true
    pending_restore = nil
    if partial then
        local detail = reason and ("原因：" .. reason .. "。") or ""
        local source_note = used_previous and "（使用上一份检查点）" or ""
        local toast = reason and ("Checkpoint restore incomplete: " .. reason) or "Some saved state could not be restored. Check the map."
        if power_toast_summary ~= "" then toast = toast .. "; powers: " .. power_toast_summary end
        write_status("检查点恢复未完成" .. source_note .. "（目标 " .. tostring(tower_count) .. " 座塔）。" .. detail
            .. (power_summary ~= "" and ("技能按钮：" .. power_summary .. "。") or ""), toast)
    else
        local skipped_note = skipped_towers > 0 and ("另有 " .. tostring(skipped_towers) .. " 座不支持的塔未恢复。") or ""
        local skipped_enemy_note = skipped_enemies > 0 and ("另有 " .. tostring(skipped_enemies) .. " 个怪物因缺少路径数据未恢复。") or ""
        local toast_note = skipped_towers > 0 and ("; unsupported towers skipped: " .. tostring(skipped_towers)) or ""
        local source_note = used_previous and "（使用上一份检查点）" or ""
        local toast_source = used_previous and " (previous checkpoint)" or ""
        write_status("检查点已恢复" .. source_note .. "：" .. tostring(tower_count) .. " 座塔、"
            .. tostring(restored_enemies) .. " 个怪物、" .. tostring(restored_heroes) .. " 位英雄和 "
            .. tostring(restored_soldiers) .. " 名兵营士兵已恢复；" .. skipped_note .. skipped_enemy_note
            .. (power_summary ~= "" and ("技能按钮：" .. power_summary .. "。") or "")
            .. "未触发出兵；下一波已定位到 "
            .. (waves_finished and "本关最后一波之后（无待出波次）。" or ("第 " .. tostring(next_wave_group_idx) .. " 波。"))
            .. "限时效果、攻击动画和投射物不会恢复。", "Checkpoint restored: " .. tostring(tower_count)
            .. " towers, " .. tostring(restored_enemies) .. " enemies, " .. tostring(restored_heroes)
            .. " heroes, " .. tostring(restored_soldiers) .. " barrack soldiers" .. toast_note .. toast_source
            .. (power_toast_summary ~= "" and ("; powers: " .. power_toast_summary) or "")
            .. "; next wave " .. (waves_finished and "finished" or tostring(next_wave_group_idx)) .. "; no wave started.")
    end
end

local function abort_restore(reason)
    finish_restore(true, reason)
end

local function apply_soldier_snapshot(soldier, snapshot)
    if type(soldier) ~= "table" or type(soldier.soldier) ~= "table"
        or soldier.template_name ~= snapshot.template or type(soldier.health) ~= "table" then
        return false
    end
    soldier.health.hp = snapshot.hp
    if type(snapshot.level) == "number" and type(soldier.unit) == "table" then
        soldier.unit.level = snapshot.level
    end
    return true
end

local function queue_saved_enemies(store)
    local units = pending_restore.units or {}
    local enemies = units.enemies or {}
    if #enemies == 0 then
        if pending_restore.unit_warning then
            finish_restore(true, pending_restore.unit_warning)
        else
            finish_restore(false)
        end
        return
    end

    local ok_db, entity_db = pcall(require, "entity_db")
    local simulation = rawget(_G, "game") and game.simulation
    if not ok_db or type(entity_db) ~= "table" or type(simulation) ~= "table"
        or type(simulation.queue_insert_entity) ~= "function" then
        abort_restore("无法调用游戏实体数据库或插入接口")
        return
    end

    pending_restore.enemy_ids = {}
    for _, snapshot in ipairs(enemies) do
        local ok_create, entity = pcall(function()
            return entity_db:create_entity(snapshot.template)
        end)
        if not ok_create or type(entity) ~= "table" or not apply_enemy_snapshot(entity, snapshot) then
            abort_restore("无法重建怪物 " .. tostring(snapshot.template))
            return
        end
        if type(entity.id) ~= "number" or type(store.entities) ~= "table" or store.entities[entity.id] ~= nil then
            abort_restore("怪物 " .. tostring(snapshot.template) .. " 的实体编号无效或冲突")
            return
        end
        local ok_insert, insert_error = pcall(function()
            simulation:queue_insert_entity(entity)
        end)
        if not ok_insert then
            abort_restore("无法加入怪物 " .. tostring(snapshot.template) .. "（" .. tostring(insert_error) .. "）")
            return
        end
        pending_restore.enemy_ids[#pending_restore.enemy_ids + 1] = {
            id = entity.id,
            template = snapshot.template,
        }
    end
    pending_restore.phase = "enemies"
    pending_restore.unit_elapsed = 0
    write_status(
        "正在恢复 " .. tostring(#pending_restore.enemy_ids) .. " 个怪物的位置、血量和路径进度。",
        "Restoring " .. tostring(#pending_restore.enemy_ids) .. " enemies and path positions..."
    )
end

local function begin_unit_restore(store)
    if not pending_restore then return end
    local units = pending_restore.units or {enemies = {}, heroes = {}, barracks = {}}
    pending_restore.units = units
    pending_restore.phase = "units"
    pending_restore.unit_elapsed = 0
    pending_restore.barrack_index = 1
    pending_restore.restored_enemies = 0
    pending_restore.restored_heroes = 0
    pending_restore.restored_soldiers = 0
    pending_restore.enemy_ids = {}

    for _, snapshot in ipairs(units.heroes or {}) do
        if not apply_hero_snapshot(store, snapshot) then
            abort_restore("当前关卡找不到保存时的英雄 " .. tostring(snapshot.template))
            return
        end
        pending_restore.restored_heroes = pending_restore.restored_heroes + 1
    end
    if #(units.barracks or {}) == 0 then
        queue_saved_enemies(store)
    else
        write_status("正在等待兵营生成原生士兵，以恢复其血量和等级。", "Waiting for barrack soldiers to spawn...")
    end
end

local function update_unit_restore(dt, store)
    pending_restore.unit_elapsed = pending_restore.unit_elapsed + dt
    if pending_restore.phase == "units" then
        local units = pending_restore.units or {}
        local barrack_state = (units.barracks or {})[pending_restore.barrack_index]
        if not barrack_state then
            queue_saved_enemies(store)
            return
        end

        local _, tower = find_tower_or_holder(store, barrack_state.holder_id)
        if not tower or type(tower.barrack) ~= "table" then
            if pending_restore.unit_elapsed > 20 then
                abort_restore("塔位 " .. tostring(barrack_state.holder_id) .. " 没有生成兵营组件")
            end
            return
        end

        local soldiers_by_slot, current_count = barrack_soldiers_by_slot(tower.barrack)
        if current_count < #barrack_state.soldiers then
            if pending_restore.unit_elapsed > 30 then
                abort_restore("塔位 " .. tostring(barrack_state.holder_id) .. " 的士兵数量不足")
            end
            return
        end

        if barrack_state.rally_pos and type(tower.barrack.rally_pos) == "table" then
            apply_point(tower.barrack.rally_pos, barrack_state.rally_pos)
            tower.barrack.rally_new = true
        end
        for _, soldier_snapshot in ipairs(barrack_state.soldiers) do
            local soldier = soldiers_by_slot[soldier_snapshot.slot]
            if not soldier or not apply_soldier_snapshot(soldier, soldier_snapshot) then
                pending_restore.unit_warning = "塔位 " .. tostring(barrack_state.holder_id)
                    .. " 的士兵栏位 " .. tostring(soldier_snapshot.slot) .. " 与保存状态不匹配"
            else
                pending_restore.restored_soldiers = pending_restore.restored_soldiers + 1
            end
        end
        pending_restore.barrack_index = pending_restore.barrack_index + 1
        pending_restore.unit_elapsed = 0
        return
    end

    if pending_restore.phase == "enemies" then
        local all_inserted = true
        for _, saved in ipairs(pending_restore.enemy_ids or {}) do
            local entity = store.entities and store.entities[saved.id]
            if not entity or entity.template_name ~= saved.template or type(entity.enemy) ~= "table" then
                all_inserted = false
                break
            end
        end
        if all_inserted then
            pending_restore.restored_enemies = #(pending_restore.enemy_ids or {})
            if pending_restore.unit_warning then
                finish_restore(true, pending_restore.unit_warning)
            else
                finish_restore(false)
            end
        elseif pending_restore.unit_elapsed > 15 then
            abort_restore("游戏没有接收全部保存的怪物实体")
        end
    end
end

local function start_next_tower(store)
    if not pending_restore then return end
    if pending_restore.plan_index > #pending_restore.plans then
        begin_unit_restore(store)
        return
    end
    local plan = pending_restore.plans[pending_restore.plan_index]
    local holder, tower = find_tower_or_holder(store, plan.holder_id)
    if tower then
        abort_restore("塔位 " .. tostring(plan.holder_id) .. " 已出现意外塔 " .. tostring(tower.template_name))
        return
    end
    if not holder or type(holder.tower) ~= "table" then
        abort_restore("找不到塔位 " .. tostring(plan.holder_id))
        return
    end

    plan.waiting_for = plan.chain.levels[1]
    plan.next_index = 2
    plan.stage_elapsed = 0
    holder.tower.upgrade_to = plan.chain.build
    write_status(
        "正在恢复塔位 " .. tostring(plan.holder_id) .. "（" .. tostring(pending_restore.plan_index)
            .. "/" .. tostring(#pending_restore.plans) .. "）" .. (pending_restore.used_previous and "；使用上一份检查点" or "") .. "。",
        "Restoring tower slot " .. tostring(plan.holder_id) .. " ("
            .. tostring(pending_restore.plan_index) .. "/" .. tostring(#pending_restore.plans) .. ")"
            .. (pending_restore.used_previous and " from previous checkpoint." or ".")
    )
end

local function update_pending_restore(dt)
    if not pending_restore then return end
    local _, store = active_state()
    if not store then pending_restore = nil; return end
    dt = type(dt) == "number" and math.max(0, dt) or 0
    pending_restore.elapsed = pending_restore.elapsed + dt
    if pending_restore.elapsed > RESTORE_TOTAL_TIMEOUT then
        abort_restore("恢复超过 " .. tostring(RESTORE_TOTAL_TIMEOUT) .. " 秒")
        return
    end

    if pending_restore.phase == "units" or pending_restore.phase == "enemies" then
        update_unit_restore(dt, store)
        return
    end

    local plan = pending_restore.plans[pending_restore.plan_index]
    if not plan then
        finish_restore(false)
        return
    end

    local _, tower = find_tower_or_holder(store, plan.holder_id)
    if tower and tower.template_name == plan.waiting_for then
        local next_template = plan.chain.levels[plan.next_index]
        if next_template then
            tower.tower.upgrade_to = next_template
            plan.waiting_for = next_template
            plan.next_index = plan.next_index + 1
            plan.stage_elapsed = 0
        else
            pending_restore.plan_index = pending_restore.plan_index + 1
            start_next_tower(store)
        end
        return
    end

    plan.stage_elapsed = plan.stage_elapsed + dt
    if plan.stage_elapsed > RESTORE_STAGE_TIMEOUT then
        local actual = tower and tostring(tower.template_name) or "塔尚未生成"
        abort_restore(
            "塔位 " .. tostring(plan.holder_id) .. " 等待 " .. tostring(plan.waiting_for)
                .. " 超时，当前状态：" .. actual
        )
    end
end

local function read_checkpoint_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local decoded_ok, payload = pcall(json.decode, content)
    if not decoded_ok or type(payload) ~= "table"
        or (payload.format ~= MOD_VERSION and payload.format ~= 2 and payload.format ~= 3 and payload.format ~= 4 and payload.format ~= 5 and payload.format ~= 6 and payload.format ~= 7 and payload.format ~= 8) then
        return nil
    end
    local metadata, state = payload.metadata, payload.state
    if type(metadata) ~= "table" or type(state) ~= "table" or type(state.towers) ~= "table" then
        return nil
    end
    if type(state.units) ~= "table" then state.units = {} end
    for _, key in ipairs({"enemies", "heroes", "barracks"}) do
        if state.units[key] == nil then
            state.units[key] = {}
        elseif type(state.units[key]) ~= "table" then
            return nil
        end
    end
    if state.powers == nil then
        state.powers = {}
    elseif type(state.powers) ~= "table" then
        return nil
    end
    if state.next_wave_group_idx ~= nil and (type(state.next_wave_group_idx) ~= "number"
        or state.next_wave_group_idx < 1 or state.next_wave_group_idx % 1 ~= 0) then
        return nil
    end
    if state.waves_finished ~= nil and type(state.waves_finished) ~= "boolean" then return nil end
    for _, key in ipairs({"power_1", "power_2"}) do
        local power = state.powers[key]
        if power ~= nil and (type(power) ~= "table" or type(power.mode) ~= "string" or not POWER_MODES[power.mode]) then
            return nil
        end
        if type(power) == "table" then
            for _, timer_key in ipairs({"cooldown_time", "cooldown_elapsed", "cooldown_remaining"}) do
                local value = power[timer_key]
                if value ~= nil and (type(value) ~= "number" or value < 0 or value ~= value
                    or value == math.huge or value == -math.huge) then
                    return nil
                end
            end
        end
    end
    if payload.format ~= MOD_VERSION then
        metadata.detected_towers = metadata.detected_towers or #state.towers
        metadata.skipped_towers = metadata.skipped_towers or 0
    end
    return payload, metadata, state
end

local function checkpoint_matches_level(metadata, store)
    return metadata.level_idx == store.level_idx
        and metadata.level_mode == store.level_mode
        and metadata.difficulty == store.level_difficulty
end

local function checkpoint_has_missing_towers(metadata, state, format)
    local wave = type(metadata.wave) == "number" and metadata.wave or 0
    local detected = type(metadata.detected_towers) == "number" and metadata.detected_towers or 0
    return #state.towers == 0 and (detected > 0 or (format < COMBAT_UNIT_FORMAT and wave > 1))
end

local function validate_saved_units(units, towers, store)
    local saved_tower_ids = {}
    for _, tower in ipairs(towers) do
        if type(tower) == "table" and type(tower.holder_id) == "number" then
            saved_tower_ids[tower.holder_id] = true
        end
    end

    for _, snapshot in ipairs(units.heroes or {}) do
        if type(snapshot) ~= "table" or type(snapshot.template) ~= "string"
            or not find_hero(store, snapshot.template) then
            return false, "当前关卡找不到检查点中的英雄 "
                .. tostring(type(snapshot) == "table" and snapshot.template or "?")
        end
        if (snapshot.hp ~= nil and type(snapshot.hp) ~= "number")
            or (snapshot.level ~= nil and type(snapshot.level) ~= "number")
            or (snapshot.xp ~= nil and type(snapshot.xp) ~= "number") then
            return false, "英雄状态数据无效"
        end
        if snapshot.skills ~= nil and type(snapshot.skills) ~= "table" then
            return false, "英雄技能数据无效"
        end
        for key, value in pairs(snapshot.skills or {}) do
            local value_type = type(value)
            if type(key) ~= "string" or (value_type ~= "number" and value_type ~= "boolean" and value_type ~= "string") then
                return false, "英雄技能数据无效"
            end
        end
    end

    for _, barrack in ipairs(units.barracks or {}) do
        if type(barrack) ~= "table" or type(barrack.holder_id) ~= "number"
            or not saved_tower_ids[barrack.holder_id] or type(barrack.soldiers) ~= "table" then
            return false, "兵营士兵数据没有对应的已保存塔位"
        end
        local holder, tower = find_tower_or_holder(store, barrack.holder_id)
        if not holder and not tower then
            return false, "当前地图找不到兵营塔位 " .. tostring(barrack.holder_id)
        end
        local seen_slots = {}
        for _, soldier in ipairs(barrack.soldiers) do
            if type(soldier) ~= "table" or type(soldier.slot) ~= "number"
                or soldier.slot < 1 or soldier.slot % 1 ~= 0 or seen_slots[soldier.slot]
                or type(soldier.template) ~= "string" or type(soldier.hp) ~= "number" or soldier.hp <= 0 then
                return false, "兵营士兵状态数据无效"
            end
            seen_slots[soldier.slot] = true
        end
        if barrack.rally_pos and (type(barrack.rally_pos) ~= "table"
            or type(barrack.rally_pos.x) ~= "number" or type(barrack.rally_pos.y) ~= "number") then
            return false, "兵营集结点数据无效"
        end
    end

    for _, snapshot in ipairs(units.enemies or {}) do
        local path = type(snapshot) == "table" and snapshot.nav_path or nil
        if type(snapshot) ~= "table" or type(snapshot.template) ~= "string"
            or snapshot.template:sub(1, 6) ~= "enemy_" or type(snapshot.hp) ~= "number" or snapshot.hp <= 0
            or type(snapshot.pos) ~= "table" or type(snapshot.pos.x) ~= "number" or type(snapshot.pos.y) ~= "number"
            or type(path) ~= "table" or type(path.pi) ~= "number"
            or type(path.spi) ~= "number" or type(path.ni) ~= "number" then
            return false, "检查点中的怪物位置或路径数据无效"
        end
    end
    if #units.enemies > 0 then
        local ok_db, entity_db = pcall(require, "entity_db")
        local simulation = rawget(_G, "game") and game.simulation
        if not ok_db or type(entity_db) ~= "table" or type(entity_db.create_entity) ~= "function"
            or type(simulation) ~= "table" or type(simulation.queue_insert_entity) ~= "function" then
            return false, "当前游戏没有可用的怪物创建接口"
        end
        if type(entity_db.entities) == "table" then
            for _, snapshot in ipairs(units.enemies) do
                if entity_db.entities[snapshot.template] == nil then
                    return false, "当前游戏找不到怪物模板 " .. snapshot.template
                end
            end
        end
    end
    return true
end

local function load_checkpoint()
    local current_game, store = active_state()
    if not store then
        write_status("未恢复：请先进入保存时的同一关卡。", "Enter the saved level before restoring.")
        return
    end
    if pending_restore then
        write_status("恢复请求已在处理中。", "Checkpoint restore is still running.")
        return
    end
    local payload, metadata, state = read_checkpoint_file(checkpoint_path)
    local used_previous = false
    if not payload then
        local old_payload, old_metadata, old_state = read_checkpoint_file(checkpoint_path .. ".previous")
        if old_payload and #old_state.towers > 0 and checkpoint_matches_level(old_metadata, store) then
            payload, metadata, state = old_payload, old_metadata, old_state
            used_previous = true
        else
            write_status("恢复失败：找不到有效的中途检查点。", "No usable checkpoint was found.")
            return
        end
    elseif checkpoint_has_missing_towers(metadata, state, payload.format) then
        local old_payload, old_metadata, old_state = read_checkpoint_file(checkpoint_path .. ".previous")
        if old_payload and #old_state.towers > 0 and checkpoint_matches_level(old_metadata, store) then
            payload, metadata, state = old_payload, old_metadata, old_state
            used_previous = true
        else
            write_status(
                "恢复失败：当前检查点没有塔位数据，上一份检查点也没有可用于本关的塔数据。请在仍有塔的关卡状态下重新保存。",
                "No usable tower data in this or the previous checkpoint."
            )
            return
        end
    end
    if not checkpoint_matches_level(metadata, store) then
        write_status("恢复失败：关卡、模式或难度与检查点不一致。", "Level, mode, or difficulty does not match.")
        return
    end
    if count_live_enemies(store) > 0 then
        write_status("恢复失败：当前仍有敌人。请在刚进入关卡、尚未出兵时恢复。", "Wait until the map is clear before restoring.")
        return
    end
    local units_ok, units_error = validate_saved_units(state.units, state.towers, store)
    if not units_ok then
        write_status("恢复失败：" .. units_error .. "。", "Invalid or unsupported unit data: " .. units_error .. ".")
        return
    end
    local plan = {}
    local seen = {}
    for _, wanted in ipairs(state.towers) do
        if type(wanted) ~= "table" or type(wanted.holder_id) ~= "number"
            or type(wanted.template) ~= "string" or wanted.template:sub(1, 6) ~= "tower_"
            or wanted.template:sub(1, 12) == "tower_build_" or seen[wanted.holder_id] then
            write_status("恢复失败：检查点内的塔数据无效。", "Invalid tower data in checkpoint.")
            return
        end
        seen[wanted.holder_id] = true
        local chain = TOWER_PATHS[wanted.template]
        if not chain then
            write_status("恢复失败：检查点包含当前不支持的特殊塔。", "This checkpoint contains an unsupported tower type.")
            return
        end
        local holder, existing_tower = find_tower_or_holder(store, wanted.holder_id)
        if existing_tower then
            if existing_tower.template_name ~= wanted.template then
                write_status("恢复失败：当前地图已有不同的塔。请在空关卡开始时恢复。", "A different tower already occupies a saved slot.")
                return
            end
        elseif holder then
            if holder.tower_holder and holder.tower_holder.blocked then
                write_status("恢复失败：保存的塔位当前仍被封锁。", "A saved tower slot is still blocked.")
                return
            end
            plan[#plan + 1] = {
                holder = holder,
                holder_id = wanted.holder_id,
                template = wanted.template,
                chain = chain,
                waiting_for = chain.levels[1],
                next_index = 2,
                complete = false,
            }
        else
            write_status("恢复失败：当前地图找不到对应塔位。", "A saved tower slot was not found on this map.")
            return
        end
    end

    local target_gold = type(state.player_gold) == "number" and state.player_gold or store.player_gold
    local target_lives = type(state.lives) == "number" and state.lives or store.lives
    local target_wave = type(state.wave_group_number) == "number" and state.wave_group_number or store.wave_group_number
    local next_wave_group_idx = type(state.next_wave_group_idx) == "number" and state.next_wave_group_idx
        or (type(metadata.next_wave_group) == "number" and metadata.next_wave_group or target_wave + 1)
    local waves_finished = state.waves_finished == true
    if not waves_finished and type(store.wave_group_total) == "number" and store.wave_group_total > 0
        and next_wave_group_idx > store.wave_group_total then
        waves_finished = true
        next_wave_group_idx = nil
    end
    if not waves_finished then
        local next_group = get_wave_group(next_wave_group_idx)
        local cursor, cursor_error = read_wave_cursor_locals(store)
        if not next_group or not cursor then
            write_status("恢复失败：无法安全定位检查点的下一波。" .. (cursor_error and (" " .. cursor_error .. "。") or ""),
                "Cannot safely restore the native wave cursor. " .. tostring(cursor_error or "The saved next wave is unavailable."))
            return
        end
    end
    store.send_next_wave = false
    store.force_next_wave = false
    set_next_wave_button(current_game, false)
    if #plan == 0 then
        pending_restore = {
            player_gold = target_gold,
            lives = target_lives,
            wave = target_wave,
            next_wave_group_idx = next_wave_group_idx,
            waves_finished = waves_finished,
            plans = {},
            plan_index = 1,
            expected_towers = state.towers,
            tower_count = #state.towers,
            skipped_towers = tonumber(metadata.skipped_towers) or 0,
            skipped_enemies = tonumber(metadata.skipped_enemies) or 0,
            units = state.units,
            powers = state.powers,
            used_previous = used_previous,
            elapsed = 0,
        }
        begin_unit_restore(store)
        return
    end

    -- Give the game's own tower_upgrade system enough gold while it rebuilds the towers.
    store.player_gold = math.max(tonumber(store.player_gold) or 0, tonumber(target_gold) or 0) + 100000
    pending_restore = {
        player_gold = target_gold,
        lives = target_lives,
        wave = target_wave,
        next_wave_group_idx = next_wave_group_idx,
        waves_finished = waves_finished,
        plans = plan,
        plan_index = 1,
        expected_towers = state.towers,
        tower_count = #state.towers,
        skipped_towers = tonumber(metadata.skipped_towers) or 0,
        skipped_enemies = tonumber(metadata.skipped_enemies) or 0,
        units = state.units,
        powers = state.powers,
        used_previous = used_previous,
        elapsed = 0,
    }
    start_next_tower(store)
end

local previous_f5, previous_f9 = false, false
local M = {}
function M.update(dt)
    update_pending_restore(dt)
    update_power_restore()
    if not love or not love.keyboard then return end
    local f5 = love.keyboard.isDown("f5")
    local f9 = love.keyboard.isDown("f9")
    if f5 and not previous_f5 then save_checkpoint() end
    if f9 and not previous_f9 then
        local now = os.clock()
        if restore_armed_at and now - restore_armed_at <= 5 then
            restore_armed_at = nil
            load_checkpoint()
        else
            restore_armed_at = now
            write_status("请在 5 秒内再次按 F9 确认恢复。", "Press F9 again within 5 seconds to restore.")
        end
    end
    if restore_armed_at and os.clock() - restore_armed_at > 5 then restore_armed_at = nil end
    previous_f5, previous_f9 = f5, f9
end

function M.draw()
    if not toast_text or os.clock() > toast_until or not love or not love.graphics then return end
    local graphics = love.graphics
    local ok, old_r, old_g, old_b, old_a = pcall(graphics.getColor)
    local major = love.getVersion and select(1, love.getVersion()) or 11
    local full = major >= 11 and 1 or 255
    local alpha = major >= 11 and 0.82 or 220
    old_a = old_a or full
    local width = graphics.getWidth and graphics.getWidth() or 800
    pcall(function()
        graphics.setColor(0, 0, 0, alpha)
        graphics.rectangle("fill", 8, 8, math.max(300, width - 16), 42)
        graphics.setColor(full, full, full, full)
        graphics.print(toast_text, 16, 17)
    end)
    if ok then pcall(graphics.setColor, old_r, old_g, old_b, old_a) end
end

write_status("KRQuickSave v9 已加载。F5 保存；F9 需按两次确认。", "KRQuickSave v9 ready. F5 saves; double-press F9 to restore.")
return M
