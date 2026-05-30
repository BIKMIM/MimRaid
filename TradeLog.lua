--------------------------------------------------------------------------------
-- MimRaid - TradeLog.lua
-- 낙찰 기록 관리 및 정산 계산
--------------------------------------------------------------------------------

local MR = MimRaid

--------------------------------------------------------------------------------
-- 낙찰 기록 목록
-- log[n] = {
--   itemLink  : string   아이템 링크
--   itemName  : string   아이템 이름
--   texture   : string   아이콘 텍스처
--   winner    : string   낙찰자 이름 (realm 포함 가능)
--   bid       : number   낙찰 금액 (골드 정수)
--   state     : string   MR.TRADE_STATE.*
--   paidGold  : number   실제 거래된 골드 (부분 납부 포함)
--   timestamp : number   os.time() 기준
-- }
--------------------------------------------------------------------------------
MR.TradeLog = {}

-- 목록 변경 콜백
local onChangeCallbacks = {}

function MR.TradeLog.OnChange(fn)
    table.insert(onChangeCallbacks, fn)
end

local function fireChange()
    for _, fn in ipairs(onChangeCallbacks) do
        pcall(fn)
    end
end

-- 외부에서 강제로 콜백 발동 (예: 설정 변경 후 UI 즉시 갱신 — debug 토글 등)
function MR.TradeLog.FireChange()
    fireChange()
end

--------------------------------------------------------------------------------
-- 낙찰 기록 추가
--------------------------------------------------------------------------------
function MR.TradeLog.Add(itemLink, itemName, texture, winner, bid, bossGroup)
    local entry = {
        itemLink  = itemLink,
        itemName  = itemName  or "?",
        texture   = texture,
        winner    = winner    or "?",
        bid       = bid       or 0,
        state     = MR.TRADE_STATE.PENDING,
        paidGold  = 0,
        timestamp = time(),
        bossGroup = bossGroup or 0,
        bossName  = (MR.ItemList and MR.ItemList.bossNames and bossGroup
                     and MR.ItemList.bossNames[bossGroup]) or nil,
    }
    table.insert(MR.TradeLog, entry)
    MR.TradeLog.Save()
    fireChange()
    return #MR.TradeLog
end

--------------------------------------------------------------------------------
-- 거래 상태 업데이트
-- paidGold: 실제 거래창에서 확인된 골드
--------------------------------------------------------------------------------
function MR.TradeLog.UpdateTrade(index, paidGold)
    local entry = MR.TradeLog[index]
    if not entry then return end

    entry.paidGold = paidGold or 0

    if entry.paidGold >= entry.bid then
        entry.state = MR.TRADE_STATE.DONE
    elseif entry.paidGold > 0 then
        entry.state = MR.TRADE_STATE.PARTIAL
    else
        entry.state = MR.TRADE_STATE.PENDING
    end

    MR.TradeLog.Save()
    fireChange()
end

-- 낙찰자 이름으로 가장 최근 미완료(PENDING/PARTIAL) 기록 찾기
function MR.TradeLog.FindPending(winnerName)
    for i = #MR.TradeLog, 1, -1 do
        local e = MR.TradeLog[i]
        if MR.NamesMatch(e.winner, winnerName)
            and (e.state == MR.TRADE_STATE.PENDING or e.state == MR.TRADE_STATE.PARTIAL) then
            return i, e
        end
    end
    return nil, nil
end

--------------------------------------------------------------------------------
-- 수동 상태 변경 (UI에서 직접 수정 시)
--------------------------------------------------------------------------------
function MR.TradeLog.SetState(index, state)
    local entry = MR.TradeLog[index]
    if not entry then return end
    if not MR.TRADE_STATE[state] then return end
    entry.state = state
    MR.TradeLog.Save()
    fireChange()
end

--------------------------------------------------------------------------------
-- 기록 삭제
--------------------------------------------------------------------------------
function MR.TradeLog.Remove(index)
    if not MR.TradeLog[index] then return false end
    table.remove(MR.TradeLog, index)
    MR.TradeLog.Save()
    fireChange()
    return true
end

function MR.TradeLog.Clear()
    -- wipe() 는 메서드(Save/Add 등)까지 모두 지우므로 숫자 인덱스만 제거
    for i = #MR.TradeLog, 1, -1 do MR.TradeLog[i] = nil end
    MR.TradeLog.Save()
    fireChange()
end

--------------------------------------------------------------------------------
-- 정산 계산
-- totalGold  : 총 골드 (입력값, 기본은 낙찰 합계)
-- memberCount: 분배 인원
-- 반환: { perPerson, totalGold, memberCount, remainder }
--------------------------------------------------------------------------------
function MR.TradeLog.CalcSettlement(memberCount, totalGoldOverride)
    local totalGold = totalGoldOverride

    if not totalGold then
        totalGold = 0
        for _, entry in ipairs(MR.TradeLog) do
            if entry.state == MR.TRADE_STATE.DONE then
                totalGold = totalGold + entry.paidGold
            elseif entry.state == MR.TRADE_STATE.PARTIAL then
                totalGold = totalGold + entry.paidGold
            end
        end
    end

    memberCount = memberCount or 1
    if memberCount < 1 then memberCount = 1 end

    local perPerson  = math.floor(totalGold / memberCount)
    local remainder  = totalGold - (perPerson * memberCount)

    return {
        perPerson   = perPerson,
        totalGold   = totalGold,
        memberCount = memberCount,
        remainder   = remainder,
    }
