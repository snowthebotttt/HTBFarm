--[[
    HTBFarm - Garuda HTBF party farming loop (Windower4, private server)
    v0.5.0 - six-character synchronized party mode

    ONE ADDON FILE, ALL SIX CLIENTS. Each client identifies its role by
    character name (LEADER_NAME below). Run "//htb start" on the LEADER
    only - it broadcasts the start to the other five over Windower IPC.

    Cycle (all six in lockstep, synced over IPC):
      1. Each character buys their own "Avatar phantom gem" if not held,
         then runs to the Sandy home point and reports ready
      2. Leader waits for 6/6, fires //hp a cape (superwarp moves everyone)
      3. Everyone runs Teriggan -> Cloister -> protocrystal, reports ready
      4. Leader enters the battlefield via the real menu (Down/Enter/Up/
         Enter = VERY EASY), then broadcasts go; followers enter the same
         way, staggered a few seconds apart
      5. Everyone runs to the buff spot; when 6/6 inside, leader fires
         //sm all on
      6. Each client detects its own ejection; when 6/6 are out (+ lotter
         pause), everyone runs back out of the Cloister to the Teriggan HP
      7. Leader fires //hp a northern sandy 2; all land home; next cycle

    Any character dying, timing out, or hitting an unexpected zone
    broadcasts a halt to the whole party and sends //sm all off.

    Commands:
      //htb start    -> (leader) start the party loop; (follower) refuses
      //htb stop     -> stop ALL six clients (broadcasts)
      //htb unstick  -> force-close a stuck NPC menu on this client
      //htb status   -> print state/role
      //htb hud      -> toggle HUD

    Packet values decoded from capture 2026-07-17:
      KI NPC (N. Sandy, index 427): Menu ID 892, option 3586, single step
        (KI purchase still uses packet injection - proven working)
      Protocrystal (Cloister, index 50): entry via real keyboard input
        (server validates packet sequence numbers on this code path)
]]

_addon.name    = 'HTBFarm'
_addon.author  = 'Jared + Claude'
_addon.version = '0.7.1'
_addon.commands = {'htbfarm', 'htb'}

local packets = require('packets')
local res     = require('resources')
local texts   = require('texts')
require('logger')

----------------------------------------------------------------------
-- CONFIG -------------------------------------------------------------
----------------------------------------------------------------------

local LEADER_NAME = 'Snowmann'

local ZONE_SANDY    = 231
local ZONE_TERIGGAN = 113
local ZONE_CLOISTER = 201

local KI_NAME = 'Avatar phantom gem'

local KI_NPC = {
    index    = 427,
    menu_id  = 892,     -- Trisvain, N. San d'Oria (J-7)
    option   = 3586,    -- 0x100 * 14 + 0x02: Avatar phantom gem
    slot     = 14,      -- Avatar phantom gem's bit in the availability mask
    cost     = 10,      -- merit points per gem
}

local PROTOCRYSTAL = {
    index    = 50,
    menu_id  = 32000,
}

-- LEGACY (unused since v0.6.0): keyboard entry sequence, kept for reference
-- in case the Silmaril reflect ever needs a fallback.
-- Very Difficult: down, enter, up x5, enter. Very Easy: down, enter, up, enter.
local ENTRY_KEY_SEQUENCE = {
    { 'down',  2.5 },
    { 'enter', 3.0 },
    { 'up',    2.0 },
    { 'up',    2.0 },
    { 'up',    2.0 },
    { 'up',    2.0 },
    { 'up',    2.0 },
    { 'enter', 3.0 },
}
local ENTRY_MENU_RENDER_WAIT = 6.0  -- wait after menu packet before first key
local ENTRY_STAGGER = 0             -- seconds between each follower's entry
                                    -- (0 = all followers enter simultaneously
                                    -- once the leader is inside)

local SUPERWARP_OUT  = 'input //hp a cape'             -- leader only; warps all
local SUPERWARP_HOME = 'input //hp a northern sand 2'  -- leader only; warps all
local FIGHT_ON_CMD   = 'input //sm all on'             -- leader only
local FIGHT_OFF_CMD  = 'input //sm all off'            -- any client, on halt
local REFLECT_CMD    = 'input //sm all reflect Garuda' -- leader only; Silmaril
                                                       -- mirror enters the BC
                                                       -- on ALL characters
