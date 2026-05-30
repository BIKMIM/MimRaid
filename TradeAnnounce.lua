--------------------------------------------------------------------------------
-- MimRaid - TradeAnnounce.lua
-- 거래 완료 시 상대방에게 귓말로 거래내역 전송 (증빙용)
-- 참고 애드온: TradeShout (bout / 인벤, 아쿤델라르 / 얼음피) — 아이디어만 참고, 구현은 독립.
--
-- 흐름:
--   TRADE_SHOW            → 대상 이름 캐시, 스냅샷 초기화
--   TRADE_ACCEPT_UPDATE   → 양쪽 아이템/골드 스냅샷 (이 시점에는 API 유효)
--   Auction.OnTradeAccept → 거래 완료 판정 직후 귓말 발송
--   TRADE_CLOSED / 오버레이 해제 시 → 스냅샷 리셋
--------------------------------------------------------------------------------

---@diagnostic disable: undefined-global

local MR = MimRaid
MR.TradeAnnounce = {}
local TA = MR.TradeAnnounce

-- 스냅샷: 마지막 TRADE_ACCEPT_UPDATE 시점의 거래창 상태
local snap = {
    targetName   = nil,
    playerItems  = {},   -- [slot] = { link, name, count }
    targetItems  = {},
    playerCopper = 0,
    targetCopper = 0,
}
local _sent = false   -- 이번 거래에 이미 귓말을 보냈는지 (중복 발송 방지)

local function reset()
    snap.targetName   = nil
    snap.playerItems  = {}
    snap.targetItems  = {}
    snap.playerCopper = 0
    snap.targetCopper = 0
    _sent = false
end

-- copper(정수) → "100골 5실 3코". 0이면 nil 반환 (빈 항목 스킵용).
-- 큰 값(35만골+ 거래)도 안전: string.format("%.0f")는 더블(2^53)까지 처리, 자동 과학표기법 회피.
local function formatCopper(c)
    c = tonumber(c) or 0
    if c == 0 then return nil end
    local g  = math.floor(c / 10000)
    local s  = math.floor((c % 10000) / 100)
    local cp = c % 100
    local parts = {}
    if g  > 0 then table.insert(parts, string.format("%.0f골", g))   end
    if s  > 0 then table.insert(parts, string.format("%.0f실", s))   end
    if cp > 0 then table.insert(parts, string.format("%.0f코", cp))  end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

-- 아이템 슬롯 테이블 → "링크x2, 링크, 링크x3" 형식.
local function formatItems(items)
    local parts = {}
    for i = 1, 7 do   -- 7번은 마부 슬롯
        local it = items[i]
        if it and it.link then
            local entry = it.link
            if (it.count or 1) > 1 then
                entry = entry .. "x" .. it.count
            end
            table.insert(parts, entry)
        end
    end
    return table.concat(parts, ", ")
end

-- (구) splitUtf8 은 바이트 기반이라 |Hitem:...|h|r 중간을 잘라 "Invalid escape code" 유발 → 제거.
--
-- 귓말 분할 전략:
--   WoW 채팅은 255바이트 제한 + 이스케이프(|Hitem:...|h[...]|h|r, |cff...|r) 중간을 자르면
--   "Invalid escape code" 에러. 바이트 기반 분할 대신 의미 기반으로 분할:
--     1) 섹션을 " / " 경계로 그리디 패킹
--     2) 한 섹션(예: "받은 아이템: A, B, C")이 한도 초과면 ", " 경계에서 분할
--     3) 단일 아이템 링크 하나가 한도 초과면 그대로 단일 청크 (WoW는 링크만 유효하면 관대)
--   이 분할점들은 모두 이스케이프 바깥이라 안전.
-- 귓말 실한도: 한국 서버에서 전체 링크 포함 ~500바이트까지 들어감 (경험치).
-- 아이템 링크 1개 ≈ 70~90바이트 (아이템명 한글 기준). 6개 + 섹션 헤더 + 금액 섹션 ≈ 550바이트.
local SAFE_LIMIT = 550

-- "header: body" 형식 섹션을 ", " 경계로 분할 (한도 초과 시).
local function splitSectionAtCommas(section, limit)
    if #section <= limit then return { section } end
    local headerEnd = section:find(": ", 1, true)
    if not headerEnd then return { section } end
    local header = section:sub(1, headerEnd + 1)  -- "받은 아이템: "
    local body   = section:sub(headerEnd + 2)

    local items = {}
    local s = 1
    while true do
        local e = body:find(", ", s, true)
        if not e then
            table.insert(items, body:sub(s))
            break
        end
        table.insert(items, body:sub(s, e - 1))
        s = e + 2
    end

    local chunks = {}
    local cur = header
    for _, item in ipairs(items) do
        local attempt = (cur == header) and (cur .. item) or (cur .. ", " .. item)
        if #attempt <= limit then
            cur = attempt
        elseif cur == header then
            -- 단일 아이템이 limit 초과 — 링크는 못 자르므로 그대로
            table.insert(chunks, attempt)
            cur = header
        else
            table.insert(chunks, cur)
            cur = header .. item
        end
    end
    if cur ~= header then table.insert(chunks, cur) end
    return chunks
