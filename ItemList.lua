--------------------------------------------------------------------------------
-- MimRaid - ItemList.lua
-- 경매 아이템 목록 관리
-- 하드코딩 없음 - 루팅 자동 감지 + 수동 추가/제거
--------------------------------------------------------------------------------

local MR = MimRaid

--------------------------------------------------------------------------------
-- 아이템 목록 상태
-- items[n] = {
--   itemLink        : string    아이템 링크 (대표 링크)
--   itemLinks       : table     드롭된 각 아이템 링크 배열 (수량만큼)
--   itemName        : string    아이템 이름
--   texture         : string    아이템 아이콘 텍스처
--   quality         : number    아이템 품질 (4=Epic, 5=Legendary)
--   auctionMode     : string    "auto" | "manual"
--   addedBy         : string    "loot" | "manual" | "reauction"
--   auctionCount    : number    경매 시도 횟수 (유찰 후 재경매 추적용)
--   quantity        : number    동일 아이템 드롭 수 (기본 1)
--   hasVariant      : boolean   bonusID가 다른 변형 존재 여부
--   variantBestSlot : number    파괴불가 등 특수 변형 슬롯 번호 (1~N)
-- }
--------------------------------------------------------------------------------
MR.ItemList = {}
MR.ItemList.currentBossGroup = 1   -- 현재 보스 번호
MR.ItemList.lastLootTime     = 0   -- 마지막 루팅 시각 (time())
MR.ItemList.bossNames        = {}  -- [boss그룹번호] = "보스이름" (ENCOUNTER_END에서 획득)

-- 엔카운터 종료 → 다음 루팅에서 보스 그룹 증가 (Clear()에서도 리셋되므로 상단에 선언)
local pendingNewBossGroup = false
local pendingBossName     = nil

-- 목록 변경 시 호출할 콜백 (AuctionFrame 등에서 등록)
local onChangeCallbacks = {}

function MR.ItemList.OnChange(fn)
    table.insert(onChangeCallbacks, fn)
end

local function fireChange()
    for _, fn in ipairs(onChangeCallbacks) do
        pcall(fn)
    end
end
-- 외부에서 직접 변경 후 강제 갱신이 필요할 때 (테스트/디버그용)
MR.ItemList.FireChange = fireChange

--------------------------------------------------------------------------------
-- 내부 유틸
--------------------------------------------------------------------------------
local function linkToID(itemLink)
    if not itemLink then return nil end
    local itemID = itemLink:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

-- 동일 baseID + 동일 그룹 번호 항목 검색 (인덱스 + 항목 반환)
-- 옵션창에서 카테고리별로 다른 그룹 번호를 지정한 경우, 같은 itemID여도 별도 entry로 분리됨
local function findByBaseID(itemLink)
    local id = linkToID(itemLink)
    if not id then return nil, nil end
    local newGroup = MR.GetItemGroupNumber and MR.GetItemGroupNumber(itemLink) or 4
    for i, entry in ipairs(MR.ItemList) do
        if linkToID(entry.itemLink) == id then
            local existGroup = entry.groupNumber or 4
            if existGroup == newGroup then
                return i, entry
            end
        end
    end
    return nil, nil
end

