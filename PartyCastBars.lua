local BAR_WIDTH        = 120
local BAR_HEIGHT       = 10
local BAR_X_OFFSET     = 10
local BAR_Y_OFFSET     = -19
local BAR_STRATA       = "HIGH"
local BAR_LEVEL        = 60
local ANCHOR_POINT     = "BOTTOM"
local ANCHOR_RELPOINT  = "TOP"

local MEDIA            = "Interface\\AddOns\\PartyCastBars\\textures\\"
local BAR_TEXTURE      = MEDIA .. "UI-StatusBar"
local CAST_COLOR       = CreateColor(1.0, 0.7, 0.0, 1)
local CHANNEL_COLOR    = CreateColor(0.0, 1.0, 0.0, 1)
local LOCKED_COLOR     = CreateColor(0.7, 0.7, 0.7, 1)
local BG_R, BG_G, BG_B, BG_A = 0.0, 0.0, 0.0, 0.5

local BORDER_TEXTURE   = MEDIA .. "UI-CastingBar-Border-Small"
local SHIELD_TEXTURE   = MEDIA .. "UI-CastingBar-Small-Shield"
local FRAME_SCALE      = BAR_WIDTH / 150
local FRAME_HEIGHT     = 1.18

local REF_BORDER_H     = 56
local REF_BORDER_X     = 23
local REF_SHIELD_H     = 56
local REF_SHIELD_L     = 28
local REF_SHIELD_R     = 18
local REF_SHIELD_W     = 196
local REF_BAY_CENTRE   = 15
local REF_ICON_SIZE    = 16

local FONT             = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local FONT_SIZE        = 9
local FONT_FLAGS       = "OUTLINE"
local TEXT_PADDING     = 2
local TEXT_Y_OFFSET    = 0.5

local ICON_SCALE       = 1.25
local ICON_NUDGE_X     = 0
local ICON_NUDGE_Y     = 0

local WATCHDOG_PERIOD  = 0.2

local UnitCastingInfo              = UnitCastingInfo
local UnitChannelInfo              = UnitChannelInfo
local UnitCastingDuration          = UnitCastingDuration
local UnitChannelDuration          = UnitChannelDuration
local UnitEmpoweredChannelDuration = UnitEmpoweredChannelDuration
local issecretvalue                = issecretvalue
local IsInRaid                     = IsInRaid
local GetNumGroupMembers           = GetNumGroupMembers
local UnitInRaid                   = UnitInRaid
local UnitIsUnit                   = UnitIsUnit
local CreateFrame                  = CreateFrame
local hooksecurefunc               = hooksecurefunc
local UIParent                     = UIParent
local After                        = C_Timer.After
local NewTicker                    = C_Timer.NewTicker

local IMMEDIATE = Enum.StatusBarInterpolation.Immediate
local ELAPSED   = Enum.StatusBarTimerDirection.ElapsedTime
local REMAINING = Enum.StatusBarTimerDirection.RemainingTime

local SMALL_GROUP_SIZE = MEMBERS_PER_RAID_GROUP or 5

local RAID_TOKENS = {}
for i = 1, SMALL_GROUP_SIZE do RAID_TOKENS[i] = "raid" .. i end

local selfUnit  = "player"
local selfDirty = true

local KIND_CAST    = 1
local KIND_CHANNEL = 2
local KIND_EMPOWER = 3

local ANCHOR_X = BAR_X_OFFSET

local BORDER_X  = REF_BORDER_X * FRAME_SCALE
local SHIELD_XL = REF_SHIELD_L * FRAME_SCALE
local SHIELD_XR = REF_SHIELD_R * FRAME_SCALE
local BORDER_H  = REF_BORDER_H * FRAME_SCALE * FRAME_HEIGHT
local SHIELD_H  = REF_SHIELD_H * FRAME_SCALE * FRAME_HEIGHT

local SHIELD_W    = BAR_WIDTH + SHIELD_XL + SHIELD_XR
local ICON_SIZE   = SHIELD_W * (REF_ICON_SIZE / REF_SHIELD_W) * ICON_SCALE
local ICON_CENTRE = SHIELD_W * (REF_BAY_CENTRE / REF_SHIELD_W) - SHIELD_XL
local ICON_X      = ICON_CENTRE + ICON_SIZE * 0.5 + ICON_NUDGE_X
local ICON_Y      = ICON_NUDGE_Y

