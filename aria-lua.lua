--[[
    Aria LUA.

    This script adds some additional settings and modes for Aria of Sorrow to introduce some new
    novel gameplay.
]]

--[[
###     Variables and Memory Addresses     ###
]]
SETTING_REPRISE_ENABLED = false -- todo: add menu button to enable / disable Reprise stuff.
SETTING_DEBUG = false

MODE_CHAOS = false
MODE_NES_MOVEMENT = false
MODE_HIGH_GRAV = false
MODE_LOW_GRAV = false
MODE_MP_REFUND = false
MODE_RANDOM_COMMANDS = false
MODE_BIGTOSS = false
MODE_SPRINT = false
MODE_ROOMCHANGE_HEAL = false
MODE_ROOM_MODIFIER = 0     -- set to number of the room modifier if being used
local FORM_NES_BUTTON
local FORM_CHAOS_BUTTON
local FORM_HIGH_GRAV_BUTTON
local FORM_LOW_GRAV_BUTTON

local active_commands = {}  -- function pointers to commands
local active_command_names = {}  -- command names (string)

local ACTIVE_COMMAND_DELAY = 60*120 -- 2 mins until an active commands goes away (shortened if more commands come in)
local active_command_timer = ACTIVE_COMMAND_DELAY
local MIN_TIMER_INCOMING_ACTION = 60*40   -- if a new command is incoming, should only last for 40 seconds.
local COMMAND_QUEUE_DELAY = 60*1 -- 1 seconds before an incoming command will be executed
local command_queue_timer = COMMAND_QUEUE_DELAY

local InputAddr = 0x001C
local Input     -- contains bitflags for all inputs
local InputJump = 0x1
local InputAttack = 0x2
local InputLeft = 0x20
local InputRight = 0x10
local Jumped
local Player_Attacking_Addr = 0x4EE  -- this is 1 when player is using weapon, 2 if player used red soul. otherwise 0
local Player_Attacking
local Player_Current_Weapon_Addr = 0x013268
local Player_Current_Soul_Addr = 0x013269
local Owned_Weapons_Addr = 0x132B4  -- starting address for owned weapons (1 byte each for qty, starts with knife)
local Player_Y_Velocity_Addr = 0x0530
local Player_X_Velocity_Addr = 0x0530-0x4
local Player_Y_Gravity_Addr = 0x0538
local Player_Dir_Addr = 0x04E4+0x58
local Prev_Player_X_Velocity
local Player_X_Velocity
local Player_Y_Velocity
local Player_Y_Gravity
local Prev_Left = False
local Prev_Right = False
local Slingshot = False -- jump while backdashing to keep momentum

local MenuStateAddr = 0x0064
local MenuState_InGame = 0x1

local Player_Passive_Effect_Addr = 0x013260
local Effect_Flying_Armor = 0x100

local Player_HP_Addr = 0x01327A -- stats are 2 bytes (signed 16bit)
local Player_HPMax_Addr = 0x1327E
local Player_MP_Addr = 0x01327C
local Player_MPMax_Addr = 0x013280
local Player_XP_Addr = 0x01328C --4 bytes
local Player_Gold_Addr = 0x013290 --4 bytes
local Player_Animation_Addr = 0x0551
local Player_Animation_Frame_Addr = 0x0552

local DoubleJumpsAddr = 0x04F4
local Prev_DoubleJumps = 0

-- reprise addresses
local Reprise_RoomModifier_Addr = 0x3F030   -- 1 byte

--[[
###     Command functions     ###
]]
function using_flying_armor()
    local Player_Effect = memory.read_u32_le(Player_Passive_Effect_Addr)
    return Player_Effect & Effect_Flying_Armor ~= 0
end
function hold_atk_to_run()
    Player_Y_Velocity = memory.read_s32_le(Player_Y_Velocity_Addr)
    Player_X_Velocity = memory.read_s32_le(Player_X_Velocity_Addr)
    Player_Attacking = memory.readbyte(Player_Attacking_Addr) ~= 0
    Input = memory.readbyte(InputAddr)
    local Attack_Pressed = Input & InputAttack ~=0
    local Left_Pressed = Input & InputLeft ~= 0
    local Right_Pressed = Input & InputRight ~= 0
    if Player_Y_Velocity == 0 and Attack_Pressed and Player_X_Velocity ~= 0 and not Player_Attacking and (Left_Pressed or Right_Pressed) then
        -- only increase if player isn't already going too fast
        if math.abs(Player_X_Velocity) < 0x20000 then
            Player_X_Velocity = Player_X_Velocity * 1.4
            memory.write_s32_le(Player_X_Velocity_Addr, Player_X_Velocity)

            -- advance frame to show Soma running faster
            local Frame = memory.readbyte(Player_Animation_Frame_Addr)
            if Frame % 3 == 0 then
                Frame = Frame + 1
                memory.writebyte(Player_Animation_Frame_Addr, Frame)
            end
        end
    end