local REFLECT_KI_CMD = 'input //sm all reflect Avatar' -- leader only; Silmaril
                                                       -- mirror buys the KI on
                                                       -- ALL characters (works
                                                       -- even for characters who
                                                       -- cannot buy it normally)

local BC_X_THRESHOLD = 100   -- zone 201: x > this = inside the battlefield

local MAX_NPC_DISTANCE   = 6.0
local WAYPOINT_STOP_DIST = 2.0
local MOVE_POLL          = 0.2
local MOVE_TIMEOUT_PER_WAYPOINT = 25
local MENU_STEP_DELAY    = 0.5
local ZONE_LINE_PUSH_SECS = 15
local LOTTER_WAIT        = 4.0
local CYCLE_GAP          = 3.0

-- Per-state timeouts (seconds). Exceeding one halts the whole party.
local TIMEOUTS = {
    BUY_KI        = 45,
    WAIT_PARTY    = 120,   -- generic "waiting for everyone" states
    ZONE_LOAD     = 60,
    ENTER_BC      = 60,
    WAIT_ENTRY    = 180,   -- followers waiting for their staggered turn
    FIGHT         = 1800,
}

----------------------------------------------------------------------
-- MOVEMENT DATA (PathMap recording 2026-07-17 + reversed legs) -------
----------------------------------------------------------------------

local LEG_S1 = {  -- Sandy: start -> KI NPC
    { x = 26.26, y = 86.01 },
}

local LEG_S2 = {  -- Sandy: KI NPC -> HP crystal
    { x = 11.27, y = 93.77 },
}

local LEG_T1 = {  -- Teriggan: HP -> Cloister zone line
    { x = -300.19, y = 534.03 },
    { x = -296.19, y = 538.40 },
    { x = -291.96, y = 539.67 },
}

local LEG_C1 = {  -- Cloister: entrance -> protocrystal
    { x = -388.41, y = -419.24 },
    { x = -383.43, y = -415.83 },
    { x = -381.23, y = -411.85 },
    { x = -378.51, y = -395.02 },
    { x = -375.88, y = -389.57 },
    { x = -371.25, y = -383.56 },
    { x = -360.43, y = -380.14 },
}

local LEG_B1 = {  -- Battlefield: entry -> buff spot
    { x = 485.47, y = -424.05 },
    { x = 474.72, y = -418.71 },
    { x = 467.12, y = -409.55 },
    { x = 462.75, y = -409.46 },
    { x = 456.52, y = -413.44 },
    { x = 452.59, y = -411.62 },
    { x = 452.86, y = -407.37 },
    { x = 464.00, y = -391.56 },
    { x = 483.24, y = -388.09 },
    { x = 486.30, y = -386.53 },
}

-- Return trip (reversed from the recorded legs)
local LEG_C1_HOME = {  -- Cloister: ejection point -> zone exit
    { x = -371.25, y = -383.56 },
    { x = -375.88, y = -389.57 },
    { x = -378.51, y = -395.02 },
    { x = -381.23, y = -411.85 },
    { x = -383.43, y = -415.83 },
    { x = -388.41, y = -419.24 },
    { x = -399.54, y = -421.13 },  -- zone-in point; push past here to exit
}

local LEG_T1_HOME = {  -- Teriggan: Cloister exit -> HP crystal
    { x = -296.19, y = 538.40 },
    { x = -300.19, y = 534.03 },
    { x = -303.00, y = 525.00 },   -- the home point crystal
}

----------------------------------------------------------------------
-- STATE --------------------------------------------------------------
----------------------------------------------------------------------

local role = 'follower'   -- set on load/login from LEADER_NAME
local my_name = '?'

local loop = {
    active     = false,
    state      = 'IDLE',
    state_time = 0,
    cycles     = 0,
    kis_bought = 0,
    started_at = nil,
}

-- Leader-only: tracks which party members have reported for each phase
local roster = {
    expected = 0,        -- party size captured at start
    counts   = {},       -- counts[phase] = { [name] = true }
}