local CAST_R, CAST_G, CAST_B, CAST_A = CAST_COLOR:GetRGBA()
local CHAN_R, CHAN_G, CHAN_B, CHAN_A = CHANNEL_COLOR:GetRGBA()
local LOCK_R, LOCK_G, LOCK_B, LOCK_A = LOCKED_COLOR:GetRGBA()

local bars        = {}
local bound       = {}
local boundCount  = 0

local active      = {}
local activeUnit  = {}
local activeKind  = {}
local activeCount = 0

local watchdog
local generation  = 0
local scanPending = false
local forceResync = false

local PCB = CreateFrame("StatusBar")
PCB:Hide()

local Frame_Show          = PCB.Show
local Frame_Hide          = PCB.Hide
local SetTimerDuration    = PCB.SetTimerDuration
local RegisterUnitEvent   = PCB.RegisterUnitEvent
local UnregisterAllEvents = PCB.UnregisterAllEvents

local SetAlpha, SetAlphaFromBoolean, SetVertexColor, SetVertexColorFromBoolean, SetTexture
do
    local tex = PCB:CreateTexture()
    SetAlpha                  = tex.SetAlpha
    SetAlphaFromBoolean       = tex.SetAlphaFromBoolean
    SetVertexColor            = tex.SetVertexColor
    SetVertexColorFromBoolean = tex.SetVertexColorFromBoolean
    SetTexture                = tex.SetTexture
end

local SetText = PCB:CreateFontString().SetText

local PCB_FONT = CreateFont("PartyCastBarsNameFont")
if GameFontHighlightSmall then PCB_FONT:SetFontObject(GameFontHighlightSmall) end
PCB_FONT:SetFont(FONT, FONT_SIZE, FONT_FLAGS)
PCB_FONT:SetShadowColor(0, 0, 0, 0.9)
PCB_FONT:SetShadowOffset(1, -1)
PCB_FONT:SetJustifyH("CENTER")
PCB_FONT:SetJustifyV("MIDDLE")

local partyMemberFrames    = {}
local numPartyMemberFrames = 0

local function SnapshotPartyPool(f)
    local pool = f and f.PartyMemberFramePool
    if not pool then return end
    local n = 0
    for frame in pool:EnumerateActive() do
        n = n + 1
        partyMemberFrames[n] = frame
    end
    numPartyMemberFrames = n
end

local Sweep, ScheduleScan

local function ShowBar(bar, kind, unit)
    local n = activeCount + 1
    activeCount = n

    active[n]     = bar
    activeUnit[n] = unit
    activeKind[n] = kind
    bar.slot      = n

    Frame_Show(bar)

    if not watchdog then
        watchdog = NewTicker(WATCHDOG_PERIOD, Sweep)
    end
end

local function HideBar(bar)
    local slot = bar.slot
    local n    = activeCount

    if slot ~= n then
        local a, au, ak = active, activeUnit, activeKind
        local last = a[n]
        a[slot]   = last
        au[slot]  = au[n]
        ak[slot]  = ak[n]
        last.slot = slot
    end
    activeCount = n - 1

    bar.slot = nil
    Frame_Hide(bar)

    if n == 1 then
        local w = watchdog
        if w then
            w:Cancel()
            watchdog = nil
        end
    end
end

local function CastFull(bar)
    local unit = bar.unit
    local name, _, texture, _, _, _, _, notInterruptible = UnitCastingInfo(unit)
    if not name then
        if bar.slot and not bar.channeling then HideBar(bar) end
        return
    end

    local duration = UnitCastingDuration(unit)
    if not duration then
        if bar.slot and not bar.channeling then HideBar(bar) end
        return
    end

    bar.channeling = false

    local fill = bar.fill
    if issecretvalue(notInterruptible) then
        SetVertexColorFromBoolean(fill, notInterruptible, LOCKED_COLOR, CAST_COLOR)
        SetAlphaFromBoolean(bar.shield, notInterruptible, 1, 0)
        SetAlphaFromBoolean(bar.border, notInterruptible, 0, 1)
    elseif notInterruptible then
        SetVertexColor(fill, LOCK_R, LOCK_G, LOCK_B, LOCK_A)
        SetAlpha(bar.shield, 1)
        SetAlpha(bar.border, 0)
    else
        SetVertexColor(fill, CAST_R, CAST_G, CAST_B, CAST_A)
        SetAlpha(bar.shield, 0)
        SetAlpha(bar.border, 1)
    end

    SetText(bar.text, name)
    SetTexture(bar.icon, texture)

    SetTimerDuration(bar, duration, IMMEDIATE, ELAPSED)

    local slot = bar.slot
    if slot then
        activeKind[slot] = KIND_CAST
    else
        ShowBar(bar, KIND_CAST, unit)
    end
