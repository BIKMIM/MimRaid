--------------------------------------------------------------------------------
-- MimRaid - MimRaid.lua
-- 메인 초기화, 이벤트 처리, 슬래시 명령어, 미니맵 버튼
-- 모든 로직 모듈(Settings, ItemList, TradeLog, Auction)이 먼저 로드된 후 실행됨
--------------------------------------------------------------------------------

---@diagnostic disable: undefined-global

local MR = MimRaid

--------------------------------------------------------------------------------
-- 미니맵 버튼 — 파일 최상단 정의 (이후 코드 오류와 무관하게 항상 유효)
--------------------------------------------------------------------------------
function MR.CreateMinimapButton()
    local ldb = LibStub("LibDataBroker-1.1", true)
    local icon = LibStub("LibDBIcon-1.0", true)
    if not ldb or not icon then
        MR.Debug("LibDBIcon 또는 LibDataBroker를 찾을 수 없음 - 미니맵 버튼 생략")
        return
    end
    if not MimRaidDB.minimap then MimRaidDB.minimap = {} end
    local launcher = ldb:NewDataObject("MimRaid", {
        type  = "launcher",
        icon  = "Interface\\AddOns\\MimRaid\\img\\MimRaid_minimap_icon",
        OnClick = function(_, button)
            if button == "LeftButton" then
                MR.ToggleMainFrame()
            elseif button == "RightButton" then
                MR.ResetFramePosition()
            end
        end,
        OnTooltipShow = function(tooltip)
            if not tooltip or not tooltip.AddLine then return end
            tooltip:AddLine("MIM RAID\n좌클릭 : 창 열기/닫기\n우클릭 : 창 위치 / 크기 / 글꼴 초기화")
        end,
    })
    icon:Register("MimRaid", launcher, MimRaidDB.minimap)
    MR.Debug("MinimapButton: registered via LibDBIcon")
end

--------------------------------------------------------------------------------
-- 글꼴 크기 조절 시스템
-- 모든 2002.TTF 폰트스트링을 런타임에 수집 → +/- 버튼으로 일괄 변경
--------------------------------------------------------------------------------
local _fontStrings  = {}   -- 수집된 FontString 목록
local _fontBaseSizes = {}  -- FontString → 기본 크기 테이블

-- 멱등성 보장: 이미 추적 중인 region 은 SKIP (재호출 시 중복 추가 X).
-- GetFont() 가 일부 Blizzard 프레임에서 string 경로 대신 FileDataID(number) 를 반환할 수 있어
-- :find 호출 전 type 가드 필수.
local function _collectFonts(frame)
    for _, region in ipairs({frame:GetRegions()}) do
        if region.GetFont and not _fontBaseSizes[region] then
            local font, size = region:GetFont()
            if font and type(font) == "string" and font:find("2002", 1, true) and size then
                _fontBaseSizes[region] = size
                table.insert(_fontStrings, region)
            end
        end
    end
    for _, child in ipairs({frame:GetChildren()}) do
        _collectFonts(child)
    end
end

function MR.RefreshFontSizes()
    -- 동적 생성된 FontString 들 (거래 완료 기록 행, 안팔린 아이템 행 등) 재수집
    local mf = _G["MimRaidMainFrame"]
    if mf then _collectFonts(mf) end

    local delta = MR.cfg.fontDelta or 0
    for _, fs in ipairs(_fontStrings) do
        if _fontBaseSizes[fs] then
            fs:SetFont("Fonts\\2002.TTF", math.max(6, _fontBaseSizes[fs] + delta))
        end
    end
end

function MR.AdjustFontSize(delta)
    MR.cfg.fontDelta = math.max(-4, math.min(20, (MR.cfg.fontDelta or 0) + delta))
    MR.RefreshFontSizes()
    MR.SaveSettings()
end

--------------------------------------------------------------------------------
-- 창 위치/크기 초기화
--------------------------------------------------------------------------------
function MR.ResetFramePosition()
    local f = _G["MimRaidMainFrame"]
    if not f then return end
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetScale(1.0)
    if MimRaidDB then
        MimRaidDB.frameX = nil
        MimRaidDB.frameY = nil
        MimRaidDB.frameScale = 1.0
    end
    if MR.cfg then
        MR.cfg.fontDelta = (MR.DEFAULTS and MR.DEFAULTS.fontDelta) or 2
        if MR.RefreshFontSizes then MR.RefreshFontSizes() end
        if MR.SaveSettings then MR.SaveSettings() end
    end
    MR.Print("창 위치 / 크기 / 글꼴 초기화", MR.COLOR.gray)
end

--------------------------------------------------------------------------------
-- 이벤트 프레임
--------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "MimRaidEventFrame")

--------------------------------------------------------------------------------
-- 이벤트 핸들러 테이블
--------------------------------------------------------------------------------
local handlers = {}

handlers["ADDON_LOADED"] = function(addonName)
    if addonName ~= "MimRaid" then return end

    -- SavedVariables 로드
    MR.LoadSettings()
    -- 1회성: 기존 계정 루트의 레이드 데이터를 현재 캐릭터 파티션으로 이동.
    -- 이미 마이그레이션된 경우 무해 (조건부로 해당 키들이 없으면 noop).
    MR.MigrateAccountToCharData()
    MR.ItemList.Load()
    MR.FailedItems.Load()
    MR.TradeLog.Load()
    MR.RaidTimer.Load()
    MR.RaidHistory.Load()
    if MR.LoadSettleAdjust then MR.LoadSettleAdjust() end

    -- 리로드 후 거래 자동 배치/오버레이 복구 (TradeLog PENDING → pendingWinners)
    if MR.Auction and MR.Auction.RebuildPendingFromTradeLog then
        MR.Auction.RebuildPendingFromTradeLog()
    end

    -- 미니맵 버튼 생성 (MimRaidDB 로드 후)
    MR.CreateMinimapButton()

    -- 주기적 자동저장 (60초마다) - 예기치 않은 종료 대비
    C_Timer.NewTicker(60, function()
        MR.ItemList.Save()
        MR.FailedItems.Save()
        MR.TradeLog.Save()
        MR.SaveSettings()
        MR.Debug("자동저장 완료")
    end)

    -- 글꼴 크기: 모든 프레임 생성 후 한 프레임 뒤에 수집 + 저장된 delta 적용
    C_Timer.After(0, function()
        local mf = _G["MimRaidMainFrame"]
        if mf then _collectFonts(mf) end
        MR.RefreshFontSizes()
    end)

    MR.Print("로드 완료 v" .. MR.VERSION .. "  /경매  /밈레이드  /ㅁㄹ")
    MR.Debug("ADDON_LOADED: settings & data restored")
end

-- 게임 종료/로그아웃/연결 끊김/존 변경 시:
-- 1) 데이터 강제 저장
-- 2) Auction 이 Busy 상태면 "공대장 로딩 대기" 알림 송출 + 일시정지
handlers["PLAYER_LEAVING_WORLD"] = function()
    MR.ItemList.Save()
    MR.FailedItems.Save()
    MR.TradeLog.Save()
    MR.SaveSettings()
    MR.Debug("PLAYER_LEAVING_WORLD: 데이터 저장 완료")
    if MR.Auction and MR.Auction.OnPlayerLeavingWorld then
        MR.Auction.OnPlayerLeavingWorld()
    end
end

handlers["LOOT_OPENED"] = function()
    MR.ItemList.OnLootOpened()
end

handlers["CHAT_MSG_LOOT"] = function(msg)
    MR.ItemList.OnChatLoot(msg)
end

-- 보너스 루팅창 관측용 상태 (v0.9.12~, 임시)
local _lastEncounterEndTime = 0
local _lastEncounterInfo = "none"

handlers["ENCOUNTER_START"] = function()
    MR.Auction.OnEncounterStart()
end

handlers["ENCOUNTER_END"] = function(encounterID, encounterName, difficultyID, _, success)
    MR.Auction.OnEncounterEnd()
    MR.ItemList.OnEncounterEnd(success == 1 or success == true, encounterName)
    -- 보너스 루팅창 관측용: 마지막 보스 처치 시각/정보 기록
    _lastEncounterEndTime = GetTime()
    _lastEncounterInfo = string.format("%s(id=%s diff=%s success=%s)",
        tostring(encounterName), tostring(encounterID), tostring(difficultyID), tostring(success))
    MR.Debug("[ROLL-OBS] ENCOUNTER_END " .. _lastEncounterInfo)
end

handlers["GET_ITEM_INFO_RECEIVED"] = function()
    MR.ItemList.FlushPending()
end

-- CHAT_MSG_* sender 는 전투/크로스렐름에서 secret string 으로 올 수 있음.
-- 이벤트 경계에서 CanonicalName 으로 정규화해 downstream 을 taint 로부터 격리.
handlers["CHAT_MSG_RAID"] = function(msg, sender)
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["CHAT_MSG_RAID_LEADER"] = function(msg, sender)
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["CHAT_MSG_RAID_WARNING"] = function(msg, sender)
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["CHAT_MSG_INSTANCE_CHAT"] = function(msg, sender)
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["CHAT_MSG_INSTANCE_CHAT_LEADER"] = function(msg, sender)
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["CHAT_MSG_PARTY"] = function(msg, sender)
    if IsInRaid() then return end  -- 레이드 중엔 파티채팅 무시
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["CHAT_MSG_PARTY_LEADER"] = function(msg, sender)
    if IsInRaid() then return end
    MR.Auction.OnChatMsg(msg, MR.CanonicalName(sender) or sender)
