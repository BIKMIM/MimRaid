--------------------------------------------------------------------------------
-- MimRaid - RaidHistory.lua
-- 거래 기록 영구 저장 (캐릭터별 파티션: MimRaidDB.chars[<charKey>].history)
-- 저장 위치: WTF\Account\계정명\SavedVariables\MimRaid.lua
-- 애드온 업데이트/재설치 후에도 기록 유지됨
--------------------------------------------------------------------------------

---@diagnostic disable: undefined-global

local MR = MimRaid

MR.RaidHistory = {}

-- 현재 캐릭터의 history 테이블 (없으면 생성)
local function getHistory()
    local cdata = MR.GetCharData()
    if not cdata.history then cdata.history = {} end
    return cdata.history
end

--------------------------------------------------------------------------------
-- 초기화 (ADDON_LOADED에서 호출)
--------------------------------------------------------------------------------
function MR.RaidHistory.Load()
    if not MimRaidDB then MimRaidDB = {} end
    local history = getHistory()

    -- 마이그레이션: 옛 버전 buildRecord 가 모든 TradeLog DONE 을 포함해 저장 → 다른 세션
    -- 거래(예: "[골드 거래] 보라색흑마법사 1.3만골 00:58") 가 여러 세션 기록에 섞임.
    -- 각 record 의 sales 를 자체 startTime~endTime 범위로 재필터링 + totalGold 재조정.
    local cleaned = 0
    for _, record in ipairs(history) do
        if record.sales and record.startTime then
            local startTime = record.startTime
            local endTime   = record.endTime or (startTime + 86400)  -- 폴백: +24h
            local filtered = {}
            local removedGold = 0
            for _, sale in ipairs(record.sales) do
                if sale.time and sale.time >= startTime and sale.time <= endTime then
                    table.insert(filtered, sale)
                else
                    removedGold = removedGold + (sale.paidGold or 0)
                end
            end
            if removedGold > 0 then
                cleaned = cleaned + 1
                record.sales = filtered
                record.totalGold = math.max(0, (record.totalGold or 0) - removedGold)
                if record.memberCount and record.memberCount > 0 then
                    record.perPerson = math.floor(record.totalGold / record.memberCount)
                end
            end
        end
    end
    if cleaned > 0 and MR.Print and MR.COLOR then
        MR.Print(string.format("거래 기록 마이그레이션: %d개 세션의 잔재 거래 정리됨", cleaned), MR.COLOR.gold)
    end
end

--------------------------------------------------------------------------------
-- 현재 판매 상태로 record 스냅샷 생성 (내부용)
-- 인스턴스 이름은 레이드 타이머 시작 시점의 캐시값 우선 사용
--------------------------------------------------------------------------------
local function buildRecord(memberCount, totalGold, perPerson, existingDistributions)
    local now = time()
    local startTime = MR.RaidTimer.startTime or now

    -- 현재 세션 시간대(startTime ~ now)의 DONE 엔트리만 포함.
    -- 이전 세션의 잔여 TradeLog 엔트리가 새 세션 기록에 섞이지 않도록 timestamp 필터링.
    -- "[거래완료]"/"[거래취소]" 접두 = 감사용 요약 entry (bid=0). sales 통계에서 제외.
    local sales = {}
    for _, entry in ipairs(MR.TradeLog) do
        local isAuditSummary = entry.tradeAuditType ~= nil   -- 1.0.92+ 신규 필드
            or (entry.itemName and type(entry.itemName) == "string"
                and (entry.itemName:find("^%[거래완료%]")
                     or entry.itemName:find("^%[거래취소%]")))
        if entry.state == MR.TRADE_STATE.DONE
            and entry.timestamp
            and entry.timestamp >= startTime
            and entry.timestamp <= now
            and not isAuditSummary then
            table.insert(sales, {
                time      = entry.timestamp,
                itemName  = entry.itemName,
                itemLink  = entry.itemLink,
                winner    = entry.winner,
                bid       = entry.bid,
                paidGold  = entry.paidGold,
                bossGroup = entry.bossGroup or 0,
            })
        end
    end

    local bossNames = {}
    if MR.ItemList and MR.ItemList.bossNames then
        for g, name in pairs(MR.ItemList.bossNames) do
            bossNames[g] = name
        end
    end

    local cachedInstance = MR.RaidTimer.GetInstanceName and MR.RaidTimer.GetInstanceName()
    local instanceName   = cachedInstance or GetInstanceInfo() or "알 수 없음"

    return {
        id            = startTime,
        date          = date("%Y-%m-%d", startTime),
        time          = date("%H:%M", startTime),
        startTime     = startTime,
        endTime       = now,
        instance      = instanceName,
        memberCount   = memberCount or 0,
        totalGold     = totalGold   or 0,
        perPerson     = perPerson   or 0,
        sales         = sales,
        bossNames     = bossNames,
        -- 공대장 → 파티원 분배 송금 이력. UpsertCurrent 재생성 시 기존 목록 보존.
        distributions = existingDistributions or {},
    }