end

-- 정산 공지 문자열 생성
function MR.TradeLog.BuildSettlementMsg(result)
    return string.format(
        "[MimRaid 골드 분배] 총 %s | %d명 | 1인당 %s",
        MR.FormatGold(result.totalGold),
        result.memberCount,
        MR.FormatGold(result.perPerson)
    )
end

--------------------------------------------------------------------------------
-- 요약 통계
--------------------------------------------------------------------------------
function MR.TradeLog.GetSummary()
    local total, done, partial, pending = 0, 0, 0, 0
    local totalGold = 0

    for _, entry in ipairs(MR.TradeLog) do
        -- "[거래완료]"/"[거래취소]" 접두 = 감사용 요약 (bid=0/paidGold=0). 판매 통계 제외.
        local isAuditSummary = entry.tradeAuditType ~= nil   -- 1.0.92+ 신규 필드
            or (entry.itemName and type(entry.itemName) == "string"
                and (entry.itemName:find("^%[거래완료%]")
                     or entry.itemName:find("^%[거래취소%]")))
        if not isAuditSummary then
            total = total + 1
            if entry.state == MR.TRADE_STATE.DONE then
                done = done + 1
                totalGold = totalGold + entry.paidGold
            elseif entry.state == MR.TRADE_STATE.PARTIAL then
                partial = partial + 1
                totalGold = totalGold + entry.paidGold
            else
                pending = pending + 1
            end
        end
    end

    return { total = total, done = done, partial = partial, pending = pending, totalGold = totalGold }
end

--------------------------------------------------------------------------------
-- SavedVariables 저장/로드
--------------------------------------------------------------------------------
function MR.TradeLog.Save()
    if not MimRaidDB then MimRaidDB = {} end
    local cdata = MR.GetCharData()
    cdata.tradeLog = {}
    for i, entry in ipairs(MR.TradeLog) do
        cdata.tradeLog[i] = {
            itemLink  = entry.itemLink,
            itemName  = entry.itemName,
            texture   = entry.texture,
            winner    = entry.winner,
            bid       = entry.bid,
            state     = entry.state,
            paidGold  = entry.paidGold,
            timestamp = entry.timestamp,
            bossGroup = entry.bossGroup or 0,
            -- T-Raid 식 검증용 audit 필드 (v1.0.91+):
            --   tradeAuditType="complete"|"cancelled"|"distribution", tradeReceivedCopper, tradeSentCopper
            --   v1.0.92+: 컬럼 분리 표시를 위한 raw 아이템 링크 리스트
            --   v0.9.105+: tradeOrigin="auction"|"manual" (거래기록 탭 라벨 표시용)
            --   v0.9.105+: distributionGold (분배 송금 entry 의 실제 송금 금액)
            tradeAuditType      = entry.tradeAuditType,
            tradeReceivedCopper = entry.tradeReceivedCopper,
            tradeSentCopper     = entry.tradeSentCopper,
            tradeReceivedItems  = entry.tradeReceivedItems,
            tradeSentItems      = entry.tradeSentItems,
            tradeOrigin         = entry.tradeOrigin,
            distributionGold    = entry.distributionGold,
        }
    end
end