local pending_menu = {
    kind      = nil,
    npc_id    = nil,
    npc_index = nil,
    zone      = nil,
    menu_id   = nil,
}

local ki_id = nil

----------------------------------------------------------------------
-- HUD ----------------------------------------------------------------
----------------------------------------------------------------------

local hud = texts.new('${text}', {
    pos   = { x = 20, y = 340 },
    bg    = { alpha = 160 },
    text  = { size = 10, font = 'Consolas' },
    flags = { draggable = true },
})
local hud_visible = true

local function phase_count(phase)
    local c = 0
    for _ in pairs(roster.counts[phase] or {}) do c = c + 1 end
    return c
end

local function refresh_hud()
    if not hud_visible then hud:hide() return end
    local elapsed = loop.started_at and (os.clock() - loop.started_at) or 0
    local avg = loop.cycles > 0 and (elapsed / loop.cycles) or 0
    local lines = {
        '-- HTBFarm (' .. role .. ') --',
        ('State        : %s'):format(loop.active and loop.state or 'stopped'),
        ('Cycles done  : %d'):format(loop.cycles),
        ('KIs bought   : %d'):format(loop.kis_bought),
        ('Avg cycle    : %s'):format(avg > 0 and ('%dm %02ds'):format(math.floor(avg/60), math.floor(avg%60)) or '-'),
    }
    if role == 'leader' and loop.active and roster.current_phase then
        lines[#lines + 1] = ('Party synced : %d / %d (%s)'):format(
            phase_count(roster.current_phase), roster.expected, roster.current_phase)
    end
    hud.text = table.concat(lines, '\n')
    hud:show()
end

----------------------------------------------------------------------
-- HELPERS ------------------------------------------------------------
----------------------------------------------------------------------

local function me()
    return windower.ffxi.get_mob_by_target('me')
end

local function current_zone()
    local info = windower.ffxi.get_info()
    return info and info.zone or -1
end

local function is_dead()
    local player = windower.ffxi.get_player()
    if not player then return false end
    if player.vitals and player.vitals.hp == 0 then return true end
    return player.status == 2 or player.status == 3
end

local function has_ki()
    if not ki_id then return false end
    local kis = windower.ffxi.get_key_items()
    if not kis then return false end
    for _, id in ipairs(kis) do
        if id == ki_id then return true end
    end
    return false
end

local function resolve_ki()
    local want = KI_NAME:lower()
    for id, ki in pairs(res.key_items) do
        if (ki.en or ''):lower() == want then
            return id
        end
    end
    return nil
end