end

-- 섹션 리스트 → 프리픽스 붙은 청크 리스트. 여러 섹션을 " / "로 패킹 후 초과분만 분할.
local function buildChunks(sections)
    local pieces = {}
    for _, sec in ipairs(sections) do
        for _, p in ipairs(splitSectionAtCommas(sec, SAFE_LIMIT)) do
            table.insert(pieces, p)
        end
    end

    local packed = {}
    local cur
    for _, p in ipairs(pieces) do
        if not cur then
            cur = p
        elseif #cur + 3 + #p <= SAFE_LIMIT then
            cur = cur .. " / " .. p
        else
            table.insert(packed, cur)
            cur = p
        end
    end
    if cur then table.insert(packed, cur) end

    local chunks = {}
    local total = #packed
    for i, p in ipairs(packed) do
        if total == 1 then
            table.insert(chunks, p)
        else
            table.insert(chunks, string.format("[%d/%d] %s", i, total, p))
        end
    end
    return chunks
end

--------------------------------------------------------------------------------
-- 이벤트 훅
--------------------------------------------------------------------------------

-- 대상 이름을 가능한 경로로 수집. 여러 폴백 체인:
--   1) Auction.currentTradeName (OnTradeShow에서 이미 캐시해둔 값 — 가장 신뢰 가능)
--   2) UnitExists("NPC") + MR.FullName
--   3) UnitExists("target") + MR.FullName
local function captureTarget()
    if MR.Auction and MR.Auction.currentTradeName and MR.Auction.currentTradeName ~= "" then
        return MR.Auction.currentTradeName
    end
    local name
    if UnitExists("NPC") and MR.FullName then
        name = MR.FullName("NPC")
        if name and name ~= "" then return name end
    end
    if UnitExists("target") and MR.FullName then
        name = MR.FullName("target")
        if name and name ~= "" then return name end
    end
    return nil
end

function TA.OnTradeShow()
    reset()
    snap.targetName = captureTarget()
end

function TA.Snapshot()
    if not TradeFrame or not TradeFrame:IsShown() then
        if MR.Debug then MR.Debug("[TradeAnnounce] Snapshot skip: TradeFrame not shown") end
        return
    end

    snap.playerCopper = GetPlayerTradeMoney() or 0
    snap.targetCopper = GetTargetTradeMoney() or 0

    for i = 1, 7 do
        local pName, _, pCount = GetTradePlayerItemInfo(i)
        local pLink = GetTradePlayerItemLink(i)
        if pName then
            snap.playerItems[i] = { link = pLink or pName, name = pName, count = pCount or 1 }
        else
            snap.playerItems[i] = nil
        end

        local tName, _, tCount = GetTradeTargetItemInfo(i)
        local tLink = GetTradeTargetItemLink(i)
        if tName then
            snap.targetItems[i] = { link = tLink or tName, name = tName, count = tCount or 1 }
        else
            snap.targetItems[i] = nil
        end
    end

    -- TRADE_SHOW 시점에 대상 이름을 못 잡는 경우 대비 (일부 퀘스트/파티 거래)
    if not snap.targetName or snap.targetName == "" then
        snap.targetName = captureTarget()
    end

    if MR.Debug then
        local pCount, tCount = 0, 0
        for i = 1, 7 do
            if snap.playerItems[i] then pCount = pCount + 1 end
            if snap.targetItems[i] then tCount = tCount + 1 end
        end
        -- copper는 21억(2^31)을 넘는 경우(예: 350,000+ 골드)가 있어 %d로 포맷하면 정수 오버플로우.
        -- %.0f는 더블 정밀도(2^53)라 안전.
        MR.Debug(string.format("[TradeAnnounce] Snapshot target=%s pC=%.0f tC=%.0f pItems=%d tItems=%d",
            tostring(snap.targetName), snap.playerCopper, snap.targetCopper, pCount, tCount))
    end
end

function TA.Reset()
    reset()
end

-- 외부 모듈(예: Auction.OnTradeAccept) 에서 마지막 거래창 슬롯 상태 조회용.
-- snap.playerItems[1..7] = { link, name, count } (없으면 nil)
function TA.GetPlayerItems()
    return snap.playerItems
end

-- 전체 snapshot (양쪽 아이템 + 골드 + 대상 이름) 접근.
function TA.GetSnapshot()
    return snap
end

--------------------------------------------------------------------------------
-- 귓말 발송 (Auction.OnTradeAccept 성공 판정 후 호출)
--------------------------------------------------------------------------------
local function dbg(msg)
    if MR.Debug then MR.Debug("[TradeAnnounce] " .. msg) end
end