end

--------------------------------------------------------------------------------
-- 현재 레이드 세션을 history에 저장 (명시적 저장, 수동 버튼용)
-- memberCount, totalGold, perPerson: 정산 패널 계산값
-- 반환: 저장된 record
--------------------------------------------------------------------------------
function MR.RaidHistory.SaveSession(memberCount, totalGold, perPerson)
    if not MimRaidDB then MimRaidDB = {} end
    local history = getHistory()

    local record = buildRecord(memberCount, totalGold, perPerson, nil)
    table.insert(history, record)
    MR.Debug("RaidHistory: #" .. #history .. " 저장 (" .. #record.sales .. "건)")
    return record
end

--------------------------------------------------------------------------------
-- 현재 세션을 upsert (거래/정산 변경 시 자동 호출)
-- 같은 startTime의 레코드가 있으면 제자리 갱신, 없으면 새로 추가
-- DONE 거래가 1건도 없으면 저장 안 함 (pre-세션 노이즈 방지)
--------------------------------------------------------------------------------
function MR.RaidHistory.UpsertCurrent(memberCount, totalGold, perPerson)
    if not MR.RaidTimer.startTime then return nil end
    if not MimRaidDB then MimRaidDB = {} end
    local history = getHistory()

    -- 기존 레코드의 distributions 보존 (sales만 rebuild, 분배 이력은 append-only)
    local startTime = MR.RaidTimer.startTime
    local existingDist = nil
    local existingIdx = nil
    for i, existing in ipairs(history) do
        if existing.startTime == startTime then
            existingDist = existing.distributions
            existingIdx = i
            break
        end
    end

    local record = buildRecord(memberCount, totalGold, perPerson, existingDist)
    if #record.sales == 0 then return nil end

    if existingIdx then
        history[existingIdx] = record
        return record
    end

    table.insert(history, record)
    return record
end

--------------------------------------------------------------------------------
-- 분배 송금 1건 추가 (공대장 → 파티원)
-- status: "done" | "over" | "short"
-- 현재 세션 레코드에 append. 세션 레코드가 아직 없으면 생성 시도 (sales 0이면 스킵).
--------------------------------------------------------------------------------
function MR.RaidHistory.AddDistribution(target, gold, status)
    if not MR.RaidTimer.startTime then return end
    if not MimRaidDB then MimRaidDB = {} end
    local history = getHistory()

    local startTime = MR.RaidTimer.startTime
    local entry = {
        time   = time(),
        target = target or "?",
        gold   = gold or 0,
        status = status or "done",
    }

    for _, existing in ipairs(history) do
        if existing.startTime == startTime then
            existing.distributions = existing.distributions or {}
            table.insert(existing.distributions, entry)
            return
        end
    end

    -- 세션 레코드가 없으면 스킵 (sales 없이 분배만 있는 케이스는 비정상)
    MR.Debug("AddDistribution: 현재 세션 레코드 없음. 스킵")
end

--------------------------------------------------------------------------------
-- 기여(공대원 → 공대장) 골드 1건 추가. 아이템 없이 골드만 받은 경우.
-- 분배 풀에 합산되며, 별도 트래킹으로 누가 얼마 보탰는지 사후 확인 가능.
--------------------------------------------------------------------------------
function MR.RaidHistory.AddContribution(source, gold)
    if not MR.RaidTimer.startTime then return end
    if not MimRaidDB then MimRaidDB = {} end
    local history = getHistory()

    local startTime = MR.RaidTimer.startTime
    local entry = {
        time   = time(),
        source = source or "?",
        gold   = gold or 0,
    }

    for _, existing in ipairs(history) do
        if existing.startTime == startTime then
            existing.contributions = existing.contributions or {}
            table.insert(existing.contributions, entry)
            return
        end
    end

    MR.Debug("AddContribution: 현재 세션 레코드 없음. 스킵")
end

--------------------------------------------------------------------------------
-- 조회
--------------------------------------------------------------------------------
function MR.RaidHistory.GetAll()
    if not MimRaidDB then return {} end
    return getHistory()
end

function MR.RaidHistory.Count()
    if not MimRaidDB then return 0 end
    return #getHistory()
end