-- Party member names (mains, p0-p5), used for follower slot ordering and
-- the leader's expected count.
local function party_names()
    local names = {}
    local party = windower.ffxi.get_party()
    if not party then return names end
    for i = 0, 5 do
        local m = party['p' .. i]
        if m and m.name then names[#names + 1] = m.name end
    end
    return names
end

-- Deterministic follower slot: alphabetical position among non-leader
-- members. Every client computes the same ordering from its own party
-- data, so no slot negotiation is needed.
local function my_follower_slot()
    local followers = {}
    for _, n in ipairs(party_names()) do
        if n ~= LEADER_NAME then followers[#followers + 1] = n end
    end
    table.sort(followers)
    for i, n in ipairs(followers) do
        if n == my_name then return i - 1 end
    end
    return 0
end

local function poke_npc(mob)
    local p = packets.new('outgoing', 0x01A, {
        ['Target']       = mob.id,
        ['Target Index'] = mob.index,
        ['Category']     = 0,
        ['Param']        = 0,
        ['_unknown1']    = 0,
    })
    packets.inject(p)
end

local function send_menu_option(menu_id, option, npc_id, npc_index, zone, automated, unknown1)
    local p = packets.new('outgoing', 0x05B, {
        ['Target']            = npc_id,
        ['Option Index']      = option,
        ['_unknown1']         = unknown1 or 0,
        ['Target Index']      = npc_index,
        ['Automated']         = automated and 1 or 0,
        ['Automated Message'] = automated and true or false,
        ['_unknown2']         = 0,
        ['Zone']              = zone,
        ['Menu ID']           = menu_id,
    })
    packets.inject(p)
end

local function press_escape()
    windower.send_command('setkey escape down;wait 0.5;setkey escape up')
end

local function press_key(key)
    windower.send_command(('setkey %s down;wait 0.2;setkey %s up'):format(key, key))
end

local function send_menu_exit()
    if not (pending_menu.menu_id and pending_menu.npc_id) then
        press_escape()
        return
    end
    send_menu_option(pending_menu.menu_id, 0,
        pending_menu.npc_id, pending_menu.npc_index, pending_menu.zone, false, 0x4000)
    press_escape()
end

----------------------------------------------------------------------
-- IPC ----------------------------------------------------------------
----------------------------------------------------------------------

-- Message format: "htbf <sender> <type>[ <extra...>]"
local function ipc_send(msg_type, extra)
    windower.send_ipc_message(('htbf %s %s%s'):format(my_name, msg_type, extra and (' ' .. extra) or ''))
end

local function halt(reason, from_ipc)
    if not loop.active and loop.state == 'IDLE' then return end
    loop.active = false
    loop.state = 'IDLE'
    pending_menu.kind = nil
    windower.ffxi.run(false)
    windower.send_command(FIGHT_OFF_CMD)
    log('[HALT] ' .. reason)
    if not from_ipc then
        ipc_send('STOP', reason)
    end
    refresh_hud()
end

local function set_state(s)
    loop.state = s
    loop.state_time = os.clock()
    log('[state] ' .. s)
    refresh_hud()
end

local function state_elapsed()
    return os.clock() - loop.state_time
end

-- Leader: record a member's report for a phase; returns true if everyone
-- (including the leader itself, which must self-report) has reported.
local function leader_mark(phase, name)
    roster.counts[phase] = roster.counts[phase] or {}
    roster.counts[phase][name] = true
    roster.current_phase = phase
    refresh_hud()
    return phase_count(phase) >= roster.expected
end

local function leader_reset_phase(phase)
    roster.counts[phase] = {}
end

----------------------------------------------------------------------
-- MOVEMENT -----------------------------------------------------------
----------------------------------------------------------------------

local function walk_to_point(x, y, zone, on_done, elapsed)
    elapsed = elapsed or 0
    if not loop.active then windower.ffxi.run(false) return end
    if current_zone() ~= zone then windower.ffxi.run(false) return end
    local m = me()
    if m then
        local dx, dy = x - m.x, y - m.y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= WAYPOINT_STOP_DIST then
            on_done(true)
            return
        end
        windower.ffxi.run(dx, dy)
    end
    if elapsed >= MOVE_TIMEOUT_PER_WAYPOINT then
        windower.ffxi.run(false)
        on_done(false)
        return
    end
    coroutine.schedule(function()
        walk_to_point(x, y, zone, on_done, elapsed + MOVE_POLL)
    end, MOVE_POLL)
end

local function play_leg(points, zone, on_done)
    local function step(i)
        if not loop.active then windower.ffxi.run(false) return end
        if i > #points then
            windower.ffxi.run(false)
            on_done()
            return
        end
        walk_to_point(points[i].x, points[i].y, zone, function(ok)
            if not loop.active then windower.ffxi.run(false) return end
            if not ok then
                halt(('timed out walking to waypoint %d (%.1f, %.1f) - stuck?')
                    :format(i, points[i].x, points[i].y))
                return
            end
            step(i + 1)
        end)
    end
    step(1)
end

local function push_through_zone_line(points, zone, elapsed)
    elapsed = elapsed or 0
    if not loop.active then windower.ffxi.run(false) return end
    if current_zone() ~= zone then windower.ffxi.run(false) return end
    if elapsed >= ZONE_LINE_PUSH_SECS then
        windower.ffxi.run(false)
        halt('pushed past the last waypoint but never crossed the zone line.')
        return
    end
    local a, b = points[#points - 1], points[#points]
    local dx, dy = b.x - a.x, b.y - a.y
    if dx == 0 and dy == 0 then dx = 1 end
    windower.ffxi.run(dx, dy)
    coroutine.schedule(function()
        push_through_zone_line(points, zone, elapsed + MOVE_POLL)
    end, MOVE_POLL)
end

----------------------------------------------------------------------
-- WATCHDOG helper ----------------------------------------------------
----------------------------------------------------------------------

local function watchdog(state_name, timeout, reason)
    local function check()
        if not loop.active or loop.state ~= state_name then return end
        if state_elapsed() >= timeout then
            halt(reason)
        else
            coroutine.schedule(check, 2)
        end
    end
    coroutine.schedule(check, 2)
end

----------------------------------------------------------------------
-- STATE MACHINE ------------------------------------------------------
----------------------------------------------------------------------

local enter_state = {}

local function goto_state(s)
    if not loop.active then return end
    set_state(s)
    if enter_state[s] then enter_state[s]() end
end

-- 1. Everyone runs to Trisvain and reports; leader fires the KI reflect
-- for the whole party; each client polls its own key items.
enter_state.BUY_KI = function()
    if current_zone() ~= ZONE_SANDY then
        halt('expected to be in N. San d\'Oria to start a cycle.')
        return
    end
    watchdog('BUY_KI', TIMEOUTS.BUY_KI, 'never reached the KI NPC.')
    play_leg(LEG_S1, ZONE_SANDY, function()
        local mob = windower.ffxi.get_mob_by_index(KI_NPC.index)
        if not mob or mob.distance:sqrt() > MAX_NPC_DISTANCE then
            halt('KI NPC (Trisvain) not found or too far.')
            return
        end
        goto_state('WAIT_KI')
        ipc_send('READY_KINPC')
        if role == 'leader' then
            if leader_mark('READY_KINPC', my_name) then
                log('Party at Trisvain - reflecting the KI purchase.')
                windower.send_command(REFLECT_KI_CMD)
            end
        end
    end)
end

-- Wait for the KI to actually appear in this character's key items after
-- the reflect (characters that already held it pass immediately).
enter_state.WAIT_KI = function()
    watchdog('WAIT_KI', TIMEOUTS.WAIT_PARTY, 'KI never appeared after the reflect (out of merits/gil? reflect failed?).')
    local function poll()
        if not loop.active or loop.state ~= 'WAIT_KI' then return end
        if has_ki() then
            loop.kis_bought = loop.kis_bought + 1
            log('KI confirmed.')
            goto_state('TO_HP')
            return
        end
        coroutine.schedule(poll, 0.5)
    end
    coroutine.schedule(poll, 1.0)
end

-- 2. At the HP: report ready; leader warps everyone when 6/6
enter_state.TO_HP = function()
    play_leg(LEG_S2, ZONE_SANDY, function()
        goto_state('WAIT_WARP_OUT')
        ipc_send('READY_HP')
        if role == 'leader' then
            if leader_mark('READY_HP', my_name) then
                log('Party ready - superwarping to Cape Teriggan.')
                windower.send_command(SUPERWARP_OUT)
            end
        end
    end)
end

enter_state.WAIT_WARP_OUT = function()
    watchdog('WAIT_WARP_OUT', TIMEOUTS.WAIT_PARTY, 'party never assembled for the outbound warp.')
end

-- 3. Teriggan -> Cloister -> protocrystal
enter_state.RUN_TERIGGAN = function()
    watchdog('RUN_TERIGGAN', TIMEOUTS.ZONE_LOAD, 'never zoned into the Cloister of Gales.')
    play_leg(LEG_T1, ZONE_TERIGGAN, function()
        log('Pushing through the zone line...')
        push_through_zone_line(LEG_T1, ZONE_TERIGGAN)
    end)
end

enter_state.RUN_CLOISTER = function()
    play_leg(LEG_C1, ZONE_CLOISTER, function()
        goto_state('WAIT_ENTRY_TURN')
        ipc_send('READY_CRYSTAL')
        if role == 'leader' then
            if leader_mark('READY_CRYSTAL', my_name) then
                goto_state('ENTER_BC')
            end
        end
    end)
end

-- 4. Battlefield entry: leader first, then staggered followers
enter_state.WAIT_ENTRY_TURN = function()
    watchdog('WAIT_ENTRY_TURN', TIMEOUTS.WAIT_ENTRY, 'never got the signal/turn to enter the battlefield.')
end

-- Leader only: fires the Silmaril mirror that enters the battlefield for
-- the entire party. Everyone (leader included) then just waits for their
-- own position jump, detected in the tick loop.
enter_state.ENTER_BC = function()
    windower.send_command(REFLECT_CMD)
    log('Reflect fired - waiting for the battlefield to take everyone.')
    watchdog('ENTER_BC', TIMEOUTS.ENTER_BC, 'battlefield entry never happened (reflect failed?).')
end

-- 5. Inside: run to buff spot, report, leader starts the fight at 6/6
enter_state.RUN_BUFF = function()
    press_escape()
    play_leg(LEG_B1, ZONE_CLOISTER, function()
        goto_state('WAIT_FIGHT')
        ipc_send('IN_BC')
        if role == 'leader' then
            if leader_mark('IN_BC', my_name) then
                ipc_send('FIGHT')
                goto_state('FIGHT')
                windower.send_command(FIGHT_ON_CMD)
                log('All six inside - fight program engaged for the party.')
            end
        end
    end)
end

enter_state.WAIT_FIGHT = function()
    watchdog('WAIT_FIGHT', TIMEOUTS.WAIT_PARTY, 'party never fully assembled inside the battlefield.')
end

enter_state.FIGHT = function()
    -- Ejection detected positionally in the tick loop.
end

-- 6. Ejected: report; when all are out, run home
enter_state.WAIT_ALL_OUT = function()
    watchdog('WAIT_ALL_OUT', TIMEOUTS.WAIT_PARTY, 'not everyone made it out of the battlefield.')
end

enter_state.RUN_HOME_CLOISTER = function()
    play_leg(LEG_C1_HOME, ZONE_CLOISTER, function()
        log('Pushing through the Cloister exit...')
        push_through_zone_line(LEG_C1_HOME, ZONE_CLOISTER)
    end)
    watchdog('RUN_HOME_CLOISTER', TIMEOUTS.ZONE_LOAD, 'never zoned back into Cape Teriggan.')
end

enter_state.RUN_HOME_TERIGGAN = function()
    play_leg(LEG_T1_HOME, ZONE_TERIGGAN, function()
        goto_state('WAIT_WARP_HOME')
        ipc_send('READY_HOME')
        if role == 'leader' then
            if leader_mark('READY_HOME', my_name) then
                log('Party at the Teriggan HP - superwarping home.')
                windower.send_command(SUPERWARP_HOME)
            end
        end
    end)
end

enter_state.WAIT_WARP_HOME = function()
    watchdog('WAIT_WARP_HOME', TIMEOUTS.WAIT_PARTY, 'party never assembled for the warp home.')
end

-- 7. Home: report; leader kicks off the next cycle at 6/6
enter_state.CYCLE_DONE = function()
    loop.cycles = loop.cycles + 1
    log(('Cycle %d complete.'):format(loop.cycles))
    refresh_hud()
    ipc_send('READY_CYCLE')
    if role == 'leader' then
        if leader_mark('READY_CYCLE', my_name) then
            coroutine.schedule(function()
                if not loop.active then return end
                leader_reset_all()
                ipc_send('NEXT')
                goto_state('BUY_KI')
            end, CYCLE_GAP)
        end
    end
end

function leader_reset_all()
    roster.counts = {}
    roster.current_phase = nil
end

----------------------------------------------------------------------
-- TICK LOOP ----------------------------------------------------------
----------------------------------------------------------------------

local function tick()
    if not loop.active then return end

    if is_dead() then
        halt(my_name .. ' died - halting the whole party.')
        return
    end

    local m = me()
    if m and current_zone() == ZONE_CLOISTER then
        if (loop.state == 'ENTER_BC' or loop.state == 'WAIT_ENTRY_TURN') and m.x > BC_X_THRESHOLD then
            pending_menu.kind = nil
            goto_state('RUN_BUFF')
        elseif loop.state == 'FIGHT' and m.x < BC_X_THRESHOLD then
            log('Battlefield ejection detected.')
            goto_state('WAIT_ALL_OUT')
            ipc_send('OUT')
            if role == 'leader' then
                if leader_mark('OUT', my_name) then
                    coroutine.schedule(function()
                        if not loop.active then return end
                        ipc_send('GO_HOME')
                        goto_state('RUN_HOME_CLOISTER')
                    end, LOTTER_WAIT)
                end
            end
        end
    end

    if loop.state == 'FIGHT' and state_elapsed() >= TIMEOUTS.FIGHT then
        halt('fight exceeded max duration.')
        return
    end

    coroutine.schedule(tick, 0.5)
end

----------------------------------------------------------------------
-- IPC HANDLER --------------------------------------------------------
----------------------------------------------------------------------

windower.register_event('ipc message', function(msg)
    local sender, msg_type, extra = msg:match('^htbf (%S+) (%S+)%s*(.*)$')
    if not sender then return end

    -- STOP is honored even when idle-ish, everything else needs a live loop
    if msg_type == 'STOP' then
        if loop.active then
            halt(('stopped via party broadcast from %s: %s'):format(sender, extra or ''), true)
        end
        return
    end

    if msg_type == 'START' then
        if not loop.active then
            loop.active = true
            loop.cycles = 0
            loop.kis_bought = 0
            loop.started_at = os.clock()
            log(('Party start received from %s.'):format(sender))
            goto_state('BUY_KI')
            tick()
        end
        return
    end

    if not loop.active then return end

    -- Follower-side broadcasts from the leader
    if msg_type == 'FIGHT' then
        if role == 'follower' and loop.state == 'WAIT_FIGHT' then
            goto_state('FIGHT')
        end
    elseif msg_type == 'GO_HOME' then
        if role == 'follower' and loop.state == 'WAIT_ALL_OUT' then
            goto_state('RUN_HOME_CLOISTER')
        end
    elseif msg_type == 'NEXT' then
        if role == 'follower' and loop.state == 'CYCLE_DONE' then
            goto_state('BUY_KI')
        end

    -- Leader-side reports from followers
    elseif role == 'leader' then
        if msg_type == 'READY_KINPC' then
            if leader_mark('READY_KINPC', sender) and loop.state == 'WAIT_KI' then
                log('Party at Trisvain - reflecting the KI purchase.')
                windower.send_command(REFLECT_KI_CMD)
            end
        elseif msg_type == 'READY_HP' then
            if leader_mark('READY_HP', sender) and loop.state == 'WAIT_WARP_OUT' then
                log('Party ready - superwarping to Cape Teriggan.')
                windower.send_command(SUPERWARP_OUT)
            end
        elseif msg_type == 'READY_CRYSTAL' then
            if leader_mark('READY_CRYSTAL', sender) and loop.state == 'WAIT_ENTRY_TURN' then
                goto_state('ENTER_BC')
            end
        elseif msg_type == 'IN_BC' then
            if leader_mark('IN_BC', sender) and loop.state == 'WAIT_FIGHT' then
                ipc_send('FIGHT')
                goto_state('FIGHT')
                windower.send_command(FIGHT_ON_CMD)
                log('All six inside - fight program engaged for the party.')
            end
        elseif msg_type == 'OUT' then
            if leader_mark('OUT', sender) and loop.state == 'WAIT_ALL_OUT' then
                coroutine.schedule(function()
                    if not loop.active then return end
                    ipc_send('GO_HOME')
                    goto_state('RUN_HOME_CLOISTER')
                end, LOTTER_WAIT)
            end
        elseif msg_type == 'READY_HOME' then
            if leader_mark('READY_HOME', sender) and loop.state == 'WAIT_WARP_HOME' then
                log('Party at the Teriggan HP - superwarping home.')
                windower.send_command(SUPERWARP_HOME)
            end
        elseif msg_type == 'READY_CYCLE' then
            if leader_mark('READY_CYCLE', sender) and loop.state == 'CYCLE_DONE' then
                coroutine.schedule(function()
                    if not loop.active then return end
                    leader_reset_all()
                    ipc_send('NEXT')
                    goto_state('BUY_KI')
                end, CYCLE_GAP)
            end
        end
    end
end)

----------------------------------------------------------------------
-- ZONE CHANGE TRANSITIONS --------------------------------------------
----------------------------------------------------------------------

windower.register_event('zone change', function(new_zone)
    if not loop.active then return end
    windower.ffxi.run(false)

    if loop.state == 'WAIT_WARP_OUT' and new_zone == ZONE_TERIGGAN then
        coroutine.schedule(function()
            if loop.active and loop.state == 'WAIT_WARP_OUT' then
                goto_state('RUN_TERIGGAN')
            end
        end, 3)
    elseif loop.state == 'RUN_TERIGGAN' and new_zone == ZONE_CLOISTER then
        coroutine.schedule(function()
            if loop.active and loop.state == 'RUN_TERIGGAN' then
                goto_state('RUN_CLOISTER')
            end
        end, 3)
    elseif loop.state == 'RUN_HOME_CLOISTER' and new_zone == ZONE_TERIGGAN then
        coroutine.schedule(function()
            if loop.active and loop.state == 'RUN_HOME_CLOISTER' then
                goto_state('RUN_HOME_TERIGGAN')
            end
        end, 3)
    elseif loop.state == 'WAIT_WARP_HOME' and new_zone == ZONE_SANDY then
        coroutine.schedule(function()
            if loop.active and loop.state == 'WAIT_WARP_HOME' then
                goto_state('CYCLE_DONE')
            end
        end, 2)
    else
        halt(('unexpected zone change to %d during state %s.'):format(new_zone, loop.state))
    end
end)

-- NOTE: as of v0.7.0 both the KI purchase and the battlefield entry are
-- handled by Silmaril reflects (//sm reflect Avatar / Garuda), so no
-- incoming-menu packet handling is needed - the addon just fires the
-- command and watches key items / position.

----------------------------------------------------------------------
-- COMMANDS -----------------------------------------------------------
----------------------------------------------------------------------

windower.register_event('addon command', function(cmd)
    cmd = (cmd or 'status'):lower()
    if cmd == 'start' then
        if loop.active then
            log('Already running. //htb stop first.')
            return
        end
        if role ~= 'leader' then
            log(('This character is a follower - run //htb start on %s.'):format(LEADER_NAME))
            return
        end
        if not ki_id then
            log(('Cannot start: key item "%s" not found in resources.'):format(KI_NAME))
            return
        end
        if current_zone() ~= ZONE_SANDY then
            log('Start the loop in Northern San d\'Oria (near the home point).')
            return
        end
        local members = party_names()
        if #members < 2 then
            log('WARNING: party appears to have fewer than 2 members - starting anyway with count ' .. #members .. '.')
        end
        roster.expected = #members
        leader_reset_all()
        loop.active = true
        loop.cycles = 0
        loop.kis_bought = 0
        loop.started_at = os.clock()
        log(('HTBFarm party mode: leading %d characters. //htb stop halts everyone.'):format(roster.expected))
        ipc_send('START')
        goto_state('BUY_KI')
        tick()
    elseif cmd == 'stop' then
        if loop.active then
            halt('stopped by user.')
        else
            ipc_send('STOP', 'stopped by user (idle client)')
            log('Stop broadcast sent to the party.')
        end
    elseif cmd == 'unstick' then
        send_menu_exit()
    elseif cmd == 'status' then
        log(('Role: %s | State: %s | cycles: %d | KIs bought: %d')
            :format(role, loop.active and loop.state or 'stopped', loop.cycles, loop.kis_bought))
    elseif cmd == 'hud' then
        hud_visible = not hud_visible
        refresh_hud()
    else
        log('Commands: //htb start | stop | unstick | status | hud')
    end
end)

----------------------------------------------------------------------
-- LOAD ---------------------------------------------------------------
----------------------------------------------------------------------

windower.register_event('load', 'login', function()
    local player = windower.ffxi.get_player()
    my_name = player and player.name or '?'
    role = (my_name == LEADER_NAME) and 'leader' or 'follower'

    ki_id = resolve_ki()
    if not ki_id then
        log(('WARNING: key item "%s" not found in resources - check KI_NAME.'):format(KI_NAME))
    end
    log(('Loaded as %s (%s). %s'):format(my_name, role,
        role == 'leader' and '//htb start here to launch the party.' or ('Waiting for start from %s.'):format(LEADER_NAME)))
    refresh_hud()
end)