function MR.TradeLog.Load()
    if not MimRaidDB then return end
    local cdata = MR.GetCharData()
    if not cdata.tradeLog then return end
    -- wipe() 는 메서드까지 지우므로 숫자 인덱스만 제거
    for i = #MR.TradeLog, 1, -1 do MR.TradeLog[i] = nil end
    for _, entry in ipairs(cdata.tradeLog) do
        table.insert(MR.TradeLog, entry)
    end
    if #MR.TradeLog > 0 then
        MR.Debug("TradeLog.Load:", #MR.TradeLog, "records restored")
    end
    -- 로드 후 UI 즉시 갱신
    fireChange()
end

--------------------------------------------------------------------------------
-- 레이드 타이머
-- 시작 조건 (둘 중 하나):
--   1. 레이드 인스턴스 내 첫 전투 진입 시 자동 시작 (PLAYER_REGEN_DISABLED)
--   2. UI 버튼으로 수동 시작
-- 한 번 시작하면 리셋 없음 - 레이드 전체 소요시간 추적용
--------------------------------------------------------------------------------
MR.RaidTimer = {
    startTime     = nil,   -- 시작 timestamp (nil = 미시작)
    frozenElapsed = nil,   -- 정지 시 저장된 경과 초 (nil = 정지 아님)
    instanceName  = nil,   -- 시작 시점의 인스턴스 이름 (히스토리 저장에 사용)
}

-- 타이머 시작 (이미 시작된 경우 무시)
function MR.RaidTimer.Start(isManual)
    if MR.RaidTimer.startTime or MR.RaidTimer.frozenElapsed then
        if isManual then
            MR.Print("레이드 타이머가 이미 시작되었습니다. (" .. MR.RaidTimer.Format() .. " 경과)", MR.COLOR.gray)
        end
        return false
    end

    MR.RaidTimer.startTime    = time()
    MR.RaidTimer.instanceName = GetInstanceInfo()
    if MimRaidDB then
        local cdata = MR.GetCharData()
        cdata.raidStartTime    = MR.RaidTimer.startTime
        cdata.raidInstanceName = MR.RaidTimer.instanceName
    end

    if isManual then
        MR.Print("레이드 타이머 시작!", MR.COLOR.green)
    else
        MR.Debug("RaidTimer: auto-started on first combat, instance=" ..
            tostring(MR.RaidTimer.instanceName))
    end
    return true
end

-- 시작 시점의 인스턴스 이름 (미시작이면 nil)
function MR.RaidTimer.GetInstanceName()
    return MR.RaidTimer.instanceName
end

-- 자동 시작 조건 확인 (레이드 / 5인 인던 / 시나리오(Delve 포함) + 전투 진입)
-- MimRaid.lua의 PLAYER_REGEN_DISABLED 이벤트에서 호출
local TIMER_INSTANCE_TYPES = { raid = true, party = true, scenario = true }
function MR.RaidTimer.TryAutoStart()
    if MR.RaidTimer.startTime then return end           -- 이미 시작됨
    if not MR.cfg.raidTimerAutoStart then return end    -- 자동시작 비활성

    local _, instanceType = GetInstanceInfo()
    if not TIMER_INSTANCE_TYPES[instanceType] then return end

    MR.RaidTimer.Start(false)
end

-- 경과 시간 반환 (초 단위, 미시작이면 nil)
function MR.RaidTimer.GetElapsed()
    if MR.RaidTimer.frozenElapsed then
        return MR.RaidTimer.frozenElapsed
    end
    if not MR.RaidTimer.startTime then return nil end
    return time() - MR.RaidTimer.startTime
end

-- 타이머 정지 (경과 시간 보존, 표시만 멈춤)
function MR.RaidTimer.Freeze()
    local elapsed = MR.RaidTimer.GetElapsed()
    if not elapsed then return end
    MR.RaidTimer.frozenElapsed = elapsed
    MR.RaidTimer.startTime = nil
    if MimRaidDB then
        local cdata = MR.GetCharData()
        cdata.raidFrozenElapsed = elapsed
        cdata.raidStartTime = nil
    end
end

-- 경과 시간 포맷 문자열 ("1시간 23분 45초" / "23분 45초")
function MR.RaidTimer.Format()
    local elapsed = MR.RaidTimer.GetElapsed()
    if not elapsed then return "측정 안됨" end

    local h = math.floor(elapsed / 3600)
    local m = math.floor((elapsed % 3600) / 60)
    local s = elapsed % 60

    if h > 0 then
        return string.format("%d시간 %d분 %d초", h, m, s)
    else
        return string.format("%d분 %d초", m, s)
    end
end

-- 시작 timestamp 반환 (정지 중이면 현재-경과로 역산)
function MR.RaidTimer.GetStartTime()
    if MR.RaidTimer.startTime then
        return MR.RaidTimer.startTime
    end
    if MR.RaidTimer.frozenElapsed then
        return time() - MR.RaidTimer.frozenElapsed
    end
    return nil
end

-- 출발 시각 포맷 ("2026년 4월 19일 일요일 오후 2시 30분 5초")
local WDAY_KO = { "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일" }
function MR.RaidTimer.FormatStart()
    local t = MR.RaidTimer.GetStartTime()
    if not t then return nil end
    local d = date("*t", t)
    local ampm = (d.hour < 12) and "오전" or "오후"
    local h12  = d.hour % 12
    if h12 == 0 then h12 = 12 end
    local wday = WDAY_KO[d.wday] or ""
    return string.format("%d년 %d월 %d일 %s %s %d시 %d분 %d초",
        d.year, d.month, d.day, wday, ampm, h12, d.min, d.sec)
end

-- 타이머 완전 초기화
-- 분배 인원/조정 금액/끝자리 정리는 사용자가 수동으로 관리 → 여기서 안 건드림.
function MR.RaidTimer.Reset()
    MR.RaidTimer.startTime     = nil
    MR.RaidTimer.frozenElapsed = nil
    MR.RaidTimer.instanceName  = nil
    if MimRaidDB then
        local cdata = MR.GetCharData()
        cdata.raidStartTime     = nil
        cdata.raidFrozenElapsed = nil
        cdata.raidInstanceName  = nil
    end
end

-- SavedVariables에서 복원 (캐릭터별 파티션)
function MR.RaidTimer.Load()
    if not MimRaidDB then return end
    local cdata = MR.GetCharData()
    if cdata.raidStartTime then
        MR.RaidTimer.startTime = cdata.raidStartTime
    end
    if cdata.raidFrozenElapsed then
        MR.RaidTimer.frozenElapsed = cdata.raidFrozenElapsed
    end
    if cdata.raidInstanceName then
        MR.RaidTimer.instanceName = cdata.raidInstanceName
    end
end