-- itemLinks 중 "추가 옵션이 붙은" 슬롯을 variantBestSlot에 저장.
-- 1순위: 카테고리(이속/파불/보석홈/광피/생흡) 보유 개수가 많은 슬롯
-- 2순위(카테고리 동점): bonus 필드 수가 많은 슬롯
-- 동점이면 앞 슬롯 유지 (1위 낙찰자 기본 우선)
local function refreshVariantBestSlot(entry)
    entry.variantBestSlot = nil
    if not entry.itemLinks or #entry.itemLinks < 2 then return end
    local function score(link)
        local cats = (MR.GetItemCategories and MR.GetItemCategories(link)) or {}
        local bonuses = MR.CountItemBonusFields(link) or 0
        return #cats, bonuses
    end
    local bestSlot = 1
    local bestCat, bestBonus = score(entry.itemLinks[1])
    for slot = 2, #entry.itemLinks do
        local c, b = score(entry.itemLinks[slot])
        if c > bestCat or (c == bestCat and b > bestBonus) then
            bestCat, bestBonus = c, b
            bestSlot = slot
        end
    end
    entry.variantBestSlot = bestSlot
    MR.Debug(string.format("variantBestSlot | itemName=%s slot=%d cats=%d bonuses=%d (of %d links)",
        tostring(entry.itemName), bestSlot, bestCat, bestBonus, #entry.itemLinks))
end

--------------------------------------------------------------------------------
-- 내부 순서를 UI 표시 순서와 동일하게 정렬 (in-place)
-- 정렬 키: bossGroup asc → minGroupByBase asc → baseID asc → groupNumber asc
-- 루팅 순서와 옵션 그룹 순서를 내부 인덱스에 반영해야
-- 경매 진행(StartSequential/TryAdvance)과 화면이 어긋나지 않음
--------------------------------------------------------------------------------
function MR.ItemList.SortByDisplayOrder()
    if #MR.ItemList < 2 then return end

    local minGroupByBase = {}
    for _, entry in ipairs(MR.ItemList) do
        local bid = linkToID(entry.itemLink) or 0
        local g   = entry.groupNumber or 4
        if not minGroupByBase[bid] or g < minGroupByBase[bid] then
            minGroupByBase[bid] = g
        end
    end

    table.sort(MR.ItemList, function(a, b)
        local bga = a.bossGroup or 0
        local bgb = b.bossGroup or 0
        if bga ~= bgb then return bga < bgb end
        local ba  = linkToID(a.itemLink) or 0
        local bb  = linkToID(b.itemLink) or 0
        local mga = minGroupByBase[ba] or 4
        local mgb = minGroupByBase[bb] or 4
        if mga ~= mgb then return mga < mgb end
        if ba  ~= bb  then return ba  < bb  end
        return (a.groupNumber or 4) < (b.groupNumber or 4)
    end)
end

--------------------------------------------------------------------------------
-- 아이템 추가
-- addedBy: "loot" | "manual"
-- auctionMode: "auto" | "manual"  (Settings.lua 기본값 따름)
-- 동일 itemID가 이미 목록에 있으면 수량(quantity)을 올리고 링크를 추가함
--------------------------------------------------------------------------------
-- 워밴드 귀속 아이템 검사 — 다른 사람에게 줄 수 없는 (자기 계정 내에서만 이동 가능) 아이템.
-- 한국 클라:
--   "전투귀속"           — 그냥 전투귀속 (warband bound)
--   "착용 전 전투귀속"     — Warbound until equipped (착용 전엔 워밴드 내 양도 가능)
-- 영문 클라:
--   "Warbound"            — Warband bound
--   "Warbound until equipped"
local function isWarbandBoundLink(itemLink)
    if not itemLink or itemLink == "" then return false end
    if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then return false end
    local data
    local ok = pcall(function() data = C_TooltipInfo.GetHyperlink(itemLink) end)
    if not ok or not data or not data.lines then return false end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end
    for _, line in ipairs(data.lines) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, line)
        end
        local txt = line.leftText or ""
        -- 한국 클라: "전투귀속" (착용전/일반/사용시 등 모든 변형이 이 단어 포함)
        if txt:find("전투귀속", 1, true) then return true end
        -- 영문 클라: "Warbound"
        if txt:find("Warbound", 1, true) then return true end
    end
    return false
end
MR.ItemList._isWarbandBoundLink = isWarbandBoundLink   -- 다른 모듈에서 재사용 가능

function MR.ItemList.Add(itemLink, addedBy, auctionMode, auctionCount, bossGroup)
    if not itemLink or itemLink == "" then return false end

    -- 전투부대 귀속 아이템: 다른 사람에게 줄 수 없으므로 경매 등록 차단
    if isWarbandBoundLink(itemLink) then
        local nameDisplay = itemLink:match("|h%[(.-)%]|h") or itemLink
        if addedBy == "manual" then
            MR.Print(string.format(
                "전투부대 귀속 아이템은 경매 등록 불가: %s", nameDisplay),
                MR.COLOR.red)
        else
            MR.Print(string.format(
                "[자동 등록 건너뜀] 전투부대 귀속: %s (다른 사람에게 줄 수 없음)", nameDisplay),
                MR.COLOR.yellow)
            MR.Debug("ItemList.Add SKIP warband-bound: " .. tostring(itemLink))
        end
        return false
    end

    -- 안팔린 아이템 목록 중복 방지 (레이스 컨디션 방어막)
    -- SOLD→ItemList.Remove 2초 지연 사이에 같은 아이템이 양쪽 목록에 등록되는 버그 방지
    local addID = linkToID(itemLink)
    if addID then
        for _, fEntry in ipairs(MR.FailedItems) do
            if linkToID(fEntry.itemLink) == addID then
                if addedBy == "manual" then
                    MR.Print(string.format(
                        "이미 안팔린 아이템 목록에 있습니다: %s",
                        fEntry.itemName or "?"), MR.COLOR.yellow)
                end
                return false
            end
        end
    end

    -- 동일 baseID 기존 항목 탐색
    local _, existEntry = findByBaseID(itemLink)
    if existEntry then
        local itemID   = linkToID(itemLink)
        local bagCount = itemID and (C_Item.GetItemCount(itemID) or 0) or 0
        local curQty   = existEntry.quantity or 1
        MR.Debug(string.format(
            "ItemList.Add DUP: addedBy=%s itemID=%s name=%s existQty=%d bagCount=%d",
            tostring(addedBy), tostring(itemID),
            existEntry.itemName or "?", curQty, bagCount))
        -- 수동 드래그: 가방 실제 수량을 넘으면 거부 (실수 방지)
        if addedBy == "manual" and curQty >= bagCount then
            MR.Print(string.format(
                "가방에 %d개뿐입니다: %s",
                bagCount, existEntry.itemName or "?"), MR.COLOR.gray)
            return false
        end
        -- 같은 아이템이 추가로 드롭됨 → 수량 증가
        existEntry.quantity = (existEntry.quantity or 1) + 1
        if not existEntry.itemLinks then
            existEntry.itemLinks = { existEntry.itemLink }
        end
        table.insert(existEntry.itemLinks, itemLink)

        -- bonusID가 다르면 변형(variant) 플래그
        if itemLink ~= existEntry.itemLink then
            existEntry.hasVariant = true
        end
        refreshVariantBestSlot(existEntry)

        MR.Debug("ItemList.Add: stacked x" .. existEntry.quantity, existEntry.itemName)
        MR.ItemList.Save()
        fireChange()
        return true
    end

    local itemName, _, quality, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemLink)
    if not itemName then
        -- 아이템 캐시 미로드 시 재시도 (GET_ITEM_INFO_RECEIVED 이벤트)
        MR.ItemList.PendingAdd(itemLink, addedBy, auctionMode)
        return false
    end

    local entry = {
        itemLink        = itemLink,
        itemLinks       = { itemLink },
        itemName        = itemName,
        texture         = texture,
        quality         = quality or 0,
        auctionMode     = auctionMode or "auto",
        addedBy         = addedBy or "manual",
        auctionCount    = auctionCount or 0,
        bossGroup       = bossGroup or MR.ItemList.currentBossGroup,
        quantity        = 1,
        hasVariant      = false,
        variantBestSlot = nil,
        groupNumber     = MR.GetItemGroupNumber and MR.GetItemGroupNumber(itemLink) or 4,
    }

    table.insert(MR.ItemList, entry)
    MR.ItemList.SortByDisplayOrder()
    MR.Debug("ItemList.Add:", itemName, "mode=", entry.auctionMode)
    MR.ItemList.Save()
    fireChange()
    return true