end

handlers["PLAYER_REGEN_DISABLED"] = function()
    MR.RaidTimer.TryAutoStart()
end

-- 쐐기 단수 캐시 (START에서 저장 → COMPLETED에서 출력 → 다음 START에서 초기화)
local _mkKeystoneLevel = nil

-- 쐐기 던전(M+) 카운트다운 종료 시 타이머 자동 시작 (공식 타이머와 동일 시점)
handlers["CHALLENGE_MODE_START"] = function()
    if not MR.cfg.raidTimerAutoStart then return end

    -- 재진입 감지: 이미 동일 던전에서 타이머가 흐르고 있으면 Reset 하지 않음.
    -- (M+ 진행 중 외부로 나갔다 재입장 시 CHALLENGE_MODE_START 가 재발화해 시간이 날아가던 문제)
    if MR.RaidTimer.startTime and MR.RaidTimer.instanceName then
        local currentInstance = GetInstanceInfo()
        if currentInstance == MR.RaidTimer.instanceName then
            MR.Debug(string.format(
                "CHALLENGE_MODE_START: 동일 던전 재진입(%s) → 타이머 유지",
                tostring(currentInstance)))
            return
        end
    end

    -- 새 던전 또는 타이머 미시작: 단수 캐시 + Reset + Start
    _mkKeystoneLevel = nil
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        local ok, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
        if ok and level then _mkKeystoneLevel = level end
    end
    MR.RaidTimer.Reset()
    MR.RaidTimer.Start(false)
    MR.Debug("RaidTimer: M+ START 단수=" .. tostring(_mkKeystoneLevel))
end

-- 쐐기 던전(M+) 완료 시 타이머 자동 정지 + 결과 출력
handlers["CHALLENGE_MODE_COMPLETED"] = function()
    if not MR.RaidTimer.GetElapsed() then return end
    MR.RaidTimer.Freeze()
    local instanceName = MR.RaidTimer.instanceName or GetInstanceInfo() or ""
    local parts = {}
    if instanceName ~= "" then table.insert(parts, instanceName) end
    if _mkKeystoneLevel   then table.insert(parts, _mkKeystoneLevel .. "단") end
    table.insert(parts, MR.RaidTimer.Format())
    MR.Print("쐐기 완료!  " .. table.concat(parts, "  "), MR.COLOR.green)
end

handlers["TRADE_SHOW"] = function()
    MR.Auction.OnTradeShow()
    if MR.TradeAnnounce then MR.TradeAnnounce.OnTradeShow() end
end

handlers["TRADE_CLOSED"] = function()
    MR.Auction.OnTradeClosed()
    -- TA 스냅샷은 여기서 리셋하지 않음. ERR_TRADE_COMPLETE(UI_INFO_MESSAGE)가 TRADE_CLOSED
    -- 이후에 도착하는 경우가 있어 여기서 리셋하면 귓말 발송 시점에 스냅샷이 비어버림.
    -- 대신 다음 TRADE_SHOW 시작 시 reset()으로 초기화됨. _sent 플래그가 중복 발송 방지.
end

handlers["TRADE_ACCEPT_UPDATE"] = function(playerAccepted, targetAccepted)
    MR.Auction.OnTradeAcceptUpdate(playerAccepted, targetAccepted)
    if MR.TradeAnnounce then MR.TradeAnnounce.Snapshot() end
end

-- Blizzard 시스템 메시지 — 거래 완료/취소 (ERR_TRADE_COMPLETE / ERR_TRADE_CANCELLED) 정식 시그널
-- 거래 기록(Auction)도 이 시그널로 1차 판정 → TRADE_CLOSED + _bothAccepted 래치는 폴백.
handlers["UI_INFO_MESSAGE"] = function(messageType)
    if MR.Auction and MR.Auction.OnUIInfoMessage then
        MR.Auction.OnUIInfoMessage(messageType)
    end
    if MR.TradeAnnounce then MR.TradeAnnounce.OnUIInfoMessage(messageType) end
end

handlers["TRADE_PLAYER_ITEM_CHANGED"] = function(slot)
    MR.Auction.OnTradePlayerItemChanged(slot)
end

--------------------------------------------------------------------------------
-- 공대장 전용 자동 주사위 굴리기
-- ROLL_STARTED 이벤트 = 그룹 루팅 시 아이템 주사위 창이 열릴 때 발동
-- 공대장이 아니거나 옵션이 꺼져 있으면 무시
--------------------------------------------------------------------------------
-- 보스 드롭 10개가 거의 동시에 트리거되면 포기 안내 메시지도 10번 전송됨.
-- 루팅 세션당 1회만 공지하도록 20초 쿨다운 적용 (보스 간 간격은 30초+)
local lastAutoRollMsgTime = 0
-- 동시에 주사위창이 여러 개 뜨면 와우가 처리를 못하고 잔상/UI버그가 남음.
-- 0.2초 간격으로 순차 처리하여 UI가 따라올 수 있게 함.
local autoRollQueue = {}
local autoRollDraining = false
local function drainAutoRollQueue()
    -- 전투 중에는 RollOnLoot 이 protected (차단). 큐에 다시 넣고 잠시 대기.
    if InCombatLockdown and InCombatLockdown() then
        C_Timer.After(0.5, drainAutoRollQueue)
        return
    end
    local entry = table.remove(autoRollQueue, 1)
    if not entry then
        autoRollDraining = false
        MR.Debug(string.format("AutoRoll drain: 큐 비어서 종료 t=%.3f", GetTime()))
        return
    end
    -- rollID가 만료됐을 수 있으니 여전히 유효한지 확인 (타임아웃/다른곳에서 굴림 등)
    local _, stillName = GetLootRollItemInfo(entry.rollID)
    if stillName then
        RollOnLoot(entry.rollID, entry.rollType)
        MR.Debug(string.format("AutoRoll drain: %s 굴림 type=%d t=%.3f 남은=%d",
            tostring(stillName), entry.rollType, GetTime(), #autoRollQueue))
    else
        MR.Debug(string.format("AutoRoll drain: rollID=%s 만료 스킵 t=%.3f",
            tostring(entry.rollID), GetTime()))
    end
    C_Timer.After(0.2, drainAutoRollQueue)
end

--------------------------------------------------------------------------------
-- 보너스 루팅창 관측 코드 (v0.9.12~, 임시)
-- 11.x에서 공허핵 소모 → 추가 주사위창 시스템 추가됨. 이 창이 START_LOOT_ROLL을 발동시키는지,
-- 발동 시 일반 드롭과 어떻게 구별되는지 관측. 보너스 창이 확인되면 이 블록은 정식 가드로 교체됨.
-- (_lastEncounterEndTime / _lastEncounterInfo 는 위 ENCOUNTER_END 핸들러 근처에서 선언됨)
--------------------------------------------------------------------------------

-- 보너스 창 후보 프레임들 (하나라도 보이면 보너스 컨텍스트로 추정)
local _bonusFrameCandidates = {
    "BonusRollFrame", "GenericBonusRollFrame", "BonusRollMoneyWonFrame",
    "WeaveRewardFrame", "VoidwovenRewardFrame", "VoidwovenBonusFrame",
    "BonusLootFrame", "EncounterBonusLootFrame",
    "GroupLootContainer",  -- 컨테이너 (정상/보너스 모두 여기에 들어감)
}

local function _dumpRollObservation(rollID)
    local texture, name, count, quality, bindOnPickUp,
          canNeed, canGreed, canDisenchant,
          reasonNeed, reasonGreed, reasonDisenchant,
          deSkillRequired, canTransmog = GetLootRollItemInfo(rollID)
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID) or nil
    local timeLeft = GetLootRollTimeLeft and GetLootRollTimeLeft(rollID) or -1
    local elapsed = _lastEncounterEndTime > 0 and (GetTime() - _lastEncounterEndTime) or -1
    local _, iType = IsInInstance()

    MR.Debug(string.format(
        "[ROLL-OBS] rollID=%s name=%s q=%s bop=%s cN=%s cG=%s cD=%s cT=%s rN=%s rG=%s rD=%s deSk=%s tLeft=%.1f sinceEnc=%.1fs enc=%s iType=%s",
        tostring(rollID), tostring(name), tostring(quality), tostring(bindOnPickUp),
        tostring(canNeed), tostring(canGreed), tostring(canDisenchant), tostring(canTransmog),
        tostring(reasonNeed), tostring(reasonGreed), tostring(reasonDisenchant),
        tostring(deSkillRequired), timeLeft, elapsed, _lastEncounterInfo, tostring(iType)))
    MR.Debug("[ROLL-OBS] link=" .. tostring(link))

    local visibleFrames = {}
    for i = 1, 4 do
        local f = _G["GroupLootFrame" .. i]
        if f and f.IsShown then
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then table.insert(visibleFrames, "GroupLootFrame" .. i) end
        end
    end
    for _, fname in ipairs(_bonusFrameCandidates) do
        local f = _G[fname]
        if f and f.IsShown then
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then table.insert(visibleFrames, fname) end
        end
    end
    MR.Debug("[ROLL-OBS] visibleFrames=" .. (next(visibleFrames) and table.concat(visibleFrames, ",") or "(none)"))
end

handlers["START_LOOT_ROLL"] = function(rollID)
    -- 관측: 모든 주사위창 시작 시 필드/프레임 덤프 (가드 통과 여부와 무관하게 항상 로깅)
    _dumpRollObservation(rollID)

    if not MR.cfg.autoRollEnabled then return end
    -- 파티/개인 인던에서는 동작 금지. 공격대이면서 공대장 또는 부공대장일 때만.
    if not IsInRaid() then
        MR.Debug("AutoRoll skip: 공격대 아님 (파티/개인 인던)")
        return
    end
    -- 실제 레이드 인스턴스 안에서만 동작. 월드 보스, 오픈월드 이벤트 주사위, 공대 포맷 필드 파티,
    -- 추가 주사위 이벤트 등은 IsInRaid()=true여도 instanceType은 "raid"가 아님 → 차단.
    local _, instanceType = IsInInstance()
    if instanceType ~= "raid" then
        MR.Debug("AutoRoll skip: 레이드 인스턴스 아님 (type=" .. tostring(instanceType) .. ")")
        return
    end
    if not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
        MR.Debug("AutoRoll skip: 공대장/부공대장 아님")
        return
    end

    -- retail: texture, name, count, quality, bindOnPickUp, canNeed, canGreed,
    --         canDisenchant, reasonNeed, reasonGreed, reasonDisenchant,
    --         deSkillRequired, canTransmog
    local _, name, _, _, _, canNeed, canGreed, canDisenchant, _, _, _, _, canTransmog
        = GetLootRollItemInfo(rollID)
    if not name then return end

    local n = GetNumGroupMembers()
    local hasOthers = false
    for i = 1, n do
        local unit = "raid" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
            hasOthers = true
            break
        end
    end
    if hasOthers and MR.cfg.autoRollMsg and MR.cfg.autoRollMsg ~= "" then
        local now = GetTime()
        if now - lastAutoRollMsgTime >= 20 then
            local msg = MR.cfg.autoRollMsg:gsub("\n", " ")
            -- 자동 주사위 안내는 공격대 경보(RAID_WARNING)로 발송 — 화면 중앙에 큰 글씨로 표시
            MR.SafeSendChat(msg, "RAID_WARNING")
            lastAutoRollMsgTime = now
        end
    end

    -- 자동 굴리기 우선순위
    -- 1) Need(주사위) : 공대장이 착용 가능 → 바로 획득
    -- 2) Transmog(차비) : 착용 불가지만 외형 수집 가능 → 낙찰 시 아이템 획득
    -- 3) Greed(전리품 주사위) : 보편적 획득
    -- 4) Disenchant(분해) : 최후 수단 (아이템 소멸, 가루 획득)
    local rollType
    if canNeed then
        rollType = 1
    elseif canTransmog then
        rollType = 4
    elseif canGreed then
        rollType = 2
    elseif canDisenchant then
        rollType = 3
    end
    if rollType then
        table.insert(autoRollQueue, { rollID = rollID, rollType = rollType })
        if not autoRollDraining then
            autoRollDraining = true
            C_Timer.After(0.2, drainAutoRollQueue)
        end
    end
    MR.Debug(string.format(
        "AutoRoll: %s need=%s transmog=%s greed=%s de=%s -> queued=%s",
        tostring(name), tostring(canNeed), tostring(canTransmog),
        tostring(canGreed), tostring(canDisenchant), tostring(rollType)))
