--------------------------------------------------------------------------------
-- MimRaid - Auction.lua
-- 경매 진행 로직 및 채팅 파싱
--------------------------------------------------------------------------------

---@diagnostic disable: undefined-global

local MR = MimRaid

--------------------------------------------------------------------------------
-- 경매 진행 상태
--------------------------------------------------------------------------------
MR.Auction = {
    state            = MR.AUCTION_STATE.IDLE,
    itemIndex        = nil,      -- ItemList 내 현재 경매 중인 인덱스
    topBidder        = nil,      -- 현재 최고 입찰자 이름
    topBid           = 0,        -- 현재 최고 입찰 금액 (골드 정수)
    bidHistory       = {},       -- { name, bid, timestamp } 입찰 기록 (현재 경매 한정)
    allPlayerBids    = {},       -- [playerName] = {bid1, bid2, ...}  한 명이 n슬롯 입찰 시 배열 (내림차순)
    bidFirstTime     = {},       -- [playerName] = { [bidValue] = timestamp }  동률 tiebreak 용
    winnerSlots      = 1,        -- 낙찰 슬롯 수 (= item.quantity)
    pendingWinners   = {},       -- [{name, itemLink, bid}] 거래 미완료 낙찰자 목록
    placementQueue   = nil,      -- 거래창 자동 배치 큐 {{link, slotIdx}, ...}
    silenceTimer     = nil,      -- 침묵 감지 C_Timer 핸들
    countTimer       = nil,      -- 카운트다운 C_Timer 핸들
    countStep        = 0,        -- 현재 카운트 숫자
    sequential       = false,    -- 연속경매 모드 여부
    pausedItemIndex  = nil,      -- 일시정지 시 저장된 아이템 인덱스
    pausedByEncounter = false,   -- 보스 전투로 인한 일시정지 여부
    pausedByLoading   = false,   -- 공대장 로딩(존 변경)으로 인한 일시정지 여부
    inPreview        = false,    -- 살펴보기 단계 (입찰 받지 않음)
}

local AC = MR.Auction

-- 공격대장만 경매 시작 가능 (부공대장 권한 제거).
-- 5인 던전/파티/솔로에서는 아무도 권한 없음 — 던전명/시간 표시 외엔 사용 X.
local function canStartAuction()
    if not IsInRaid() then return false end
    return UnitIsGroupLeader("player")
end

-- 다중 낙찰 순위 스냅샷 (순위 변동 감지용)
-- 이름 중복 가능 (동일인이 n슬롯 점유) → key = name + bid
local prevTopSnapshot = {}  -- { [i] = "name|bid" } 순서 배열

-- 모든 입찰을 (name, bid, t) 쌍으로 flatten 하여 내림차순 정렬.
-- 동률 tiebreak: AC.bidFirstTime[name][bid] (먼저 도달한 입찰이 상위)
local function flattenAndSort(excludeName)
    local flat = {}
    for name, bids in pairs(AC.allPlayerBids) do
        if name ~= excludeName then
            for _, bid in ipairs(bids) do
                local t = (AC.bidFirstTime[name] and AC.bidFirstTime[name][bid]) or math.huge
                table.insert(flat, { name = name, bid = bid, t = t })
            end
        end
    end
    table.sort(flat, function(a, b)
        if a.bid ~= b.bid then return a.bid > b.bid end
        return a.t < b.t
    end)
    return flat
end