end

local function CastStopProbe(bar)
    if UnitCastingDuration(bar.unit) then
        if not bar.slot then CastFull(bar) end
        return
    end

    if bar.slot and not bar.channeling then HideBar(bar) end
end

local function CastDelayed(bar)
    if not bar.slot or bar.channeling then
        CastFull(bar)
        return
    end

    local d = UnitCastingDuration(bar.unit)
    if d then
        SetTimerDuration(bar, d, IMMEDIATE, ELAPSED)
    else
        HideBar(bar)
    end
end

local function ChannelDraw(bar, empowered)
    local unit = bar.unit
    local name, _, texture, _, _, _, notInterruptible, _, isEmpowered = UnitChannelInfo(unit)
    if not name then
        if bar.slot and bar.channeling then HideBar(bar) end
        return
    end

    if empowered == nil then empowered = isEmpowered end

    local duration, direction, kind
    if empowered then
        duration  = UnitEmpoweredChannelDuration(unit)
        direction = ELAPSED
        kind      = KIND_EMPOWER
    else
        duration  = UnitChannelDuration(unit)
        direction = REMAINING
        kind      = KIND_CHANNEL
    end

    if not duration then
        if bar.slot and bar.channeling then HideBar(bar) end
        return
    end

    bar.channeling = true

    local fill = bar.fill
    if issecretvalue(notInterruptible) then
        SetVertexColorFromBoolean(fill, notInterruptible, LOCKED_COLOR, CHANNEL_COLOR)
        SetAlphaFromBoolean(bar.shield, notInterruptible, 1, 0)
        SetAlphaFromBoolean(bar.border, notInterruptible, 0, 1)
    elseif notInterruptible then
        SetVertexColor(fill, LOCK_R, LOCK_G, LOCK_B, LOCK_A)
        SetAlpha(bar.shield, 1)
        SetAlpha(bar.border, 0)
    else
        SetVertexColor(fill, CHAN_R, CHAN_G, CHAN_B, CHAN_A)
        SetAlpha(bar.shield, 0)
        SetAlpha(bar.border, 1)
    end

    SetText(bar.text, name)
    SetTexture(bar.icon, texture)

    SetTimerDuration(bar, duration, IMMEDIATE, direction)

    local slot = bar.slot
    if slot then
        activeKind[slot] = kind
    else
        ShowBar(bar, kind, unit)
    end
end

local function ChannelUpdate(bar, empowered)
    local slot = bar.slot
    if not slot or not bar.channeling then
        return ChannelDraw(bar, empowered)
    end

    local unit = bar.unit
    local d, direction, kind
    if empowered then
        d         = UnitEmpoweredChannelDuration(unit)
        direction = ELAPSED
        kind      = KIND_EMPOWER
    else
        d         = UnitChannelDuration(unit)
        direction = REMAINING
        kind      = KIND_CHANNEL
    end

    if not d then
        HideBar(bar)
        return
    end

    activeKind[slot] = kind
    SetTimerDuration(bar, d, IMMEDIATE, direction)
end

local function ChannelStop(bar, empowered)
    local unit = bar.unit
    local d
    if empowered then
        d = UnitEmpoweredChannelDuration(unit)
    else
        d = UnitChannelDuration(unit)
    end

    if d then
        if not bar.slot then ChannelDraw(bar, empowered) end
        return
    end

    if bar.slot and bar.channeling then HideBar(bar) end
end

local function BarEvent(bar, event)
    if event == "UNIT_SPELLCAST_FAILED"         then return CastStopProbe(bar) end
    if event == "UNIT_SPELLCAST_STOP"           then return CastStopProbe(bar) end
    if event == "UNIT_SPELLCAST_START"          then return CastFull(bar) end
    if event == "UNIT_SPELLCAST_DELAYED"        then return CastDelayed(bar) end
    if event == "UNIT_SPELLCAST_CHANNEL_START"  then return ChannelDraw(bar, false) end
    if event == "UNIT_SPELLCAST_CHANNEL_STOP"   then return ChannelStop(bar, false) end
    if event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then return ChannelUpdate(bar, false) end
    if event == "UNIT_SPELLCAST_INTERRUPTED"    then return CastStopProbe(bar) end
    if event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then return ChannelUpdate(bar, true) end
    if event == "UNIT_SPELLCAST_EMPOWER_START"  then return ChannelDraw(bar, true) end
    return ChannelStop(bar, true)