end

function airborn_lock()
    -- can't change directions after jump, except by doublejumping or with flying armor active.
    Player_Y_Velocity = memory.read_s32_le(Player_Y_Velocity_Addr)
    Player_X_Velocity = memory.read_s32_le(Player_X_Velocity_Addr)
    Player_Y_Gravity = memory.read_s32_le(Player_Y_Gravity_Addr)
    DoubleJumps = memory.readbyte(DoubleJumpsAddr)
    Input = memory.readbyte(InputAddr)
    local Jumped = Input & InputJump ~= 0
    local Left_Pressed = Input & InputLeft ~= 0
    local Right_Pressed = Input & InputRight ~= 0

    -- change direction with doublejump
    if Prev_Left == nil then
        Prev_Left = Left_Pressed
        Prev_Right = Right_Pressed
    end
    if Prev_DoubleJumps and Prev_DoubleJumps == 2 and DoubleJumps == 6 then
        Prev_Left = nil
        Prev_Right = nil
        Slingshot = False
    end

    local Flying_Armor = using_flying_armor()
    if Player_Y_Velocity ~= 0 and not Flying_Armor then
        local new_input = {}
        new_input['Left']=Prev_Left
        new_input['Right']=Prev_Right
        if Player_Y_Velocity < 0 then
            -- always full jump
            -- need to be falling to input double jump
            -- makes you keep jumping in water
            -- new_input['A'] = true
        end
        if Prev_Player_X_Velocity == nil then
            if Jumped then
                Prev_Player_X_Velocity = Player_X_Velocity
            else
                Prev_Player_X_Velocity = 0
            end

            if Prev_Player_X_Velocity ~=0 and Slingshot then
                -- keep momentum you had when jumping out of backdash
                -- limit speed, full backdash speed is a bit crazy
                local negative = (Prev_Player_X_Velocity < 0)
                Prev_Player_X_Velocity = math.min(math.abs(Prev_Player_X_Velocity), 0x24000)
                if negative then
                    Prev_Player_X_Velocity = Prev_Player_X_Velocity * -1
                end
            end

            Prev_Left = Left_Pressed
            Prev_Right = Right_Pressed
        end
        if Slingshot and (Prev_Left or Prev_Right) then
            memory.write_s32_le(Player_X_Velocity_Addr, Prev_Player_X_Velocity)
        end
        joypad.set(new_input)
    else
        Prev_Player_X_Velocity = nil
        Prev_Left = nil
        Prev_Right = nil

        -- enable slingshot next time you jump if you are backdashing, and pointing the opposite direction
        local Player_Left = memory.readbyte(Player_Dir_Addr) & 0x40 == 0x40
        local Opposite_Dir = (Left_Pressed and not Player_Left or Right_Pressed and Player_Left)
        local Player_Animation = memory.readbyte(Player_Animation_Addr)
        Slingshot = (Player_Animation == 0x15) and Opposite_Dir
    end
    Prev_DoubleJumps = DoubleJumps
end

function high_gravity()
    Player_Y_Velocity = memory.read_s32_le(Player_Y_Velocity_Addr)
    if Player_Y_Velocity > -0x10000 and Player_Y_Velocity ~= 0 and not using_flying_armor() and Player_Y_Velocity < 0x40000 then
        Player_Y_Velocity = Player_Y_Velocity + 0x6000
        memory.write_s32_le(Player_Y_Velocity_Addr, Player_Y_Velocity)
    end
end
function low_gravity()
    Player_Y_Velocity = memory.read_s32_le(Player_Y_Velocity_Addr)
    -- Can't set player Y velocity to -0x3000 until player already has some speed, otherwise player will float.
    if Player_Y_Velocity > -0x40000 and  Player_Y_Velocity <= 0x10000 then
        Player_Y_Velocity = Player_Y_Velocity - 0x2000
    end
    if Player_Y_Velocity > 0x10000 then
        Player_Y_Velocity = Player_Y_Velocity - 0x3000
        memory.write_s32_le(Player_Y_Velocity_Addr, Player_Y_Velocity)
    end