local function getTopN(n)
    local sorted = flattenAndSort()
    local top = {}
    for i = 1, math.min(n, #sorted) do top[i] = sorted[i] end
    return top, sorted
end

local function snapshotKey(e) return e.name .. "|" .. tostring(e.bid) end

local function topChanged(newTop)
    if #newTop ~= #prevTopSnapshot then return true end
    for i = 1, #newTop do
        if snapshotKey(newTop[i]) ~= prevTopSnapshot[i] then return true end
    end
    return false
end

-- UI 갱신 콜백
local onUpdateCallbacks = {}
function MR.Auction.OnUpdate(fn)
    table.insert(onUpdateCallbacks, fn)
end
local function fireUpdate()
    for _, fn in ipairs(onUpdateCallbacks) do pcall(fn) end
end

--------------------------------------------------------------------------------
-- 내부: 채팅 전송 (경매 채널)
-- 공대 → 설정 채널(RAID/RAID_WARNING), 파티 → PARTY, 혼자 → 로컬 출력
--------------------------------------------------------------------------------
local function sendChat(msg, channelOverride)
    -- 실제 플레이어 파티원 확인 (이야기 모드 NPC 파티원 제외)
    local inRaid = IsInRaid()
    local prefix = inRaid and "raid" or "party"
    local n = GetNumGroupMembers()
    local hasRealPlayer = false
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
            hasRealPlayer = true
            break
        end
    end

    -- 기본 채널: 공대 → auctionChannel, 파티 → PARTY
    -- override 있으면 해당 채널 사용. RAID_WARNING은 공대 밖이면 fallback.
    local channel = channelOverride or (inRaid and MR.cfg.auctionChannel or "PARTY")
    if channel == "RAID_WARNING" and not inRaid then
        channel = "PARTY"
    end

    if hasRealPlayer then
        MR.SafeSendChat(msg, channel)
    else
        MR.Print("[채팅] " .. msg, MR.COLOR.white)
    end
end

-- 다른 모듈(기록 패널의 거래기록 보고 등)이 재사용할 수 있도록 공개
MR.SendChat = sendChat

--------------------------------------------------------------------------------
-- 내부: 타이머 취소
--------------------------------------------------------------------------------
local function cancelSilenceTimer()
    if AC.silenceTimer then
        ---@diagnostic disable-next-line: undefined-field
        AC.silenceTimer:Cancel()
        AC.silenceTimer = nil
    end
end

local function cancelCountTimer()
    if AC.countTimer then
        ---@diagnostic disable-next-line: undefined-field
        AC.countTimer:Cancel()
        AC.countTimer = nil
    end
end

local function cancelAllTimers()
    MR.Debug(string.format(
        "cancelAllTimers: silence=%s count=%s state=%s",
        tostring(AC.silenceTimer ~= nil),
        tostring(AC.countTimer ~= nil),
        tostring(AC.state)))
    cancelSilenceTimer()
    cancelCountTimer()
end

--------------------------------------------------------------------------------
-- 내부: 침묵 감지 타이머 시작
-- 새 입찰이 오면 기존 타이머 취소 후 재시작
--------------------------------------------------------------------------------
local function startSilenceTimer()
    cancelSilenceTimer()
    AC.state = MR.AUCTION_STATE.WAITING
    fireUpdate()

    AC.silenceTimer = C_Timer.NewTimer(MR.cfg.silenceTimeout, function()
        AC.silenceTimer = nil
        MR.Auction.StartCountdown()
    end)
end

--------------------------------------------------------------------------------
-- 카운트다운 사운드 파일 경로
--------------------------------------------------------------------------------
local COUNTDOWN_SOUNDS = {
    [1] = "Interface\\AddOns\\MimRaid\\sounds\\1.mp3",
    [2] = "Interface\\AddOns\\MimRaid\\sounds\\2.mp3",
    [3] = "Interface\\AddOns\\MimRaid\\sounds\\3.mp3",
    [4] = "Interface\\AddOns\\MimRaid\\sounds\\4.mp3",
    [5] = "Interface\\AddOns\\MimRaid\\sounds\\5.mp3",
}
local SOUND_DANG         = "Interface\\AddOns\\MimRaid\\sounds\\땡.mp3"
-- WoW 내부 FileDataID 사용 (품질/볼륨 개선).
-- 558132: 작업 완료 (오크 피온 남자) - 인게임 검증됨
-- 539226: 돈이 모자라 (블러드엘프 여자) - 인게임 검증됨
-- 3164885: 맞습니다 (기계음 여자) - 인게임 검증됨
-- 다른 소리 쓰려면 /mr snd <id> 로 미리 확인.
local SOUND_TRADE_DONE   = 558132
local SOUND_MONEY_SHORT  = 539226
local SOUND_CORRECT      = 3164885

-- 거래 사운드는 WoW 내장 거래창 효과음(열림/수락/완료 클릭)과 타이밍이 겹쳐
-- 마스킹되어 작게 들림. 0.4초 지연 + Master 채널로 회피.
local function playTradeSound(id)
    if not MR.cfg.soundEnabled then return end
    C_Timer.After(0.4, function()
        PlaySoundFile(id, "Master")
    end)
end

-- 이 거래에서 이미 소리를 재생했는지 추적 (TRADE_ACCEPT_UPDATE용)
-- TRADE_ACCEPT_UPDATE는 금액 변경 시 (0,0)→(0,1) 순으로 재발화하므로
-- 단순 이전상태 비교 대신 "재생 완료" 플래그로 중복 재생 방지
local _tradeSoundPlayed = false

--------------------------------------------------------------------------------
-- 카운트다운 시작
--------------------------------------------------------------------------------
function MR.Auction.StartCountdown()
    cancelAllTimers()
    AC.state     = MR.AUCTION_STATE.COUNTDOWN
    AC.countStep = MR.cfg.countdownFrom
    fireUpdate()

    local function tick()
        if AC.state ~= MR.AUCTION_STATE.COUNTDOWN then
            MR.Debug(string.format(
                "tick SKIP: state=%s (expected COUNTDOWN) countStep=%s",
                tostring(AC.state), tostring(AC.countStep)))
            return
        end
        MR.Debug(string.format(
            "tick FIRE: countStep=%d state=%s",
            AC.countStep, tostring(AC.state)))

        if AC.countStep > 0 then
            sendChat(string.format(MR.cfg.msgCountdown, AC.countStep))
            if MR.cfg.soundEnabled then
                local snd = COUNTDOWN_SOUNDS[AC.countStep]
                if snd then PlaySoundFile(snd, "Dialog") end
            end
            AC.countStep = AC.countStep - 1
            AC.countTimer = C_Timer.NewTimer(MR.cfg.countdownStepDelay or 2, tick)
        else
            -- "0" 채팅 + 땡 사운드.
            -- 채팅 큐 drain (~100ms) + 서버 echo (~30ms) 후에야 리더 채팅창에 "0" 표시.
            -- 그 사이 도착 입찰은 시청자가 "0" 못 본 상태에서 친 것 → 수용해야 함.
            --   → AC._postZero=true: state 는 COUNTDOWN 유지 (입찰 받음), 다만 카운트 재시작은 차단.
            -- 0.15초 후 state=SOLD 로 전환 → 이후 도착 입찰은 가시 경고와 함께 거부.
            sendChat(string.format(MR.cfg.msgCountdown, 0))
            if MR.cfg.soundEnabled then
                PlaySoundFile(SOUND_DANG, "Dialog")
            end
            AC._postZero = true
            fireUpdate()
            AC.countTimer = C_Timer.NewTimer(0.15, function()
                AC._postZero = false
                AC.state = MR.AUCTION_STATE.SOLD
                fireUpdate()
                AC.countTimer = C_Timer.NewTimer(0.2, function()
                    AC.countTimer = nil
                    if AC.state == MR.AUCTION_STATE.SOLD then
                        MR.Auction.Sold()
                    end
                end)
            end)
        end
    end

    tick()
end

--------------------------------------------------------------------------------
-- 경매 시작
-- index: MR.ItemList 내 인덱스
--------------------------------------------------------------------------------
function MR.Auction.Start(index, isNextInSequence)
    -- 중지 후 race 방어: 추적되지 않는 C_Timer.After가 발동해도 sequential=false면 무시
    if isNextInSequence and not AC.sequential then
        MR.Debug("Auction.Start SKIP: sequential=false (race after Stop)")
        return false
    end
    if not canStartAuction() then
        MR.Print("공격대장만 경매를 시작할 수 있습니다. (레이드 인스턴스 내)", MR.COLOR.red)
        return false
    end
    if AC.state ~= MR.AUCTION_STATE.IDLE then
        MR.Print("이미 경매 진행 중입니다.", MR.COLOR.red)
        return false
    end

    local item = MR.ItemList[index]
    if not item then
        MR.Print("아이템을 찾을 수 없습니다.", MR.COLOR.red)
        return false
    end

    MR.Debug(string.format(
        "Auction.Start: idx=%d name=%s link=%s linksCnt=%d qty=%s mode=%s bg=%s group=%s",
        index, tostring(item.itemName), tostring(item.itemLink),
        #(item.itemLinks or {}), tostring(item.quantity),
        tostring(item.auctionMode), tostring(item.bossGroup),
        tostring(item.groupNumber)))

    -- 상태 초기화 (이전 경매에서 stale 플래그가 남아있을 가능성 제거)
    AC.state       = MR.AUCTION_STATE.WAITING
    AC.itemIndex   = index
    AC.topBidder   = nil
    AC.topBid      = 0
    AC.winnerSlots = item.quantity or 1
    AC.inPreview         = false   -- 이전 경매 살펴보기 잔존 차단 플래그 명시 초기화
    AC.pausedByEncounter = false
    AC.pausedByLoading   = false
    wipe(AC.bidHistory)
    wipe(AC.allPlayerBids)
    wipe(AC.bidFirstTime)
    prevTopSnapshot = {}

    -- 경매 시작 공지
    -- NOTE: RAID_WARNING 은 하이퍼링크 바깥의 raw color escape(|c..|r) 가 포함되면
    -- 메시지 전체를 드롭한다. 수량 텍스트는 색상 없이 평문으로만 덧붙임.
    local qtyText = AC.winnerSlots > 1
        and string.format(" ×%d", AC.winnerSlots) or ""
    if isNextInSequence then
        sendChat("[경매] 다음 경매")
    end
    local catLabel = MR.BuildCategoryLabel
        and MR.BuildCategoryLabel(item.itemLinks or item.itemLink) or ""
    -- 1차/2차 스탯 + 부위 + 홈 요약은 살펴보기 ON/OFF 무관하게 항상 송출
    -- summary 와 catLabel 은 보석홈/파불/광피 등 카테고리가 중복되므로 summary 가 있으면 catLabel 생략
    local summary = ""
    if MR.BuildItemSummary then
        summary = MR.BuildItemSummary(item.itemLink) or ""
    end
    local previewTime = tonumber(MR.cfg.previewTime) or 0

    local extra = (summary ~= "") and summary or catLabel
    sendChat(string.format("[경매] %s%s%s",
        MR.CleanItemLink(item.itemLink) or MR.CleanItemName(item.itemName),
        qtyText,
        extra ~= "" and (" " .. extra) or ""),
        "RAID_WARNING")

    fireUpdate()

    -- 카운트다운 지연: previewTime > 0 이면 N초 동안 대기 후 카운트다운 시작.
    -- 그 사이 첫 입찰이 들어오면 OnChatMsg 가 지연 타이머 취소 후 즉시 카운트다운 진입.
    -- N초 동안 입찰이 없어도 만료 시 그냥 카운트다운 시작 (강제 침묵 없음).
    if previewTime > 0 then
        AC.inPreview = true
        sendChat(string.format("[경매] %d초 뒤 카운트다운 시작", previewTime))
        AC.silenceTimer = C_Timer.NewTimer(previewTime, function()
            AC.silenceTimer = nil
            AC.inPreview   = false
            if AC.state == MR.AUCTION_STATE.WAITING then
                MR.Auction.StartCountdown()
            end
        end)
    else
        MR.Auction.StartCountdown()
    end
    return true
end

--------------------------------------------------------------------------------
-- 낙찰 처리 (단독 / 다중 N등 균일가 공통)
--------------------------------------------------------------------------------
function MR.Auction.Sold()
    cancelAllTimers()

    local item = MR.ItemList[AC.itemIndex]
    if not item then
        MR.Auction.Reset()
        return
    end

    AC.state = MR.AUCTION_STATE.SOLD
    MR.Auction._lastSoldAt = time()   -- 늦은 입찰 경고 윈도우 기준 시점
    fireUpdate()

    -- 모든 입찰을 flatten 해서 내림차순 정렬 (한 명이 n슬롯 점유 가능)
    local sortedBids = flattenAndSort()

    local slots    = AC.winnerSlots          -- 낙찰 슬롯 수 (= 드롭 수량)
    local winCount = math.min(slots, #sortedBids)

    -- pendingWinners는 거래 완료 전까지 누적 유지 (연속 경매 다중 낙찰자 대응)
    local pendingCountBefore = #AC.pendingWinners

    if winCount == 0 then
        -- ── 입찰자 없음 → 유찰 ────────────────────────────────────────────
        local nameOrLink = MR.CleanItemLink(item.itemLink) or MR.CleanItemName(item.itemName)
        local qty = item.quantity or 1
        local displayName = (qty > 1) and (nameOrLink .. " x " .. qty) or nameOrLink
        sendChat(string.format(MR.cfg.msgNoWinner, displayName))
        MR.FailedItems.Add(item)

    else
        -- ── 낙찰 ─────────────────────────────────────────────────────────
        -- 균일가 = N위 입찰가 (N = 실제 낙찰 인원)
        local uniformPrice = sortedBids[winCount].bid

        -- 아이템 링크 배정: 변형이 있을 경우 variantBestSlot → 1위 낙찰자
        local linkAssign = {}
        local links = item.itemLinks or {}
        for i = 1, winCount do
            linkAssign[i] = links[i] or item.itemLink
        end
        -- 추가 옵션이 붙은 variantBestSlot 은 항상 1위 낙찰자에게 배정
        local best = item.variantBestSlot
        if best and best ~= 1 then
            if winCount >= best then
                -- 낙찰 범위 내 → 1번 슬롯과 스왑 (양쪽 모두 낙찰자에게 전달)
                linkAssign[1], linkAssign[best] = linkAssign[best], linkAssign[1]
            else
                -- 낙찰 범위 밖 (예: 3개 중 3번 슬롯이 변형인데 낙찰자 2명)
                -- → 1등에게 변형을 주고 원래 1번 링크는 미낙찰 처리.
                -- 안전망: links[best] 가 nil 이면 기존 linkAssign[1] 유지, 그도 nil 이면 item.itemLink.
                -- (itemLink=nil 로 TradeLog 에 들어가면 이후 itemID 매칭 실패 → silent loss 위험)
                linkAssign[1] = links[best] or linkAssign[1] or item.itemLink
            end
        end

        -- 낙찰 공지
        if winCount == 1 then
            sendChat(string.format(MR.cfg.msgSold,
                MR.CleanItemLink(item.itemLink) or MR.CleanItemName(item.itemName),
                MR.BaseName(sortedBids[1].name),
                MR.FormatGold(uniformPrice)))
        else
            local nameTags = {}
            for i = 1, winCount do
                table.insert(nameTags, "[" .. MR.BaseName(sortedBids[i].name) .. "]")
            end
            sendChat(string.format("[경매] %s ×%d 판매완료!  %d등 균일가 %s  (%s)",
                MR.CleanItemLink(item.itemLink) or MR.CleanItemName(item.itemName),
                winCount,
                winCount,
                table.concat(nameTags, ""),
                MR.FormatGold(uniformPrice)))
        end

        -- 변형 안내 (채팅에 추가로 출력)
        if item.hasVariant and winCount > 1 then
            local bestLink = linkAssign[1]
            local tag = (bestLink and (bestLink:find(":3524:", 1, true)
                         or bestLink:find(":3524|", 1, true)))
                        and "★파괴불가" or "★변형"
            MR.Print(string.format("%s 아이템 → %s 에게 우선 배정",
                tag, sortedBids[1].name), MR.COLOR.gold)
        end

        -- 사운드
        if MR.cfg.soundEnabled then
            PlaySound(MR.cfg.soundSold, "Master")
        end

        -- TradeLog 기록 + pendingWinners 구성
        local myName = MR.FullName("player") or ""
        for i = 1, winCount do
            local wName = sortedBids[i].name
            local wLink = linkAssign[i]
            local logIdx = MR.TradeLog.Add(wLink, item.itemName, item.texture, wName, uniformPrice, item.bossGroup)
            -- 거래기록 탭에서 "[경매판매]" 라벨 표시용 (수동거래와 시각 구분)
            do
                local e = MR.TradeLog[logIdx]
                if e then e.tradeOrigin = "auction"; if MR.TradeLog.Save then MR.TradeLog.Save() end end
            end

            -- 가상 낙찰 거래가 Sold() 전에 완료되었던 경우: 디퍼된 paidGold 즉시 적용.
            -- 매칭 우선순위: (1) name + paidGold==uniformPrice 정확 일치, (2) name + bid==uniformPrice,
            -- (3) name 만 (마지막 폴백). 정확 일치를 먼저 시도해서 같은 사람이 여러 deferred 를
            -- 쌓은 케이스 (다중 슬롯 입찰 + 여러 가상낙찰) 에서 잘못된 항목에 paid 가 적용되는
            -- silent-loss 를 방어.
            local matchedDeferred = false
            if MR.Auction._deferredPreliminary then
                local function _tryMatch(predicate)
                    for di = #MR.Auction._deferredPreliminary, 1, -1 do
                        local d = MR.Auction._deferredPreliminary[di]
                        if predicate(d) then
                            MR.TradeLog.UpdateTrade(logIdx, d.paidGold)
                            MR.Print(string.format(
                                "[가상 낙찰 확정] %s 거래 기록 완료 (납부 %s / 낙찰가 %s)",
                                wName, MR.FormatGold(d.paidGold), MR.FormatGold(uniformPrice)),
                                MR.COLOR.green)
                            table.remove(MR.Auction._deferredPreliminary, di)
                            return true
                        end
                    end
                    return false
                end
                -- 1차: paid 가 균일가와 정확히 일치 (가장 신뢰)
                matchedDeferred = _tryMatch(function(d)
                    return MR.NamesMatch(d.name, wName) and d.paidGold == uniformPrice
                end)
                -- 2차: bid (가상 낙찰 시점 입찰가) 가 현재 균일가와 일치
                if not matchedDeferred then
                    matchedDeferred = _tryMatch(function(d)
                        return MR.NamesMatch(d.name, wName) and (d.bid or 0) == uniformPrice
                    end)
                end
                -- 3차: 이름만 (호환 폴백 — 기존 동작 보존)
                if not matchedDeferred then
                    matchedDeferred = _tryMatch(function(d)
                        return MR.NamesMatch(d.name, wName)
                    end)
                end
            end

            if MR.NamesMatch(wName, myName) then
                -- 공대장 본인 낙찰: 거래 없이 즉시 납부 완료로 기록
                if not matchedDeferred then
                    MR.TradeLog.UpdateTrade(logIdx, uniformPrice)
                end
                MR.Print(string.format("본인 낙찰 %s (%s) → 분배 풀에 자동 포함",
                    item.itemName, MR.FormatGold(uniformPrice)), MR.COLOR.gold)
            elseif not matchedDeferred then
                -- 디퍼 매칭이 없으면 정상 pending 등록 (거래는 아직 진행 안 됨)
                local newPending = {
                    name     = wName,
                    itemLink = wLink,
                    bid      = uniformPrice,
                    logEntry = MR.TradeLog[logIdx],
                }
                table.insert(AC.pendingWinners, newPending)
                -- 거래창이 이미 열려있고 그 거래 대상이 이번 낙찰자면, 거래창에 동적 추가
                if MR.Auction.AugmentTradeForNewWinner then
                    MR.Auction.AugmentTradeForNewWinner(newPending)
                end
            end
            -- 매칭된 경우: 거래는 이미 끝나서 pendingWinners 등록 불필요
        end

        -- 매칭 안 된 가상 낙찰 처리:
        -- 거래 자체는 성사돼서 골드가 공대장에게 들어왔으므로, 그냥 버리지 말고 TradeLog 에
        -- 비정상 거래로 기록 → 총 판매 골드에 반영. 사용자가 사후에 수동 정리 가능.
        -- (예: 거래자 X 가 1위였다가 트레이드 완료 후 Y가 더 높게 입찰해 X 가 최종 1위 아님)
        if MR.Auction._deferredPreliminary and #MR.Auction._deferredPreliminary > 0 then
            for _, d in ipairs(MR.Auction._deferredPreliminary) do
                local recoveredIdx = MR.TradeLog.Add(
                    item.itemLink, item.itemName, item.texture,
                    d.name,
                    d.bid or d.paidGold or 0,    -- 명목 낙찰가: 가상 낙찰 시점 입찰가
                    item.bossGroup)
                MR.TradeLog.UpdateTrade(recoveredIdx, d.paidGold or 0)
                MR.Print(string.format(
                    "[가상 낙찰 무효] %s 가 최종 낙찰자가 아닙니다. 받은 %s 는 비정상 거래로 기록됩니다 (확인 후 수동 정리 권장).",
                    d.name, MR.FormatGold(d.paidGold or 0)), MR.COLOR.orange)
                MR.Debug(string.format(
                    "[Trade] deferred-preliminary 무효 → 비정상 거래 기록: name=%s bid=%s paidGold=%s logIdx=%s",
                    tostring(d.name), tostring(d.bid),
                    tostring(d.paidGold), tostring(recoveredIdx)))
            end
            MR.Auction._deferredPreliminary = {}
        end

        -- 이번 경매에서 새로 추가된 첫 낙찰자를 거래 훅용 fallback 으로 설정
        if #AC.pendingWinners > pendingCountBefore then
            local newIdx = pendingCountBefore + 1
            MR.Auction.lastWinner     = AC.pendingWinners[newIdx].name
            MR.Auction.lastWinnerItem = AC.pendingWinners[newIdx].itemLink
        end

        -- 부분 유찰: drop 수량보다 입찰자가 적었을 때 미판매분을 FailedItems로
        -- 예: 2개 드랍, 1명 입찰 → 1개 판매, 1개 유찰
        if slots > winCount then
            local unsoldQty = slots - winCount
            MR.FailedItems.Add(item, unsoldQty)
            MR.Print(string.format(
                "%s 부분 유찰: %d개 중 %d개만 판매, %d개 미판매로 기록",
                item.itemName or "?", slots, winCount, unsoldQty), MR.COLOR.orange)
        end
    end

    -- 아이템 목록에서 제거 후 다음 진행
    local removedIndex = AC.itemIndex
    AC.itemIndex = nil
    MR.Debug(string.format(
        "Sold: scheduling post-sold advance in 2s (removedIndex=%s sequential=%s)",
        tostring(removedIndex), tostring(AC.sequential)))
    C_Timer.After(2, function()
        MR.Debug(string.format(
            "post-sold timer FIRE: state=%s sequential=%s pausedByEncounter=%s",
            tostring(AC.state), tostring(AC.sequential), tostring(AC.pausedByEncounter)))
        -- 2초 사이 ENCOUNTER_START 발화 시: Reset 이 pausedByEncounter=false 로 덮어쓰면서
        -- 보스 전투 중 "재개" 메시지/카운트다운이 오발화될 수 있음. 인카운터 / 로딩 중이면
        -- Reset 과 TryAdvance 모두 보류 (재개는 OnEncounterEnd / OnPlayerEnteringWorld 에서).
        if AC.pausedByEncounter or AC.pausedByLoading then
            MR.Debug("post-sold SKIP: paused by encounter/loading")
            return
        end
        MR.Auction.Reset()
        MR.Auction.TryAdvance(removedIndex)
    end)
end

--------------------------------------------------------------------------------
-- 일시정지 / 재개 (보스 전투 + 로딩)
-- 둘 다 공대장(애드온 운영자)의 일방향 상태 → 다른 공대원에게는 채팅으로 알림 송출 +
-- 본인 UI 에는 상단 배너로 표시.
--------------------------------------------------------------------------------

-- 큐 우회 직송. SafeSendChat 은 ENCOUNTER_END 까지 큐잉이 되어 인카운터 시작 시점에는
-- 메시지가 묶이거나 누락될 수 있으니, 이런 "지금 즉시 알려야 할" 메시지는 직송.
local function sendChatNow(msg, channel)
    if not msg or msg == "" then return end
    pcall(SendChatMessage, msg, channel or MR.cfg.auctionChannel or "RAID")
end

-- 애드온이 "일하는 중"인지 (대기 메시지 송출 여부 판단용)
local function isAddonBusy()
    return AC.sequential or AC.state ~= MR.AUCTION_STATE.IDLE
end

-- 일시정지 사유 — UI 배너에 표시하기 위해 외부에서 호출
function MR.Auction.GetPauseReason()
    if AC.pausedByEncounter then return "encounter" end
    if AC.pausedByLoading   then return "loading"   end
    return nil
end

local function notifyBannerChange()
    if MR.UpdateStatusBanner then MR.UpdateStatusBanner() end
end

--------------------------------------------------------------------------------
-- 보스 전투 일시정지 / 재개 (ENCOUNTER_START / ENCOUNTER_END)
--------------------------------------------------------------------------------
function MR.Auction.OnEncounterStart()
    local active = (AC.state == MR.AUCTION_STATE.WAITING
                 or AC.state == MR.AUCTION_STATE.COUNTDOWN
                 or AC.state == MR.AUCTION_STATE.GRACE)
    if not active then
        notifyBannerChange()
        return
    end
    cancelAllTimers()
    AC.pausedByEncounter = true
    AC.inPreview = false   -- 살펴보기 중이었어도 보스 전투로 강제 종료
    AC.state = MR.AUCTION_STATE.WAITING
    sendChatNow("[경매] 전투중 대기")
    notifyBannerChange()
    fireUpdate()
end

function MR.Auction.OnEncounterEnd()
    MR.FlushChatQueue()
    if not AC.pausedByEncounter then
        notifyBannerChange()
        return
    end
    AC.pausedByEncounter = false
    sendChatNow("[경매] 재개")
    notifyBannerChange()
    local active = (AC.state == MR.AUCTION_STATE.WAITING
                 or AC.state == MR.AUCTION_STATE.COUNTDOWN
                 or AC.state == MR.AUCTION_STATE.GRACE)
    if not active then return end
    startSilenceTimer()
end

--------------------------------------------------------------------------------
-- 공대장 로딩(존 변경) 일시정지 / 재개 (PLAYER_LEAVING_WORLD / PLAYER_ENTERING_WORLD)
-- 로딩 직전엔 짧은 시간 채팅을 보낼 수 있으니 직송으로 알림. 로딩 직후 자동 재개.
--------------------------------------------------------------------------------
function MR.Auction.OnPlayerLeavingWorld()
    if not isAddonBusy() then return end
    if AC.pausedByEncounter then return end  -- 인카운터 중이면 그쪽 메시지 우선
    AC.pausedByLoading = true
    AC.inPreview = false   -- 살펴보기 중이었어도 로딩으로 강제 종료
    cancelAllTimers()
    sendChatNow("[경매] 로딩 대기")
    notifyBannerChange()
    fireUpdate()
end

function MR.Auction.OnPlayerEnteringWorld(isInitialLogin, isReloadingUi)
    if isInitialLogin or isReloadingUi then return end
    if not AC.pausedByLoading then
        notifyBannerChange()
        return
    end
    AC.pausedByLoading = false
    sendChatNow("[경매] 재개")
    notifyBannerChange()
    local active = (AC.state == MR.AUCTION_STATE.WAITING
                 or AC.state == MR.AUCTION_STATE.COUNTDOWN
                 or AC.state == MR.AUCTION_STATE.GRACE)
    if active then startSilenceTimer() end
end

-- 경매 강제 종료 (중단)
function MR.Auction.Stop()
    cancelAllTimers()
    if AC.state ~= MR.AUCTION_STATE.IDLE then
        sendChat("[경매] 경매 중단됨")
    end
    AC.sequential = false
    AC.pausedItemIndex = nil
    MR.Auction.Reset()
end

--------------------------------------------------------------------------------
-- 전체 연속경매 시작 (sequential 모드)
-- auto 체크된 아이템을 순서대로 자동 진행
--------------------------------------------------------------------------------
function MR.Auction.StartSequential()
    if not canStartAuction() then
        MR.Print("공격대장만 경매를 시작할 수 있습니다. (레이드 인스턴스 내)", MR.COLOR.red)
        return false
    end
    if AC.state ~= MR.AUCTION_STATE.IDLE then
        MR.Print("이미 경매 진행 중입니다.", MR.COLOR.red)
        return false
    end
    -- 일시정지 후 재개: 저장된 인덱스부터 시작
    local startIdx = AC.pausedItemIndex
    AC.pausedItemIndex = nil

    -- 시퀀셜 경매 대상 판별: 테스트 가짜 행(_isTest)만 제외, 나머지 모두 포함.
    -- (구버전 modeBtn 시절 auctionMode="manual"로 저장된 레거시 데이터도 정상 경매)
    local function isAuctionable(entry)
        return entry and not entry._isTest
    end

    if startIdx and isAuctionable(MR.ItemList[startIdx]) then
        AC.sequential = true
        MR.Auction.Start(startIdx)
        fireUpdate()
        return true
    end
    MR.Debug("StartSequential scan — MR.ItemList 내부 순서:")
    for i, entry in ipairs(MR.ItemList) do
        MR.Debug(string.format(
            "  [%d] name=%s mode=%s bg=%s group=%s link=%s",
            i, tostring(entry.itemName), tostring(entry.auctionMode),
            tostring(entry.bossGroup), tostring(entry.groupNumber),
            tostring(entry.itemLink)))
    end
    for i, entry in ipairs(MR.ItemList) do
        if isAuctionable(entry) then
            AC.sequential = true
            sendChat("[경매] 경매 준비중")
            MR.Auction.Start(i)
            fireUpdate()
            return true
        end
    end
    MR.Print("경매할 아이템이 없습니다.", MR.COLOR.gray)
    return false
end

-- 전체 연속경매 일시정지 (현재 아이템 인덱스 저장)
function MR.Auction.PauseSequential()
    AC.pausedItemIndex = AC.itemIndex  -- 현재 경매 중인 아이템 기억
    AC.sequential = false
    cancelAllTimers()
    sendChat("[경매] 경매 일시정지")
    MR.Auction.Reset()
end

-- 전체 연속경매 완전 중지 (재개 불가)
function MR.Auction.StopSequential()
    MR.Debug(string.format(
        "StopSequential ENTER: state=%s sequential=%s itemIndex=%s countStep=%s",
        tostring(AC.state), tostring(AC.sequential),
        tostring(AC.itemIndex), tostring(AC.countStep)))
    AC.sequential = false
    AC.pausedItemIndex = nil
    cancelAllTimers()
    if AC.state ~= MR.AUCTION_STATE.IDLE then
        sendChat("[경매] 경매 전체 중단")
    end
    MR.Auction.Reset()
    MR.Debug(string.format(
        "StopSequential EXIT: state=%s sequential=%s",
        tostring(AC.state), tostring(AC.sequential)))
end

function MR.Auction.Reset()
    cancelAllTimers()
    AC.state       = MR.AUCTION_STATE.IDLE
    AC.itemIndex   = nil
    AC.topBidder   = nil
    AC.topBid      = 0
    AC.winnerSlots = 1
    AC.pausedByEncounter = false
    AC.inPreview         = false
    AC._postZero         = false
    wipe(AC.bidHistory)
    wipe(AC.allPlayerBids)
    wipe(AC.bidFirstTime)
    prevTopSnapshot = {}
    -- pendingWinners는 거래 완료 전까지 유지 (Reset에서 지우지 않음)
    -- _deferredPreliminary 는 Sold() 에서 처리되지만 Stop/Encounter 등 Sold 미경유 경로 대비
    -- 안전망으로 Reset 시점에 정리. Sold 흐름에선 이미 비어있는 상태.
    if MR.Auction._deferredPreliminary and #MR.Auction._deferredPreliminary > 0 then
        MR.Debug(string.format("Reset: stale _deferredPreliminary 정리 %d 건",
            #MR.Auction._deferredPreliminary))
    end
    MR.Auction._deferredPreliminary = nil
    fireUpdate()
end

--------------------------------------------------------------------------------
-- pendingWinners 에서 특정 logEntry 참조하는 항목 제거.
-- "취소 후 재경매"로 PENDING/PARTIAL TradeLog 항목을 지울 때 호출 → 스테일 참조 누적 방지.
-- 스테일 참조가 남으면 그 낙찰자의 다음 거래에서 OnTradeAccept 의 logIdx 검색이 실패하여
-- UpdateTrade 가 호출되지 않음 → 거래는 됐는데 paidGold=0 유지 → 총골드에 안 잡힘.
--------------------------------------------------------------------------------
function MR.Auction.RemovePendingByLogEntry(logEntry)
    if not logEntry or not AC.pendingWinners then return 0 end
    local removed = 0
    for i = #AC.pendingWinners, 1, -1 do
        if AC.pendingWinners[i].logEntry == logEntry then
            table.remove(AC.pendingWinners, i)
            removed = removed + 1
        end
    end
    if removed > 0 then
        MR.Debug(string.format("RemovePendingByLogEntry: %d 스테일 항목 제거", removed))
        -- 첫 번째 항목 갱신
        if #AC.pendingWinners > 0 then
            MR.Auction.lastWinner     = AC.pendingWinners[1].name
            MR.Auction.lastWinnerItem = AC.pendingWinners[1].itemLink
        else
            MR.Auction.lastWinner     = nil
            MR.Auction.lastWinnerItem = nil
        end
    end
    return removed
end

--------------------------------------------------------------------------------
-- 리로드/재접속 복구: TradeLog 의 PENDING 상태 엔트리로 pendingWinners 재구성
-- ADDON_LOADED 에서 TradeLog.Load() 직후 호출
--------------------------------------------------------------------------------
function MR.Auction.RebuildPendingFromTradeLog()
    if not MR.TradeLog or not MR.TRADE_STATE then return end
    wipe(AC.pendingWinners)
    for _, e in ipairs(MR.TradeLog) do
        if e.state == MR.TRADE_STATE.PENDING then
            table.insert(AC.pendingWinners, {
                name     = e.winner,
                itemLink = e.itemLink,
                bid      = e.bid or 0,
                logEntry = e,
            })
        end
    end
    if #AC.pendingWinners > 0 then
        MR.Auction.lastWinner     = AC.pendingWinners[1].name
        MR.Auction.lastWinnerItem = AC.pendingWinners[1].itemLink
        MR.Debug(string.format(
            "RebuildPendingFromTradeLog: %d건 복구 (첫 낙찰=%s)",
            #AC.pendingWinners, tostring(MR.Auction.lastWinner)))
    end
end

--------------------------------------------------------------------------------
-- 자동 다음 아이템 진행
-- 이전 항목 제거 전 인덱스를 기준으로 다음 auto 항목 탐색
--------------------------------------------------------------------------------
function MR.Auction.TryAdvance(removedIndex)
    MR.Debug(string.format(
        "TryAdvance ENTER: removedIndex=%s sequential=%s state=%s",
        tostring(removedIndex), tostring(AC.sequential), tostring(AC.state)))
    -- 목록에서 해당 인덱스 제거
    MR.ItemList.Remove(removedIndex)

    -- sequential 모드가 아니면 다음 아이템으로 진행하지 않음 (개별경매)
    if not AC.sequential then
        MR.Debug("TryAdvance SKIP: sequential=false")
        return
    end

    -- 남은 목록에서 첫 번째 정상 아이템 자동 시작 (테스트 행만 제외)
    for i, item in ipairs(MR.ItemList) do
        if not item._isTest then
            C_Timer.After(1, function()
                MR.Auction.Start(i, true)
            end)
            return
        end
    end
    -- auto 항목 더 없으면 sequential 종료 후 IDLE
    sendChat("[경매] 경매 종료", "RAID_WARNING")
    AC.sequential = false
    fireUpdate()
end

--------------------------------------------------------------------------------
-- 채팅 파싱 (CHAT_MSG_RAID, CHAT_MSG_RAID_WARNING)
--------------------------------------------------------------------------------
function MR.Auction.OnChatMsg(msg, sender)
    -- sender 는 이벤트 경계(MimRaid.lua 의 CHAT_MSG_* 핸들러)에서 이미 정규화됨.
    -- 슬래시 커맨드 등 다른 경로에서 들어온 경우를 대비해 한 번 더 정규화.
    sender = MR.CanonicalName(sender) or sender

    -- ParseBids 를 먼저: 숫자 메시지가 아니면 그냥 잡담이므로 어떤 경고도 띄우지 않고 무시.
    -- (state 체크보다 먼저 해서 "ㅋㅋ" 같은 잡담이 늦은입찰 경고를 트리거하지 않게)
    local newBids = MR.ParseBids(msg)
    if not newBids then
        MR.Debug(string.format("OnChatMsg SKIP ParseBids=nil sender=%s msg=%s",
            tostring(sender), tostring(msg)))
        return
    end

    -- 경매가 받을 수 있는 상태인지 확인. 아니면 진단 + 늦은입찰 경고.
    if AC.state ~= MR.AUCTION_STATE.WAITING
       and AC.state ~= MR.AUCTION_STATE.COUNTDOWN
       and AC.state ~= MR.AUCTION_STATE.GRACE then
        MR.Debug(string.format(
            "OnChatMsg SKIP state=%s sender=%s msg=%s",
            tostring(AC.state), tostring(sender), tostring(msg)))
        -- 최근 Sold 이후 윈도우 (state=SOLD 또는 Sold 후 5초 이내 IDLE) → 가시 경고 송출.
        -- 다음 경매가 시작되면 state 가 WAITING 으로 바뀌어 이 분기 자체를 안 거침 → 스팸 없음.
        local sinceSold = MR.Auction._lastSoldAt and (time() - MR.Auction._lastSoldAt) or nil
        local recentSold = (AC.state == MR.AUCTION_STATE.SOLD)
            or (AC.state == MR.AUCTION_STATE.IDLE and sinceSold and sinceSold < 5)
        if recentSold then
            sendChat(string.format("[경매] %s님 경매 종료 이후 입찰하셨습니다.",
                MR.BaseName(sender) or sender))
        end
        return
    end

    -- 보스 전투 중 일시정지: 입찰 무시 (재개 후 다시 받아야 함)
    if AC.pausedByEncounter then
        MR.Debug(string.format("OnChatMsg SKIP pausedByEncounter sender=%s msg=%s",
            tostring(sender), tostring(msg)))
        return
    end

    -- COUNTDOWN/GRACE 상태인데 inPreview=true 면 stale → 자동 복구
    if AC.inPreview and
       (AC.state == MR.AUCTION_STATE.COUNTDOWN or AC.state == MR.AUCTION_STATE.GRACE) then
        MR.Debug(string.format(
            "OnChatMsg: stale inPreview=true 를 감지 (state=%s) → false 로 복구",
            tostring(AC.state)))
        AC.inPreview = false
    end

    -- 1슬롯 경매에 다중입찰 들어오면 최고값만 사용 (관대 처리)
    if AC.winnerSlots <= 1 and #newBids > 1 then
        newBids = { newBids[1] }  -- 이미 내림차순이므로 [1]이 최고값
    end

    -- 최소 입찰 미달 + 레이스 단위 배수 검증 (둘 다 가시 안내).
    -- 예: minBid=2, unit=1만골이면 1만골 입찰은 "최소 레이스 금액은 2만골 입니다" 안내.
    -- 예: unit=1만골이면 1.5만/2.5만 같은 비배수 입찰은 "레이스 단위는 1만골 입니다" 안내.
    local minBidGold = MR.cfg.minBid * MR.cfg.goldUnit
    local unit       = MR.cfg.goldUnit or 10000
    for _, b in ipairs(newBids) do
        if b < minBidGold then
            sendChat(string.format("[경매] 최소 레이스 금액은 %s 입니다.",
                MR.FormatGold(minBidGold)))
            return
        end
        if b % unit ~= 0 then
            sendChat(string.format("[경매] 레이스 단위는 %s 입니다.",
                MR.FormatGold(unit)))
            return
        end
    end

    local prevBids = AC.allPlayerBids[sender]

    -- 동일 금액 재입력: 이전 배열과 새 배열이 완전히 동일 (개수 + 각 값)
    if prevBids and #prevBids == #newBids then
        local same = true
        for i = 1, #newBids do
            if prevBids[i] ~= newBids[i] then same = false; break end
        end
        if same then
            MR.Debug(string.format("OnChatMsg SKIP 동일금액 재입력 sender=%s",
                tostring(sender)))
            return
        end
    end

    -- 입찰가 검증 (한국 와우 골드팟 룰):
    --   (1) 동률 금지: 자신의 newBids 가 타인의 입찰가와 같으면 안 됨 (자기 자신 이전 가격은 OK).
    --   (2) 컷오프: 신규 입찰자는 N위(winnerSlots) 입찰가보다 높아야 (낙찰 가능성 확보).
    -- 거부 시 minRequired (cutoff/동률값 + 단위, 다시 동률이면 추가 단위) 를 미리 계산해서 안내.
    local othersFlat   = flattenAndSort(sender)
    local takenBids    = {}
    for _, o in ipairs(othersFlat) do takenBids[o.bid] = true end
    local cutoff       = 0
    if #othersFlat >= AC.winnerSlots then
        cutoff = othersFlat[AC.winnerSlots].bid
    end
    -- unit 은 위쪽 minBid 검증 블록에서 이미 선언됨 (재사용)

    -- base 값보다 한 단위 위에서 시작, 이미 점유된 입찰가면 한 단위씩 올림
    local function computeMinRequired(base)
        local r = base + unit
        while takenBids[r] do r = r + unit end
        return r
    end

    -- (1) 동률 검사: 신규/기존 모두 적용
    for _, b in ipairs(newBids) do
        if takenBids[b] then
            sendChat(string.format("[경매] %s 이상 입찰하셔야 합니다.",
                MR.FormatGold(computeMinRequired(b))))
            return
        end
    end

    -- (2) 컷오프 검사: 신규 입찰자만 (본인은 오타정정/하향 허용)
    if not prevBids and newBids[1] <= cutoff then
        sendChat(string.format("[경매] %s 이상 입찰하셔야 합니다.",
            MR.FormatGold(computeMinRequired(cutoff))))
        return
    end

    -- 입찰 갱신
    local now = time()
    local prevTimes = AC.bidFirstTime[sender] or {}
    local newTimes = {}
    for _, b in ipairs(newBids) do
        newTimes[b] = prevTimes[b] or now  -- 기존 금액이면 이전 시각 유지
    end
    AC.bidFirstTime[sender] = newTimes
    AC.allPlayerBids[sender] = newBids

    for _, b in ipairs(newBids) do
        table.insert(AC.bidHistory, { name = sender, bid = b, timestamp = now })
    end

    -- topBidder / topBid 재계산 (flatten 기반, 동률 tiebreak 은 bidFirstTime)
    local prevTopBidder = AC.topBidder
    AC.topBidder = nil
    AC.topBid    = 0
    local flat = flattenAndSort()
    if flat[1] then
        AC.topBidder = flat[1].name
        AC.topBid    = flat[1].bid
    end

    -- 가상 낙찰 거래 중 1등 변경 → 거래창 즉시 닫음 + 잘못된 자동 기록 차단
    local ctw = MR.Auction.currentTradeWinners
    if ctw and ctw[1] and ctw[1]._preliminary
        and prevTopBidder and AC.topBidder
        and not MR.NamesMatch(prevTopBidder, AC.topBidder)
    then
        MR.Print(string.format(
            "1위 변경 (%s -> %s). 가상 낙찰 거래창을 닫습니다.",
            MR.BaseName(prevTopBidder), MR.BaseName(AC.topBidder)),
            MR.COLOR.orange)
        -- Race 방어: 이미 양쪽 수락 상태였더라도 OnTradeAccept 가 잘못된 자동 기록을 만들지 않도록
        -- _tradeRejected 플래그 set → OnTradeAccept 진입 즉시 return (early-exit at function head)
        MR.Auction._tradeRejected = true
        if CloseTrade then pcall(CloseTrade) end
    end

    MR.Debug("Auction: bids", table.concat((function()
        local t = {}
        for _, b in ipairs(newBids) do table.insert(t, MR.FormatGold(b)) end
        return t
    end)(), ","), "by", sender,
        "(slots:", AC.winnerSlots, "top:", MR.FormatGold(AC.topBid), ")")

    -- 입찰 공지
    if AC.winnerSlots <= 1 then
        -- 모든 수락 입찰에 대해 현재 1위 공지. 다중 낙찰과 동일 포맷으로 통일.
        if AC.topBidder then
            sendChat(string.format("[경매] 1등:%s(%s)",
                MR.BaseName(AC.topBidder), MR.FormatGold(AC.topBid)))
        end
    else
        -- 다중 낙찰: 순위 변동 시 채팅 알림 (빈 슬롯은 "N등 없음"으로 표시)
        local newTop = getTopN(AC.winnerSlots)
        if topChanged(newTop) then
            local parts = {}
            for i = 1, AC.winnerSlots do
                local e = newTop[i]
                if e then
                    table.insert(parts, string.format("%d등:%s(%s)",
                        i, MR.BaseName(e.name), MR.FormatGold(e.bid)))
                else
                    table.insert(parts, string.format("%d등 없음", i))
                end
            end
            sendChat(string.format("[경매] %s", table.concat(parts, " / ")))
        end
        prevTopSnapshot = {}
        for i, e in ipairs(newTop) do prevTopSnapshot[i] = snapshotKey(e) end
    end

    fireUpdate()

    -- 카운트다운 지연 중 첫 입찰 → 지연 타이머 취소하고 즉시 카운트다운 시작.
    -- COUNTDOWN/GRACE 중 입찰 → 카운트다운 5부터 재시작 (표준 경매 동작).
    -- 단, _postZero 윈도우 (0 출력 후 ~150ms) 동안은 카운트 재시작 차단:
    --   입찰은 받지만 (위에서 topBidder 갱신 완료) 카운트 재시작 없이 그대로 Sold 진행.
    if AC.state == MR.AUCTION_STATE.WAITING then
        AC.inPreview = false
        MR.Auction.StartCountdown()
    elseif (AC.state == MR.AUCTION_STATE.COUNTDOWN
        or AC.state == MR.AUCTION_STATE.GRACE) and not AC._postZero then
        MR.Auction.StartCountdown()
    end
end

--------------------------------------------------------------------------------
-- 징표자 거래 시 파티 분배금 자동 입력
-- settlement.perPerson × 해당 공대원 서브그룹 인원수 → 거래창 골드란에 세팅
--
-- ⚠ DEAD CODE (호출 비활성화됨, v0.9.107~):
--   WoW 11.x 에서 GetRaidTargetIndex / UnitName 등이 secret-tainted 되어 전투/거래 컨텍스트에서
--   ADDON_ACTION_FORBIDDEN 자주 발생. 그래서 OnTradeShow 의 호출을 모두 제거했음 (line ~1573 참고).
--   본체는 향후 옵션 부활 가능성 대비해 그대로 보존. 호출하지 말 것.
--------------------------------------------------------------------------------
function MR.Auction.TryAutoFillDistributionGold()
    local tradeUnit = UnitExists("NPC") and "NPC" or "target"
    local tradeName = MR.FullName(tradeUnit)
    if not tradeName then return end
    local baseTradeeName = tradeName:match("^([^%-]+)") or tradeName

    if not MR.GetSettlement then return end
    local settlement = MR.GetSettlement()
    if not settlement or (settlement.perPerson or 0) <= 0 then return end

    local inRaid = IsInRaid()
    local prefix = inRaid and "raid" or "party"
    local n = GetNumGroupMembers()

    local subgroupCounts = {}
    if inRaid then
        for i = 1, n do
            local _, _, sg = GetRaidRosterInfo(i)
            if sg then subgroupCounts[sg] = (subgroupCounts[sg] or 0) + 1 end
        end
    end

    -- WoW 11.x: 거래 컨텍스트에서 GetRaidTargetIndex/UnitName 등이 시크릿 값으로 반환되어
    -- 비교/매치 연산이 taint 에러를 던지는 경우가 있음 → 유닛 검사를 통째로 pcall로 보호.
    for i = 1, n do
        local unit = prefix .. i
        local ok, partySize = pcall(function()
            local unitName = UnitName(unit)
            if not unitName then return nil end
            local baseUnitName = unitName:match("^([^%-]+)") or unitName
            if baseUnitName ~= baseTradeeName then return nil end
            local mark = tonumber(GetRaidTargetIndex(unit))
            if not (mark and mark > 0) then return nil end
            local sz = 5
            if inRaid then
                local _, _, sg = GetRaidRosterInfo(i)
                if sg and subgroupCounts[sg] then sz = subgroupCounts[sg] end
            end
            return sz
        end)
        if ok and partySize then
            local partyGold = settlement.perPerson * partySize
            -- 전투 중 SetTradeMoney 는 protected → 오버레이 표시만 하고 자동 입력 SKIP
            if not (InCombatLockdown and InCombatLockdown()) then
                SetTradeMoney(partyGold * 10000)
            end
            MR.Auction.ShowDistributionOverlay(tradeName, partyGold)
            MR.Print(string.format(
                "징표자 [%s] %d명 파티 → 분배금 %s 자동 입력됨",
                tradeName, partySize, MR.FormatGold(partyGold)), MR.COLOR.gold)
            return
        end
    end
end

--------------------------------------------------------------------------------
-- 분배 거래 완료 기록
-- OnTradeAccept에서 내가 골드를 보내는 거래(= 분배)일 때 호출
--------------------------------------------------------------------------------
function MR.Auction.RecordDistribution(targetName, paidGold)
    playTradeSound(SOUND_TRADE_DONE)

    -- 기대 금액(오버레이에서 세팅됨)과 비교해 status 판정
    local expected = MR.Auction._expectedDist or 0
    local status = "done"
    if expected > 0 then
        if paidGold > expected then status = "over"
        elseif paidGold < expected then status = "short"
        end
    end

    if MR.RaidHistory and MR.RaidHistory.AddDistribution then
        MR.RaidHistory.AddDistribution(targetName, paidGold, status)
    end
    if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end

    -- 거래기록 탭 가시화: 공대장이 골드 송금한 거래도 TradeLog 에 entry 추가.
    -- 라벨은 "[골드 거래]" 로 통일 (분배인지 일반 송금인지 자동 구분 어려워 의미 분류 통합).
    -- 방향(보냄)은 거래기록 탭에서 받은금액 컬럼 (-) 주황 + stateIcon "송금" 으로 식별.
    -- bid=0/paidGold=0 이라 분배 풀(bidTotal/paidTotal)에는 영향 없음 — 실제 송금 정보는
    -- distributionGold 필드 + RaidHistory.distributions 에 보존.
    if MR.TradeLog and MR.TradeLog.Add then
        local logIdx = MR.TradeLog.Add(nil, "[골드 거래]", nil, targetName, 0, 0)
        local entry = MR.TradeLog[logIdx]
        if entry then
            entry.tradeAuditType    = "distribution"   -- 분배 풀 제외 + 표시 분기 (내부 키, 사용자 노출 X)
            entry.distributionGold  = paidGold
            if MR.TradeLog.Save then MR.TradeLog.Save() end
        end
        MR.TradeLog.UpdateTrade(logIdx, 0)   -- DONE 상태로
    end

    MR.Print(string.format("분배 완료: %s ← %s", targetName, MR.FormatGold(paidGold)), MR.COLOR.green)
end

--------------------------------------------------------------------------------
-- 기여 거래 완료 기록 (공대원 → 공대장 골드만, 아이템 없음)
-- TradeLog 에 entry 추가 → 총 골드에 자동 합산. RaidHistory에도 별도 트래킹.
--------------------------------------------------------------------------------
function MR.Auction.RecordContribution(sourceName, paidGold)
    if not paidGold or paidGold <= 0 then return end
    playTradeSound(SOUND_TRADE_DONE)

    -- TradeLog 에 기여 entry 추가 → 분배 풀(총 골드) 에 자동 합산.
    -- itemName 은 "[골드 거래]" 만 — 구매자 컬럼에 sourceName 이 표시되므로 닉네임 중복 제거.
    local logIdx = MR.TradeLog.Add(
        nil,                                           -- itemLink: 없음
        "[골드 거래]",                                 -- 표시 라벨
        nil,                                           -- texture: 없음
        sourceName,
        paidGold,                                      -- bid = 기여 금액 (= paidGold)
        0)                                             -- bossGroup: 없음
    MR.TradeLog.UpdateTrade(logIdx, paidGold)          -- DONE 상태로

    -- RaidHistory 별도 트래킹
    if MR.RaidHistory and MR.RaidHistory.AddContribution then
        MR.RaidHistory.AddContribution(sourceName, paidGold)
    end
    if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end

    MR.Print(string.format("골드 거래 받음: %s → %s (분배 풀에 합산)",
        MR.BaseName(sourceName) or sourceName, MR.FormatGold(paidGold)),
        MR.COLOR.green)
end

--------------------------------------------------------------------------------
-- 거래창 자동 배치 큐 처리
-- 형상(transmog)/BoP 팝업이 뜨면 커서가 보류 상태라 연속 PickupContainerItem이
-- 이전 아이템을 덮어쓴다. TRADE_PLAYER_ITEM_CHANGED 이벤트로 슬롯이 실제 채워진
-- 뒤에야 다음 아이템을 집도록 순차 처리.
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- 진행 중인 거래창에 새 낙찰자 entry 동적 추가
-- 시나리오: A가 아이템1 낙찰 → 거래창 열어 거래 진행 중에 아이템2 카운트 종료 → A가 아이템2도 낙찰
-- 이때 열린 거래창에 아이템2를 자동 배치하고 오버레이 금액도 갱신
--------------------------------------------------------------------------------
function MR.Auction.AugmentTradeForNewWinner(newPending)
    if not newPending or not newPending.name then return end
    if not (TradeFrame and TradeFrame.IsShown and TradeFrame:IsShown()) then return end
    if not MR.Auction.currentTradeName then return end
    if not MR.NamesMatch(newPending.name, MR.Auction.currentTradeName) then return end

    -- 중복 방지: currentTradeWinners 에 같은 logEntry 가 이미 있으면 skip
    MR.Auction.currentTradeWinners = MR.Auction.currentTradeWinners or {}
    for _, w in ipairs(MR.Auction.currentTradeWinners) do
        if w.logEntry == newPending.logEntry then return end
    end

    -- 거래창 슬롯 가용 확인 (1-6 중 비어있는 슬롯)
    local nextSlot = nil
    for i = 1, 6 do
        if not GetTradePlayerItemLink(i) then nextSlot = i; break end
    end
    if not nextSlot then
        MR.Print(string.format(
            "[주의] %s 거래창 슬롯 가득 참. 추가 낙찰분(%s)은 거래 완료 후 새 거래에서 처리해주세요.",
            MR.BaseName(newPending.name), newPending.itemLink or "?"),
            MR.COLOR.orange)
        return
    end

    -- currentTradeWinners 에 entry 추가 (OnTradeAccept 가 이걸 보고 UpdateTrade 함)
    table.insert(MR.Auction.currentTradeWinners, {
        name     = newPending.name,
        itemLink = newPending.itemLink,
        bid      = newPending.bid or 0,
        logEntry = newPending.logEntry,
    })

    -- 아이템 자동 배치 (전투 중 protected 호출은 placementQueue 가 알아서 재시도)
    AC.placementQueue = AC.placementQueue or {}
    table.insert(AC.placementQueue, { link = newPending.itemLink, slotIdx = nextSlot })
    if not CursorHasItem() and not (InCombatLockdown and InCombatLockdown()) then
        MR.Auction.StartPlacement()
    end

    -- 오버레이 갱신 (새 합계 표시)
    MR.Auction.ShowTradeOverlay(MR.Auction.currentTradeName, MR.Auction.currentTradeWinners)

    MR.Print(string.format(
        "[거래창 추가] %s 도 낙찰되어 거래에 추가됨 (%s)",
        MR.BaseName(newPending.name) or newPending.name,
        MR.FormatGold(newPending.bid or 0)),
        MR.COLOR.green)
end

function MR.Auction.StartPlacement()
    if not AC.placementQueue or #AC.placementQueue == 0 then
        AC.placementQueue = nil
        return
    end
    -- 커서에 잔존 아이템 (직전 거래 취소/거리이탈로 cursor pickup 잔존 등) 이 있으면 잠시 후 재시도
    -- 이전엔 그냥 return 해서 자동 배치가 영구 실패하던 버그 → 0.3초 간격 재시도
    if CursorHasItem() then
        C_Timer.After(0.3, MR.Auction.StartPlacement)
        return
    end
    local job = AC.placementQueue[1]
    local bag, slot = MR.Auction.FindItemInBags(job.link)
    if not bag or not slot then
        MR.Print(string.format("[주의] 가방에서 못 찾음: %s", job.link), MR.COLOR.orange)
        table.remove(AC.placementQueue, 1)
        C_Timer.After(0.1, MR.Auction.StartPlacement)
        return
    end
    -- 전투 중에는 PickupContainerItem/ClickTradeButton 이 protected → 짧게 재시도 대기
    if InCombatLockdown and InCombatLockdown() then
        C_Timer.After(0.5, MR.Auction.StartPlacement)
        return
    end
    C_Container.PickupContainerItem(bag, slot)
    ClickTradeButton(job.slotIdx)
end

-- 잘못 올린 아이템 감지: 거래창 슬롯 vs pendingWinners / FailedItems 매칭.
-- (1) 거래 대상이 아닌 다른 낙찰자의 아이템 → 강력 경고
-- (2) 거래 대상이 낙찰자인데 안팔린 아이템 (FailedItem) 도 같이 올림 → 혼용 경고
-- 매번 슬롯 변경 시 호출. 새로 발견된 (itemID,kind) 만 채팅 출력 (재방송 방지).
local _placedWarnIds = {}   -- key = "itemID|type" → true if already warned this trade
local function _checkPlacedMismatch()
    if not (TradeFrame and TradeFrame.IsShown and TradeFrame:IsShown()) then return end
    local tradeTarget = MR.Auction.currentTradeName
    if not tradeTarget then return end

    -- 거래 대상이 pendingWinners 에 있는지 (Case 2 판단용)
    local targetIsPendingWinner = false
    if AC.pendingWinners then
        for _, pw in ipairs(AC.pendingWinners) do
            if MR.NamesMatch(pw.name, tradeTarget) then
                targetIsPendingWinner = true
                break
            end
        end
    end

    local activeWarns = {}
    for slot = 1, 6 do
        local placedLink = GetTradePlayerItemLink(slot)
        if placedLink then
            local placedID = placedLink:match("item:(%d+)")
            if placedID then
                local warnType, warnMsg = nil, nil

                -- Case 1: 다른 낙찰자의 아이템
                if AC.pendingWinners then
                    for _, pw in ipairs(AC.pendingWinners) do
                        if pw.itemLink and not MR.NamesMatch(pw.name, tradeTarget) then
                            local pwID = pw.itemLink:match("item:(%d+)")
                            if pwID == placedID then
                                warnType = "other"
                                warnMsg = string.format("%s 의 낙찰 아이템! 다른 사람에게 잘못 주는 중",
                                    MR.BaseName(pw.name) or pw.name)
                                break
                            end
                        end
                    end
                end

                -- Case 2: 거래 대상이 낙찰자인데 안팔린 아이템도 같이 올림
                if not warnType and targetIsPendingWinner and MR.FailedItems then
                    for _, fi in ipairs(MR.FailedItems) do
                        if fi.itemLink then
                            local fID = fi.itemLink:match("item:(%d+)")
                            if fID == placedID then
                                warnType = "unsold"
                                warnMsg = "안팔린 아이템 — 낙찰결제 후 잔액 없으면 미정리됨"
                                break
                            end
                        end
                    end
                end

                if warnType then
                    local key = placedID .. "|" .. warnType
                    if not _placedWarnIds[key] then
                        _placedWarnIds[key] = true
                        MR.Print("[주의] " .. warnMsg .. " " .. placedLink, MR.COLOR.red)
                    end
                    table.insert(activeWarns, "! " .. warnMsg)
                end
            end
        end
    end

    if ovWarning then
        if #activeWarns > 0 then
            ovWarning:SetText("|cffff4444" .. table.concat(activeWarns, "\n") .. "|r")
            ovWarning:Show()
            -- 오버레이 높이 동적 조정 (경고 라인 수에 따라)
            tradeOverlay:SetHeight(80 + #activeWarns * 24)
        else
            ovWarning:SetText("")
            ovWarning:Hide()
        end
    end
end

function MR.Auction.OnTradePlayerItemChanged()
    -- 자동 배치 큐 진행
    if AC.placementQueue and #AC.placementQueue > 0 then
        local job = AC.placementQueue[1]
        local placedLink = GetTradePlayerItemLink(job.slotIdx)
        -- itemID 일치 검증: 자동 배치 직전 사용자가 동일 슬롯에 다른 아이템을 수동 배치한
        -- 경우 큐가 잘못된 아이템을 "완료" 처리하고 다음 아이템을 다음 슬롯에 PickupContainerItem
        -- 호출 → 의도와 다른 조합. itemID 일치할 때만 큐 pop, 아니면 다음 tick 에 재확인.
        if placedLink then
            local placedID = placedLink:match("item:(%d+)")
            local expectedID = job.link and job.link:match("item:(%d+)")
            if expectedID and placedID == expectedID then
                table.remove(AC.placementQueue, 1)
                if #AC.placementQueue > 0 then
                    C_Timer.After(0.15, MR.Auction.StartPlacement)
                else
                    AC.placementQueue = nil
                end
            else
                MR.Debug(string.format(
                    "[Placement] slot=%d 에 다른 아이템 발견 (expected=%s placed=%s) → 큐 pop 보류",
                    job.slotIdx, tostring(expectedID), tostring(placedID)))
            end
        end
    end

    -- 잘못 올린 아이템 검사 (자동 배치 / 수동 배치 모두)
    _checkPlacedMismatch()
end

--------------------------------------------------------------------------------
-- 거래창 훅: 낙찰자가 거래 요청했을 때 아이템 자동 등록
-- 낙찰자가 아닌 경우 징표자 분배금 자동 입력 시도
-- MimRaid.lua의 ADDON_LOADED에서 hooksecurefunc 등록
--------------------------------------------------------------------------------
function MR.Auction.OnTradeShow()
    -- CRITICAL: 새 거래 시작 시점에 _alreadyFinalized 무조건 리셋.
    -- 이유: 이전 거래의 ERR_TRADE_COMPLETE 가 _finalizeTrade 호출 → _alreadyFinalized=true 후
    -- 어떤 이유(lockdown / 리로드 / 보스 시작)로 TRADE_CLOSED 미발화 → HideTradeOverlay 미호출
    -- → _alreadyFinalized=true 가 다음 거래까지 잔존 → 다음 거래의 finalize 가 SKIP →
    -- OnTradeAccept 자체가 실행 안 되어 낙찰자 통째로 미납 잔존하는 silent-loss.
    -- HideTradeOverlay 도 같은 리셋을 하지만, 이 함수 자체가 누락된 경로 방어 차원으로 직접.
    MR.Auction._alreadyFinalized = false

    -- 방어적 cleanup: 이전 거래가 비정상 종료(거리/전투/타임아웃) 되어 stale state 가
    -- 남아있을 수 있으므로 무조건 초기화 후 새 거래 컨텍스트를 구성한다.
    -- HideTradeOverlay 는 idempotent (이미 깨끗하면 no-op) 이라 안전.
    if MR.Auction.HideTradeOverlay then
        MR.Auction.HideTradeOverlay()
    end

    local unit = UnitExists("NPC") and "NPC" or "target"
    local tradeTarget = MR.FullName(unit)
    MR.Auction.currentTradeName = tradeTarget  -- AcceptTrade 시점에 NPC 이름이 사라질 수 있어 캐시

    if MR.Debug then
        MR.Debug(string.format(
            "[Trade] OnTradeShow target=%s pendingWinners=%d lastWinner=%s state=%s",
            tostring(tradeTarget), AC.pendingWinners and #AC.pendingWinners or -1,
            tostring(MR.Auction.lastWinner), tostring(AC.state)))
    end

    -- 거래 대상의 미결제 항목 수집:
    --   1) pendingWinners (PENDING — 아직 거래 안한 낙찰. 아이템 자동 배치 대상)
    --   2) TradeLog 의 PARTIAL (이전 거래에서 부족 납부된 잔액. 아이템은 이미 전달됨 → 자동 배치 X)
    if tradeTarget then
        local matched = {}
        if AC.pendingWinners then
            for _, winner in ipairs(AC.pendingWinners) do
                if MR.NamesMatch(winner.name, tradeTarget) then
                    table.insert(matched, winner)
                end
            end
        end
        -- TradeLog 잔액/누락 fallback:
        --   PARTIAL: 이전 거래에서 부족 결제 → 다음 거래에서 잔액 회수 (아이템 배치 X)
        --   PENDING: (Fix B) pendingWinners 에 누락된 PENDING 도 보강 → 자동 배치 + 정산
        -- 안전망: 이미 matched 에 동일 logEntry 가 있으면 SKIP (이중 매칭 방지)
        if MR.TradeLog and MR.TRADE_STATE then
            local seenEntries = {}
            for _, m in ipairs(matched) do
                if m.logEntry then seenEntries[m.logEntry] = true end
            end
            for i = 1, #MR.TradeLog do
                local e = MR.TradeLog[i]
                if MR.NamesMatch(e.winner, tradeTarget) and not seenEntries[e] then
                    if e.state == MR.TRADE_STATE.PARTIAL then
                        local remainder = (e.bid or 0) - (e.paidGold or 0)
                        if remainder > 0 then
                            table.insert(matched, {
                                name           = e.winner,
                                itemLink       = e.itemLink,
                                itemName       = e.itemName,
                                bid            = remainder,
                                logEntry       = e,
                                _remainderOnly = true,
                                _originalBid   = e.bid or 0,
                            })
                            seenEntries[e] = true
                        end
                    elseif e.state == MR.TRADE_STATE.PENDING then
                        table.insert(matched, {
                            name     = e.winner,
                            itemLink = e.itemLink,
                            itemName = e.itemName,
                            bid      = e.bid or 0,
                            logEntry = e,
                            _fromTradeLogFallback = true,
                        })
                        seenEntries[e] = true
                    end
                end
            end
        end
        if #matched > 0 then
            -- 거래창 슬롯은 6개 제한 → 이번 거래에 올릴 대상만 잘라냄
            local TRADE_SLOT_MAX = 6
            local thisTrade = {}
            for i = 1, math.min(#matched, TRADE_SLOT_MAX) do
                thisTrade[i] = matched[i]
            end
            if #matched > TRADE_SLOT_MAX then
                MR.Print(string.format(
                    "[주의] %s 낙찰 %d개 중 %d개만 이번 거래에 자동 배치. 나머지 %d개는 거래 완료 후 추가 거래 필요.",
                    tradeTarget, #matched, TRADE_SLOT_MAX, #matched - TRADE_SLOT_MAX), MR.COLOR.orange)
            end

            MR.Auction.currentTradeWinners = thisTrade
            MR.Auction.lastWinner     = thisTrade[1].name
            MR.Auction.lastWinnerItem = thisTrade[1].itemLink
            MR.Auction.ShowTradeOverlay(tradeTarget, thisTrade)

            -- 배치 큐 구성 (잔액-only 항목은 아이템 이미 전달됨 → 배치 SKIP, 슬롯 번호 재계산)
            AC.placementQueue = {}
            local slotIdx = 1
            for _, w in ipairs(thisTrade) do
                if not w._remainderOnly and w.itemLink then
                    table.insert(AC.placementQueue, { link = w.itemLink, slotIdx = slotIdx })
                    slotIdx = slotIdx + 1
                end
            end
            MR.Auction.StartPlacement()
            return
        end
    end

    -- 활성 경매 중에 1등이 거래를 시도한 케이스: 차단하지 않고 "낙찰 대기 중" 안내만.
    -- 자동 배치/숫자 체크는 안 함 → 낙찰 확정 시 AugmentTradeForNewWinner 가 자동 처리.
    -- _tradeRejected 를 set 하지 않으므로, 거래가 실제 완료되면 OnTradeAccept fallback 이
    -- PENDING 엔트리 매칭으로 골드를 기록 (silent-loss 방어).
    local isActiveAuction = (AC.state == MR.AUCTION_STATE.WAITING
                          or AC.state == MR.AUCTION_STATE.COUNTDOWN
                          or AC.state == MR.AUCTION_STATE.GRACE)
    if isActiveAuction and AC.topBidder and tradeTarget
        and MR.NamesMatch(tradeTarget, AC.topBidder)
    then
        MR.Auction.ShowWaitingOverlay(tradeTarget, AC.topBidder)
        return
    end

    -- 입찰자 경고: 현재 경매에 입찰은 했지만 1등(=낙찰 예정자)이 아닌 사람이 거래 시도
    -- → 분배 거래/일반 거래로 폴백되는데 공대장이 혼동할 수 있어 경고
    if isActiveAuction and tradeTarget and AC.allPlayerBids
        and AC.allPlayerBids[tradeTarget]
    then
        MR.Print(string.format(
            "[주의] %s 낙찰받은 사람이 아닙니다. 거래 이유를 확인하세요.",
            MR.BaseName and MR.BaseName(tradeTarget) or tradeTarget),
            MR.COLOR.orange)
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            pcall(PlaySound, SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON, "Master")
        end
        -- 차단은 안 함 — 정당한 분배/기여 거래일 수도 있음. 안내만 띄우고 fall through.
    end
    -- (target ~= topBidder 인 경우) 기존 OnTradeShow 흐름 그대로:
    -- 아래쪽 lastWinner 분기로 자연 진입.
    -- ※ TryAutoFillDistributionGold (징표자 자동 분배금 입력) 호출은 비활성화됨 —
    --   WoW 11.x 에서 GetRaidTargetIndex / UnitName 등이 secret-tainted 되어 전투 컨텍스트에서
    --   ADDON_ACTION_FORBIDDEN 에러를 자주 유발. 공대장이 거래창에 분배금을 직접 입력해야 함.
    --   ([분배 송금] entry 자체는 OnTradeAccept 의 RecordDistribution 분기에서 그대로 생성됨)

    -- pendingWinners에 없으면 단독 lastWinner 확인
    if not MR.Auction.lastWinner then
        return
    end

    if not MR.NamesMatch(tradeTarget, MR.Auction.lastWinner) then
        return
    end

    local itemLink = MR.Auction.lastWinnerItem
    -- TradeLog에서 낙찰 금액 조회하여 오버레이 표시
    local _, logEntry = MR.TradeLog.FindPending(tradeTarget)
    MR.Auction.ShowTradeOverlay(tradeTarget, logEntry and logEntry.bid or 0)

    if not itemLink or CursorHasItem() then return end
    -- 전투 중 PickupContainerItem/ClickTradeButton 차단 → SKIP (수동 배치는 가능)
    if InCombatLockdown and InCombatLockdown() then return end

    local bag, slot = MR.Auction.FindItemInBags(itemLink)
    if bag and slot then
        C_Container.PickupContainerItem(bag, slot)
        ClickTradeButton(1)
    end
end

--------------------------------------------------------------------------------
-- 완전 추적용 거래 요약 기록 (Option B + T-Raid 식 검증 데이터)
-- TRADE_ACCEPT_UPDATE 시점에 TradeAnnounce 가 캐싱한 양쪽 스냅샷을 기반으로
-- "[거래완료] 닉네임 받:... 보:... 수령:... 송금:..." (또는 "[거래취소]") entry 를
-- TradeLog 에 1건 추가. bid=0, paidGold=0, state=DONE 으로 분배 풀에는 영향 없음.
-- entry 에 raw copper 값을 직접 보관해 정산 검증 패널에서 합산.
-- result: "complete" | "cancelled"
-- RaidHistory.buildRecord / TradeLog.GetSummary 는 audit entry 를 자체 통계에서 제외.
--------------------------------------------------------------------------------
local function _logTradeSummary(tradeTarget, result)
    result = result or "complete"
    if not (MR.TradeAnnounce and MR.TradeAnnounce.GetSnapshot) then return end
    local s = MR.TradeAnnounce.GetSnapshot()
    if not s then return end

    -- 슬롯별 아이템 → {link, count} 리스트 (raw 데이터 — UI 가 컬럼별로 분리 표시)
    local function collectItems(items)
        local out = {}
        for i = 1, 7 do
            local it = items and items[i]
            if it and it.link then
                table.insert(out, { link = it.link, count = it.count or 1 })
            end
        end
        return out
    end

    local gaveList = collectItems(s.playerItems)
    local gotList  = collectItems(s.targetItems)
    local sentCopper = tonumber(s.playerCopper) or 0
    local recvCopper = tonumber(s.targetCopper) or 0
    local sentG = math.floor(sentCopper / 10000)
    local recvG = math.floor(recvCopper / 10000)

    -- complete 인데 양쪽 다 0 (빈 거래) 이면 기록 안 함 — 의미 없는 잡음 방지
    -- cancelled 는 사유 추적 위해 빈 거래도 기록
    if result == "complete"
        and sentG == 0 and recvG == 0 and #gaveList == 0 and #gotList == 0 then
        return
    end

    -- itemName 은 짧은 라벨만 (컬럼별로 winner/받은/보낸 골드/아이템 분리 표시).
    -- 옛 형식 (한 줄에 다 박힌 라벨) 은 1.0.92 미만 SavedVariables 에서만 보임.
    local prefix = (result == "cancelled") and "[거래취소]" or "[거래완료]"

    local logIdx = MR.TradeLog.Add(nil, prefix, nil, tradeTarget, 0, 0)
    -- 컬럼 분리 표시용 raw 데이터 entry 에 직접 보관
    local entry = MR.TradeLog[logIdx]
    if entry then
        entry.tradeReceivedCopper = recvCopper
        entry.tradeSentCopper     = sentCopper
        entry.tradeAuditType      = result   -- "complete" | "cancelled"
        entry.tradeReceivedItems  = gotList  -- [{link, count}, ...]
        entry.tradeSentItems      = gaveList
        if MR.TradeLog.Save then MR.TradeLog.Save() end
    end
    MR.TradeLog.UpdateTrade(logIdx, 0)   -- bid=0, paidGold=0 → DONE

    MR.Debug(string.format("[Trade] Summary logged idx=%d result=%s prefix=%s",
        logIdx, result, prefix))
end

--------------------------------------------------------------------------------
-- UI_INFO_MESSAGE 기반 거래 완료/취소 1차 판정 (T-Raid 방식)
-- ERR_TRADE_COMPLETE / ERR_TRADE_CANCELLED 는 WoW 가 직접 보내는 공식 시그널이라
-- 100% 신뢰 가능. _bothAccepted 자체 래치보다 우선해서 사용.
-- _alreadyFinalized 로 중복 진입(UI_INFO + TRADE_CLOSED 둘 다 호출되는 케이스) 방어.
-- TRADE_CLOSED 는 폴백 + cleanup 용으로 동작.
--------------------------------------------------------------------------------
function MR.Auction.OnUIInfoMessage(messageType)
    if not GetGameMessageInfo then return end
    local ok, errorName = pcall(GetGameMessageInfo, messageType)
    if not ok or not errorName then return end

    if errorName == "ERR_TRADE_COMPLETE" then
        MR.Debug("[Trade] ERR_TRADE_COMPLETE → finalize(complete)")
        MR.Auction._finalizeTrade("complete")
    elseif errorName == "ERR_TRADE_CANCELLED" then
        MR.Debug("[Trade] ERR_TRADE_CANCELLED → finalize(cancelled)")
        MR.Auction._finalizeTrade("cancelled")
    end
end

-- 거래 종료 처리. result 별로 분기:
--   complete  → audit 요약 + 기존 낙찰/분배/기여 처리 (OnTradeAccept)
--   cancelled → audit 요약만 (분배/기여 처리 없음)
-- 중복 호출 방지: _alreadyFinalized 가 true 면 SKIP.
function MR.Auction._finalizeTrade(result)
    if MR.Auction._alreadyFinalized then
        MR.Debug(string.format(
            "[Trade] finalize SKIP: already finalized (result=%s)", tostring(result)))
        return
    end
    MR.Auction._alreadyFinalized = true

    local tradeTarget = MR.Auction.currentTradeName
        or MR.FullName(UnitExists("NPC") and "NPC" or "target")

    if result == "cancelled" then
        if tradeTarget then
            _logTradeSummary(tradeTarget, "cancelled")
        else
            MR.Debug("[Trade] cancelled audit SKIP: target empty")
        end
        return
    end

    -- complete: 기존 거래 처리 (OnTradeAccept) 호출
    MR.Auction.OnTradeAccept()
end

-- 거래창 골드 확인: 낙찰자가 넣은 금액 검증
-- GetTargetTradeMoney() = 거래 상대방(낙찰자)이 거래창에 넣은 금액 (copper)
function MR.Auction.OnTradeAccept()
    -- 거절 거래(1등 아닌 사람과의 거래)는 기록하지 않음
    if MR.Auction._tradeRejected then
        MR.Auction._tradeRejected = false
        MR.Debug("[Trade] OnTradeAccept skip: rejected trade (구매자 아님)")
        return
    end

    local tradeTarget = MR.Auction.currentTradeName
        or MR.FullName(UnitExists("NPC") and "NPC" or "target")

    if not tradeTarget then
        MR.Print("[거래감지] 대상 이름 없음. 거래 기록 불가", MR.COLOR.red)
        return
    end

    -- 완전 추적: 모든 거래에 대해 요약 entry 추가 (감사용. 분배 영향 없음).
    -- 다른 어떤 record 경로(낙찰/분배/기여/안팔린/excess) 보다 먼저 1건 기록 →
    -- 거래는 됐는데 모든 분기에서 미스되는 silent-loss 케이스도 최소한 요약은 남음.
    _logTradeSummary(tradeTarget, "complete")

    if MR.Debug then
        local ctwCount = MR.Auction.currentTradeWinners and #MR.Auction.currentTradeWinners or 0
        MR.Debug(string.format(
            "[Trade] OnTradeAccept target=%s ctw=%d lastWinner=%s targetCopper=%s myCopper=%s state=%s",
            tostring(tradeTarget), ctwCount, tostring(MR.Auction.lastWinner),
            tostring(MR.Auction._lastTargetCopper), tostring(MR.Auction._lastMyCopper),
            tostring(AC.state)))
    end

    -- 거래내역 귓말: 낙찰/분배/일반거래 모두 거래가 성사된 시점이면 전송
    if MR.TradeAnnounce then MR.TradeAnnounce.SendIfEnabled() end

    -- 안팔린 아이템 (FailedItems) 거래 감지: 거래창에 올린 아이템 중 안팔린 목록과 매칭.
    -- TRADE_CLOSED 후엔 GetTradePlayerItemLink 가 nil 가능 → TradeAnnounce 의 snapshot 활용
    -- (snapshot 은 TRADE_ACCEPT_UPDATE 마다 갱신되므로 양쪽 수락 시점에 최신 상태가 캐시됨).
    -- 매칭은 역방향 iteration (큰 인덱스부터) → 가장 최근에 추가된 엔트리 우선 소진.
    -- (이전 세션 잔여 엔트리가 먼저 매칭되어 현재 세션 엔트리가 안 지워지는 문제 방지)
    local placedFailed = {}
    if MR.FailedItems then
        local snapItems = MR.TradeAnnounce and MR.TradeAnnounce.GetPlayerItems
                          and MR.TradeAnnounce.GetPlayerItems()
        local claimedIdx = {}
        for slot = 1, 7 do
            local placedLink
            if snapItems and snapItems[slot] then
                placedLink = snapItems[slot].link
            else
                placedLink = GetTradePlayerItemLink(slot)
            end
            if placedLink then
                local placedID = placedLink:match("item:(%d+)")
                MR.Debug(string.format(
                    "[Trade] FailedDetect slot=%d link=%s id=%s",
                    slot, tostring(placedLink), tostring(placedID)))
                if placedID then
                    -- 역방향: 최신 엔트리 우선 매칭
                    for failIdx = #MR.FailedItems, 1, -1 do
                        local failedEntry = MR.FailedItems[failIdx]
                        if failedEntry and failedEntry.itemLink then
                            local failID = failedEntry.itemLink:match("item:(%d+)")
                            if failID == placedID then
                                local already = claimedIdx[failIdx] or 0
                                local maxQty  = failedEntry.quantity or 1
                                if already < maxQty then
                                    claimedIdx[failIdx] = already + 1
                                    table.insert(placedFailed, {
                                        slot    = slot,
                                        link    = placedLink,
                                        failIdx = failIdx,
                                        entry   = failedEntry,
                                    })
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        MR.Debug(string.format(
            "[Trade] FailedDetect result: placed=%d failedListSize=%d snapUsed=%s",
            #placedFailed, #MR.FailedItems, tostring(snapItems ~= nil)))
    end

    -- 헬퍼: 안팔린 아이템 N개에 available 골드를 균일 분배해 sale 기록 + FailedItems 소진.
    -- 반환: 사용 후 남은 골드 (leftover)
    local function processPlacedFailedSale(availableGold)
        local n = #placedFailed
        if n == 0 or availableGold <= 0 then return availableGold end
        local pricePer = math.floor(availableGold / n)
        if pricePer <= 0 then return availableGold end
        for _, fi in ipairs(placedFailed) do
            local logIdx = MR.TradeLog.Add(
                fi.link, fi.entry.itemName, fi.entry.texture,
                tradeTarget, pricePer, fi.entry.bossGroup or 0)
            MR.TradeLog.UpdateTrade(logIdx, pricePer)
        end
        -- FailedItems 소진 (큰 인덱스부터 → 작은 인덱스 안 밀림)
        local consumed = {}
        for _, fi in ipairs(placedFailed) do
            consumed[fi.failIdx] = (consumed[fi.failIdx] or 0) + 1
        end
        local sortedIdxs = {}
        for idx in pairs(consumed) do table.insert(sortedIdxs, idx) end
        table.sort(sortedIdxs, function(a, b) return a > b end)
        for _, idx in ipairs(sortedIdxs) do
            if MR.FailedItems.Consume then
                MR.FailedItems.Consume(idx, consumed[idx])
            end
        end
        MR.Print(string.format(
            "[안팔린 아이템 판매] %s → %d개, 1개당 %s (총 %s)",
            MR.BaseName(tradeTarget) or tradeTarget, n,
            MR.FormatGold(pricePer), MR.FormatGold(pricePer * n)),
            MR.COLOR.green)
        return availableGold - pricePer * n
    end

    -- 분배 거래 감지 (낙찰자 없음): 내가 보내면 분배, 상대가 보내면 기여
    if not MR.Auction.lastWinner then
        local myCopper     = MR.Auction._lastMyCopper or 0
        local targetCopper = MR.Auction._lastTargetCopper or 0

        -- 안팔린 아이템 판매 우선 처리
        if #placedFailed > 0 and targetCopper > 0 then
            local available = math.floor(targetCopper / 10000)
            local leftover = processPlacedFailedSale(available)
            if leftover > 0 and MR.Auction.RecordContribution then
                MR.Auction.RecordContribution(tradeTarget, leftover)
            end
            return
        end

        -- 기존 분배/기여 path
        if myCopper > 0 then
            local paidGold = math.floor(myCopper / 10000)
            MR.Auction.RecordDistribution(tradeTarget, paidGold)
        elseif targetCopper > 0 then
            local paidGold = math.floor(targetCopper / 10000)
            MR.Auction.RecordContribution(tradeTarget, paidGold)
        end
        return
    end

    -- 변형 경고: 낙찰자에게 추가옵션 없는 기본 아이템을 전달하는 경우 (전체 슬롯 검사)
    if AC.pendingWinners and #AC.pendingWinners > 0 then
        for slot = 1, 6 do
            local tradedLink = GetTradePlayerItemLink(slot)
            if tradedLink then
                local tID = tradedLink:match("item:(%d+)")
                for _, cw in ipairs(AC.pendingWinners) do
                    if MR.NamesMatch(cw.name, tradeTarget) and cw.itemLink then
                        local eID = cw.itemLink:match("item:(%d+)")
                        if tID == eID and tradedLink ~= cw.itemLink then
                            local tradedBonus   = MR.CountItemBonusFields(tradedLink)
                            local expectedBonus = MR.CountItemBonusFields(cw.itemLink)
                            if tradedBonus < expectedBonus then
                                MR.Print(string.format(
                                    "[주의] %s 에게 추가옵션 없는 기본 아이템 전달 중! (배정된 아이템과 다름)",
                                    tradeTarget), MR.COLOR.red)
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    -- 이 거래에 실제로 올라간 낙찰만 처리 (6슬롯 제한 고려)
    local ctw = MR.Auction.currentTradeWinners
    if not ctw or #ctw == 0 then
        -- fallback: 캐시 없으면 이름으로 전체 pending 수집 (구 경로)
        ctw = {}
        for i = 1, #MR.TradeLog do
            local e = MR.TradeLog[i]
            if MR.NamesMatch(e.winner, tradeTarget)
                and (e.state == MR.TRADE_STATE.PENDING or e.state == MR.TRADE_STATE.PARTIAL) then
                table.insert(ctw, { logEntry = e, bid = e.bid or 0, name = e.winner, itemLink = e.itemLink })
            end
        end
    end
    if #ctw == 0 then
        local targetCopper = MR.Auction._lastTargetCopper or 0
        local myCopper     = MR.Auction._lastMyCopper or 0

        -- 안팔린 아이템 판매 우선 처리 (placedFailed = 공대장 거래슬롯에 올린 FailedItems)
        if #placedFailed > 0 and targetCopper > 0 then
            local available = math.floor(targetCopper / 10000)
            local leftover = processPlacedFailedSale(available)
            if leftover > 0 and MR.Auction.RecordContribution then
                MR.Auction.RecordContribution(tradeTarget, leftover)
            end
            return
        end

        -- 거래창의 양쪽 슬롯 아이템 수집 (TradeAnnounce snapshot)
        local snap = MR.TradeAnnounce and MR.TradeAnnounce.GetSnapshot and MR.TradeAnnounce.GetSnapshot()
        local function _collectSnapItems(items)
            local out = {}
            if not items then return out end
            for slot = 1, 7 do
                local it = items[slot]
                if it and it.link then table.insert(out, it) end
            end
            return out
        end
        local pItems = _collectSnapItems(snap and snap.playerItems)   -- 공대장이 보낸 아이템
        local tItems = _collectSnapItems(snap and snap.targetItems)   -- 공대원이 보낸 아이템
        local paidG  = math.floor(targetCopper / 10000)               -- 공대원→공대장 골드
        local sentG  = math.floor(myCopper / 10000)                   -- 공대장→공대원 골드

        -- 헬퍼: 아이템 N개 + 가격 P 골드 → 각 아이템마다 TradeLog entry 추가 (가격은 N등분, 끝자리는 마지막).
        -- audit=true 면 paidGold=0, bid=0 (분배 풀 영향 없음, "[아이템 전달]" 라벨)
        local function _addItemSales(items, price, isAuditTransfer)
            local n = #items
            if n == 0 then return end
            if isAuditTransfer then
                -- 공대장이 공대원에게 아이템 전달 (분배 풀 영향 X)
                for _, it in ipairs(items) do
                    local label = "[아이템 전달]"
                    local logIdx = MR.TradeLog.Add(it.link, label, nil, tradeTarget, 0, 0)
                    MR.TradeLog.UpdateTrade(logIdx, 0)
                end
            else
                -- 공대원이 공대장에게 판매 (분배 풀 합산) — "[수동거래]" 라벨로 식별
                local per = math.floor(price / n)
                for idx, it in ipairs(items) do
                    local thisPay = (idx == n) and (price - per * (n - 1)) or per
                    local nm = it.name or (it.link and it.link:match("|h%[(.-)%]|h")) or "?"
                    local logIdx = MR.TradeLog.Add(it.link, nm, nil, tradeTarget, thisPay, 0)
                    local e = MR.TradeLog[logIdx]
                    if e then e.tradeOrigin = "manual" end
                    MR.TradeLog.UpdateTrade(logIdx, thisPay)
                end
                if MR.TradeLog.Save then MR.TradeLog.Save() end
            end
        end

        -- ── 케이스 분류 (수동 거래, ItemList 매칭 못한 경우) ──
        -- A. 공대원→공대장 아이템+골드 : 일반 sale 처럼 기록 (자동 경매 안 거친 수동 판매)
        if paidG > 0 and #tItems > 0 then
            _addItemSales(tItems, paidG, false)
            MR.Print(string.format(
                "[수동 판매] %s 가 아이템 %d개 + %s 보냄 → 일반 판매로 기록",
                MR.BaseName(tradeTarget) or tradeTarget, #tItems, MR.FormatGold(paidG)),
                MR.COLOR.gold)
            return
        end

        -- B. 공대원→공대장 골드만 : [골드 거래] (기존 동작)
        if paidG > 0 and #tItems == 0 then
            MR.Auction.RecordContribution(tradeTarget, paidG)
            return
        end

        -- C. 공대원→공대장 아이템만 (골드 0) : 환원/반환 등. audit-like 로 기록
        if paidG == 0 and #tItems > 0 and sentG == 0 and #pItems == 0 then
            for _, it in ipairs(tItems) do
                local logIdx = MR.TradeLog.Add(
                    it.link, "[아이템 받음]", nil, tradeTarget, 0, 0)
                MR.TradeLog.UpdateTrade(logIdx, 0)
            end
            MR.Print(string.format(
                "[수동 거래] %s 가 아이템 %d개 보냄 (골드 없음, 기록만)",
                MR.BaseName(tradeTarget) or tradeTarget, #tItems), MR.COLOR.gold)
            return
        end

        -- D, E, F: 공대장 → 공대원 (분배/전달)
        if sentG > 0 or #pItems > 0 then
            -- D/F. 골드 분배 부분 (있으면)
            if sentG > 0 then
                MR.Auction.RecordDistribution(tradeTarget, sentG)
            end
            -- E/F. 아이템 전달 부분 (있으면) — audit-like (분배 풀 영향 X)
            if #pItems > 0 then
                _addItemSales(pItems, 0, true)
                MR.Print(string.format(
                    "[수동 분배] %s 에게 아이템 %d개 전달 (기록만, 골드 영향 없음)",
                    MR.BaseName(tradeTarget) or tradeTarget, #pItems), MR.COLOR.gold)
            end
            return
        end

        -- 빈 거래 (양쪽 다 0, 아이템 없음) — 진단 메시지
        MR.Print(string.format("[거래감지] '%s' 빈 거래 감지 (lastWinner=%s)",
            tradeTarget, tostring(MR.Auction.lastWinner)), MR.COLOR.red)
        return
    end

    local expectedTotal = 0
    for _, w in ipairs(ctw) do expectedTotal = expectedTotal + (w.bid or 0) end

    -- TRADE_CLOSED 이후에는 GetTargetTradeMoney()가 신뢰 불가 → 오버레이 캐시만 사용.
    -- _lastTargetCopper 가 nil 이면 TRADE_ACCEPT_UPDATE 가 (1,1) 도달 못한 race condition
    -- (HideTradeOverlay 가 새 거래 시작 시 캐시 비움 → 이전 거래 stale 잔존 위험 차단).
    -- 0 으로 silent fallback 하면 0원 기록되어 미납 잔존 → 가시 경고로 진단 가능하게.
    local paidCopper = MR.Auction._lastTargetCopper
    if paidCopper == nil then
        MR.Print(string.format(
            "[주의] %s 거래의 받은 금액 캐시가 비어있습니다. " ..
            "TRADE_ACCEPT_UPDATE 누락 의심 — paidGold=0 으로 기록되어 미납 가능. " ..
            "/mr debug on 으로 재현 시 로그 확인 권장.",
            tradeTarget), MR.COLOR.red)
        MR.Debug(string.format(
            "[Trade] PAIDCOPPER-NIL target=%s ctw=%d alreadyFinalized=%s",
            tostring(tradeTarget), #ctw, tostring(MR.Auction._alreadyFinalized)))
        paidCopper = 0
    end
    local paidGold   = math.min(math.floor((tonumber(paidCopper) or 0) / 10000), MR.MAX_GOLD)

    -- 골드 거래 자동 흡수: 동일 사람의 prior [골드 거래] DONE 엔트리를 FIFO 예산에 포함
    -- (낙찰 전 카운트다운 중 골드만 거래 완료된 케이스 → 후속 아이템 거래에서 정산)
    local priorCredits = {}   -- list of {entry, gold} - oldest first
    local priorCreditTotal = 0
    if MR.TradeLog and MR.TRADE_STATE then
        for i = 1, #MR.TradeLog do
            local e = MR.TradeLog[i]
            if e.state == MR.TRADE_STATE.DONE
               and e.itemName
               and type(e.itemName) == "string"
               and e.itemName:find("^%[골드 거래%]")
               and MR.NamesMatch(e.winner, tradeTarget) then
                table.insert(priorCredits, { entry = e, gold = e.paidGold or 0 })
                priorCreditTotal = priorCreditTotal + (e.paidGold or 0)
            end
        end
    end

    -- paidGold 를 이 거래 대상 건들에 FIFO 로 분배 + TradeLog 업데이트
    local remaining = paidGold + priorCreditTotal
    for _, w in ipairs(ctw) do
        local logIdx = nil
        if w.logEntry then
            for i = 1, #MR.TradeLog do
                if MR.TradeLog[i] == w.logEntry then logIdx = i; break end
            end
        end
        -- 폴백: logEntry 가 없거나(가상 낙찰) 못 찾으면 이름으로 PENDING 엔트리 검색
        -- (가상 낙찰이 Sold() 후 실제 TradeLog 항목과 매칭되도록)
        if not logIdx then
            for i = #MR.TradeLog, 1, -1 do
                local e = MR.TradeLog[i]
                if MR.NamesMatch(e.winner, w.name or tradeTarget)
                    and (e.state == MR.TRADE_STATE.PENDING
                      or e.state == MR.TRADE_STATE.PARTIAL) then
                    logIdx = i
                    break
                end
            end
        end
        if logIdx then
            local need = w.bid or 0   -- 잔액-only 면 이미 (originalBid - oldPaid) 로 계산되어 있음
            local thisPay
            if remaining >= need then
                thisPay = need
                remaining = remaining - need
            elseif remaining > 0 then
                thisPay = remaining
                remaining = 0
            else
                thisPay = 0
            end
            if w._remainderOnly then
                -- 잔액 결제: 기존 paidGold 에 누적 (UpdateTrade 는 SET 이므로 oldPaid + thisPay 로 호출)
                -- CRITICAL: oldPaid 를 w.logEntry 의 캐시값이 아니라 현재 TradeLog[logIdx] 에서
                -- fresh 하게 읽음. w.logEntry 가 stale reference (Remove 후 dangling, 또는
                -- 같은 entry 가 ctw 에 두 번 들어가서 첫 처리 후의 값) 인 경우의 누적 오류 방어.
                local cur = MR.TradeLog[logIdx]
                local oldPaid = (cur and cur.paidGold) or 0
                MR.TradeLog.UpdateTrade(logIdx, oldPaid + thisPay)
            else
                MR.TradeLog.UpdateTrade(logIdx, thisPay)
            end
            MR.Debug(string.format(
                "[Trade] UpdateTrade logIdx=%d name=%s thisPay=%s remaining=%s remainderOnly=%s",
                logIdx, tostring(w.name or tradeTarget),
                MR.FormatGold(thisPay), MR.FormatGold(remaining),
                tostring(w._remainderOnly)))
        elseif w._preliminary then
            -- 가상 낙찰: Sold() 가 아직 안 돌아 TradeLog 항목 없음 → 잠시 보관해뒀다가 Sold 시 매칭
            local pgForThis = math.min(remaining, w.bid or 0)
            if pgForThis < (w.bid or 0) and remaining > 0 then
                pgForThis = remaining   -- 부족분 그대로 기록
            elseif pgForThis < 0 then
                pgForThis = 0
            end
            MR.Auction._deferredPreliminary = MR.Auction._deferredPreliminary or {}
            table.insert(MR.Auction._deferredPreliminary, {
                name     = w.name or tradeTarget,
                bid      = w.bid or 0,
                paidGold = pgForThis,
                ts       = time(),
            })
            remaining = math.max(0, remaining - pgForThis)
            MR.Print(string.format(
                "[가상 낙찰] %s 와 거래 먼저 완료 (%s). 경매 끝나면 자동 기록됩니다",
                tradeTarget, MR.FormatGold(pgForThis)), MR.COLOR.gold)
        else
            -- silent-loss 방지: logIdx 없고 preliminary 도 아닌 케이스
            -- (pendingWinners 의 stale logEntry 가 TradeLog 에서 삭제됐거나, 폴백 검색도 실패한 경우)
            -- 거래는 됐는데 어디에도 기록 안 되는 상황 → 사용자 가시 경고 출력
            MR.Print(string.format(
                "[주의] %s 거래 기록 매칭 실패! 받은 금액 %s 가 총 골드에 안 잡힐 수 있습니다. " ..
                "(/mr debug on 후 재현해 로그 확인 권장)",
                tradeTarget,
                MR.FormatGold(math.min(remaining, w.bid or 0))),
                MR.COLOR.red)
            MR.Debug(string.format(
                "[Trade] silent-loss logIdx=nil w.name=%s w.bid=%s logEntry=%s preliminary=%s remainderOnly=%s",
                tostring(w.name), tostring(w.bid),
                tostring(w.logEntry), tostring(w._preliminary), tostring(w._remainderOnly)))
        end
    end

    -- 흡수된 priorCredit 만큼 [골드 거래] 엔트리 제거/감액 + remaining 을 paidGold 기준으로 복원
    -- 우선순위: prior credit 먼저 소모, 그 다음 이번 거래의 paidGold
    if priorCreditTotal > 0 then
        local consumed         = (paidGold + priorCreditTotal) - remaining
        local fromPriorCredits = math.min(consumed, priorCreditTotal)
        local fromPaidGold     = consumed - fromPriorCredits
        remaining = paidGold - fromPaidGold   -- 이후 excess contribution 판정용

        local toConsume = fromPriorCredits
        for _, pc in ipairs(priorCredits) do
            if toConsume <= 0 then break end
            local entry = pc.entry
            if pc.gold <= toConsume then
                -- 완전 흡수: TradeLog 에서 제거 (현재 인덱스 재탐색)
                local curIdx = nil
                for i = 1, #MR.TradeLog do
                    if MR.TradeLog[i] == entry then curIdx = i; break end
                end
                if curIdx then
                    MR.TradeLog.Remove(curIdx)
                    MR.Debug(string.format(
                        "[Trade] absorbed [골드 거래] entry: %s %s",
                        tostring(entry.winner), MR.FormatGold(pc.gold)))
                end
                toConsume = toConsume - pc.gold
            else
                -- 부분 흡수: bid/paidGold 감액
                local newGold = pc.gold - toConsume
                entry.paidGold = newGold
                entry.bid      = newGold
                MR.TradeLog.Save()
                MR.Debug(string.format(
                    "[Trade] partially absorbed [골드 거래] entry: %s used=%s remain=%s",
                    tostring(entry.winner), MR.FormatGold(toConsume), MR.FormatGold(newGold)))
                toConsume = 0
            end
        end

        if fromPriorCredits > 0 then
            MR.Print(string.format(
                "[자동 정산] %s 의 이전 골드 거래 %s 흡수하여 낙찰 정산 완료",
                MR.BaseName(tradeTarget) or tradeTarget,
                MR.FormatGold(fromPriorCredits)), MR.COLOR.green)
        end
    end

    -- 안팔린 아이템 판매: 낙찰자 FIFO 정산 후 남은 골드로 균일 분배
    if #placedFailed > 0 and remaining > 0 then
        remaining = processPlacedFailedSale(remaining)
    end

    -- FIFO 분배 후 남은 금액(remaining > 0) → 같은 사람의 골드 거래로 자동 기록
    -- (낙찰 합계보다 더 보낸 경우 silent-loss 방지)
    if remaining > 0 and tradeTarget and MR.Auction.RecordContribution then
        MR.Auction.RecordContribution(tradeTarget, remaining)
        MR.Debug(string.format(
            "[Trade] excess auto-contribution name=%s amount=%s",
            tostring(tradeTarget), MR.FormatGold(remaining)))
    end

    if paidGold == expectedTotal then
        playTradeSound(SOUND_TRADE_DONE)
        MR.Print(string.format("%s 거래 완료! %s (%d건)",
            tradeTarget, MR.FormatGold(expectedTotal), #ctw), MR.COLOR.green)
    elseif paidGold > expectedTotal then
        playTradeSound(SOUND_MONEY_SHORT)
        local excess = paidGold - expectedTotal
        MR.Print(string.format("[주의] %s 초과납부!  받은 금액 %s  /  낙찰 합계 %s  (초과 %s 는 골드 거래로 자동 기록)",
            tradeTarget, MR.FormatGold(paidGold), MR.FormatGold(expectedTotal), MR.FormatGold(excess)), MR.COLOR.orange)
    else
        playTradeSound(SOUND_MONEY_SHORT)
        local shortage = expectedTotal - paidGold
        MR.Print(string.format("[주의] %s 금액 부족!  받은 금액 %s  /  낙찰 합계 %s  (부족 %s)",
            tradeTarget, MR.FormatGold(paidGold), MR.FormatGold(expectedTotal), MR.FormatGold(shortage)), MR.COLOR.orange)
    end

    -- pendingWinners 정리: 결제 완료된(DONE/PARTIAL) 항목만 제거.
    -- 결제 안 된(PENDING) 항목은 유지 → 다중 낙찰 중 일부만 거래 완료 케이스에서
    -- 다음 거래창 열 때 자동으로 다시 매칭됨.
    -- (Fix A) ctw 엔트리가 AugmentTradeForNewWinner / fallback 경유로 새 테이블일 수 있어
    -- 레퍼런스 동일성만 보면 매칭 실패. logEntry 도 함께 비교.
    if AC.pendingWinners then
        for _, w in ipairs(ctw) do
            local s = w.logEntry and w.logEntry.state
            local isPaid = (s == MR.TRADE_STATE.DONE or s == MR.TRADE_STATE.PARTIAL)
            if isPaid then
                for i = #AC.pendingWinners, 1, -1 do
                    local p = AC.pendingWinners[i]
                    if p == w or (w.logEntry and p.logEntry == w.logEntry) then
                        table.remove(AC.pendingWinners, i)
                        break
                    end
                end
            end
        end
        -- 남은 낙찰자가 있으면 다음 낙찰자를 lastWinner로
        if #AC.pendingWinners > 0 then
            MR.Auction.lastWinner     = AC.pendingWinners[1].name
            MR.Auction.lastWinnerItem = AC.pendingWinners[1].itemLink
            MR.Debug("OnTradeAccept: next pending winner", MR.Auction.lastWinner)
            return
        end
    end

    -- (Fix C) pendingWinners 가 비어있어도 TradeLog 에 PENDING 이 남아있으면 그것을 lastWinner 로
    -- (pendingWinners 가 어떤 이유로든 stale/비동기 상태여도 TradeLog 기준으로 복구)
    if MR.TradeLog and MR.TRADE_STATE then
        for _, e in ipairs(MR.TradeLog) do
            if e.state == MR.TRADE_STATE.PENDING then
                MR.Auction.lastWinner     = e.winner
                MR.Auction.lastWinnerItem = e.itemLink
                MR.Debug("OnTradeAccept: lastWinner restored from TradeLog PENDING",
                    tostring(e.winner))
                return
            end
        end
    end

    MR.Auction.lastWinner     = nil
    MR.Auction.lastWinnerItem = nil
end

--------------------------------------------------------------------------------
-- 인벤토리에서 아이템 링크로 슬롯 탐색
--------------------------------------------------------------------------------
function MR.Auction.FindItemInBags(itemLink)
    if not itemLink then return nil, nil end
    local targetID = itemLink:match("item:(%d+)")
    if not targetID then return nil, nil end

    -- 1차: 링크 완전 일치 탐색 (변형 아이템 정확 배정)
    -- 2차: baseID 일치 폴백
    local fallbackBag, fallbackSlot = nil, nil
    for bag = 0, NUM_BAG_FRAMES do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and not info.isLocked then
                local link = C_Container.GetContainerItemLink(bag, slot)
                if link then
                    if link == itemLink then
                        return bag, slot          -- 완전 일치
                    elseif link:match("item:(%d+)") == targetID and not fallbackBag then
                        fallbackBag  = bag        -- baseID 일치 폴백
                        fallbackSlot = slot
                    end
                end
            end
        end
    end
    return fallbackBag, fallbackSlot
end

--------------------------------------------------------------------------------
-- 거래창 낙찰 정보 오버레이
-- TradeFrame 우측에 부착 — 구매자·낙찰금액·실시간 입금액 표시
--------------------------------------------------------------------------------
local FONT = "Fonts\\2002.TTF"

local tradeOverlay = CreateFrame("Frame", "MimRaidTradeOverlay", UIParent, "BackdropTemplate")
tradeOverlay:SetSize(210, 80)
tradeOverlay:SetFrameStrata("HIGH")
tradeOverlay:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
tradeOverlay:SetBackdropColor(0.05, 0.05, 0.10, 0.92)
tradeOverlay:SetBackdropBorderColor(0.4, 0.4, 0.5, 1)
tradeOverlay:SetPoint("LEFT", "TradeFrame", "RIGHT", 6, 0)
tradeOverlay:Hide()

local ovTitle = tradeOverlay:CreateFontString(nil, "OVERLAY")
ovTitle:SetFont(FONT, 11)
ovTitle:SetTextColor(0.7, 0.85, 1)
ovTitle:SetPoint("TOPLEFT", tradeOverlay, "TOPLEFT", 10, -10)
ovTitle:SetText("")

local ovRequired = tradeOverlay:CreateFontString(nil, "OVERLAY")
ovRequired:SetFont(FONT, 12)
ovRequired:SetTextColor(1, 0.85, 0.1)
ovRequired:SetPoint("TOPLEFT", ovTitle, "BOTTOMLEFT", 0, -6)
ovRequired:SetJustifyH("LEFT")
ovRequired:SetSpacing(2)
ovRequired:SetText("")

local ovCurrent = tradeOverlay:CreateFontString(nil, "OVERLAY")
ovCurrent:SetFont(FONT, 12)
ovCurrent:SetPoint("TOPLEFT", ovRequired, "BOTTOMLEFT", 0, -4)
ovCurrent:SetText("")

-- 잘못 올린 아이템 경고 (다른 낙찰자 아이템 / 안팔린 아이템 혼용)
local ovWarning = tradeOverlay:CreateFontString(nil, "OVERLAY")
ovWarning:SetFont(FONT, 11)
ovWarning:SetTextColor(1, 0.3, 0.3)
ovWarning:SetPoint("TOPLEFT", ovCurrent, "BOTTOMLEFT", 0, -6)
ovWarning:SetPoint("TOPRIGHT", tradeOverlay, "TOPRIGHT", -10, 0)
ovWarning:SetJustifyH("LEFT")
ovWarning:SetSpacing(2)
ovWarning:SetWordWrap(true)
ovWarning:SetText("")
ovWarning:Hide()

-- 모드: "incoming" = 낙찰자가 골드 납부 / "outgoing" = 내가 분배금 송금
local ovExpected  = 0
local ovMode      = "incoming"
-- 양쪽 모두 수락 여부 (TRADE_ACCEPT_UPDATE에서 갱신 → TRADE_CLOSED에서 완료 판정)
local _bothAccepted = false

tradeOverlay:SetScript("OnUpdate", function()
    if not TradeFrame or not TradeFrame:IsShown() then return end
    local copper
    local label
    if ovMode == "outgoing" then
        copper = (GetTradeMoney and GetTradeMoney()) or 0       -- 내가 거래창에 넣은 골드
        label  = "송금액: "
        MR.Auction._lastMyCopper = copper
    else
        copper = (GetTargetTradeMoney and GetTargetTradeMoney()) or 0   -- 상대방이 거래창에 넣은 골드
        label  = "입금액: "
        MR.Auction._lastTargetCopper = copper  -- AcceptTrade 이후 API가 0 반환 대비 캐시
    end
    local current = math.floor(copper / 10000)
    if current >= ovExpected and ovExpected > 0 then
        ovCurrent:SetTextColor(0.2, 1, 0.3)
        ovCurrent:SetText(label .. MR.FormatGold(current))
    elseif current > 0 then
        ovCurrent:SetTextColor(1, 0.35, 0.35)
        ovCurrent:SetText(label .. MR.FormatGold(current))
    else
        ovCurrent:SetTextColor(0.5, 0.5, 0.5)
        ovCurrent:SetText(label .. "-")
    end
end)

-- 낙찰 거래 오버레이 (구매자가 골드 납부)
-- winners: { {name, itemLink, bid}, ... } 또는 숫자(단일 bid, 하위호환)
function MR.Auction.ShowTradeOverlay(targetName, winners)
    ovMode            = "incoming"
    _tradeSoundPlayed = false

    local lines = {}
    local total = 0
    if type(winners) == "table" then
        for _, w in ipairs(winners) do
            local display = (w.itemLink and MR.CleanItemLink(w.itemLink))
                or MR.CleanItemName(w.itemName or "?")
            local bidText = MR.FormatGold(w.bid or 0)
            if w._remainderOnly then
                bidText = bidText .. " |cffff8800(잔액)|r"
            end
            table.insert(lines, string.format("%s  %s", display, bidText))
            total = total + (w.bid or 0)
        end
    else
        total = tonumber(winners) or 0
    end
    ovExpected = total

    tradeOverlay:SetBackdropColor(0.05, 0.05, 0.10, 0.92)
    ovTitle:SetTextColor(0.7, 0.85, 1)
    ovTitle:SetText("구매자: " .. (targetName or "?"))

    if #lines > 0 then
        local txt = table.concat(lines, "\n")
        if #lines > 1 then
            txt = txt .. "\n합계: " .. MR.FormatGold(total)
        end
        ovRequired:SetText(txt)
        -- 동적 높이: 타이틀(25) + 각 줄(~15) + 합계(한 줄 추가) + 입금액(22) + 여백
        local extraLines = (#lines > 1) and (#lines + 1) or 1
        tradeOverlay:SetHeight(50 + extraLines * 15 + 22)
    else
        ovRequired:SetText("낙찰 금액: " .. MR.FormatGold(total))
        tradeOverlay:SetHeight(80)
    end
    ovCurrent:SetText("입금액: -")
    ovCurrent:SetTextColor(0.5, 0.5, 0.5)
    tradeOverlay:Show()
end

-- 대기 오버레이: 진행 중인 경매의 1등이 거래를 시도한 케이스
-- 차단하지 않고 "낙찰 대기 중" 만 안내 → 낙찰 확정되면 AugmentTradeForNewWinner 가 자동 처리
-- _tradeRejected 는 set 하지 않음 (핵심): 그래야 OnTradeAccept fallback 이 골드 기록할 수 있음
function MR.Auction.ShowWaitingOverlay(targetName, currentTopBidder)
    ovMode            = "incoming"
    ovExpected        = 0
    _tradeSoundPlayed = false

    tradeOverlay:SetBackdropColor(0.22, 0.18, 0.04, 0.95)
    ovTitle:SetTextColor(1.0, 0.82, 0.0)
    ovTitle:SetText("거래 대상: " .. (targetName or "?"))

    local msg = "|cffffcc00낙찰 대기 중|r\n"
        .. "|cff999999낙찰 확정 후 자동 처리됩니다|r"
    ovRequired:SetText(msg)
    ovCurrent:SetText("")
    ovCurrent:SetTextColor(0.6, 0.6, 0.6)
    tradeOverlay:SetHeight(80)
    tradeOverlay:Show()
end

-- 분배 거래 오버레이 (내가 골드 송금)
function MR.Auction.ShowDistributionOverlay(targetName, expectedGold)
    ovMode            = "outgoing"
    ovExpected        = expectedGold or 0
    -- RecordDistribution에서 status 판정에 쓸 수 있도록 테이블 필드로도 노출
    MR.Auction._expectedDist = ovExpected
    _tradeSoundPlayed = false
    tradeOverlay:SetBackdropColor(0.04, 0.10, 0.05, 0.92)
    ovTitle:SetTextColor(0.5, 1, 0.6)
    ovTitle:SetText("징표자: " .. (targetName or "?"))
    ovRequired:SetText("파티 분배금: " .. MR.FormatGold(ovExpected))
    ovCurrent:SetText("송금액: -")
    ovCurrent:SetTextColor(0.5, 0.5, 0.5)
    tradeOverlay:Show()
end

-- 상대방이 거래 확인 눌렀을 때 사운드 (TRADE_ACCEPT_UPDATE 이벤트 → MimRaid.lua에서 호출)
-- _tradeSoundPlayed 플래그로 중복 재생 방지 (금액 변경 시 (0,0)→(0,1) 재발화 대응)
function MR.Auction.OnTradeAcceptUpdate(playerAccepted, targetAccepted)
    local accepted = targetAccepted == 1
    local copper   = GetTargetTradeMoney() or 0
    local myCopper = (GetTradeMoney and GetTradeMoney()) or 0
    local current  = math.floor(copper / 10000)

    -- 양쪽 모두 수락한 순간 포착 → TRADE_CLOSED에서 완료 판정에 사용.
    -- LATCH 방식: 한 번 (1,1) 로 set 되면 HideTradeOverlay 까지 유지.
    -- (WoW 가 TRADE_CLOSED 직전 UPDATE(0,0) 을 추가로 발화시켜 false 로 덮어쓰는 race condition 방어.
    --  WoW 동작상 양쪽 accept 후엔 취소 불가능하므로 latch 안전.)
    if playerAccepted == 1 and targetAccepted == 1 then
        _bothAccepted = true
        -- 거래창 슬롯 링크 캐싱 (TRADE_CLOSED 후엔 GetTradePlayerItemLink 가 nil 반환 가능).
        MR.Auction._lastPlayerSlots = {}
        for slot = 1, 6 do
            MR.Auction._lastPlayerSlots[slot] = GetTradePlayerItemLink(slot)
        end
    end

    -- 방어: tradeOverlay 가 표시되지 않아도 _lastTargetCopper / _lastMyCopper 캐싱.
    -- (OnTradeShow 가 fall-through 해서 overlay 가 안 뜨는 케이스 — 다른 경매 카운트 중 등 — 에서도
    --  trade 금액이 보존되어 OnTradeAccept 가 정상 갱신할 수 있음)
    MR.Auction._lastTargetCopper = copper
    MR.Auction._lastMyCopper     = myCopper

    if MR.Debug then
        MR.Debug(string.format(
            "[Trade] TAU pAcc=%s tAcc=%s targetCopper=%.0f myCopper=%.0f bothAccepted=%s state=%s",
            tostring(playerAccepted), tostring(targetAccepted), copper, myCopper,
            tostring(_bothAccepted), tostring(AC.state)))
    end

    if accepted and not _tradeSoundPlayed and ovMode == "incoming" and ovExpected > 0 then
        -- 정확한 금액만 "맞습니다". 부족/초과 둘 다 "돈이모자랍니다" (= 잘못됨 경고)
        if current == ovExpected then
            playTradeSound(SOUND_CORRECT)
        else
            playTradeSound(SOUND_MONEY_SHORT)
        end
        _tradeSoundPlayed = true
    end
    -- 상대방이 취소하면(금액 변경 등) 다음 accept 때 다시 소리 허용
    if not accepted then _tradeSoundPlayed = false end
end

function MR.Auction.HideTradeOverlay()
    tradeOverlay:Hide()
    ovExpected        = 0
    MR.Auction._expectedDist = 0
    _tradeSoundPlayed = false
    _bothAccepted     = false
    MR.Auction.currentTradeName     = nil
    MR.Auction.currentTradeWinners  = nil
    MR.Auction._lastTargetCopper    = nil
    MR.Auction._lastMyCopper        = nil
    MR.Auction._lastPlayerSlots     = nil
    -- 잘못 올린 아이템 경고 캐시 클리어
    for k in pairs(_placedWarnIds) do _placedWarnIds[k] = nil end
    if ovWarning then ovWarning:SetText(""); ovWarning:Hide() end
    MR.Auction._tradeRejected       = false
    AC.placementQueue               = nil
    -- 다음 거래를 위해 finalize 플래그 리셋 (UI_INFO_MESSAGE 1차 판정 진입 허용)
    MR.Auction._alreadyFinalized    = false
end

-- TRADE_CLOSED 핸들러: ERR_TRADE_COMPLETE/CANCELLED (UI_INFO_MESSAGE) 가 정상 도착했으면
-- _alreadyFinalized=true 라 SKIP. 어떤 이유로 UI_INFO 가 누락된 케이스만 폴백으로
-- _bothAccepted 래치 기반 판정. HideTradeOverlay 는 항상 마지막에 실행 (오버레이 정리).
function MR.Auction.OnTradeClosed()
    MR.Debug(string.format(
        "[Trade] TRADE_CLOSED alreadyFinalized=%s bothAccepted=%s lastWinner=%s currentTradeName=%s targetCopper=%s myCopper=%s",
        tostring(MR.Auction._alreadyFinalized),
        tostring(_bothAccepted),
        tostring(MR.Auction.lastWinner),
        tostring(MR.Auction.currentTradeName),
        tostring(MR.Auction._lastTargetCopper),
        tostring(MR.Auction._lastMyCopper)))

    if not MR.Auction._alreadyFinalized then
        -- UI_INFO_MESSAGE 가 누락된 폴백 — _bothAccepted 래치 기반 판정
        if _bothAccepted then
            MR.Debug("[Trade] TRADE_CLOSED 폴백: bothAccepted=true → finalize(complete)")
            MR.Auction._finalizeTrade("complete")
        else
            MR.Debug("[Trade] TRADE_CLOSED 폴백: bothAccepted=false → finalize(cancelled)")
            MR.Auction._finalizeTrade("cancelled")
        end
    end

    _bothAccepted = false   -- 다음 거래용
    MR.Auction.HideTradeOverlay()
end