end

local function Resync(bar)
    local unit = bar.unit

    if UnitCastingDuration(unit) or bar.slot then
        CastFull(bar)
    end

    if not bar.slot then
        if UnitChannelDuration(unit) or UnitEmpoweredChannelDuration(unit) then
            ChannelDraw(bar)
        end
    end
end

Sweep = function()
    local a, au, ak = active, activeUnit, activeKind

    for i = activeCount, 1, -1 do
        local unit = au[i]
        local kind = ak[i]

        if kind == KIND_CAST then
            if not UnitCastingDuration(unit) and not UnitCastingInfo(unit) then
                HideBar(a[i])
            end
        elseif kind == KIND_CHANNEL then
            if not UnitChannelDuration(unit) and not UnitChannelInfo(unit) then
                HideBar(a[i])
            end
        else
            if not UnitEmpoweredChannelDuration(unit) and not UnitChannelInfo(unit) then
                HideBar(a[i])
            end
        end
    end

    if activeCount == 0 and watchdog then
        watchdog:Cancel()
        watchdog = nil
    end
end

local function Unbind(bar)
    local slot = bar.boundSlot
    if not slot then return end
    local n = boundCount

    if slot ~= n then
        local b    = bound
        local last = b[n]
        b[slot]        = last
        last.boundSlot = slot
    end
    boundCount    = n - 1
    bar.boundSlot = nil
end

local function ReleaseBar(bar)
    if bar.slot then HideBar(bar) end
    Unbind(bar)
    bar.unit = nil
    UnregisterAllEvents(bar)
end

local function OwnerHidden(frame)
    local bar = bars[frame]
    if bar and bar.unit then ReleaseBar(bar) end
end

local function CreateBar(owner)
    local bar = CreateFrame("StatusBar", nil, UIParent)
    bar:Hide()
    bar:SetSize(BAR_WIDTH, BAR_HEIGHT)
    bar:SetPoint(ANCHOR_POINT, owner, ANCHOR_RELPOINT, ANCHOR_X, BAR_Y_OFFSET)
    bar:SetFrameStrata(BAR_STRATA)
    bar:SetFrameLevel(BAR_LEVEL)
    bar:EnableMouse(false)
    bar:SetIgnoreParentAlpha(true)
    bar:SetMinMaxValues(0, 1)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar.channeling = false

    bar.fill = bar:GetStatusBarTexture()

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(BG_R, BG_G, BG_B, BG_A)

    local icon = bar:CreateTexture(nil, "OVERLAY", nil, 4)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("RIGHT", bar, "LEFT", ICON_X, ICON_Y)
    bar.icon = icon

    local border = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    border:SetTexture(BORDER_TEXTURE)
    border:SetHeight(BORDER_H)
    border:SetPoint("LEFT", bar, "LEFT", -BORDER_X, 0)
    border:SetPoint("RIGHT", bar, "RIGHT", BORDER_X, 0)
    bar.border = border

    local shield = bar:CreateTexture(nil, "OVERLAY", nil, 2)
    shield:SetTexture(SHIELD_TEXTURE)
    shield:SetHeight(SHIELD_H)
    shield:SetPoint("LEFT", bar, "LEFT", -SHIELD_XL, 0)
    shield:SetPoint("RIGHT", bar, "RIGHT", SHIELD_XR, 0)
    shield:SetAlpha(0)
    bar.shield = shield

    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetDrawLayer("OVERLAY", 5)
    text:SetFontObject(PCB_FONT)
    text:SetWordWrap(false)
    text:SetPoint("TOPLEFT", bar, "TOPLEFT", TEXT_PADDING, TEXT_Y_OFFSET)
    text:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -TEXT_PADDING, TEXT_Y_OFFSET)
    bar.text = text

    bar:SetScript("OnEvent", BarEvent)
    bar:Raise()

    owner:HookScript("OnHide", OwnerHidden)
    owner:HookScript("OnShow", ScheduleScan)

    bars[owner] = bar
    return bar
end