end

--------------------------------------------------------------------------------
-- 아이템 제거 (인덱스 기준)
--------------------------------------------------------------------------------
function MR.ItemList.Remove(index)
    if not MR.ItemList[index] then return false end
    local name = MR.ItemList[index].itemName
    table.remove(MR.ItemList, index)
    MR.Debug("ItemList.Remove:", name)
    MR.ItemList.Save()
    fireChange()
    return true
end

--------------------------------------------------------------------------------
-- 아이템 제거 (itemLink 기준)
--------------------------------------------------------------------------------
function MR.ItemList.RemoveByLink(itemLink)
    local id = linkToID(itemLink)
    for i = #MR.ItemList, 1, -1 do
        if linkToID(MR.ItemList[i].itemLink) == id then
            return MR.ItemList.Remove(i)
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- 옵션창에서 카테고리→그룹 매핑이 바뀌었을 때 기존 목록 재계산
-- 각 링크(itemLinks)의 개별 groupNumber를 다시 계산해
-- (baseID, groupNumber) 버킷 단위로 entry 재구성 (분리/병합 모두 커버)
--------------------------------------------------------------------------------
function MR.ItemList.RecalcGroupNumbers()
    if not MR.GetItemGroupNumber then return end
    if MR.ResetCategoryDebugCache then MR.ResetCategoryDebugCache() end

    local buckets, orderKeys = {}, {}
    for _, entry in ipairs(MR.ItemList) do
        local links = entry.itemLinks or { entry.itemLink }
        for _, link in ipairs(links) do
            local g   = MR.GetItemGroupNumber(link) or 4
            local key = tostring(linkToID(link)) .. ":" .. tostring(g)
            if not buckets[key] then
                buckets[key] = { links = {}, meta = entry, groupNumber = g }
                table.insert(orderKeys, key)
            end
            table.insert(buckets[key].links, link)
        end
    end

    local newList = {}
    for _, key in ipairs(orderKeys) do
        local b         = buckets[key]
        local meta      = b.meta
        local firstLink = b.links[1]
        local hasVariant = false
        for _, l in ipairs(b.links) do
            if l ~= firstLink then hasVariant = true; break end
        end
        local e = {
            itemLink        = firstLink,
            itemLinks       = b.links,
            itemName        = meta.itemName,
            texture         = meta.texture,
            quality         = meta.quality or 0,
            auctionMode     = meta.auctionMode or "auto",
            addedBy         = meta.addedBy or "loot",
            auctionCount    = meta.auctionCount or 0,
            bossGroup       = meta.bossGroup or 0,
            quantity        = #b.links,
            hasVariant      = hasVariant,
            variantBestSlot = nil,
            groupNumber     = b.groupNumber,
        }
        refreshVariantBestSlot(e)
        table.insert(newList, e)
    end

    for i = #MR.ItemList, 1, -1 do MR.ItemList[i] = nil end
    for _, e in ipairs(newList) do table.insert(MR.ItemList, e) end

    MR.ItemList.SortByDisplayOrder()
    MR.ItemList.Save()
    fireChange()