end

function nes_movement()
    airborn_lock()
end
function sprint_movement()
    hold_atk_to_run()
end

function set_player_hp(amount)
    local Player_HP = memory.read_s16_le(Player_HP_Addr)
    Player_HP = amount
    memory.write_s16_le(Player_HP_Addr, Player_HP)
end
function add_player_hp(amount)
    local Player_HP = memory.read_s16_le(Player_HP_Addr)
    Player_HP = Player_HP + amount
    local Player_HPMax = memory.read_s16_le(Player_HPMax_Addr)
    Player_HP = math.min(Player_HP, Player_HPMax)
    memory.write_s16_le(Player_HP_Addr, Player_HP)
end
function set_player_mp(amount)
    local Player_MP = memory.read_s16_le(Player_MP_Addr)
    Player_MP = amount
    memory.write_s16_le(Player_MP_Addr, Player_MP)
end
function add_player_mp(amount)
    local Player_MP = memory.read_s16_le(Player_MP_Addr)
    Player_MP = Player_MP + amount
    local Player_MPMax = memory.read_s16_le(Player_MPMax_Addr)
    Player_MP = math.min(Player_MP, Player_MPMax)
    memory.write_s16_le(Player_MP_Addr, Player_MP)
end
function set_player_gold(amount)
    local Player_Gold = memory.read_s32_le(Player_Gold_Addr)
    Player_Gold = amount
    memory.write_s32_le(Player_Gold_Addr, Player_Gold)
end
function add_player_gold(amount)
    local Player_Gold = memory.read_s32_le(Player_Gold_Addr)
    Player_Gold = Player_Gold + amount
    memory.write_s32_le(Player_Gold_Addr, Player_Gold)
end
function increase_hp_5()
    add_player_hp(5)
end
function increase_hp_on_room_change()
    MODE_ROOMCHANGE_HEAL = true
end

local prev_weapon = nil
local prev_soul = nil
function chaos_mode()
    prev_weapon = memory.readbyte(Player_Current_Weapon_Addr)
    prev_soul = memory.readbyte(Player_Current_Soul_Addr)
end
function disable_chaos_mode()
    if prev_weapon ~= nil then
        memory.writebyte(Player_Current_Weapon_Addr, prev_weapon)
        memory.writebyte(Player_Current_Soul_Addr, prev_soul)
    end
    prev_weapon = nil
    prev_soul = nil
end