end

-- 인던 입장 시 이전 레이드 기록이 있으면 초기화 제안 (단일 확인)
StaticPopupDialogs["MIMRAID_RESET_CONFIRM"] = {
    text      = "이전 레이드의 경매 기록을 초기화 하시겠습니까?\n|cffff4444초기화는 되돌릴 수 없습니다.|r",
    button1   = "초기화",
    button2   = "유지",
    OnAccept  = function()
        -- Auction 상태도 깨끗히 리셋 — pendingWinners/inPreview 등 stale 플래그 제거
        if MR.Auction and MR.Auction.Reset then
            pcall(MR.Auction.Reset)
        end
        MR.ItemList.Clear()
        MR.TradeLog.Clear()
        MR.FailedItems.Clear()
        MR.RaidTimer.Reset()
        -- 골드 분배 탭의 수동 입력값 (조정 금액 / 분배 인원 / 끝자리 정리) 도 함께 초기화
        if MR.ResetSettleInputs then pcall(MR.ResetSettleInputs) end
        MR.Print("경매 기록 초기화 완료", MR.COLOR.green)
    end,
    timeout   = 0,
    whileDead = false,
}

-- 마지막 인스턴스 타입 추적 (인스턴스 → 야외 전환 감지용)
local _lastInstanceType = "none"

handlers["PLAYER_ENTERING_WORLD"] = function(isInitialLogin, isReloadingUi)
    -- 로딩 종료 알림 (Auction 모듈이 Busy 상태였으면 재개 메시지 송출)
    if MR.Auction and MR.Auction.OnPlayerEnteringWorld then
        MR.Auction.OnPlayerEnteringWorld(isInitialLogin, isReloadingUi)
    end

    -- 최초 로그인·UI 리로드는 무시
    if isInitialLogin or isReloadingUi then return end

    local instanceName, instanceType = GetInstanceInfo()
    local prevType = _lastInstanceType
    _lastInstanceType = instanceType

    local tradeN, itemN = #MR.TradeLog, #MR.ItemList
    local hasData = (tradeN > 0 or itemN > 0)

    -- 진단 로그: 팝업이 안 떠서 의문일 때 원인 파악용
    MR.Debug(string.format(
        "PEW: instance=%s type=%s prev=%s tradeLog=%d itemList=%d hasData=%s",
        tostring(instanceName), tostring(instanceType), tostring(prevType),
        tradeN, itemN, tostring(hasData)))

    -- 인스턴스 → 야외 전환 시: 기록이 있으면 초기화 제안 팝업.
    -- 사용자가 초기화 선택 시 RaidTimer 도 함께 리셋됨 (popup OnAccept 에 포함됨).
    -- "유지" 선택하면 타이머 계속 진행 + 데이터 유지.
    if instanceType == "none" then
        if prevType ~= "none" and hasData then
            StaticPopup_Show("MIMRAID_RESET_CONFIRM")
        end
        return
    end

    -- 5인 던전 (party): CHALLENGE_MODE_START 가 쐐기 시작 시 자동 Reset → 팝업 불필요
    if instanceType == "party" then return end

    -- 레이드 + 일부 시나리오형 레이드(scenario) 도 포함: 기록이 있으면 팝업
    if (instanceType == "raid" or instanceType == "scenario") and hasData then
        StaticPopup_Show("MIMRAID_RESET_CONFIRM")
    end
end


eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then handler(...) end
end)

for event in pairs(handlers) do
    eventFrame:RegisterEvent(event)
end

--------------------------------------------------------------------------------
-- 슬래시 명령어
-- /mr, /mimraid, /경매, /레이드, /밈레이드 → 창 토글
-- /mr <서브커맨드> → 기능 실행
--------------------------------------------------------------------------------
SLASH_MIMRAID1 = "/mr"
SLASH_MIMRAID2 = "/mimraid"
SLASH_MIMRAID3 = "/경매"
SLASH_MIMRAID4 = "/레이드"
SLASH_MIMRAID5 = "/밈레이드"
SLASH_MIMRAID6 = "/밈레"
SLASH_MIMRAID7 = "/ㅁㄹ"
SLASH_MIMRAID8 = "/af"