end

--------------------------------------------------------------------------------
-- 목록 전체 초기화
--------------------------------------------------------------------------------
function MR.ItemList.Clear()
    for i = #MR.ItemList, 1, -1 do MR.ItemList[i] = nil end
    MR.ItemList.currentBossGroup = 0
    MR.ItemList.bossNames        = {}
    MR.ItemList.lastLootTime     = 0
    pendingNewBossGroup = false
    pendingBossName     = nil
    MR.ItemList.Save()
    fireChange()
end

--------------------------------------------------------------------------------
-- 변형 배정 순번 순환 (★→1위 → ★→2위 → ... → ★→1위)
-- 공대장이 수동으로 "어떤 변형을 몇 위에게 줄지" 조정할 때 사용
--------------------------------------------------------------------------------
function MR.ItemList.CycleVariantBest(index)
    local entry = MR.ItemList[index]
    if not entry or not entry.hasVariant or not entry.quantity then return end
    local qty     = entry.quantity
    local current = entry.variantBestSlot or 1
    entry.variantBestSlot = (current % qty) + 1   -- 1→2→...→qty→1
    MR.ItemList.Save()
    fireChange()
end

--------------------------------------------------------------------------------
-- 경매 모드 토글 (auto ↔ manual)
--------------------------------------------------------------------------------
function MR.ItemList.ToggleMode(index)
    local entry = MR.ItemList[index]
    if not entry then return end
    entry.auctionMode = (entry.auctionMode == "auto") and "manual" or "auto"
    MR.ItemList.Save()
    fireChange()
end

--------------------------------------------------------------------------------
-- 캐시 미로드 아이템 재시도 큐
--------------------------------------------------------------------------------
local pendingQueue = {}

function MR.ItemList.PendingAdd(itemLink, addedBy, auctionMode)
    table.insert(pendingQueue, { itemLink = itemLink, addedBy = addedBy, auctionMode = auctionMode })
    MR.Debug("ItemList.PendingAdd: queued", itemLink)
end

function MR.ItemList.FlushPending()
    if #pendingQueue == 0 then return end
    local remaining = {}
    for _, p in ipairs(pendingQueue) do
        local ok = MR.ItemList.Add(p.itemLink, p.addedBy, p.auctionMode)
        if not ok then
            -- C_Item.GetItemInfo 아직 미로드면 다음 기회에 재시도
            local itemName = C_Item.GetItemInfo(p.itemLink)
            if not itemName then
                table.insert(remaining, p)
            end
        end
    end
    pendingQueue = remaining
end

--------------------------------------------------------------------------------
-- 루팅 경로 간 중복 방지
-- LOOT_OPENED와 CHAT_MSG_LOOT가 동일 아이템을 이중 등록하는 것 차단
-- lootDedup[itemLink] = { count, expiry }
--------------------------------------------------------------------------------
local lootDedup = {}
local LOOT_DEDUP_TTL = 10   -- 초

local function markLootAdded(link)
    if not link then return end
    local now = time()
    local e = lootDedup[link]
    if not e or e.expiry < now then
        lootDedup[link] = { count = 1, expiry = now + LOOT_DEDUP_TTL }
    else
        e.count  = e.count + 1
        e.expiry = now + LOOT_DEDUP_TTL
    end
end

local function tryConsumeLootMark(link)
    local e = lootDedup[link]
    if not e then return false end
    if e.expiry < time() then
        lootDedup[link] = nil
        return false
    end
    e.count = e.count - 1
    if e.count <= 0 then lootDedup[link] = nil end
    return true
end