function TA.SendIfEnabled()
    if _sent then
        dbg("skip: already sent for this trade")
        return
    end
    if not MR.cfg then
        dbg("skip: MR.cfg nil")
        return
    end
    if MR.cfg.tradeWhisperEnabled == false then
        dbg("skip: tradeWhisperEnabled=false")
        return
    end

    -- 대상 이름: 스냅샷에 없으면 지금 시점에 다시 시도 (TRADE_CLOSED 이후에도 currentTradeName은 남아있음)
    local target = snap.targetName
    if not target or target == "" then
        target = captureTarget()
    end
    if not target or target == "" then
        dbg("skip: target name missing")
        return
    end

    -- 자기거래(은행알트 교환)는 귓말 무의미 → 스킵
    local me = (MR.FullName and MR.FullName("player")) or UnitName("player")
    if me and (target == me or (MR.NamesMatch and MR.NamesMatch(target, me))) then
        dbg("skip: self-trade with " .. tostring(me))
        return
    end

    local gotMoney  = formatCopper(snap.targetCopper)
    local gaveMoney = formatCopper(snap.playerCopper)
    local gotItems  = formatItems(snap.targetItems)
    local gaveItems = formatItems(snap.playerItems)

    local sections = {}
    if gotMoney           then table.insert(sections, "받은 골드: "   .. gotMoney)  end
    if gotItems  ~= ""    then table.insert(sections, "받은 아이템: " .. gotItems)  end
    if gaveMoney          then table.insert(sections, "보낸 골드: "   .. gaveMoney) end
    if gaveItems ~= ""    then table.insert(sections, "보낸 아이템: " .. gaveItems) end

    -- 빈 거래(양쪽 다 0골/0아이템)는 스킵
    if #sections == 0 then
        dbg(string.format("skip: empty trade (pC=%.0f tC=%.0f pI=0 tI=0) target=%s",
            snap.playerCopper, snap.targetCopper, target))
        return
    end

    local chunks = buildChunks(sections)
    dbg(string.format("send → %s : %d chunk(s)", target, #chunks))

    -- 청크 사이 0.4초 간격 (서버 스로틀 방지). 첫 청크는 즉시.
    -- SafeSendChat 사용: 거래 종료 직후 ENCOUNTER_START 발화 race 방어.
    -- (IsEncounterInProgress 중 SendChatMessage 직접 호출 시 ADDON_ACTION_FORBIDDEN 가능 →
    --  SafeSendChat 가 인카운터 중에는 큐잉 후 ENCOUNTER_END 에서 자동 재개)
    for idx, chunk in ipairs(chunks) do
        local delay = (idx - 1) * 0.4
        if delay == 0 then
            MR.SafeSendChat(chunk, "WHISPER", nil, target)
        else
            C_Timer.After(delay, function()
                MR.SafeSendChat(chunk, "WHISPER", nil, target)
            end)
        end
    end
    _sent = true

    -- 자신 채팅창에도 기록 (증빙 확인용)
    if MR.Print and MR.COLOR then
        for _, chunk in ipairs(chunks) do
            MR.Print("[거래내역→" .. target .. "] " .. chunk, MR.COLOR.gray)
        end
    end
end

--------------------------------------------------------------------------------
-- 테스트용: 가짜 스냅샷으로 귓속말 발송 시뮬레이션
-- /mr tatest <이름> <받은골드골드> [준골드]
-- 예) /mr tatest 김철수 50000       → 5만골 수령 귓속말 시뮬
--     /mr tatest 김철수 50000 1000  → 5만골 받고 100코 준 거래
--------------------------------------------------------------------------------
function TA.Test(targetName, gotCopper, gaveCopper)
    if not targetName or targetName == "" then
        MR.Print("/mr tatest <이름> <받은골드(골드정수)> [준골드(골드정수)]", MR.COLOR.yellow)
        MR.Print("예) /mr tatest 김철수 50000", MR.COLOR.gray)
        return
    end
    reset()
    _sent = false
    snap.targetName   = targetName
    snap.targetCopper = (gotCopper  or 0) * 10000   -- 골드 → copper
    snap.playerCopper = (gaveCopper or 0) * 10000
    snap.playerItems  = {}
    snap.targetItems  = {}
    MR.Print(string.format("TradeAnnounce 시뮬: 대상=%s 받은골드=%s 준골드=%s",
        targetName,
        formatCopper(snap.targetCopper)  or "0",
        formatCopper(snap.playerCopper) or "0"), MR.COLOR.gray)
    TA.SendIfEnabled()
end

-- UI_INFO_MESSAGE 에서 거래 완료 판정 — TradeShout 와 동일한 정식 시그널
-- Auction 의 _bothAccepted 플래그는 빠른 거래/자기거래에서 누락될 수 있음 → 이 경로가 신뢰성 높음
function TA.OnUIInfoMessage(messageType)
    if not GetGameMessageInfo then return end
    local ok, errorName = pcall(GetGameMessageInfo, messageType)
    if not ok or not errorName then return end
    if MR.Debug then MR.Debug("[TradeAnnounce] UI_INFO_MESSAGE errorName=" .. tostring(errorName)) end
    if errorName == "ERR_TRADE_COMPLETE" then
        TA.SendIfEnabled()
    end
end