dropped_weapons = {}
function set_drop_weapon(enable)
    if enable then
         -- unequip
        local Player_Current_Weapon = memory.readbyte(Player_Current_Weapon_Addr)
        table.insert(dropped_weapons, Player_Current_Weapon)
        memory.writebyte(Player_Current_Weapon_Addr, 0xFF) -- No weapon
        -- take away qty 1 from the current weapon
        local Dropped_Weapon_Addr = Owned_Weapons_Addr+Player_Current_Weapon
        local Dropped_Weapon_Qty = memory.readbyte(Dropped_Weapon_Addr)
        Dropped_Weapon_Qty = Dropped_Weapon_Qty-1
        memory.writebyte(Dropped_Weapon_Addr, Dropped_Weapon_Qty)
    else
        local weapon_id = table.remove(dropped_weapons, 1)
        -- add qty 1 for picked up weapon (don't auto equip)
        local Pickup_Weapon_Addr = Owned_Weapons_Addr+weapon_id
        local pickup_weapon_qty = memory.readbyte(Pickup_Weapon_Addr)
        pickup_weapon_qty = pickup_weapon_qty+1
        memory.writebyte(Pickup_Weapon_Addr, pickup_weapon_qty)
    end
end
function swap_NES_mode()
    set_NES_mode(not MODE_NES_MOVEMENT)
end
function set_NES_mode(enabled)
    MODE_NES_MOVEMENT = enabled
    local new_text = 'NES Movement Disabled'
    if MODE_NES_MOVEMENT then
        new_text = 'NES Movement Enabled'
    end
    forms.settext(FORM_NES_BUTTON, new_text)
end

function swap_CHAOS_mode()
    set_CHAOS_mode(not MODE_CHAOS)
end
function set_CHAOS_mode(enabled)
    MODE_CHAOS = enabled
    local new_text = 'CHAOS Mode Disabled'
    if MODE_CHAOS then
        new_text = 'CHAOS Mode Enabled'
        chaos_mode()
    else
        disable_chaos_mode()
    end
    forms.settext(FORM_CHAOS_BUTTON, new_text)
end

function swap_HIGH_GRAV_mode()
    set_HIGH_GRAV_mode(not MODE_HIGH_GRAV)
end
function set_HIGH_GRAV_mode(enabled)
    MODE_HIGH_GRAV = enabled

    local new_text = 'HIGH GRAV Mode Disabled'
    if MODE_HIGH_GRAV then
        new_text = 'HIGH GRAV Mode Enabled'
    end
    forms.settext(FORM_HIGH_GRAV_BUTTON, new_text)
end

function swap_LOW_GRAV_mode()
    set_LOW_GRAV_mode(not MODE_LOW_GRAV)
end
function set_LOW_GRAV_mode(enabled)
    MODE_LOW_GRAV = enabled
    local new_text = 'LOW GRAV Mode Disabled'
    if MODE_LOW_GRAV then
        new_text = 'LOW GRAV Mode Enabled'
    end
    forms.settext(FORM_LOW_GRAV_BUTTON, new_text)
end
function swap_RANDOM_COMMANDS_mode()
    MODE_RANDOM_COMMANDS = not MODE_RANDOM_COMMANDS
    local new_text = 'RANDOM CMDS Disabled'
    if MODE_RANDOM_COMMANDS then
        new_text = 'RANDOM CMDS Enabled'
    end
    forms.settext(FORM_RANDOM_COMMANDS_BUTTON, new_text)
end
function swap_SPRINT_mode()
    set_SPRINT_mode(not MODE_SPRINT)
end
function set_SPRINT_mode(enabled)
    MODE_SPRINT = not MODE_SPRINT
    local new_text = 'SPRINT Mode Disabled'
    if MODE_SPRINT then
        new_text = 'SPRINT Mode Enabled'
    end
    forms.settext(FORM_SPRINT_BUTTON, new_text)
end

function set_100HP(enabled)
    if enabled then
        set_player_hp(100)
        active_command_timer = 60*10 -- Instant effect, move on to next command quicker
    end
    -- do nothing when command expires
end
function set_full_heal(enabled)
    if enabled then
        add_player_hp(9999)
        active_command_timer = 60*10 -- Instant effect, move on to next command quicker
    end
    -- do nothing when command expries
end
function set_0MP(enabled)
    if enabled then
        set_player_mp(0)
        active_command_timer = 60*10 -- Instant effect, move on to next command quicker
    end
    -- do nothing when command expires
end
function set_add_50MP(enabled)
    if enabled then
        add_player_mp(50)
        active_command_timer = 60*10 -- Instant effect, move on to next command quicker
    end
    -- do nothing when command expires
end
function set_add_5k_gold(enabled)
    if enabled then
        add_player_gold(5000)
        active_command_timer = 60*10 -- Instant effect, move on to next command quicker
    end
    -- do nothing when command expires
end
function set_add_50HP(enabled)
    if enabled then
        add_player_hp(50)
        active_command_timer = 60*10 -- Instant effect, move on to next command quicker
    end
    -- do nothing when command expires
end
function apply_bigtoss()
    local Player_KB_Type_Addr = 0x0131d4
    local KB_Custom = 3
    -- save KB to Hitbox's KB type.
    -- hitbox is in R7, KB type is at [r7, 0x6], 2 bytes
    local hitbox_addr = emu.getregister('R7')
    local hitbox_KB_type_addr = hitbox_addr + 0x6
    memory.write_u16_le(hitbox_KB_type_addr, KB_Custom,  'System Bus')

    local KB_Horizontal_Addr = 0x0131e0
    local KB_Horizontal = 0x60000
    -- base horizontal on Player's Direction (0 is right)
    local Player_Dir = memory.readbyte(Player_Dir_Addr)
    if Player_Dir == 0 then 
        KB_Horizontal = -0x60000
    end

    local KB_Vertical_Addr = 0x0131e4
    local KB_Vertical = -0x60000
    memory.write_s32_le(KB_Horizontal_Addr, KB_Horizontal)
    memory.write_s32_le(KB_Vertical_Addr, KB_Vertical)
end
function set_bigtoss(enabled)
    MODE_BIGTOSS = enabled
end

--[[
###     Reprise functions      ###
]]
function apply_room_modifier(modifier_id)
    -- Actually modifies / replaces room modifier
    memory.writebyte(Reprise_RoomModifier_Addr, modifier_id)
end
function set_spectral_crow(enabled)
    if enabled then
        MODE_ROOM_MODIFIER = 0xC
    else
        MODE_ROOM_MODIFIER = 0
    end
end


--[[
###     Hooks      ###
]]
function on_damage_hook()
    if MODE_BIGTOSS then
        apply_bigtoss()
    end
end

function on_loadroom_hook()
    if MODE_ROOMCHANGE_HEAL then
        increase_hp_5()
    end
end

function on_checkdrops_hook()
    if MODE_CHAOS then
        local Player_Current_Weapon = math.floor(math.random(58))
        memory.writebyte(Player_Current_Weapon_Addr, Player_Current_Weapon)
    end
end

function on_use_redsoul_hook()
    -- todo: change hook, so ID changed before MP cost is calculated?
        -- or look into this more
    if MODE_CHAOS then
        local RandSoul = math.floor(math.random(36))+1
        emu.setregister('R1', RandSoul)
        memory.writebyte(Player_Current_Soul_Addr, RandSoul)
    end
end

function on_redsoul_mp_hook()
    -- called right before subracting MP (using r1)
    if MODE_MP_REFUND then
        emu.setregister('R1', 0)
    end
end

function on_loadentities_hook()
    -- called before loading room entities
    if MODE_ROOM_MODIFIER ~= 0 then
        apply_room_modifier(MODE_ROOM_MODIFIER)
    end
end



--[[
###     Init / Setup functions     ###
]]
function setup_hooks()
    local player_DMG_Addr = 0x0802172a
    local LoadRoom_Addr = 0x0800f9ec
    local LoadEntities_Addr = 0x0800f678
    local Enemy_CheckDrops = 0x080683bc
    local UseRedSoul = 0x08019478
    local RedSoulMPCost = 0x08019570 -- loads MP cost into r1 before subtracting

    event.onmemoryexecute(on_damage_hook, player_DMG_Addr, 'OnPlayerDamage')
    event.onmemoryexecute(on_loadroom_hook, LoadRoom_Addr, 'OnLoadRoom')
    event.onmemoryexecute(on_checkdrops_hook, Enemy_CheckDrops, 'OnCheckDrops')
    event.onmemoryexecute(on_use_redsoul_hook, UseRedSoul, 'OnUseRedSoul')
    event.onmemoryexecute(on_redsoul_mp_hook, RedSoulMPCost, 'OnRedSoulMPCost')
    event.onmemoryexecute(on_loadentities_hook, LoadEntities_Addr, 'OnLoadEntities')
end

function clear_hooks()
    -- todo: this might not be needed
end

function init_command_list()
    -- set fn to a function that can take true or false to active/deactivate
    command_list = {
        ['!nes_mode']= {
            fn = set_NES_mode,
            name = '!nes_mode'
        },
        ['!chaos_mode']= {
            fn = set_CHAOS_mode,
            name = '!chaos_mode'
        },
        ['!high_grav']= {
            fn = set_HIGH_GRAV_mode,
            name = '!high_grav'
        },
        ['!low_grav']= {
            fn = set_LOW_GRAV_mode,
            name = '!low_grav'
        },
        ['!drop_weapon']= {
            fn = set_drop_weapon,
            name = '!drop_weapon'
        },
        ['!mp_refund']= {
            fn = set_MP_REFUND,
            name = '!mp_refund'
        },
        ['!100_hp']= {
            fn = set_100HP,
            name = '!100_hp'
        },
        ['!full_heal']= {
            fn = set_full_heal,
            name = '!full_heal'
        },
        ['!0_mp']= {
            fn = set_0MP,
            name = '!0_mp'
        },
        ['!heart']= {
            fn = set_add_50MP,
            name = '!heart'
        },
        ['!give_gold']= {
            fn = set_add_5k_gold,
            name = '!give_gold'
        },
        ['!steak']= {
            fn = set_add_50HP,
            name = '!steak'
        },
        ['!bigtoss']= {
            fn = set_bigtoss,
            name = '!bigtoss'
        },
        ['!sprint_mode']= {
            fn = set_SPRINT_mode,
            name = '!sprint_mode'
        },
    }
    if SETTING_REPRISE_ENABLED then
        command_list['!spectral_crow']= {
            fn = set_spectral_crow,
            name = '!spectral_crow',
            reprise = true
        }
    end

    local dropdown_list = {'-Command-'}
    for k, v in pairs(command_list) do
        table.insert(dropdown_list, k)
    end
    forms.setdropdownitems(FORM_CMD_DROPDOWN, dropdown_list)
end

--[[
###     GUI functions and commands     ###
]]
function update_gui()
    local hud_commands = ''
    if #active_commands > 0 then
        -- substring, get command name, skip over (ACTIVE) 
        local active_cmd_name = active_command_names[1]
        hud_commands = string.sub(active_cmd_name,9, #active_cmd_name)

        local seconds = math.floor(active_command_timer/60)
        forms.settext(FORM_ACTIVE_TIMER_LABEL, 'Cmd Time Left: '..seconds)
    end
    if #aos_command_queue > 0 then
        local incoming_cmd_name = aos_command_queue[1]
        hud_commands = hud_commands .. ' << ' .. incoming_cmd_name
    end

    local content = '-- No commands in queue --'
    if #active_command_names + #aos_command_queue ~= 0 then
        local content_active = table.concat(active_command_names, '\n')
        local content_inactive = table.concat(aos_command_queue, '\n')
        content = content_active .. '\n-- Incoming Commands --\n' .. content_inactive
    end
    gui.clearGraphics()
    if #hud_commands>0 then
        gui.pixelText(30,0, hud_commands)
    end
    forms.settext(FORM_QUEUE_CONTENT, content)
end

function give_abilities()
    -- used for testing
    memory.writebyte(0x013354, 0x11) -- Giant Bat, Flying Armor
    memory.writebyte(0x01336E, 0x11) -- Skula, Undine
    memory.write_u32_le(0x013392, 0xFFFFFFFF) -- ability souls
end

function clear_queue()
    aos_command_queue = {}
    for _, cmd in pairs(active_commands) do
        cmd.fn(false)
    end
    active_commands = {}
    active_command_names = {}
end
function add_command()
    local command = forms.gettext(FORM_CMD_DROPDOWN)
    table.insert(aos_command_queue, command)
end
function add_random_command()
    local command_list_len = 0
    for name, command in pairs(command_list) do
        command_list_len = command_list_len + 1
    end

    local random_index = math.random(1, command_list_len)
    local i=0
    local next_command_name
    for name, command in pairs(command_list) do
        i = i + 1
        if i == random_index then
            console.log('Next Random Cmd: '..name)
            next_command_name = name
            break
        end
    end
    table.insert(aos_command_queue, next_command_name)
    command_queue_timer = COMMAND_QUEUE_DELAY
end
function shorten_command()
    if #active_commands > 0 then
        active_command_timer = 60
        return
    end
    command_queue_timer = 60
end
function change_cmd_timer()
    local new_time = forms.gettext(FORM_CMD_LENGTH_TIME)
    ACTIVE_COMMAND_DELAY = new_time
end

function close_xanthus_form()
    forms.destroy(XANTHUS_FORM)
end
function init_gui()
    XANTHUS_FORM = forms.newform(400,400, 'AriaLUA')
    FORM_NES_BUTTON = forms.button(XANTHUS_FORM, 'NES Movement Disabled', swap_NES_mode, 10, 10, 200, 20)
    FORM_CHAOS_BUTTON = forms.button(XANTHUS_FORM, 'CHAOS Mode Disabled', swap_CHAOS_mode, 10, 40, 200, 20)
    FORM_HIGH_GRAV_BUTTON = forms.button(XANTHUS_FORM, 'HIGH GRAV Mode Disabled', swap_HIGH_GRAV_mode, 10, 70, 200, 20)
    FORM_LOW_GRAV_BUTTON = forms.button(XANTHUS_FORM, 'LOW GRAV Mode Disabled', swap_LOW_GRAV_mode, 10, 100, 200, 20)
    FORM_RANDOM_COMMANDS_BUTTON = forms.button(XANTHUS_FORM, 'RANDOM CMDS Disabled', swap_RANDOM_COMMANDS_mode, 210, 10, 150, 20)
    FORM_SPRINT_BUTTON = forms.button(XANTHUS_FORM, 'Sprint Movement Disabled', swap_SPRINT_mode, 210, 40, 150, 20)
    if SETTING_DEBUG then
        FORM_ABILITIES_BUTTON = forms.button(XANTHUS_FORM, '(Cheat) Give Abilities', give_abilities, 10, 130, 200, 20)
        FORM_SHORTEN_CMD = forms.button(XANTHUS_FORM, 'Shorten CMD', shorten_command, 210, 100, 150, 20)
    end
    FORM_QUEUE_HEADER = forms.label(XANTHUS_FORM, 'Command Queue', 10, 160, 200, 20)
    FORM_ACTIVE_TIMER_LABEL = forms.label(XANTHUS_FORM, 'Cmd Time Left: 0', 10, 180, 150, 20)
    FORM_QUEUE_CONTENT = forms.label(XANTHUS_FORM, '-- No Commands --', 10, 200, 200, 200)
    FORM_CLEAR_BUTTON = forms.button(XANTHUS_FORM, 'Clear Queue', clear_queue, 210, 160, 150, 20)
    FORM_CMD_LENGTH_LABEL = forms.label(XANTHUS_FORM, 'Cmd Len (s):', 210, 280, 100, 20)
    FORM_CMD_LENGTH_TIME = forms.textbox(XANTHUS_FORM, '120', 50, 20, 'UNSIGNED', 320, 280)
    FORM_CMD_LENGTH_BUTTON = forms.button(XANTHUS_FORM, 'Update Cmd Len', change_cmd_timer, 210, 310, 100, 20)
    FORM_CMD_ADD = forms.button(XANTHUS_FORM, 'Add', add_command, 210, 220, 50, 20)
    FORM_CMD_DROPDOWN = forms.dropdown(XANTHUS_FORM, {'-Command-'}, 270, 220, 100, 20)
    event.onexit(close_xanthus_form)
end

function execute_command_queue()
    if #active_commands> 0 then
        if active_command_timer > 0 then
            active_command_timer = active_command_timer - 1
            --- Reduce time to a minimum if there's another command in queue
            if #aos_command_queue>0 then
                active_command_timer = math.min(MIN_TIMER_INCOMING_ACTION, active_command_timer)
            end
        else
            local expire_command = table.remove(active_commands, 1)
            local expire_command_name = table.remove(active_command_names, 1)
            console.log(expire_command.name..' DEACTIVATED')
            expire_command.fn(false)  -- deactivates command
            active_command_timer = ACTIVE_COMMAND_DELAY
            if #aos_command_queue>0 then
                -- reduce time by 2 second for each additional command in the queue
                local adjust_timer = 60*#aos_command_queue*2
                active_command_timer = active_command_timer - adjust_timer

                -- last at least for 20 seconds (no matter how many are in queue)
                active_command_timer = math.max(60*20, active_command_timer)
            end
        end
    end

    -- aos_command_queue is altered by aos-twitch.lua
    if #aos_command_queue == 0 then
        if #active_commands == 0 and MODE_RANDOM_COMMANDS then
            add_random_command()
        end
        return
    end
    if command_queue_timer > 0 then
        command_queue_timer = command_queue_timer - 1
        return
    end
    -- only have one active command at a time
    if #active_commands == 1 then
        return
    end

    local command_name = table.remove(aos_command_queue, 1)
    local command = command_list[command_name]

    console.log(command.name..' ACTIVATED')
    command.fn(true)
    table.insert(active_commands, command)
    table.insert(active_command_names, '(ACTIVE) '..command.name)
    command_queue_timer = COMMAND_QUEUE_DELAY
end

--[[
###     INIT AND MAIN LOOP     ###
]]
math.randomseed(os.time())
math.random()
math.random()
math.random()
aos_command_queue = {}
init_gui()
init_command_list()
setup_hooks()

-- MAIN LOOP
memory.usememorydomain('EWRAM')
while true do
    update_gui()
    local InGame = memory.readbyte(MenuStateAddr) == MenuState_InGame
    if InGame then
        execute_command_queue()
        if MODE_NES_MOVEMENT then
            nes_movement()
        end
        if MODE_HIGH_GRAV then
            high_gravity()
        end
        if MODE_LOW_GRAV then
            low_gravity()
        end
        if MODE_SPRINT then
            sprint_movement()
        end
    end
    emu.frameadvance()
end