local function Bind(owner, unit)
    if not unit or not owner:IsVisible() then return end

    local bar = bars[owner] or CreateBar(owner)
    bar.generation = generation

    if not bar.boundSlot then
        local n = boundCount + 1
        boundCount = n
        bound[n] = bar
        bar.boundSlot = n
    end

    if bar.unit ~= unit then
        if bar.slot then HideBar(bar) end
        bar.unit = unit

        RegisterUnitEvent(bar, "UNIT_SPELLCAST_START",       unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_DELAYED",     unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_STOP",        unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_FAILED",      unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_INTERRUPTED", unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_CHANNEL_START",  unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_CHANNEL_UPDATE", unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_CHANNEL_STOP",   unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_EMPOWER_START",  unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_EMPOWER_UPDATE", unit)
        RegisterUnitEvent(bar, "UNIT_SPELLCAST_EMPOWER_STOP",   unit)

        Resync(bar)
    elseif forceResync then
        Resync(bar)
    end
end

local hookedParty, hookedRaid, hookedStandard, allHooked
local partyContainer, raidContainer, standardParty

local function TryHooks()
    if not hookedParty then
        local f = CompactPartyFrame
        if f then
            hookedParty    = true
            partyContainer = f
            hooksecurefunc(f, "RefreshMembers", ScheduleScan)
        end
    end

    if not hookedRaid then
        local f = CompactRaidFrameContainer
        if f then
            hookedRaid    = true
            raidContainer = f
            hooksecurefunc(f, "LayoutFrames", ScheduleScan)
        end
    end

    if not hookedStandard then
        local f = PartyFrame
        if f then
            hookedStandard = true
            standardParty  = f
            hooksecurefunc(f, "UpdatePartyFrames", ScheduleScan)

            if f.InitializePartyMemberFrames then
                hooksecurefunc(f, "InitializePartyMemberFrames", SnapshotPartyPool)
            end

            SnapshotPartyPool(f)
        end
    end

    allHooked = hookedParty and hookedRaid and hookedStandard
end

local function ResolveSelf(inRaid, groupSize)
    if not inRaid then return "player" end

    local idx = UnitInRaid("player")
    if not issecretvalue(idx) and idx then
        local t = RAID_TOKENS[idx]
        if t then return t end
    end

    for i = 1, groupSize do
        local t = RAID_TOKENS[i]
        if not t then break end
        local r = UnitIsUnit(t, "player")
        if not issecretvalue(r) and r then return t end
    end

    return nil
end

local function Scan()
    scanPending = false
    generation = generation + 1

    if not allHooked then TryHooks() end

    local inRaid    = IsInRaid()
    local groupSize = inRaid and GetNumGroupMembers() or 0

    if not (inRaid and groupSize > SMALL_GROUP_SIZE) then
        if selfDirty then
            local s = ResolveSelf(inRaid, groupSize)
            if s then
                selfUnit  = s
                selfDirty = false
            end
        end
        local me = selfUnit

        local c = partyContainer
        if c and c:IsVisible() then
            local frames = c.memberUnitFrames
            if frames then
                for i = 1, #frames do
                    local frame = frames[i]
                    local unit  = frame.unit
                    if unit and unit ~= "player" and unit ~= me then Bind(frame, unit) end
                end
            end
        end

        c = raidContainer
        if c and c:IsVisible() then
            local frames = c.frameUpdateList
            frames = frames and frames.normal
            if frames then
                for i = 1, #frames do
                    local frame = frames[i]
                    local unit = frame.unit
                    if unit and unit ~= "player" and unit ~= me then Bind(frame, unit) end
                end
            end
        end

        local p = standardParty
        if p and p:IsVisible() then
            local pmf = partyMemberFrames
            for i = 1, numPartyMemberFrames do
                local frame = pmf[i]
                local unit  = frame.unitToken
                if unit then Bind(frame, unit) end
            end
        end
    end

    local bnd = bound
    local g   = generation
    for i = boundCount, 1, -1 do
        local b = bnd[i]
        if b.generation ~= g then
            ReleaseBar(b)
        end
    end

    forceResync = false
end

ScheduleScan = function()
    if scanPending then return end
    scanPending = true
    After(0, Scan)
end

local function OnGroupEvent(self, event)
    selfDirty = true

    if event == "PLAYER_ENTERING_WORLD" then
        forceResync = true
        After(2, ScheduleScan)
    end

    ScheduleScan()
end

PCB:SetScript("OnEvent", function(self)
    C_AddOns.LoadAddOn("Blizzard_CompactRaidFrames")
    self:UnregisterEvent("PLAYER_LOGIN")
    self:SetScript("OnEvent", OnGroupEvent)
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    ScheduleScan()
end)

PCB:RegisterEvent("PLAYER_LOGIN")