--------------------------------------------------------------------------------
-- 포맷 문자열 → Lua 패턴 변환 (%s → (.+), %d → (%d+))
-- LOOT_ITEM_SELF 등 전역 상수의 한/영 현지화 자동 대응
--------------------------------------------------------------------------------
local function fmtToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    -- %s / %d 위치를 보존하기 위해 임시 센티넬로 치환
    local p = fmt:gsub("%%s", "\1"):gsub("%%d", "\2")
    -- Lua 패턴 메타문자 이스케이프 (%s/%d 치환 후라 %는 안전)
    p = p:gsub("([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
    p = p:gsub("\1", "(.+)"):gsub("\2", "(%%d+)")
    return "^" .. p .. "$"
end

-- 순서 중요: MULTIPLE 패턴을 먼저 시도 (SINGLE이 greedy하게 매치할 수 있음)
local SELF_LOOT_PATTERNS = {
    { pat = fmtToPattern(LOOT_ITEM_PUSHED_SELF_MULTIPLE), hasCount = true  },
    { pat = fmtToPattern(LOOT_ITEM_SELF_MULTIPLE),        hasCount = true  },
    { pat = fmtToPattern(LOOT_ITEM_PUSHED_SELF),          hasCount = false },
    { pat = fmtToPattern(LOOT_ITEM_SELF),                 hasCount = false },
}

--------------------------------------------------------------------------------
-- 엔카운터 종료 → 다음 루팅부터 새 보스 그룹
-- (pendingNewBossGroup/pendingBossName은 Clear()에서 접근하므로 파일 상단에 선언됨)
--------------------------------------------------------------------------------
function MR.ItemList.OnEncounterEnd(success, encounterName)
    MR.Debug(string.format(
        "ItemList.OnEncounterEnd: success=%s name=%s",
        tostring(success), tostring(encounterName)))
    if success then
        pendingNewBossGroup = true
        pendingBossName     = encounterName
        MR.Debug("ItemList: pending new boss group flag set, name=" ..
            tostring(encounterName))
    end
end

--------------------------------------------------------------------------------
-- CHAT_MSG_LOOT 기반 자동 등록
-- 최신 레이드 주사위/차비 낙찰은 루팅 창 없이 바로 가방행 → LOOT_OPENED 미발동
-- 이 경로로 "당신이 획득: [링크]" 메시지를 파싱해서 자동 등록
--------------------------------------------------------------------------------
-- 캐시 미준비 LOOT 의 retry 큐.
-- 시간 지연 입수 (예: 공대원 모두 포기 후 자동 입수) 시 GetItemInfo 가 quality=nil 반환
-- → 큐에 보관 후 GET_ITEM_INFO_RECEIVED 이벤트마다 재확인. 30초 timeout.
-- bossGroup 도 큐에 캡쳐 (consume 시점 기준) → retry 시 정확한 그룹으로 분류.
local _pendingLoot = {}   -- { {link, count, bossGroup, ts}, ... }
local PENDING_TTL = 30    -- 30초 후 자동 폐기

-- pendingNewBossGroup 를 consume 하고 현재 bossGroup 반환. ItemList.Add 호출 직전에만 호출.
local function _consumeBossGroupAndGet()
    if pendingNewBossGroup then
        MR.ItemList.currentBossGroup = MR.ItemList.currentBossGroup + 1
        pendingNewBossGroup = false
        if pendingBossName and pendingBossName ~= "" then
            MR.ItemList.bossNames[MR.ItemList.currentBossGroup] = pendingBossName
            MR.Debug(string.format(
                "CHAT_MSG_LOOT: boss group %d -> name=%s",
                MR.ItemList.currentBossGroup, pendingBossName))
        end
        pendingBossName = nil
        MR.Debug("CHAT_MSG_LOOT: consumed pending boss group -> " ..
            MR.ItemList.currentBossGroup)
    end
    return MR.ItemList.currentBossGroup
end

-- 실제 ItemList.Add 호출 + dedup
local function _doAdd(link, count, bossGroup)
    for _ = 1, count do
        if tryConsumeLootMark(link) then
            MR.Debug("CHAT_MSG_LOOT skip: dedup (LOOT_OPENED already added) " .. link)
        else
            MR.Debug(string.format(
                "CHAT_MSG_LOOT add: link=%s group=%d", link, bossGroup))
            MR.ItemList.Add(link, "loot", "auto", nil, bossGroup)
        end
    end
end

function MR.ItemList.OnChatLoot(msg)
    -- 크로스렐름 등에서 msg가 시크릿 스트링으로 들어올 수 있음 → `==`로 비교하면 taint 에러.
    -- nil 체크만 하고 빈 문자열은 아래 패턴매칭이 자연스럽게 처리 (string:match는 시크릿 문자열에 안전).
    if not msg then return end
    if not MR.cfg.autoDetectLoot then return end
    if not UnitIsGroupLeader("player") then
        MR.Debug("CHAT_MSG_LOOT skip: not-leader")
        return
    end

    -- msg 가 시크릿 스트링이면 `msg:match` (콜론-인덱싱)가 taint 에러.
    -- 함수 형태 `string.match`를 pcall로 감싸 안전하게 호출.
    local link, count
    for _, entry in ipairs(SELF_LOOT_PATTERNS) do
        if entry.pat then
            local ok, l, c = pcall(string.match, msg, entry.pat)
            if ok and l then
                link, count = l, entry.hasCount and (tonumber(c) or 1) or 1
                break
            end
        end
    end

    if not link then return end   -- 본인 획득 메시지 아님

    local itemName, _, quality = C_Item.GetItemInfo(link)
    local threshold = MR.cfg.lootQualityThreshold or 4

    MR.Debug(string.format(
        "CHAT_MSG_LOOT match: name=%s quality=%s count=%d link=%s",
        tostring(itemName), tostring(quality), count, link))

    -- 캐시 미준비: pending 큐에 보관 후 GET_ITEM_INFO_RECEIVED 이벤트에서 재시도.
    -- 시간 지연 입수 케이스 (공대원 전체 포기 후 자동 입수) 대응. bossGroup 도 함께 캡쳐.
    if not quality then
        -- 강제 캐시 요청 (있으면)
        local itemID = tonumber(link:match("item:(%d+)"))
        if itemID and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end
        local bossGroup = _consumeBossGroupAndGet()
        table.insert(_pendingLoot, {
            link = link, count = count, bossGroup = bossGroup, ts = time(),
            itemID = itemID,
        })
        MR.Debug(string.format(
            "CHAT_MSG_LOOT queued (not-cached): link=%s group=%d (큐 크기=%d)",
            link, bossGroup, #_pendingLoot))
        return
    end
    if quality < threshold then
        MR.Debug(string.format(
            "CHAT_MSG_LOOT skip: low-quality quality=%d threshold=%d",
            quality, threshold))
        return
    end

    local bossGroup = _consumeBossGroupAndGet()
    _doAdd(link, count, bossGroup)
end

-- GET_ITEM_INFO_RECEIVED 이벤트에서 호출. pending 큐 재처리.
-- 인자는 사용 안 함 — 큐 전체 재확인이 더 robust (어떤 itemID 가 늦게 도착하든 관련 pending 모두 검사).
-- TTL 30초 넘은 항목은 큐에서 제거 (영구 캐시 실패 케이스 방어).
---@diagnostic disable-next-line: unused-local
function MR.ItemList.OnItemInfoReceived(itemID, success)
    if #_pendingLoot == 0 then return end
    local threshold = MR.cfg.lootQualityThreshold or 4
    local now = time()

    -- 역순 순회 (table.remove 안전)
    for i = #_pendingLoot, 1, -1 do
        local p = _pendingLoot[i]
        -- TTL 초과 → 폐기
        if now - p.ts > PENDING_TTL then
            MR.Debug(string.format(
                "CHAT_MSG_LOOT pending timeout (%ds): %s — 폐기",
                PENDING_TTL, p.link))
            table.remove(_pendingLoot, i)
        else
            local _, _, q = C_Item.GetItemInfo(p.link)
            if q then
                table.remove(_pendingLoot, i)
                if q >= threshold then
                    MR.Debug(string.format(
                        "CHAT_MSG_LOOT pending resolved: %s quality=%d group=%d",
                        p.link, q, p.bossGroup))
                    _doAdd(p.link, p.count, p.bossGroup)
                else
                    MR.Debug(string.format(
                        "CHAT_MSG_LOOT pending skip low-quality: %s quality=%d",
                        p.link, q))
                end
            end
            -- 아직 캐시 안 됨 → 큐에 남겨두고 다음 이벤트 대기
        end
    end
end

--------------------------------------------------------------------------------
-- 루팅 자동 감지
-- LOOT_OPENED: 공대장 본인이 루팅 창을 열었을 때 (구레이드/직접루팅 커버)
-- 품질 기준: MR.cfg.lootQualityThreshold (기본 4 = Epic)
--------------------------------------------------------------------------------
function MR.ItemList.OnLootOpened()
    -- 공대장만 동작
    if not UnitIsGroupLeader("player") then return end
    if not MR.cfg.autoDetectLoot then return end

    local threshold    = MR.cfg.lootQualityThreshold or 4
    local bossMinItems = MR.cfg.bossMinItems or 3   -- 이 수량 이상이면 보스 킬로 판정

    -- 해당 루팅 창의 고품질 아이템 링크 수집
    local eligibleLinks = {}
    for slot = 1, GetNumLootItems() do
        local texture, _, _, quality, locked = GetLootSlotInfo(slot)
        if texture and not locked and quality and quality >= threshold then
            local itemLink = GetLootSlotLink(slot)
            if itemLink then
                table.insert(eligibleLinks, itemLink)
            end
        end
    end

    if #eligibleLinks == 0 then return end

    -- 보스 킬 판정: 한 번에 bossMinItems개 이상 → 새 보스 그룹 생성
    -- 그 미만(월드드랍 등)은 현재 그룹(0) 유지 — 보스탭에서 제외됨
    local isBossKill = (#eligibleLinks >= bossMinItems)
    if isBossKill then
        MR.ItemList.currentBossGroup = MR.ItemList.currentBossGroup + 1
        MR.Debug("ItemList: boss kill detected, group", MR.ItemList.currentBossGroup,
            "items:", #eligibleLinks)
        -- ENCOUNTER_END로 예약된 보스 그룹은 여기서 소비 (중복 증가 방지)
        pendingNewBossGroup = false
        if pendingBossName and pendingBossName ~= "" then
            MR.ItemList.bossNames[MR.ItemList.currentBossGroup] = pendingBossName
            MR.Debug(string.format(
                "LOOT_OPENED: boss group %d -> name=%s",
                MR.ItemList.currentBossGroup, pendingBossName))
        end
        pendingBossName = nil
    end

    local bossGroup = isBossKill and MR.ItemList.currentBossGroup or 0
    for _, itemLink in ipairs(eligibleLinks) do
        MR.ItemList.Add(itemLink, "loot", "auto", nil, bossGroup)
        markLootAdded(itemLink)
    end
end

--------------------------------------------------------------------------------
-- SavedVariables 저장/로드
-- 경매 중 튕겨도 목록 복원
--------------------------------------------------------------------------------
function MR.ItemList.Save()
    if not MimRaidDB then MimRaidDB = {} end
    local cdata = MR.GetCharData()
    cdata.itemList = {}
    for i, entry in ipairs(MR.ItemList) do
        cdata.itemList[i] = {
            itemLink        = entry.itemLink,
            itemLinks       = entry.itemLinks,
            itemName        = entry.itemName,
            texture         = entry.texture,
            quality         = entry.quality,
            auctionMode     = entry.auctionMode,
            addedBy         = entry.addedBy,
            auctionCount    = entry.auctionCount or 0,
            quantity        = entry.quantity or 1,
            hasVariant      = entry.hasVariant,
            variantBestSlot = entry.variantBestSlot,
            bossGroup       = entry.bossGroup or 0,
            groupNumber     = entry.groupNumber or 4,
        }
    end
    cdata.bossNames = {}
    for g, name in pairs(MR.ItemList.bossNames) do
        cdata.bossNames[g] = name
    end
end

function MR.ItemList.Load()
    if not MimRaidDB then return end
    local cdata = MR.GetCharData()
    if not cdata.itemList then return end
    for i = #MR.ItemList, 1, -1 do MR.ItemList[i] = nil end
    local maxGroup = 1
    for _, entry in ipairs(cdata.itemList) do
        table.insert(MR.ItemList, entry)
        if entry.bossGroup and entry.bossGroup > maxGroup then
            maxGroup = entry.bossGroup
        end
    end
    MR.ItemList.currentBossGroup = maxGroup
    MR.ItemList.bossNames = {}
    if cdata.bossNames then
        for g, name in pairs(cdata.bossNames) do
            MR.ItemList.bossNames[tonumber(g) or g] = name
        end
    end
    MR.ItemList.SortByDisplayOrder()
    if #MR.ItemList > 0 then
        MR.Debug("ItemList.Load:", #MR.ItemList, "items, bossGroup=", maxGroup)
    end
    -- 로드 후 UI 즉시 갱신 (ADDON_LOADED 순서 문제 해결)
    fireChange()
end

--------------------------------------------------------------------------------
-- 유찰 아이템 목록
-- failedItems[n] = {
--   itemLink     : string   아이템 링크
--   itemName     : string   아이템 이름
--   texture      : string   아이콘 텍스처
--   quality      : number   아이템 품질
--   auctionCount : number   총 경매 시도 횟수
--   disposition  : string   nil | "reauction" | "disenchant" | "vendor"
-- }
--------------------------------------------------------------------------------
MR.FailedItems = {}

-- 처분 상태 상수
MR.FAILED_DISP = {
    REAUCTION  = "reauction",   -- 재경매
    DISENCHANT = "disenchant",  -- 마법부여 추출
    VENDOR     = "vendor",      -- 상점 판매
}

MR.FAILED_DISP_TEXT = {
    reauction  = "재경매",
    disenchant = "마법부여 추출",
    vendor     = "상점 판매",
}

-- 유찰 목록 변경 콜백
local onFailedChangeCallbacks = {}

function MR.FailedItems.OnChange(fn)
    table.insert(onFailedChangeCallbacks, fn)
end

local function fireFailedChange()
    for _, fn in ipairs(onFailedChangeCallbacks) do
        pcall(fn)
    end
end

-- 유찰 아이템 추가 (ItemList entry를 그대로 받음)
-- overrideQty: 부분 유찰 시 (예: 2개 드랍 중 1개만 판매) 미판매분 수량 지정. nil이면 entry.quantity 사용.
function MR.FailedItems.Add(entry, overrideQty)
    local countBefore = #MR.FailedItems
    local failed = {
        itemLink     = entry.itemLink,
        itemName     = entry.itemName,
        texture      = entry.texture,
        quality      = entry.quality,
        quantity     = overrideQty or entry.quantity or 1,
        disposition  = nil,
        bossGroup    = entry.bossGroup or 0,
    }
    table.insert(MR.FailedItems, failed)
    MR.FailedItems.Save()
    MR.Debug(string.format(
        "FailedItems.Add: #before=%d -> #after=%d name=%s qty=%d",
        countBefore, #MR.FailedItems, failed.itemName or "?", failed.quantity))
    fireFailedChange()
end

-- 처분 상태 설정
function MR.FailedItems.SetDisposition(index, disp)
    local entry = MR.FailedItems[index]
    if not entry then return end
    if disp ~= nil and not MR.FAILED_DISP_TEXT[disp] then return end
    entry.disposition = disp
    MR.FailedItems.Save()
    fireFailedChange()
end

-- 거래로 소진: 안팔린 아이템이 거래창을 통해 공대원에게 전달됨.
-- count 만큼 수량 감소. 0 이하면 엔트리 제거.
function MR.FailedItems.Consume(index, count)
    local entry = MR.FailedItems[index]
    if not entry then return false end
    local consumed = count or 1
    entry.quantity = (entry.quantity or 1) - consumed
    if entry.quantity <= 0 then
        table.remove(MR.FailedItems, index)
    end
    MR.FailedItems.Save()
    fireFailedChange()
    return true
end

-- 유찰 항목 삭제 (직접 제거)
function MR.FailedItems.Clear()
    for i = #MR.FailedItems, 1, -1 do MR.FailedItems[i] = nil end
    MR.FailedItems.Save()
    fireFailedChange()
end

function MR.FailedItems.Remove(index)
    if not MR.FailedItems[index] then return false end
    table.remove(MR.FailedItems, index)
    MR.FailedItems.Save()
    fireFailedChange()
    return true
end

-- SavedVariables 저장/로드 (캐릭터별 파티션)
function MR.FailedItems.Save()
    if not MimRaidDB then MimRaidDB = {} end
    local cdata = MR.GetCharData()
    cdata.failedItems = {}
    for i, entry in ipairs(MR.FailedItems) do
        cdata.failedItems[i] = {
            itemLink     = entry.itemLink,
            itemName     = entry.itemName,
            texture      = entry.texture,
            quality      = entry.quality,
            quantity     = entry.quantity or 1,
            disposition  = entry.disposition,
            bossGroup    = entry.bossGroup or 0,
        }
    end
end

function MR.FailedItems.Load()
    if not MimRaidDB then return end
    local cdata = MR.GetCharData()
    if not cdata.failedItems then
        MR.Debug("FailedItems.Load: DB empty or no failedItems key for char")
        return
    end
    for i = #MR.FailedItems, 1, -1 do MR.FailedItems[i] = nil end
    for i, entry in ipairs(cdata.failedItems) do
        -- 구버전 마이그레이션: auctionCount 필드 제거 (영속성에서 더이상 사용 안 함)
        entry.auctionCount = nil
        if not entry.quantity then entry.quantity = 1 end
        table.insert(MR.FailedItems, entry)
        MR.Debug(string.format(
            "FailedItems.Load[%d]: name=%s qty=%d disp=%s",
            i, entry.itemName or "?", entry.quantity or 1,
            tostring(entry.disposition)))
    end
    MR.Debug(string.format(
        "FailedItems.Load DONE: total=%d (DB had %d entries)",
        #MR.FailedItems, #cdata.failedItems))
    -- 로드 후 UI 즉시 갱신
    fireFailedChange()
end