SlashCmdList["MIMRAID"] = function(input)
    local args = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if args == "" then
        MR.ToggleMainFrame()
        return
    end

    -- /mr snd <id>  : FileDataID 사운드 테스트 (PlaySoundFile on Dialog)
    local cmd, rest = args:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "snd" or cmd == "sound" then
        local id = tonumber(rest)
        if not id then
            MR.Print("/mr snd <FileDataID> : 숫자 ID 필요", MR.COLOR.yellow)
            return
        end
        local ok = PlaySoundFile(id, "Dialog")
        MR.Print(string.format("PlaySoundFile(%d, Dialog) → %s",
            id, tostring(ok)), MR.COLOR.gray)
        return
    end

    -- /mr tdump : TradePlayerInputMoneyFrame 구조 덤프
    -- /mr tset <num> : mf.gold 에 값을 여러 방식으로 넣어보고 성공한 방식 출력
    if cmd == "tdump" then
        local mf = TradePlayerInputMoneyFrame
        if not mf then MR.Print("TradePlayerInputMoneyFrame 없음", MR.COLOR.red); return end
        if not (TradeFrame and TradeFrame:IsShown()) then
            MR.Print("※ 거래창이 안 열려 있음. 덤프만 시도", MR.COLOR.yellow)
        end
        local function dump(label, f)
            if not f then MR.Print(label .. " = nil", MR.COLOR.red); return end
            local ok, t = pcall(function() return f:GetObjectType() end)
            MR.Print(string.format("%s: type=%s, [0]=%s",
                label, ok and t or "<fail>", type(f[0])), MR.COLOR.gray)
            -- 메타테이블 __index 덤프
            local mt = getmetatable(f)
            if mt and mt.__index and type(mt.__index) == "table" then
                local count = 0
                for _ in pairs(mt.__index) do count = count + 1 end
                MR.Print(string.format("  metatable.__index: %d entries", count), MR.COLOR.gray)
            elseif mt then
                MR.Print(string.format("  metatable: %s", type(mt)), MR.COLOR.gray)
            end
            -- [0] userdata 위에서 widget method 호출 시도
            if type(f[0]) == "userdata" then
                local ok1 = pcall(function() return f[0]:GetObjectType() end)
                MR.Print(string.format("  f[0]:GetObjectType() via pcall → %s",
                    ok1 and "OK" or "FAIL"), MR.COLOR.gray)
            end
            -- Set* 함수 이름 직접 나열
            local setfns = {}
            for k, v in pairs(f) do
                if type(v) == "function" and type(k) == "string" and k:match("^Set") then
                    table.insert(setfns, k)
                end
            end
            table.sort(setfns)
            if #setfns > 0 then
                MR.Print("  direct Set*: " .. table.concat(setfns, ", "), MR.COLOR.gray)
            end
        end
        dump("mf", mf)
        dump("mf.gold",   mf.gold)
        dump("mf.silver", mf.silver)
        dump("mf.copper", mf.copper)
        return
    end

    if cmd == "tset" then
        local v = tonumber(rest) or 1234
        local mf = TradePlayerInputMoneyFrame
        if not mf or not mf.gold then MR.Print("거래창 없음", MR.COLOR.red); return end
        local g = mf.gold
        local tests = {
            { name = "g:SetText(v)",        fn = function() g:SetText(tostring(v)) end },
            { name = "g:SetNumber(v)",      fn = function() g:SetNumber(v) end },
            { name = "g:SetAmount(v*1e4)",  fn = function() g:SetAmount(v * 10000) end },
            { name = "g:SetValue(v)",       fn = function() g:SetValue(v) end },
            { name = "g[0]:SetText(v)",     fn = function() g[0]:SetText(tostring(v)) end },
            { name = "g[0]:SetNumber(v)",   fn = function() g[0]:SetNumber(v) end },
            { name = "mf:SetCopper(v*1e4)", fn = function() mf:SetCopper(v * 10000) end },
            { name = "mf:SetMoney(v*1e4)",  fn = function() mf:SetMoney(v * 10000) end },
            { name = "MIF_SetCopper",       fn = function() MoneyInputFrame_SetCopper(mf, v * 10000) end },
        }
        for _, t in ipairs(tests) do
            local ok, err = pcall(t.fn)
            MR.Print(string.format("  %-26s → %s%s",
                t.name, ok and "OK" or "FAIL",
                (not ok) and (" (" .. tostring(err):match("[^:]+$") .. ")") or ""),
                ok and MR.COLOR.green or MR.COLOR.gray)
        end
        return
    end

    -- /mr debug [on|off]  : 디버그 로그 토글 (인수 없으면 현재 상태 반전)
    if cmd == "debug" then
        local r = (rest or ""):lower()
        if r == "on" or r == "1" or r == "true" then
            MR.cfg.debugMode = true
        elseif r == "off" or r == "0" or r == "false" then
            MR.cfg.debugMode = false
        else
            MR.cfg.debugMode = not MR.cfg.debugMode
        end
        MR.SaveSettings()
        -- audit entry 표시/숨김이 debugMode 에 의존 → 토글 즉시 UI 재갱신
        if MR.TradeLog and MR.TradeLog.FireChange then MR.TradeLog.FireChange() end
        MR.Print("debugMode = " .. tostring(MR.cfg.debugMode), MR.COLOR.yellow)
        return
    end

    -- /mr calapi : 사용 가능한 Calendar API 함수 목록 출력 (달초 자동화 진단용)
    if cmd == "calapi" or cmd == "cal" then
        MR.Print("=== C_Calendar 함수 목록 ===", MR.COLOR.gold)
        if C_Calendar then
            local names = {}
            for k, v in pairs(C_Calendar) do
                if type(v) == "function" then table.insert(names, k) end
            end
            table.sort(names)
            for _, n in ipairs(names) do
                MR.Print("  C_Calendar." .. n, MR.COLOR.gray)
            end
            MR.Print(string.format("총 %d개 함수", #names), MR.COLOR.yellow)
        else
            MR.Print("C_Calendar 네임스페이스가 없습니다.", MR.COLOR.red)
        end
        MR.Print("=== 주요 전역 함수 ===", MR.COLOR.gold)
        for _, n in ipairs({
            "Calendar_LoadUI", "Calendar_Show", "ToggleCalendar",
            "OpenCalendar", "CalendarFrame_OpenEvent", "CalendarFrame_NewEvent",
            "CalendarNewEvent", "CalendarCreateEvent",
            "CalendarFrame", "CalendarCreateEventFrame",
        }) do
            local v = _G[n]
            local typ = (v ~= nil) and type(v) or "nil"
            local color = (v ~= nil) and MR.COLOR.green or MR.COLOR.gray
            MR.Print(string.format("  %s = %s", n, typ), color)
        end
        return
    end

    -- /mr uitest          : 현실적 케이스 7개 한 번에 추가 (보통 2개씩 옵션 붙는 패턴)
    -- /mr uitest stress   : 옵션 많이 붙은 행 추가 (2줄 fallback 검증용)
    -- /mr uitest clear    : 모든 _isTest 행 제거
    if cmd == "uitest" then
        local mode = (rest or ""):lower():gsub("^%s*(.-)%s*$", "%1")

        if mode == "clear" then
            local removed = 0
            for i = #MR.ItemList, 1, -1 do
                if MR.ItemList[i]._isTest then
                    table.remove(MR.ItemList, i)
                    removed = removed + 1
                end
            end
            if MR.ItemList.FireChange then MR.ItemList.FireChange() end
            MR.Print(string.format("UI 시험 행 %d개 제거", removed), MR.COLOR.gold)
            return
        end

        local samples
        if mode == "stress" then
            samples = {
                { name = "엄청 길고 긴 시험용 아이템 이름 한국어 길이 겹침 검증",
                  summary = "[치][가][특][유] - [힘][민][지] - [천][머리]\n[보홈 x 2][광피][생흡][이속][파불]",
                  qty = 1 },
            }
        else
            -- 현실적 케이스: 2차 2개 + 1차 + 부위 + 옵션 0~2개
            samples = {
                { name = "도살자의 강철 가슴갑옷",
                  summary = "[치][특] - [힘] - [판금][가슴]",                    qty = 1 },
                { name = "야수왕의 정강이받이",
                  summary = "[가][특] - [민] - [사슬][다리]\n[보홈]",            qty = 1 },
                { name = "비전술사의 두건",
                  summary = "[치][유] - [지] - [천][머리]\n[광피]",              qty = 1 },
                { name = "수호자의 인장",
                  summary = "[치][가] - [힘][민][지] - [반지]",                  qty = 1 },
                { name = "그림자의 단검",
                  summary = "[가][특] - [민] - [단검][주무기]",                  qty = 1 },
                { name = "심판관의 건틀릿 (가죽 어깨 티어)",
                  summary = "[가죽][어깨][티어]",                                qty = 3 },
                { name = "차원의 부적",
                  summary = "[치][가] - [장신구]\n[사효]",                       qty = 1 },
            }
        end

        for _, s in ipairs(samples) do
            local entry = {
                itemLink     = nil,
                itemLinks    = nil,
                itemName     = s.name,
                texture      = "Interface\\Icons\\INV_Misc_QuestionMark",
                quality      = 4,
                auctionMode  = "auto",
                addedBy      = "uitest",
                auctionCount = 0,
                bossGroup    = 0,
                quantity     = s.qty or 1,
                hasVariant   = false,
                _testSummary = s.summary,
                _isTest      = true,
            }
            table.insert(MR.ItemList, entry)
        end
        if MR.ItemList.SortByDisplayOrder then MR.ItemList.SortByDisplayOrder() end
        if MR.ItemList.FireChange then MR.ItemList.FireChange() end
        MR.Print(string.format(
            "UI 시험 행 %d개 추가 (현실적 케이스). /mr uitest clear 로 제거.",
            #samples), MR.COLOR.gold)
        return
    end

    -- /mr typetest  : subType + equipLoc 모든 조합의 g4 출력 샘플 (번역/매핑 검증)
    if cmd == "typetest" or cmd == "weapontest" then
        local samples = {
            -- 무기: 근접 한손
            { "한손 검",     "INVTYPE_WEAPON",         "WoW: 한손 검 → 도검 매핑" },
            { "한손 검",     "INVTYPE_WEAPONMAINHAND", "주무기 전용" },
            { "한손 검",     "INVTYPE_WEAPONOFFHAND",  "보조무기 전용" },
            { "한손 도끼",   "INVTYPE_WEAPON",         "" },
            { "한손 도끼",   "INVTYPE_WEAPONMAINHAND", "주무기 전용" },
            { "한손 둔기",   "INVTYPE_WEAPON",         "" },
            { "한손 둔기",   "INVTYPE_WEAPONOFFHAND",  "보조무기 전용" },
            { "단검",        "INVTYPE_WEAPON",         "" },
            { "단검",        "INVTYPE_WEAPONMAINHAND", "주무기 전용" },
            { "단검",        "INVTYPE_WEAPONOFFHAND",  "보조무기 전용" },
            { "주먹 무기",   "INVTYPE_WEAPON",         "WoW: 주먹 무기 → 장착 무기 매핑" },
            { "주먹 무기",   "INVTYPE_WEAPONOFFHAND",  "보조무기 전용" },
            { "전투검",      "INVTYPE_WEAPON",         "악마사냥꾼" },
            { "전투검",      "INVTYPE_WEAPONMAINHAND", "주무기 전용" },
            { "전투검",      "INVTYPE_WEAPONOFFHAND",  "보조무기 전용" },
            -- 무기: 근접 양손
            { "양손 검",     "INVTYPE_2HWEAPON",       "WoW: 양손 검 → 도검 매핑" },
            { "양손 도끼",   "INVTYPE_2HWEAPON",       "" },
            { "양손 둔기",   "INVTYPE_2HWEAPON",       "" },
            { "지팡이",      "INVTYPE_2HWEAPON",       "" },
            { "장창",        "INVTYPE_2HWEAPON",       "Polearm" },
            { "낚싯대",      "INVTYPE_2HWEAPON",       "Fishing Pole" },
            -- 무기: 원거리
            { "활",          "INVTYPE_RANGED",         "" },
            { "석궁",        "INVTYPE_RANGEDRIGHT",    "" },
            { "총",          "INVTYPE_RANGEDRIGHT",    "" },
            { "마법봉",      "INVTYPE_RANGEDRIGHT",    "" },
            -- 갑옷
            { "천",          "INVTYPE_HEAD",           "천 머리" },
            { "천",          "INVTYPE_CHEST",          "천 가슴" },
            { "천",          "INVTYPE_ROBE",           "천 로브" },
            { "천",          "INVTYPE_LEGS",           "천 다리" },
            { "가죽",        "INVTYPE_SHOULDER",       "가죽 어깨" },
            { "가죽",        "INVTYPE_HAND",           "가죽 손" },
            { "가죽",        "INVTYPE_FEET",           "가죽 발" },
            { "사슬",        "INVTYPE_WAIST",          "사슬 허리" },
            { "사슬",        "INVTYPE_WRIST",          "사슬 손목" },
            { "판금",        "INVTYPE_HEAD",           "판금 머리" },
            { "판금",        "INVTYPE_CHEST",          "판금 가슴" },
            -- 방패 / 보조
            { "방패",        "INVTYPE_SHIELD",         "방패 (subType=방패=슬롯, 중복 제거됨)" },
            { "기타",        "INVTYPE_HOLDABLE",       "보조 들기 (책/등불 등)" },
            -- 액세서리 (subType 무관, 슬롯만)
            { "기타",        "INVTYPE_NECK",           "목걸이" },
            { "기타",        "INVTYPE_FINGER",         "반지" },
            { "기타",        "INVTYPE_TRINKET",        "장신구" },
            { "기타",        "INVTYPE_CLOAK",          "망토" },
        }
        local function buildG4(subType, equipLoc)
            local isWeapon = equipLoc == "INVTYPE_WEAPON"
                          or equipLoc == "INVTYPE_2HWEAPON"
                          or equipLoc == "INVTYPE_WEAPONMAINHAND"
                          or equipLoc == "INVTYPE_WEAPONOFFHAND"
                          or equipLoc == "INVTYPE_RANGED"
                          or equipLoc == "INVTYPE_RANGEDRIGHT"
            local isShield = equipLoc == "INVTYPE_SHIELD"
            local ARMOR = { ["천"]=1,["가죽"]=1,["사슬"]=1,["판금"]=1,["방패"]=1 }
            local SLOT  = {
                INVTYPE_HEAD="머리", INVTYPE_NECK="목", INVTYPE_SHOULDER="어깨",
                INVTYPE_CHEST="가슴", INVTYPE_ROBE="가슴", INVTYPE_WAIST="허리",
                INVTYPE_LEGS="다리", INVTYPE_FEET="발", INVTYPE_WRIST="손목",
                INVTYPE_HAND="손", INVTYPE_FINGER="반지", INVTYPE_TRINKET="장신구",
                INVTYPE_CLOAK="등", INVTYPE_2HWEAPON="양손", INVTYPE_WEAPON="한손",
                INVTYPE_WEAPONMAINHAND="주무기", INVTYPE_WEAPONOFFHAND="보조무기",
                INVTYPE_RANGED="원거리", INVTYPE_RANGEDRIGHT="원거리",
                INVTYPE_SHIELD="방패", INVTYPE_HOLDABLE="보조",
            }
            local DISPLAY = {
                ["주먹 무기"] = "장착 무기",
                ["한손 검"]   = "한손 도검",
                ["양손 검"]   = "양손 도검",
            }
            local parts = {}
            if isWeapon and subType and subType ~= "" then
                table.insert(parts, "[" .. (DISPLAY[subType] or subType) .. "]")
                if equipLoc == "INVTYPE_WEAPONMAINHAND" then
                    table.insert(parts, "[주무기]")
                elseif equipLoc == "INVTYPE_WEAPONOFFHAND" then
                    table.insert(parts, "[보조무기]")
                end
            elseif subType and ARMOR[subType] then
                table.insert(parts, "[" .. subType .. "]")
            end
            local slot = SLOT[equipLoc]
            if slot and not isWeapon and not isShield then
                table.insert(parts, "[" .. slot .. "]")
            end
            return table.concat(parts, "")
        end
        MR.Print("=== 무기 종류별 출력 샘플 ===", MR.COLOR.gold)
        for _, s in ipairs(samples) do
            local g4 = buildG4(s[1], s[2])
            MR.Print(string.format("%-12s + %-25s → %s   |cff888888%s|r",
                s[1], s[2], g4, s[3]))
        end
        return
    end

    -- /mr broadcastsample (또는 /mr bsample) : 가상 아이템 샘플 송출 미리보기 (실제 아이템 불요)
    if cmd == "broadcastsample" or cmd == "bsample" then
        local EPIC, LEG = "|cffa335ee", "|cffff8000"
        local R = "|r"
        local samples = {
            { desc = "천 머리 (마법사 에픽, 1차 단일)",
              name = EPIC .. "[정신지배자의 두건]" .. R, qty = 1, cat = "",
              summary = "[치명][가속] - [지능] - [천][머리]" },
            { desc = "판금 가슴 (전사 에픽)",
              name = EPIC .. "[강철 격노 가슴갑옷]" .. R, qty = 1, cat = "",
              summary = "[가속][특화] - [힘] - [판금][가슴]" },
            { desc = "가죽 어깨 (도적, 보홈+광피)",
              name = EPIC .. "[그림자칼날 견갑]" .. R, qty = 1, cat = "[보석 홈]",
              summary = "[치명][특화] - [민첩] - [가죽][어깨] - [보석 홈][광역회피]" },
            { desc = "사슬 다리 (수렵인, 파불)",
              name = EPIC .. "[야수왕의 정강이받이]" .. R, qty = 1, cat = "[파괴 불가]",
              summary = "[가속][유연] - [민첩] - [사슬][다리] - [파괴 불가]" },
            { desc = "범용 반지 (1차 다중 + 광피)",
              name = EPIC .. "[황혼군주의 인장]" .. R, qty = 1, cat = "",
              summary = "[치명][특화] - [힘][민첩][지능] - [반지] - [광역회피]" },
            { desc = "범용 목걸이 (1차 다중, 보홈 2개)",
              name = EPIC .. "[고대용의 목걸이]" .. R, qty = 1, cat = "[보석 홈]",
              summary = "[치명][가속][특화][유연] - [힘][민첩][지능] - [목] - [보석 홈 x 2]" },
            { desc = "장신구 (사용 효과)",
              name = EPIC .. "[심장맥동의 장식품]" .. R, qty = 1, cat = "",
              summary = "[치명][특화] - [장신구] - [사용 효과]" },
            { desc = "장신구 (착용 효과)",
              name = EPIC .. "[차원의 부적]" .. R, qty = 1, cat = "",
              summary = "[치명][가속] - [장신구] - [착용 효과]" },
            { desc = "장신구 (사용+착용 둘 다)",
              name = EPIC .. "[황혼의 회중시계]" .. R, qty = 1, cat = "",
              summary = "[가속][특화] - [장신구] - [사용 효과][착용 효과]" },
            { desc = "망토 (다중 1차)",
              name = EPIC .. "[찢어진 그림자 망토]" .. R, qty = 1, cat = "",
              summary = "[가속][유연] - [힘][민첩][지능] - [천][등]" },
            { desc = "한손 도검 (주무기 전용)",
              name = EPIC .. "[황혼의 단검]" .. R, qty = 1, cat = "",
              summary = "[치명][특화] - [민첩][지능] - [한손 도검][주무기]" },
            { desc = "양손 도검",
              name = EPIC .. "[거인 학살자]" .. R, qty = 1, cat = "",
              summary = "[가속][특화] - [힘] - [양손 도검]" },
            { desc = "단검 (보조무기 전용)",
              name = EPIC .. "[그림자칼]" .. R, qty = 1, cat = "",
              summary = "[치명][유연] - [민첩] - [단검][보조무기]" },
            { desc = "전투검 (악사 주무기)",
              name = EPIC .. "[복수자의 전투검]" .. R, qty = 1, cat = "",
              summary = "[가속][유연] - [민첩] - [전투검][주무기]" },
            { desc = "활 (수렵인)",
              name = EPIC .. "[숲의 격노궁]" .. R, qty = 1, cat = "",
              summary = "[치명][특화] - [민첩] - [활]" },
            { desc = "지팡이 (드루이드)",
              name = EPIC .. "[자연의 정수 지팡이]" .. R, qty = 1, cat = "",
              summary = "[치명][가속] - [지능] - [지팡이]" },
            { desc = "방패 (탱커, 다중 낙찰 ×2)",
              name = EPIC .. "[수호자의 방패]" .. R, qty = 2, cat = "",
              summary = "[가속][특화] - [힘] - [방패]" },
            { desc = "최대 옵션 (1차 단일 + 보홈 2 + 광피 + 생흡 + 파불)",
              name = LEG .. "[전설의 모든 옵션 모자]" .. R, qty = 1, cat = "[보석 홈] [파괴 불가]",
              summary = "[치명][가속][특화][유연] - [지능] - [천][머리] - [보석 홈 x 2][광역회피][생기흡수][파괴 불가]" },
            -- 티어 샘플 (현 패치: 재질별 티어. [재질][부위][티어] 형식)
            { desc = "가죽 어깨 티어",
              name = EPIC .. "[포식자의 견갑]" .. R, qty = 1, cat = "",
              summary = "[가죽][어깨][티어]" },
            { desc = "판금 가슴 티어",
              name = EPIC .. "[정복자의 흉갑]" .. R, qty = 1, cat = "",
              summary = "[판금][가슴][티어]" },
            { desc = "천 다리 티어",
              name = EPIC .. "[비전술사의 하의]" .. R, qty = 1, cat = "",
              summary = "[천][다리][티어]" },
            { desc = "사슬 머리 티어",
              name = EPIC .. "[야수왕의 투구]" .. R, qty = 1, cat = "",
              summary = "[사슬][머리][티어]" },
            { desc = "판금 손 티어",
              name = EPIC .. "[심판관의 건틀릿]" .. R, qty = 1, cat = "",
              summary = "[판금][손][티어]" },
            { desc = "전용 무기 (마법사 한손 도검, 티어 아님)",
              name = EPIC .. "[비전술사의 의지]" .. R, qty = 1, cat = "",
              summary = "[치명][특화] - [지능] - [한손 도검][주무기] - [마법사][전용]" },
            { desc = "전용 무기 (수렵인 활, 티어 아님)",
              name = EPIC .. "[야수왕의 사냥활]" .. R, qty = 1, cat = "",
              summary = "[가속][특화] - [민첩] - [활] - [사냥꾼][전용]" },
        }

        MR.Print("=== 가상 송출 샘플 (RAID_WARNING 미리보기) ===", MR.COLOR.gold)
        for _, s in ipairs(samples) do
            MR.Print("|cffaaaaaa- " .. s.desc .. "|r")
            local qtyText = (s.qty > 1) and string.format(" ×%d", s.qty) or ""
            -- 살펴보기 OFF: summary 없음 → catLabel 표시
            local off = string.format("[경매] %s%s%s",
                s.name, qtyText,
                s.cat ~= "" and (" " .. s.cat) or "")
            MR.Print("|cff666666[살펴보기 OFF]|r " .. off)
            -- 살펴보기 ON: summary 있으면 catLabel 생략 (중복 방지)
            local extraOn = (s.summary and s.summary ~= "") and s.summary or s.cat
            local on = string.format("[경매] %s%s%s",
                s.name, qtyText,
                extraOn ~= "" and (" " .. extraOn) or "")
            MR.Print("|cff44ff44[살펴보기 ON ]|r " .. on)
        end
        MR.Print("=== 끝 ===", MR.COLOR.gold)
        return
    end

    -- /mr broadcasttest <itemlink>  : 경매 시작 시 RAID_WARNING 송출 메시지 미리보기 (실제 송출 안 함)
    if cmd == "broadcasttest" then
        local link
        if rest then
            link = rest:match("(|c.-|H.-|h.-|h|r)") or rest:match("(|H.-|h.-|h)")
        end
        if not link then
            MR.Print("사용법: /mr broadcasttest <아이템링크> (Shift+클릭으로 붙여넣기)", MR.COLOR.yellow)
            return
        end

        local cleanLink = (MR.CleanItemLink and MR.CleanItemLink(link)) or link
        local catLabel  = (MR.BuildCategoryLabel and MR.BuildCategoryLabel(link)) or ""
        local summary   = (MR.BuildItemSummary and MR.BuildItemSummary(link, false)) or ""

        local function buildLine(qty, includeSummary)
            local qtyText = (qty > 1) and string.format(" ×%d", qty) or ""
            -- summary 와 catLabel 중복 방지: summary 있으면 catLabel 생략
            local extra
            if includeSummary and summary ~= "" then
                extra = summary
            else
                extra = catLabel
            end
            return string.format("[경매] %s%s%s",
                cleanLink, qtyText,
                extra ~= "" and (" " .. extra) or "")
        end

        MR.Print("=== RAID_WARNING 송출 미리보기 (실제 송출 X) ===", MR.COLOR.gold)
        MR.Print("|cff999999살펴보기 OFF, 1개:|r")
        MR.Print(buildLine(1, false))
        MR.Print("|cff999999살펴보기 OFF, 3개:|r")
        MR.Print(buildLine(3, false))
        if summary ~= "" then
            MR.Print("|cff999999살펴보기 ON, 1개 (요약 포함):|r")
            MR.Print(buildLine(1, true))
            MR.Print("|cff999999살펴보기 ON, 3개:|r")
            MR.Print(buildLine(3, true))
        else
            MR.Print("|cff888888(이 아이템은 요약 정보 없음. 살펴보기 ON 도 동일)|r")
        end
        return
    end

    -- /mr summary <itemlink>  : BuildItemSummary 결과 출력 (테스트용)
    -- 사용법: /mr summary 입력 후 가방의 아이템을 Shift+클릭하면 채팅 입력창에 링크가 들어가니
    -- 그 상태로 엔터. rest 에 raw 아이템 링크 텍스트가 들어옴.
    if cmd == "summary" then
        -- 색상 escape(|cff... 또는 |cnIQ4:) 포함한 전체 링크 캡처. 색상 빠지면 채팅에서
        -- 등급별 색상(에픽 보라색 등)이 표시되지 않음.
        local link
        if rest then
            link = rest:match("(|c.-|H.-|h.-|h|r)")  -- 색상 포함
            if not link then
                link = rest:match("(|H.-|h.-|h)")    -- 색상 없는 경우 폴백
            end
        end
        if not link then
            MR.Print("사용법: /mr summary <아이템링크> (Shift+클릭으로 링크 붙여넣기)", MR.COLOR.yellow)
            return
        end
        if not MR.BuildItemSummary then
            MR.Print("BuildItemSummary 함수 없음", MR.COLOR.red)
            return
        end
        local summary = MR.BuildItemSummary(link) or ""
        if summary == "" then
            MR.Print("요약 정보 없음 (장비가 아니거나 캐시 미로드)", MR.COLOR.gray)
        else
            MR.Print(link .. "  " .. summary)
        end
        return
    end

    -- /mr test : 사용 가능한 테스트/디버그 명령어 전체 목록 출력
    if cmd == "test" then
        local G, W, S = MR.COLOR.gold, MR.COLOR.white, "|cff888888"
        MR.Print("=== MimRaid 테스트 명령어 ===", G)
        MR.Print("|cffaaddff[경매 아이템 목록]|r", W)
        MR.Print("  /mr uitest          - 경매 대기 탭 샘플 아이템 추가", W)
        MR.Print("  /mr uitest stress   - 옵션 많은 행 추가 (2줄 fallback 검증)", W)
        MR.Print("  /mr uitest clear    - 테스트 아이템 전체 제거", W)
        MR.Print("|cffaaddff[판매완료 탭]|r", W)
        MR.Print("  /mr tradetest           - 판매완료 탭 샘플 데이터 추가 (DONE/PARTIAL/PENDING 혼합)", W)
        MR.Print("  /mr tradetest clear     - TradeLog 전체 초기화", W)
        MR.Print("|cffaaddff[T-Raid 식 검증 / 거래취소 audit]|r", W)
        MR.Print("  /mr audittest           - 골드 분배 탭 검증 패널용 audit 더미 추가 (complete + cancelled)", W)
        MR.Print("  /mr audittest match     - 일반 DONE entry 와 정합 OK 가 되는 audit 더미", W)
        MR.Print("  /mr audittest clear     - audit entry 만 제거", W)
        MR.Print("|cffaaddff[헤더 던전이름 표시 길이 테스트]|r", W)
        MR.Print("  /mr mplustest           - 짧음/보통/긴 던전명 + M+단수 시나리오 순환 표시 (잘림 확인)", W)
        MR.Print("  /mr mplustest <텍스트>  - 임의 텍스트를 mplusLine 에 즉시 표시", W)
        MR.Print("|cffaaddff[거래 완료 기록 탭]|r", W)
        MR.Print("  /mr historytest       - 거래 완료 기록 탭 샘플 세션 추가 (어제+오늘 2개)", W)
        MR.Print("  /mr historytest clear - 거래 완료 기록 전체 초기화", W)
        MR.Print("|cffaaddff[거래 귓속말 기록]|r", W)
        MR.Print("  /mr tatest <이름> <받은골드> [준골드]  - 골드만 오간 거래 귓속말 시뮬", W)
        MR.Print("  예) /mr tatest 김철수 50000", W)
        MR.Print("|cffaaddff[사운드]|r", W)
        MR.Print("  /mr soundtest       - 거래 관련 사운드 순서대로 재생 (음량 확인용)", W)
        MR.Print("  /mr snd <id>        - 사운드 ID 직접 재생 테스트", W)
        MR.Print("|cffaaddff[경매 송출 미리보기]|r", W)
        MR.Print("  /mr broadcasttest <링크>  - RAID_WARNING 메시지 미리보기 (실제 송출 X)", W)
        MR.Print("  /mr bsample               - 가상 아이템으로 송출 미리보기", W)
        MR.Print("|cffaaddff[아이템 정보]|r", W)
        MR.Print("  /mr summary <링크>  - 아이템 요약(스탯/보석홈 등) 출력", W)
        MR.Print("  /mr typetest        - subType+equipLoc 카테고리 매핑 샘플 출력", W)
        MR.Print("|cffaaddff[기타]|r", W)
        MR.Print("  /mr debug [on|off]  - 디버그 로그 토글", W)
        MR.Print("  /mr calapi          - C_Calendar 함수 목록 출력", W)
        MR.Print(S .. "링크 입력: 채팅창에 /mr <명령어> 입력 후 가방 아이템 Shift+클릭|r", W)
        return
    end

    -- /mr soundtest : 거래 관련 사운드 순서대로 재생하여 음량 확인
    if cmd == "soundtest" then
        -- { delay(초), id, channel, label }
        -- SOUND_TRADE_DONE=558132, SOUND_MONEY_SHORT=539226, SOUND_CORRECT=3164885
        local sounds = {
            { 0.0,  MR.cfg.soundSold,         "Dialog",  "낙찰 완료 (soundSold="   .. tostring(MR.cfg.soundSold)         .. ")" },
            { 1.5,  558132,                   "Master",  "거래 완료 (SOUND_TRADE_DONE=558132, 0.4초 지연 포함)" },
            { 3.5,  539226,                   "Master",  "금액 알림 (SOUND_MONEY_SHORT=539226)" },
            { 5.0,  MR.cfg.soundFailedAlert,  "Master",  "안팔린 아이템 경고 (soundFailedAlert=" .. tostring(MR.cfg.soundFailedAlert) .. ")" },
        }
        MR.Print("사운드 테스트 시작 — 각 사운드 사이 약 1.5~2초 간격", MR.COLOR.gold)
        for _, s in ipairs(sounds) do
            local delay, id, ch, label = s[1], s[2], s[3], s[4]
            C_Timer.After(delay, function()
                MR.Print(label, MR.COLOR.gray)
                if type(id) == "number" and id > 0 then
                    PlaySoundFile(id, ch)
                end
            end)
        end
        return
    end

    -- /mr tatest <이름> <받은골드> [준골드] : TradeAnnounce 귓속말 시뮬레이션
    if cmd == "tatest" then
        local name, got, gave = rest:match("^(%S+)%s*(%d*)%s*(%d*)$")
        if MR.TradeAnnounce and MR.TradeAnnounce.Test then
            MR.TradeAnnounce.Test(name, tonumber(got), tonumber(gave))
        else
            MR.Print("TradeAnnounce 모듈 없음", MR.COLOR.red)
        end
        return
    end

    -- /mr tradetest        : 판매완료 탭 UI 테스트 데이터 추가
    -- /mr tradetest clear  : 테스트 데이터 포함 전체 TradeLog 초기화
    if cmd == "tradetest" then
        local mode = (rest or ""):lower():gsub("^%s*(.-)%s*$", "%1")
        if mode == "clear" then
            MR.TradeLog.Clear()
            MR.Print("TradeLog 초기화 완료", MR.COLOR.gray)
            return
        end

        local function add(name, tex, winner, bid, bossGroup, paid)
            local i = MR.TradeLog.Add(nil, name, tex, winner, bid, bossGroup)
            if paid then MR.TradeLog.UpdateTrade(i, paid) end
        end

        -- 1보스
        add("폭풍의 칼날",      "Interface\\Icons\\INV_Sword_04",        "김철수",  5000, 1, 5000)   -- DONE
        add("태양의 두손검",    "Interface\\Icons\\INV_Sword_2H_06",     "이영희",  3000, 1, 3500)   -- DONE 초과납부
        add("달빛 지팡이",      "Interface\\Icons\\INV_Staff_13",        "박민준",  4000, 1, 2000)   -- PARTIAL
        add("영원의 반지",      "Interface\\Icons\\INV_Jewelry_Ring_01", "최수진",  2500, 1, nil)    -- PENDING
        -- 2보스
        add("심연의 가슴갑옷",  "Interface\\Icons\\INV_Chest_Plate02",   "정하나",  8000, 2, 8000)   -- DONE
        add("용의 투구",        "Interface\\Icons\\INV_Helmet_08",       "강도윤", 12000, 2, nil)    -- PENDING

        MR.Print(string.format(
            "TradeLog 테스트 데이터 추가 완료 (%d개)  |cff888888초기화: /mr tradetest clear|r",
            #MR.TradeLog), MR.COLOR.gold)
        return
    end

    -- /mr mplustest            : 헤더 mplusLine 던전이름 길이 시나리오 순환 표시 (잘림 검증)
    -- /mr mplustest <텍스트>   : 임의 텍스트를 mplusLine 에 즉시 표시 (수동 검증)
    if cmd == "mplustest" then
        if not MR._mplusLine then
            MR.Print("mplusLine 미생성 — 메인 프레임 한 번 열어주세요.", MR.COLOR.red)
            return
        end
        local arg = (rest or ""):gsub("^%s*(.-)%s*$", "%1")
        if arg ~= "" then
            MR._mplusLine:SetText(arg)
            MR.Print("mplusLine ← " .. arg, MR.COLOR.gold)
            return
        end

        -- 시나리오: 짧은 던전부터 점진적으로 긴 던전 + M+ 단수까지
        local scenarios = {
            "[현재 던전] 어둠길",
            "[현재 던전] 어둠길 +14 단",
            "[현재 던전] 사론의 구덩이",
            "[현재 던전] 사론의 구덩이 +14 단",
            "[현재 던전] 맨소러스의 권능",
            "[현재 던전] 맨소러스의 권능 +14 단",
            "[현재 던전] 꿈의 희망 아미드랏실",
            "[현재 던전] 어둠의 도가니 아베루스 +14 단",
            "[현재 던전] 어둠의 도가니 아베루스 +99 단",   -- 단수 폭 확장 케이스
            "[현재 던전] 매우긴이름의가상던전이름테스트 +14 단",
        }
        MR.Print(string.format(
            "mplusLine 길이 테스트 시작 (1.5초 간격, %d 시나리오) — 잘림 확인하세요",
            #scenarios), MR.COLOR.gold)
        for i, txt in ipairs(scenarios) do
            local delay = (i - 1) * 1.5
            C_Timer.After(delay, function()
                if MR._mplusLine then
                    MR._mplusLine:SetText(txt)
                    MR.Print(string.format("  [%d/%d] %s", i, #scenarios, txt), MR.COLOR.gray)
                end
            end)
        end
        -- 종료 후 안내
        C_Timer.After(#scenarios * 1.5 + 0.5, function()
            MR.Print("mplusLine 테스트 종료 — 인스턴스 이동/이벤트로 자동 갱신됨", MR.COLOR.gray)
        end)
        return
    end

    -- /mr audittest          : 골드 분배 탭 T-Raid 식 검증 패널 + 거래취소 토글 확인용 더미
    -- /mr audittest match    : 일반 tradetest 의 paidTotal 과 정확히 매칭되는 audit (정합 OK)
    -- /mr audittest clear    : audit entry (tradeAuditType ~= nil) 만 제거
    if cmd == "audittest" then
        local mode = (rest or ""):lower():gsub("^%s*(.-)%s*$", "%1")
        if mode == "clear" then
            local removed = 0
            for i = #MR.TradeLog, 1, -1 do
                if MR.TradeLog[i].tradeAuditType ~= nil then
                    MR.TradeLog.Remove(i)
                    removed = removed + 1
                end
            end
            MR.Print(string.format("audit entry %d개 제거됨", removed), MR.COLOR.gray)
            return
        end

        -- audit entry 1건 추가 헬퍼.
        --   result: "complete" | "cancelled"
        --   recvG / sentG: 골드 단위 (10000 곱해서 copper 저장)
        --   recvItems / sentItems: { itemLink, ... } 리스트 — 컬럼 분리 표시용
        local function addAudit(result, target, recvG, sentG, recvItems, sentItems)
            local who = target or "테스터"
            local prefix = (result == "cancelled") and "[거래취소]" or "[거래완료]"

            local idx = MR.TradeLog.Add(nil, prefix, nil, who, 0, 0)
            local e = MR.TradeLog[idx]
            if e then
                e.tradeReceivedCopper = (recvG or 0) * 10000
                e.tradeSentCopper     = (sentG or 0) * 10000
                e.tradeAuditType      = result
                e.tradeReceivedItems  = {}
                for _, link in ipairs(recvItems or {}) do
                    table.insert(e.tradeReceivedItems, { link = link, count = 1 })
                end
                e.tradeSentItems = {}
                for _, link in ipairs(sentItems or {}) do
                    table.insert(e.tradeSentItems, { link = link, count = 1 })
                end
            end
            MR.TradeLog.UpdateTrade(idx, 0)   -- DONE
            return idx
        end

        -- 샘플 아이템 링크 (테스트용 가상 — 실제 아이템 아니어도 nameText 컬럼 표시는 됨)
        local sampleChest = "|cff0070dd[샘플 가슴갑옷]|r"
        local sampleSword = "|cffa335ee[샘플 명검]|r"
        local sampleRing  = "|cff0070dd[샘플 반지]|r"

        if mode == "match" then
            -- "정합 OK" 시나리오:
            -- /mr tradetest 가 만드는 DONE 합 = 5000+3500+8000 = 16500 (PARTIAL 2000 합치면 18500)
            -- audit 의 (수령 - 송금) 도 18500 으로 맞춤
            addAudit("complete", "김철수",  5000, 0)
            addAudit("complete", "이영희",  3500, 0)
            addAudit("complete", "박민준",  2000, 0)   -- PARTIAL 분
            addAudit("complete", "정하나",  8000, 0)
            addAudit("complete", "공대원A", 1000, 1000)   -- 일반 잡거래 (왔다갔다, 순0)
            MR.Print(string.format(
                "audit (match) 추가 — tradetest 와 함께 사용 시 '정합 OK' 표시  |cff888888초기화: /mr audittest clear|r"),
                MR.COLOR.gold)
            return
        end

        -- 기본 모드: 누락 의심 / 거래취소 표시 + 컬럼 분리 확인용
        addAudit("complete", "김철수",   50000, 0)
        addAudit("complete", "이영희",   30000, 0)
        addAudit("complete", "박민준",   25000, 0,     nil, { sampleChest })   -- 아이템도 전달
        addAudit("complete", "정하나",   0,     10000)                          -- 분배 송금
        addAudit("complete", "공대원B",  5000,  1000,  { sampleSword },  { sampleRing })  -- 아이템 양방향
        -- 거래취소 (debugMode 켰을 때만 판매완료 탭에 표시)
        addAudit("cancelled", "취소자A", 0,     0)
        addAudit("cancelled", "취소자B", 5000,  0)   -- 수락 직전 취소된 케이스

        local debugOn = MR.cfg and MR.cfg.debugMode
        MR.Print(string.format(
            "audit 더미 7건 추가 — 검증 패널 확인  (수령 11.0만 - 송금 1.1만 = 순수익 9.9만)"),
            MR.COLOR.gold)
        MR.Print(string.format(
            "  거래취소 2건: %s (debugMode=%s)  |cff888888토글: /mr debug on / off|r",
            debugOn and "|cff44ff44판매완료 탭에 표시됨|r" or "|cff888888판매완료 탭에 숨겨짐|r",
            tostring(debugOn)), MR.COLOR.gray)
        MR.Print("  |cff888888초기화: /mr audittest clear|r", MR.COLOR.gray)
        return
    end

    -- /mr historytest        : 거래 완료 기록 탭 샘플 세션 추가
    -- /mr historytest clear  : 거래 완료 기록 전체 초기화
    if cmd == "historytest" then
        local mode = (rest or ""):lower():gsub("^%s*(.-)%s*$", "%1")
        if mode == "clear" then
            local history = MR.RaidHistory.GetAll()
            for i = #history, 1, -1 do history[i] = nil end
            if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end
            MR.Print("거래 완료 기록 초기화 완료", MR.COLOR.gray)
            return
        end

        local now = time()
        local history = MR.RaidHistory.GetAll()

        -- 세션1: 어제 레이드 (아토다크론) — 아이템 판매 + 분배 완료
        local s1Start = now - 86400 - 7560  -- 어제 2시간 6분 전
        local s1End   = now - 86400
        table.insert(history, {
            id          = s1Start,
            date        = date("%Y-%m-%d", s1Start),
            time        = date("%H:%M", s1Start),
            startTime   = s1Start,
            endTime     = s1End,
            instance    = "아토다크론",
            memberCount = 10,
            totalGold   = 16000,
            perPerson   = 1600,
            bossNames   = { [1] = "에레크투스", [2] = "아토다크론" },
            sales = {
                { time = s1Start+1800, itemName = "폭풍의 칼날",    winner = "김철수", bid = 5000, paidGold = 5000, bossGroup = 1 },
                { time = s1Start+2100, itemName = "태양의 두손검",  winner = "이영희", bid = 3000, paidGold = 3500, bossGroup = 1 },
                { time = s1Start+4800, itemName = "심연의 가슴갑옷",winner = "정하나", bid = 8000, paidGold = 8000, bossGroup = 2 },
            },
            distributions = {
                { time = s1End+120, target = "김철수", gold = 1600, status = "done" },
                { time = s1End+180, target = "이영희", gold = 1600, status = "done" },
                { time = s1End+240, target = "박민준", gold = 1600, status = "done" },
                { time = s1End+300, target = "최수진", gold = 1600, status = "done" },
                { time = s1End+360, target = "정하나", gold = 1600, status = "done" },
                { time = s1End+420, target = "강도윤", gold = 1600, status = "done" },
                { time = s1End+480, target = "윤지민", gold = 1600, status = "done" },
                { time = s1End+540, target = "한승우", gold = 1600, status = "done" },
                { time = s1End+600, target = "오민지", gold = 1600, status = "done" },
                { time = s1End+660, target = "서재원", gold = 1600, status = "done" },
            },
        })

        -- 세션2: 오늘 레이드 (볼라투스) — 아이템 판매 + 골드만 기여한 거래 포함
        local s2Start = now - 5400  -- 1시간 30분 전
        table.insert(history, {
            id          = s2Start,
            date        = date("%Y-%m-%d", s2Start),
            time        = date("%H:%M", s2Start),
            startTime   = s2Start,
            endTime     = now,
            instance    = "볼라투스: 역동하는 심층부",
            memberCount = 12,
            totalGold   = 14000,
            perPerson   = 1166,
            bossNames   = { [1] = "칸도리우스", [2] = "역동하는 심층부" },
            sales = {
                { time = s2Start+900,  itemName = "달빛 지팡이", winner = "박민준", bid = 4000, paidGold = 4000, bossGroup = 1 },
                { time = s2Start+1800, itemName = "용의 투구",   winner = "강도윤", bid = 8000, paidGold = 8000, bossGroup = 2 },
                { time = s2Start+2400, itemName = "영원의 반지", winner = "최수진", bid = 2000, paidGold = 2000, bossGroup = 2 },
            },
            distributions = {},
            -- 골드만 기여한 거래 (아이템 없이 골드 납부)
            contributions = {
                { time = s2Start+3000, source = "이영희", gold = 5000 },
            },
        })

        if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end
        MR.Print(string.format(
            "거래 완료 기록 테스트 데이터 추가 완료 (%d개)  |cff888888초기화: /mr historytest clear|r",
            #history), MR.COLOR.gold)
        return
    end

    MR.Print("알 수 없는 명령: " .. args, MR.COLOR.yellow)
end

--------------------------------------------------------------------------------
-- 메인 UI 토글
--------------------------------------------------------------------------------
function MR.ToggleMainFrame()
    local f = _G["MimRaidMainFrame"]
    if not f then
        MR.Print("UI 프레임을 찾을 수 없습니다.", MR.COLOR.red)
        return
    end
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

--------------------------------------------------------------------------------
-- 훅: 거래창 (TRADE_SHOW / TRADE_CLOSED 이벤트 기반 — TradeFrame OnDemand 대응)
-- 거래 완료 판정은 MR.Auction.OnTradeClosed 경로로 일원화
-- (AcceptTrade hooksecurefunc은 현재 WoW 빌드에서 신뢰할 수 없음)
--------------------------------------------------------------------------------
