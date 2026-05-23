--------------------------------------------------------------------------------
-- MimRaid - Settings.lua
-- 애드온 네임스페이스, 기본 설정값, 공통 유틸리티
--------------------------------------------------------------------------------

MimRaid = {}
local MR = MimRaid

-- 버전
MR.VERSION = "0.9.94"

--------------------------------------------------------------------------------
-- 기본 설정값 (SavedVariables 없을 때 사용)
--------------------------------------------------------------------------------
MR.DEFAULTS = {
    -- 경매 진행
    previewTime         = 0,            -- 경매 시작 후 입찰 받기 전 살펴보기 시간(초). 0이면 살펴보기 생략
    silenceTimeout      = 3,            -- 침묵 감지 초 (입찰 없으면 카운트 시작)
    countdownFrom       = 5,            -- 카운트다운 시작 숫자
    countdownStepDelay  = 2,            -- 카운트 1 당 대기 시간 (초)
    auctionChannel      = "RAID",       -- 경매 채팅 채널 (RAID / RAID_WARNING)
    goldUnit            = 10000,        -- 1 = 1만골 (10,000 골드)
    minBid              = 1,            -- 최소 입찰 단위 (만골)
    lootQualityThreshold = 4,           -- 자동 감지 최소 품질 (4=Epic, 5=Legendary)

    -- 사운드
    soundEnabled        = true,         -- 사운드 전체 활성화
    soundSold           = 569593,       -- 낙찰 완료 사운드 (FileDataID)
    -- 안팔린 아이템 경고 사운드 — Millhouse Manastorm "너 이러다가 후회할걸" VO (FileDataID)
    soundFailedAlert    = 555318,

    -- 메시지 템플릿 (%1$s=아이템명, %2$s=구매자, %3$s=금액)
    msgSold             = "[경매] 판매완료! %s -> %s (%s)",
    msgNoWinner         = "[경매] %s 판매안됨.",
    msgCountdown        = "[경매] %d",  -- 카운트다운 숫자 포맷

    -- 지연입찰 유예: 땡! 직후 이 시간 동안은 네트워크 지연으로 늦게 도착한 입찰 수용
    bidGracePeriod      = 2.0,

    -- 기타
    -- 동일 아이템 경매 그룹화: 같은 번호끼리 하나의 경매로 묶음 (1~4)
    -- 기본: 1차=보홈 / 2차=광피·생흡 / 3차=파불·이속·일반
    auctionGroupSocket       = 1,       -- 보석 홈
    auctionGroupAvoidance    = 2,       -- 광역회피
    auctionGroupLeech        = 2,       -- 생기흡수
    auctionGroupIndestruct   = 3,       -- 파괴 불가
    auctionGroupSpeed        = 3,       -- 이동 속도
    auctionGroupNormal       = 3,       -- 일반템
    autoDetectLoot      = true,         -- 루팅 아이템 자동 감지
    autoRollEnabled     = true,         -- 공대장 전용 자동 주사위 굴리기 (ROLL_STARTED)
    autoRollMsg         = "모든 아이템은 빠르게 포기 눌러주세요. \n단, 도안이나 장난감은 주사위 굴리셔도 됩니다.",
    bossMinItems        = 2,            -- 한 번에 이 수 이상 고품질 아이템 루팅 시 보스 킬로 판정
    raidTimerAutoStart  = true,         -- 레이드 첫 전투 시 타이머 자동 시작
    debugMode           = false,        -- 디버그 메시지 출력
    fontDelta           = 2,            -- 글꼴 크기 증감값 (기본값 대비 +/-)

    -- 거래 완료 시 상대방에게 귓말로 거래내역(받은/보낸 골드·아이템) 전송
    tradeWhisperEnabled = true,
}

-- 런타임 설정 (SavedVariables 로드 후 병합됨)
MR.cfg = {}

--------------------------------------------------------------------------------
-- UI 공통 스타일
--------------------------------------------------------------------------------
MR.BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 16,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

MR.BACKDROP_DARK = {
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- 색상
MR.COLOR = {
    gold    = { r = 1.0, g = 0.82, b = 0.0 },
    white   = { r = 1.0, g = 1.0,  b = 1.0 },
    green   = { r = 0.0, g = 1.0,  b = 0.0 },
    red     = { r = 1.0, g = 0.2,  b = 0.2 },
    yellow  = { r = 1.0, g = 1.0,  b = 0.0 },
    gray    = { r = 0.6, g = 0.6,  b = 0.6 },
    orange  = { r = 1.0, g = 0.6,  b = 0.0 },
}

--------------------------------------------------------------------------------
-- 경매 상태 상수
--------------------------------------------------------------------------------
MR.AUCTION_STATE = {
    IDLE       = "IDLE",        -- 대기 중
    WAITING    = "WAITING",     -- 침묵 대기 중
    COUNTDOWN  = "COUNTDOWN",   -- 카운트다운 진행 중
    GRACE      = "GRACE",       -- 땡 직후 지연입찰 유예 (네트워크 지연 보정)
    SOLD       = "SOLD",        -- 낙찰 완료
}

-- 거래 상태 상수
MR.TRADE_STATE = {
    PENDING    = "PENDING",     -- ❌ 미완료
    PARTIAL    = "PARTIAL",     -- ⚠️ 부족
    DONE       = "DONE",        -- ✅ 완료
}

MR.TRADE_STATE_ICON = {
    [MR.TRADE_STATE.PENDING]  = "|cffff4444X|r",
    [MR.TRADE_STATE.PARTIAL]  = "|cffffaa00!|r",
    [MR.TRADE_STATE.DONE]     = "|cff44ff44O|r",
}


--------------------------------------------------------------------------------
-- 캐릭터별 데이터 분리
-- 설정(cfg/frameX/Y/scale/minimap)은 계정 공유, 레이드 기록은 캐릭터별로 분리.
-- 데이터: tradeLog, itemList, failedItems, bossNames, history, raidStartTime,
--        raidFrozenElapsed, raidInstanceName
-- 저장 위치: MimRaidDB.chars[<캐릭터-서버>] = { ... }
--------------------------------------------------------------------------------
function MR.GetCharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. "-" .. realm
end

-- 현재 캐릭터의 데이터 파티션. 없으면 새로 생성해서 반환.
function MR.GetCharData()
    if not MimRaidDB then MimRaidDB = {} end
    if not MimRaidDB.chars then MimRaidDB.chars = {} end
    local key = MR.GetCharKey()
    if not MimRaidDB.chars[key] then MimRaidDB.chars[key] = {} end
    return MimRaidDB.chars[key]
end

-- 계정 루트의 레이드 데이터를 현재 캐릭터 파티션으로 이동 (1회성, 첫 로드 시).
-- 마이그레이션 후엔 다른 캐릭터는 빈 파티션으로 시작.
function MR.MigrateAccountToCharData()
    if not MimRaidDB then return end
    local FIELDS = {
        "tradeLog", "itemList", "failedItems", "bossNames", "history",
        "raidStartTime", "raidFrozenElapsed", "raidInstanceName",
    }
    local cdata = MR.GetCharData()
    local migrated = 0
    for _, key in ipairs(FIELDS) do
        if MimRaidDB[key] ~= nil and cdata[key] == nil then
            cdata[key] = MimRaidDB[key]
            MimRaidDB[key] = nil
            migrated = migrated + 1
        end
    end
    if migrated > 0 then
        MR.Print(string.format(
            "기존 계정 데이터 → '%s' 로 마이그레이션 (%d개 키). 다른 캐릭터는 빈 상태로 시작합니다.",
            MR.GetCharKey(), migrated), MR.COLOR.gold)
    end
end

--------------------------------------------------------------------------------
-- 유틸리티 함수
--------------------------------------------------------------------------------

-- 채팅 출력 (접두어 포함)
function MR.Print(msg, color)
    local c = color or MR.COLOR.gold
    local prefix = string.format("|cff%02x%02x%02x[MimRaid]|r ", c.r*255, c.g*255, c.b*255)
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. tostring(msg))
end

-- 디버그 출력 (-debug 버전은 cfg.debugMode 무시하고 항상 출력)
local function isDebugBuild()
    return type(MR.VERSION) == "string" and MR.VERSION:find("-debug", 1, true) ~= nil
end
function MR.Debug(...)
    if not isDebugBuild() and not MR.cfg.debugMode then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888[MimRaid:Debug] " .. table.concat(parts, " ") .. "|r")
end

-- 골드 포맷: 절대 금액 기준 표시 (goldUnit 설정과 무관)
-- 10000 → "1만골", 3000 → "3천골", 500 → "500골"
MR.MAX_GOLD = 9999999  -- WoW 캐릭터 소지금액 상한 (~999만골)
local MAX_GOLD = MR.MAX_GOLD

function MR.FormatGold(amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount == 0 then return "0골" end
    local sign = ""
    if amount < 0 then sign = "-"; amount = -amount end
    local result
    -- %d 는 32-bit 정수(±2^31)에서 오버플로우. 큰 골드값(예: copper-단위가 잘못 들어오는 경우)도
    -- 안전하도록 %.0f (64-bit 더블) 사용. 반올림이 아니라 절삭(9999 → "9.9천골")은 그대로 유지.
    if amount % 10000 == 0 then
        result = string.format("%.0f만골", amount / 10000)
    elseif amount >= 10000 then
        result = string.format("%.1f만골", math.floor(amount / 1000) / 10)
    elseif amount % 1000 == 0 then
        result = string.format("%.0f천골", amount / 1000)
    elseif amount >= 1000 then
        result = string.format("%.1f천골", math.floor(amount / 100) / 10)
    else
        result = string.format("%.0f골", amount)
    end
    return sign .. result
end

-- 채팅 입력 파싱: "10" → 100000골
-- 순수 정수(%d+)만 허용. 한글/영어/공백/점 등 섞이면 nil 반환.
-- 반환: bid(골드 정수) or nil
function MR.ParseBid(msg)
    if not msg then return nil end
    msg = strtrim(msg)
    if not msg:match("^%d+$") then return nil end
    local num = tonumber(msg)
    if not num or num <= 0 then return nil end
    local bid = num * MR.cfg.goldUnit
    if bid > MAX_GOLD then return nil end  -- 비정상적으로 큰 입찰 무시
    return bid
end

-- 다중 입찰 파싱: "2 3", "2/3", "2,3", "2.3", "2-3", "(2)" → {300000, 200000} (내림차순)
-- 구분자: `/`, `,`, `.`, `-`, `(`, `)`, 공백(연속 허용).
-- 각 토큰은 순수 정수(%d+)여야 함 → 한글/영문/기타 문자 섞인 토큰은 거부 (잡담 방어).
-- 동일 금액 중복, 0 이하, MAX_GOLD 초과가 하나라도 있으면 nil.
-- 반환: { bid1, bid2, ... } (내림차순, 중복 없음) 또는 nil
function MR.ParseBids(msg)
    if not msg then return nil end
    -- WoW 11.x 부터 전투 중 CHAT_MSG_* 의 msg 가 secret string 으로 올 수 있어
    -- strtrim/gsub/gmatch/match 등이 taint 에러를 던짐. 전체를 pcall 로 보호.
    local ok, result = pcall(function()
        local s = strtrim(msg)
        if s == "" then return nil end
        -- 허용 punctuation 을 모두 공백으로 치환 (이후 공백 split)
        local normalized = s:gsub("[/,.()-]", " ")
        local bids = {}
        local seen = {}
        for token in normalized:gmatch("%S+") do
            if not token:match("^%d+$") then return nil end
            local num = tonumber(token)
            if not num or num <= 0 then return nil end
            local bid = num * MR.cfg.goldUnit
            if bid > MAX_GOLD then return nil end
            if seen[bid] then return nil end  -- 동일 금액 중복 금지
            seen[bid] = true
            table.insert(bids, bid)
        end
        if #bids == 0 then return nil end
        table.sort(bids, function(a, b) return a > b end)
        return bids
    end)
    if not ok then return nil end
    return result
end

-- 아이템 링크의 비어있지 않은 bonus 필드 수 계산 (변형 비교용)
-- 필드 수가 많을수록 추가 옵션(파괴불가, 3차 스탯 등)이 더 붙어 있음
function MR.CountItemBonusFields(itemLink)
    if not itemLink then return 0 end
    local count   = 0
    local skipped = false
    local section = itemLink:match("|H(item:[^|]+)|h") or itemLink
    for num in section:gmatch(":(%d+)") do
        if not skipped then
            skipped = true  -- 첫 번째 숫자는 itemID → 건너뜀
        elseif tonumber(num) ~= 0 then
            count = count + 1
        end
    end
    return count
end

-- 동일 아이템 경매 그룹화용 카테고리 (옵션창에서 지정한 그룹 번호와 매핑)
-- 툴팁 스캔 결과를 우선순위 순으로 검사: 보석홈 > 광피 > 생흡 > 파불 > 이속 > 일반
MR.ITEM_CATEGORY = {
    SOCKET      = "socket",      -- 보석 홈
    AVOIDANCE   = "avoidance",   -- 광역회피
    LEECH       = "leech",       -- 생기흡수
    INDESTRUCT  = "indestruct",  -- 파괴 불가
    SPEED       = "speed",       -- 이동 속도
    NORMAL      = "normal",      -- 일반템 (해당 없음)
}

-- kind:
--   "stat"  = 2차 스탯 줄에만 매칭. "광역 회피 +84" (단일 leftText) 또는
--             leftText="광역 회피" / rightText="+84" (분할) 두 케이스.
--             설명란의 "이동 속도가 3%만큼 감소" 같은 문장은 제외.
--   "label" = 2차 스탯 영역의 독립 라벨 줄에만 매칭. "파괴 불가"처럼 leftText가
--             정확히 라벨이고 rightText 가 비어있는 짧은 줄만 인정.
--             설명란 문장의 "파괴 불가한 장비..." 등은 제외.
--   "text"  = 툴팁 내 어떤 줄에든 해당 문구가 있으면 매칭 (보석 홈용).
local CATEGORY_PATTERNS = {
    { cat = MR.ITEM_CATEGORY.SOCKET,     name = "보석%s*홈",   kind = "text"  },
    { cat = MR.ITEM_CATEGORY.AVOIDANCE,  name = "광역%s*회피", kind = "stat"  },
    { cat = MR.ITEM_CATEGORY.LEECH,      name = "생기%s*흡수", kind = "stat"  },
    { cat = MR.ITEM_CATEGORY.INDESTRUCT, name = "파괴%s*불가", kind = "label" },
    { cat = MR.ITEM_CATEGORY.SPEED,      name = "이동%s*속도", kind = "stat"  },
}

local function matchStatLine(line, name)
    local lt = line.leftText  or ""
    local rt = line.rightText or ""
    if lt:find(name .. "%s*[%+%-]%d") then return true end
    if #lt < 30 and lt:find(name) and rt:find("^%s*[%+%-]%d") then return true end
    return false
end

local function matchLabelLine(line, name)
    local lt = line.leftText  or ""
    local rt = line.rightText or ""
    if #lt > 20 then return false end
    if rt ~= "" and not rt:find("^%s*$") then return false end
    return lt:find("^%s*" .. name .. "%s*$") ~= nil
end

local function matchTextLine(line, name)
    return (line.leftText or ""):find(name) ~= nil
end

local function matchEntry(line, entry)
    if entry.kind == "stat"  then return matchStatLine(line, entry.name)  end
    if entry.kind == "label" then return matchLabelLine(line, entry.name) end
    return matchTextLine(line, entry.name)
end

-- 아이템의 카테고리 판별 (툴팁 스캔)
-- 우선순위: 보석홈 > 광피 > 생흡 > 파불 > 이속, 해당 없으면 일반
function MR.GetItemCategory(itemLink)
    local cats = MR.GetItemCategories(itemLink)
    return cats[1] or MR.ITEM_CATEGORY.NORMAL
end

-- 아이템에 매칭되는 모든 카테고리 배열 반환 (CATEGORY_PATTERNS 순서, NORMAL은 제외)
-- 예: 보석홈 + 파괴불가 둘 다 붙은 아이템 → { SOCKET, INDESTRUCT }
local _categoryDebugDumped = {}  -- itemLink별 한 번만 툴팁 덤프
function MR.ResetCategoryDebugCache()
    wipe(_categoryDebugDumped)
end
function MR.GetItemCategories(itemLink)
    local result = {}
    if not itemLink or not C_TooltipInfo then return result end
    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if not data then return result end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        TooltipUtil.SurfaceArgs(data)
    end

    -- 디버그: 세션 내 해당 itemLink 첫 호출 시 툴팁 구조 덤프 (-debug 빌드에서 항상 활성)
    local doDump = not _categoryDebugDumped[itemLink]
    if doDump then
        _categoryDebugDumped[itemLink] = true
        MR.Debug(string.format("카테고리 스캔 시작 | link=%s", tostring(itemLink)))
    end

    if data.lines then
        for li, line in ipairs(data.lines) do
            if TooltipUtil and TooltipUtil.SurfaceArgs then
                TooltipUtil.SurfaceArgs(line)
            end
            local lt = line.leftText  or ""
            local rt = line.rightText or ""
            local lineHits = {}
            for _, entry in ipairs(CATEGORY_PATTERNS) do
                if matchEntry(line, entry) then
                    table.insert(lineHits, entry.cat)
                    local dup = false
                    for _, c in ipairs(result) do
                        if c == entry.cat then dup = true; break end
                    end
                    if not dup then table.insert(result, entry.cat) end
                end
            end
            if doDump then
                MR.Debug(string.format("  line[%d] lt=<%s> rt=<%s> hits=[%s]",
                    li, lt, rt, table.concat(lineHits, ",")))
            end
        end
    end
    if doDump then
        MR.Debug(string.format("카테고리 스캔 결과 | [%s]", table.concat(result, ",")))
    end
    return result
end

-- 카테고리 라벨 문자열 빌드 (공백 구분). 예: "[다색 보석 홈] [파괴 불가]"
-- 해당 없으면 빈 문자열 반환
local CAT_LABELS = {
    [MR.ITEM_CATEGORY.SOCKET]     = "[보석 홈]",
    [MR.ITEM_CATEGORY.AVOIDANCE]  = "[광역회피]",
    [MR.ITEM_CATEGORY.LEECH]      = "[생기흡수]",
    [MR.ITEM_CATEGORY.INDESTRUCT] = "[파괴 불가]",
    [MR.ITEM_CATEGORY.SPEED]      = "[이동 속도]",
}
-- 단일 링크 또는 변형 링크 배열을 받아 카테고리 합집합 라벨 반환.
-- 예: 라소크 ×3 중 1개만 이동 속도 보너스가 있어도 "[이동 속도]" 표시.
function MR.BuildCategoryLabel(linkOrLinks)
    local links
    if type(linkOrLinks) == "table" then
        links = linkOrLinks
    else
        links = { linkOrLinks }
    end
    local seen, cats = {}, {}
    for _, link in ipairs(links) do
        if link then
            for _, c in ipairs(MR.GetItemCategories(link)) do
                if not seen[c] then
                    seen[c] = true
                    table.insert(cats, c)
                end
            end
        end
    end
    if #cats == 0 then return "" end
    local parts = {}
    for _, c in ipairs(cats) do
        local lbl = CAT_LABELS[c]
        if lbl then table.insert(parts, lbl) end
    end
    return table.concat(parts, " ")
end

-- 카테고리 → 그룹 번호 (1~4) 설정값 조회
function MR.GetItemGroupNumber(itemLink)
    local cat = MR.GetItemCategory(itemLink)
    local cfg = MR.cfg
    if cat == MR.ITEM_CATEGORY.SOCKET     then return cfg.auctionGroupSocket     or 4 end
    if cat == MR.ITEM_CATEGORY.AVOIDANCE  then return cfg.auctionGroupAvoidance  or 4 end
    if cat == MR.ITEM_CATEGORY.LEECH      then return cfg.auctionGroupLeech      or 4 end
    if cat == MR.ITEM_CATEGORY.INDESTRUCT then return cfg.auctionGroupIndestruct or 4 end
    if cat == MR.ITEM_CATEGORY.SPEED      then return cfg.auctionGroupSpeed      or 4 end
    return cfg.auctionGroupNormal or 4
end

-- 유닛의 이름+서버 반환 (교차서버 지원)
--------------------------------------------------------------------------------
-- Secret string 보호
-- WoW 11.x 부터 크로스렐름/크로스파벨/전투 중 공대 상황에서 UnitName / CHAT_MSG_*
-- 의 이름 값이 "secret string" 으로 반환됨. 이 값은 ==, :find, :match, .., # 등
-- 기본 문자열 연산이 모두 taint 에러를 던짐.
-- Ambiguate(name, "none") 는 secret string 을 안전한 "이름-서버" 형태로 정규화.
-- pcall 로 추가 방어 (일부 패치에서 Ambiguate 자체가 실패할 수 있음).
--------------------------------------------------------------------------------
local function sanitizeName(name)
    if not name then return nil end
    if Ambiguate then
        local ok, safe = pcall(Ambiguate, name, "none")
        if ok and type(safe) == "string" then
            local ok2, empty = pcall(function() return safe == "" end)
            if ok2 and not empty then return safe end
            if not ok2 then return safe end  -- 검사 자체가 실패해도 이름은 유효한 secret
        end
    end
    -- Ambiguate 실패: 원본 그대로 돌려줌 (호출자가 pcall 로 써야 함)
    return name
end

-- 같은 서버: "이름", 다른 서버: "이름-서버"
-- secret string 방어: UnitName 결과가 secret 일 수 있으므로 Ambiguate 로 정규화
function MR.FullName(unit)
    local ok, name = pcall(UnitName, unit)
    if not ok or not name then return nil end
    local safe = sanitizeName(name)
    if not safe then return nil end
    -- Ambiguate 는 이미 "이름-서버" 형태로 반환하므로 realm 처리 불필요
    return safe
end

-- 채팅 출력용 기본 이름: "이름-서버"에서 서버 제거
-- secret string 방어: :match 실패 시 Ambiguate("short") 또는 원본 반환
function MR.BaseName(name)
    if not name then return name end
    local ok, isEmpty = pcall(function() return name == "" end)
    if ok and isEmpty then return name end
    local ok2, result = pcall(function() return name:match("^([^-]+)") end)
    if ok2 and result then return result end
    -- secret: Ambiguate("short") 로 서버 제거 시도
    if Ambiguate then
        local ok3, short = pcall(Ambiguate, name, "short")
        if ok3 and type(short) == "string" then return short end
    end
    return name
end

-- 이름 정규화: secret string 도 Ambiguate 로 "이름-서버" 형태 통일
function MR.CanonicalName(name)
    if not name then return nil end
    local safe = sanitizeName(name)
    if not safe then return nil end
    local ok, empty = pcall(function() return safe == "" end)
    if ok and empty then return nil end
    -- Ambiguate 가 반환한 값은 "이름" 또는 "이름-서버" — "-" 없으면 내 서버 붙임
    local ok2, hasDash = pcall(function() return safe:find("-", 1, true) ~= nil end)
    if ok2 and hasDash then return safe end
    if ok2 and not hasDash then
        local myRealm = GetRealmName()
        if not myRealm or myRealm == "" then return safe end
        myRealm = myRealm:gsub("%s+", "")
        local ok3, joined = pcall(function() return safe .. "-" .. myRealm end)
        if ok3 then return joined end
    end
    return safe  -- 연산 실패 시 그대로 (downstream 에서 pcall 로 비교)
end

-- 두 플레이어 이름이 같은 인물을 가리키는지 판정 (realm 표기 차이 허용)
-- 단순 base-name 매칭은 서로 다른 서버의 동명 캐릭을 오탐하므로 사용하지 않는다
function MR.NamesMatch(a, b)
    if not a or not b then return false end
    -- 직접 비교 (성공하면 빠르게 반환)
    local ok, same = pcall(function() return a == b end)
    if ok and same then return true end
    local ca = MR.CanonicalName(a)
    local cb = MR.CanonicalName(b)
    if not ca or not cb then return false end
    local ok2, equal = pcall(function() return ca == cb end)
    return ok2 and equal
end

--------------------------------------------------------------------------------
-- 안전 채팅 전송 (rate-limited queue)
-- 보스 전투(IsEncounterInProgress) 중에는 SendChatMessage 호출이 taint 로
-- ADDON_ACTION_FORBIDDEN 을 유발할 수 있어 큐잉 후 ENCOUNTER_END 에서 재개.
-- 또한 WoW 서버 throttle 로 짧은 시간에 다수 전송 시 뒤쪽 줄이 drop 되므로,
-- 모든 전송을 0.1초 간격 큐로 통과시켜 긴 리포트도 안잘리게 함.
--------------------------------------------------------------------------------
MR._chatQueue = MR._chatQueue or {}
local CHAT_SEND_INTERVAL = 0.1
local drainScheduled = false
local lastSentAt = 0

local function isInEncounter()
    ---@diagnostic disable-next-line: undefined-global
    local ok, result = pcall(IsEncounterInProgress)
    return ok and result
end

local function drainOne()
    drainScheduled = false
    local q = MR._chatQueue
    if not q or #q == 0 then return end
    if isInEncounter() then return end  -- ENCOUNTER_END 에서 재개

    local now = GetTime()
    local remaining = (lastSentAt + CHAT_SEND_INTERVAL) - now
    if remaining > 0 then
        drainScheduled = true
        C_Timer.After(remaining, drainOne)
        return
    end

    local item = table.remove(q, 1)
    pcall(SendChatMessage, item.msg, item.channel, item.language, item.target)
    lastSentAt = now

    if #q > 0 then
        drainScheduled = true
        C_Timer.After(CHAT_SEND_INTERVAL, drainOne)
    end
end

function MR.SafeSendChat(msg, channel, language, target)
    if not msg or msg == "" then return end
    table.insert(MR._chatQueue, { msg = msg, channel = channel, language = language, target = target })
    if not drainScheduled then
        drainScheduled = true
        C_Timer.After(0, drainOne)
    end
end

function MR.FlushChatQueue()
    if drainScheduled then return end
    if not MR._chatQueue or #MR._chatQueue == 0 then return end
    drainScheduled = true
    C_Timer.After(0, drainOne)
end

-- 한국 WoW 클라이언트는 아이템 링크 표시 텍스트에 "(부위 레벨)" 접미어를 포함시킨다
-- 예: [분노한 거인의 손갑 (손 45)] → [분노한 거인의 손갑]
-- 채팅 송신 전에 링크/이름에서 이 접미어를 제거한다
local function stripIlvlSuffix(s)
    if not s then return s end
    return (s:gsub("%s*%([^()]-%d+%s*%)%s*$", ""))
end

function MR.CleanItemName(name)
    return stripIlvlSuffix(name)
end

function MR.CleanItemLink(link)
    if not link then return link end
    return (link:gsub("(|h%[)(.-)(%]|h)", function(pre, inner, post)
        return pre .. stripIlvlSuffix(inner) .. post
    end))
end

--------------------------------------------------------------------------------
-- 아이템 요약: 살펴보기 활성 시 경매 공지에 같이 송출하는 짧은 정보.
-- 형식: "[2차스탯들] - [1차스탯][갑옷재질][슬롯][홈xN]"
-- 예시: "[치][가] - [지능][천][머리]"  /  "[치][특] - [민첩][가죽][어깨][홈x2]"
-- 좌/우 한쪽만 있으면 다른쪽 + 구분 dash 생략. 둘 다 비면 빈 문자열 반환.
--------------------------------------------------------------------------------
-- 1차 스탯: 단일 스탯 아이템(천/판금 등 직업 전용)은 풀네임,
-- 다중 스탯 아이템(반지/목걸이/장신구/무기 등 범용)은 줄임말 + 힘민지 순.
local PRIMARY_STAT_FULL_KR = {
    ITEM_MOD_STRENGTH_SHORT  = "힘",
    ITEM_MOD_AGILITY_SHORT   = "민첩",
    ITEM_MOD_INTELLECT_SHORT = "지능",
}
-- 다중 1차 스탯 표시용. 짧은 줄임말 대신 풀네임으로 통일 (가독성 개선)
local PRIMARY_STAT_BRIEF_KR = {
    ITEM_MOD_STRENGTH_SHORT  = "힘",
    ITEM_MOD_AGILITY_SHORT   = "민첩",
    ITEM_MOD_INTELLECT_SHORT = "지능",
}
-- 출력 순서 고정 (힘 → 민 → 지)
local PRIMARY_ORDER = {
    "ITEM_MOD_STRENGTH_SHORT",
    "ITEM_MOD_AGILITY_SHORT",
    "ITEM_MOD_INTELLECT_SHORT",
}
-- 2차 스탯 표시명 — 줄임말(치/가/특/유) 대신 풀네임으로 통일 (가독성 개선)
local SECONDARY_STAT_KR = {
    ITEM_MOD_CRIT_RATING_SHORT    = "치명",
    ITEM_MOD_HASTE_RATING_SHORT   = "가속",
    ITEM_MOD_MASTERY_RATING_SHORT = "특화",
    ITEM_MOD_VERSATILITY          = "유연",
    ITEM_MOD_VERSATILITY_SHORT    = "유연",  -- 일부 빌드에서 _SHORT 접미어 사용
}
-- 출력 순서 고정 (치-가-특-유)
local SECONDARY_ORDER = {
    "ITEM_MOD_CRIT_RATING_SHORT",
    "ITEM_MOD_HASTE_RATING_SHORT",
    "ITEM_MOD_MASTERY_RATING_SHORT",
    "ITEM_MOD_VERSATILITY",
    "ITEM_MOD_VERSATILITY_SHORT",
}
-- 3차 스탯 (특수 능력치) — 광피/생흡/이속. 빌드별 키 변형 모두 등록.
local TERTIARY_STAT_KR = {
    ITEM_MOD_CR_AVOIDANCE_SHORT        = "광피",
    ITEM_MOD_CR_AVOIDANCE_RATING_SHORT = "광피",
    ITEM_MOD_CR_LIFESTEAL_SHORT        = "생흡",
    ITEM_MOD_CR_LIFESTEAL_RATING_SHORT = "생흡",
    ITEM_MOD_CR_SPEED_SHORT            = "이속",
    ITEM_MOD_CR_SPEED_RATING_SHORT     = "이속",
}
local TERTIARY_ORDER = {
    "ITEM_MOD_CR_AVOIDANCE_SHORT",        "ITEM_MOD_CR_AVOIDANCE_RATING_SHORT",
    "ITEM_MOD_CR_LIFESTEAL_SHORT",        "ITEM_MOD_CR_LIFESTEAL_RATING_SHORT",
    "ITEM_MOD_CR_SPEED_SHORT",            "ITEM_MOD_CR_SPEED_RATING_SHORT",
}
-- equipLoc → 한국어 슬롯명. _G[equipLoc] 도 가능하지만 명시적으로 매핑하여 누락/오타 회피.
local INVTYPE_KR = {
    INVTYPE_HEAD           = "머리",
    INVTYPE_NECK           = "목",
    INVTYPE_SHOULDER       = "어깨",
    INVTYPE_CHEST          = "가슴",
    INVTYPE_ROBE           = "가슴",
    INVTYPE_WAIST          = "허리",
    INVTYPE_LEGS           = "다리",
    INVTYPE_FEET           = "발",
    INVTYPE_WRIST          = "손목",
    INVTYPE_HAND           = "손",
    INVTYPE_FINGER         = "반지",
    INVTYPE_TRINKET        = "장신구",
    INVTYPE_CLOAK          = "등",
    INVTYPE_2HWEAPON       = "양손",
    INVTYPE_WEAPON         = "한손",
    INVTYPE_WEAPONMAINHAND = "주무기",
    INVTYPE_WEAPONOFFHAND  = "보조무기",
    INVTYPE_RANGED         = "원거리",
    INVTYPE_RANGEDRIGHT    = "원거리",
    INVTYPE_SHIELD         = "방패",
    INVTYPE_HOLDABLE       = "보조",
}

-- 갑옷 재질 (subType) — 이 값일 때만 우측에 [재질] 표시. 무기는 너무 길거나 슬롯과 겹쳐 생략.
local ARMOR_SUBTYPES = {
    ["천"]    = true,
    ["가죽"]  = true,
    ["사슬"]  = true,
    ["판금"]  = true,
    ["방패"]  = true,
}

-- 클래스 활성/비활성 무관하게 1차 스탯 모두 검출 (범용 아이템: 망토/반지/목걸이/장신구/무기 등).
-- C_Item.GetItemStats 는 활성 스탯만 반환하기 때문에 별도 툴팁 스캔으로 보완.
-- C_TooltipInfo.GetHyperlink → data.lines 의 leftText 에서 한국어 1차 스탯 키워드 검출.
local function scanTooltipForPrimaries(itemLink)
    if not itemLink or not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return nil
    end
    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if not data or not data.lines then return nil end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end

    local hasSTR, hasAGI, hasINT = false, false, false
    for _, line in ipairs(data.lines) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, line)
        end
        local text = line.leftText or ""
        -- 스탯 라인은 항상 숫자 포함 (+50 힘 / 힘 +50 등)
        if text ~= "" and text:find("%d") then
            if not hasSTR and text:find("힘",     1, true) then hasSTR = true end
            if not hasAGI and text:find("민첩성", 1, true) then hasAGI = true end
            if not hasINT and text:find("지능",   1, true) then hasINT = true end
        end
    end

    local list = {}
    if hasSTR then table.insert(list, "ITEM_MOD_STRENGTH_SHORT")  end
    if hasAGI then table.insert(list, "ITEM_MOD_AGILITY_SHORT")   end
    if hasINT then table.insert(list, "ITEM_MOD_INTELLECT_SHORT") end
    return list
end

-- multiline=true 면 g1-g2 / g3-g4 를 "\n" 로 분리 (UI 두 줄 표시용).
-- 기본(false) 은 모든 그룹을 " - " 로 연결한 단일 라인 (채팅용).
-- 직업 제한 스캔 — 툴팁의 "직업: 전사, 사냥꾼, 도적" 라인에서 직업 추출
-- 반환: { "전사", "사냥꾼", "도적" } 또는 nil (직업 제한 없음)
local function scanItemClasses(itemLink)
    if not itemLink or not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return nil
    end
    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if not data or not data.lines then return nil end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end
    for _, line in ipairs(data.lines) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, line)
        end
        local text = line.leftText or ""
        -- "직업:" 또는 "Classes:" 프리픽스 매칭 (한국 클라/영어 클라 모두 대응)
        local rest = text:match("^%s*직업%s*:%s*(.+)$")
                  or text:match("^%s*Classes%s*:%s*(.+)$")
        if rest then
            local classes = {}
            for cls in rest:gmatch("[^,]+") do
                cls = cls:gsub("^%s+", ""):gsub("%s+$", "")
                if cls ~= "" then table.insert(classes, cls) end
            end
            if #classes > 0 then return classes end
        end
    end
    return nil
end
MR._scanItemClasses = scanItemClasses   -- 테스트/디버그용 노출

-- 티어 토큰 슬롯 스캔 — 툴팁에서 "머리/어깨/가슴/손/다리" 추출
-- 1순위: 단독 라인 (일반 장비 슬롯 라인 형식과 동일)
-- 2순위: 본문 검색 (사용 효과 설명 등에 슬롯 키워드 포함된 경우)
local TIER_SLOT_KEYWORDS = { "머리", "어깨", "가슴", "손", "다리" }
local function scanTierTokenSlot(itemLink)
    if not itemLink or not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return nil
    end
    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if not data or not data.lines then return nil end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end
    for _, line in ipairs(data.lines) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, line)
        end
        local text = (line.leftText or ""):gsub("^%s+", ""):gsub("%s+$", "")
        for _, slot in ipairs(TIER_SLOT_KEYWORDS) do
            if text == slot then return slot end
        end
    end
    for _, line in ipairs(data.lines) do
        local text = line.leftText or ""
        for _, slot in ipairs(TIER_SLOT_KEYWORDS) do
            if text:find(slot, 1, true) then return slot end
        end
    end
    return nil
end

-- 직업 그룹 → 갑옷 재질 매핑 (티어 토큰 재질 추론용)
local CLASS_TO_ARMOR = {
    ["마법사"] = "천",   ["사제"] = "천",     ["흑마법사"] = "천",
    ["도적"]   = "가죽", ["수도사"] = "가죽", ["드루이드"] = "가죽", ["악마사냥꾼"] = "가죽",
    ["사냥꾼"] = "사슬", ["주술사"] = "사슬", ["기원사"]   = "사슬",
    ["전사"]   = "판금", ["성기사"] = "판금", ["죽음의 기사"] = "판금",
}
-- 모든 직업이 같은 재질 그룹이면 그 재질 반환, 아니면 nil (= 티어 토큰 아님)
local function classListToArmor(classList)
    if not classList or #classList == 0 then return nil end
    local armor
    for _, cls in ipairs(classList) do
        local a = CLASS_TO_ARMOR[cls]
        if not a then return nil end
        if armor and armor ~= a then return nil end
        armor = a
    end
    return armor
end

-- 사용/착용 효과 검출 — 툴팁 라인에서 "사용 효과:" / "착용 효과:" 키워드 스캔
local function scanItemEffects(itemLink)
    if not itemLink or not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return false, false
    end
    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if not data or not data.lines then return false, false end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end
    local hasUse, hasEquip = false, false
    for _, line in ipairs(data.lines) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, line)
        end
        local text = line.leftText or ""
        if not hasUse and (text:find("사용 효과", 1, true) or text:find("^사용%s*:")) then
            hasUse = true
        end
        if not hasEquip and (text:find("착용 효과", 1, true) or text:find("^착용%s*:")) then
            hasEquip = true
        end
    end
    return hasUse, hasEquip
end

function MR.BuildItemSummary(itemLink, multiline)
    if not itemLink or itemLink == "" then return "" end
    if not C_Item or not C_Item.GetItemInfo or not C_Item.GetItemStats then return "" end

    local _, _, _, _, _, _, subType, _, equipLoc = C_Item.GetItemInfo(itemLink)
    if not equipLoc or equipLoc == "" then return "" end

    local stats = C_Item.GetItemStats(itemLink)
    local primaries   = {}     -- 활성 1차 스탯 키 목록 (힘민지 순)
    local secondaries = {}
    local tertiaries  = {}
    local socketCount = 0

    if stats then
        -- 홈 카운트 (순서 무관)
        for k, v in pairs(stats) do
            if type(k) == "string" and k:find("EMPTY_SOCKET", 1, true) then
                socketCount = socketCount + (tonumber(v) or 1)
            end
        end
        -- 1차 스탯 검출. GetItemStats 는 클래스 활성 스탯만 반환하므로 (마법사면 INT 만)
        -- 툴팁 스캔이 더 신뢰성 있음. 툴팁 결과가 있으면 그걸 우선 사용.
        local fromTooltip = scanTooltipForPrimaries(itemLink)
        if fromTooltip and #fromTooltip > 0 then
            primaries = fromTooltip
        else
            for _, key in ipairs(PRIMARY_ORDER) do
                if stats[key] ~= nil then
                    table.insert(primaries, key)
                end
            end
        end
        -- 진단: 1차 스탯 인식 결과 (API vs 툴팁 비교)
        if MR.Debug and itemLink then
            MR.Debug(string.format(
                "[Summary] link=%s STR=%s AGI=%s INT=%s tooltipPri=%d final=%d subType=%s equipLoc=%s",
                itemLink:match("|h(.-)|h") or "?",
                tostring(stats.ITEM_MOD_STRENGTH_SHORT),
                tostring(stats.ITEM_MOD_AGILITY_SHORT),
                tostring(stats.ITEM_MOD_INTELLECT_SHORT),
                fromTooltip and #fromTooltip or -1,
                #primaries, tostring(subType), tostring(equipLoc)))
        end
        -- 2차는 정해진 순서로 (치-가-특-유)
        local seenSec = {}
        for _, key in ipairs(SECONDARY_ORDER) do
            local val = stats[key]
            if val and val > 0 then
                local kr = SECONDARY_STAT_KR[key]
                if kr and not seenSec[kr] then
                    table.insert(secondaries, kr)
                    seenSec[kr] = true
                end
            end
        end
        -- 3차 (광피/생흡/이속) — 슬롯/보홈 다음 위치
        local seenTer = {}
        for _, key in ipairs(TERTIARY_ORDER) do
            local val = stats[key]
            if val and val > 0 then
                local kr = TERTIARY_STAT_KR[key]
                if kr and not seenTer[kr] then
                    table.insert(tertiaries, kr)
                    seenTer[kr] = true
                end
            end
        end
    end

    -- 파불(파괴 불가)는 스탯이 아니라 bonusID 기반 변형 → MR.GetItemCategories 사용
    local hasIndestruct = false
    if MR.GetItemCategories and MR.ITEM_CATEGORY then
        local cats = MR.GetItemCategories(itemLink)
        for _, c in ipairs(cats or {}) do
            if c == MR.ITEM_CATEGORY.INDESTRUCT then hasIndestruct = true; break end
        end
    end

    -- 사용/착용 효과 검출 (장신구/일부 무기 등)
    local hasUseEffect, hasEquipEffect = scanItemEffects(itemLink)

    -- 직업 제한 + 티어 검출
    -- 티어는 5부위 고정 (머리/어깨/가슴/손/다리). 현 패치 기준 티어는 갑옷 재질별(천/가죽/사슬/판금)로
    -- 묶이므로 [재질][부위][티어] 형식으로 표시. 그 외(무기/허리/손목/발/장신구 등)에서 직업 제한
    -- 걸린 건 "전용" 아이템으로 분류 (티어 X).
    local TIER_SLOTS = {
        INVTYPE_HEAD     = "머리",
        INVTYPE_SHOULDER = "어깨",
        INVTYPE_CHEST    = "가슴",
        INVTYPE_ROBE     = "가슴",
        INVTYPE_HAND     = "손",
        INVTYPE_LEGS     = "다리",
    }
    local classList = scanItemClasses(itemLink)
    local isTierLike = false   -- 부가 정보 생략 여부 (티어 5부위 한정)
    local tierTag    = ""      -- [재질][부위][티어] (또는 직업 fallback)
    local classOnlyTag = ""    -- 비-티어 직업 제한: [직업][전용]
    if classList and #classList > 0 then
        local tierSlot = TIER_SLOTS[equipLoc]
        if tierSlot then
            -- 5부위 직접 장착 티어: [재질][티어][부위]
            isTierLike = true
            if subType and ARMOR_SUBTYPES[subType] and subType ~= "방패" then
                tierTag = string.format("[%s][티어][%s]", subType, tierSlot)
            else
                local classPart = "[" .. table.concat(classList, "/") .. "]"
                tierTag = classPart .. "[티어][" .. tierSlot .. "]"
            end
        else
            -- 티어 토큰 검사: 직업 그룹이 같은 재질이고 툴팁에 슬롯 키워드 있으면 토큰
            local tokenArmor = classListToArmor(classList)
            local tokenSlot  = tokenArmor and scanTierTokenSlot(itemLink) or nil
            if tokenArmor and tokenSlot then
                isTierLike = true
                tierTag = string.format("[%s][티어][%s]", tokenArmor, tokenSlot)
            else
                -- 무기/허리/손목/발/장신구/반지/목/등 — 전용 아이템 (티어 아님)
                local classPart = "[" .. table.concat(classList, "/") .. "]"
                classOnlyTag = classPart .. "[전용]"
            end
        end
    end

    -- UI 표시(multiline=true): 줄임말 사용 / 채팅 송출(multiline=false): 풀네임 (공장 콜 가독성)
    local useShort = multiline
    local SECONDARY_BRIEF   = { ["치명"] = "치", ["가속"] = "가", ["특화"] = "특", ["유연"] = "유" }
    local PRIMARY_VERY_BRIEF = {
        ITEM_MOD_STRENGTH_SHORT  = "힘",
        ITEM_MOD_AGILITY_SHORT   = "민",
        ITEM_MOD_INTELLECT_SHORT = "지",
    }

    -- 그룹 1: 2차 스탯
    local g1Parts = {}
    for _, s in ipairs(secondaries) do
        local label = (useShort and SECONDARY_BRIEF[s]) or s
        table.insert(g1Parts, "[" .. label .. "]")
    end
    local g1 = table.concat(g1Parts, "")

    -- 그룹 2: 1차 스탯
    --   UI 모드(useShort): [힘][민][지] 형식 (1개든 다중이든 동일)
    --   채팅 모드: 단일=풀네임, 다중=풀네임 (PRIMARY_STAT_BRIEF_KR 도 풀네임으로 통일됨)
    local g2Parts = {}
    if useShort then
        for _, key in ipairs(primaries) do
            table.insert(g2Parts, "[" .. (PRIMARY_VERY_BRIEF[key] or "?") .. "]")
        end
    else
        if #primaries == 1 then
            table.insert(g2Parts, "[" .. PRIMARY_STAT_FULL_KR[primaries[1]] .. "]")
        elseif #primaries > 1 then
            for _, key in ipairs(primaries) do
                table.insert(g2Parts, "[" .. PRIMARY_STAT_BRIEF_KR[key] .. "]")
            end
        end
    end
    local g2 = table.concat(g2Parts, "")

    -- 그룹 3 (풀/짧음): UI 두번째 줄 + 채팅 (모드별 라벨 다름)
    local g3FullParts = {}
    local socketLabel    = useShort and "보홈" or "보석 홈"
    local indestructText = useShort and "[파불]" or "[파괴 불가]"
    local useEffectText  = useShort and "[사효]" or "[사용 효과]"
    local equipEffectTxt = useShort and "[착효]" or "[착용 효과]"
    local TERTIARY_FULL  = { ["광피"] = "[광역회피]", ["생흡"] = "[생기흡수]", ["이속"] = "[이동 속도]" }

    if socketCount > 0 then
        if socketCount > 1 then
            table.insert(g3FullParts, "[" .. socketLabel .. " x " .. socketCount .. "]")
        else
            table.insert(g3FullParts, "[" .. socketLabel .. "]")
        end
    end
    -- tertiary: useShort 일 때 줄임말(광피/생흡/이속), 풀 모드일 때 풀네임
    for _, t in ipairs(tertiaries) do
        if useShort then
            table.insert(g3FullParts, "[" .. t .. "]")
        else
            table.insert(g3FullParts, TERTIARY_FULL[t] or ("[" .. t .. "]"))
        end
    end
    if hasIndestruct then
        table.insert(g3FullParts, indestructText)
    end
    -- 사용/착용 효과 (장신구 등). 티어 5부위에서는 가짜 사효/착효 라인 차단
    if hasUseEffect and not isTierLike then
        table.insert(g3FullParts, useEffectText)
    end
    if hasEquipEffect and not isTierLike then
        table.insert(g3FullParts, equipEffectTxt)
    end
    local g3Full = table.concat(g3FullParts, "")

    -- 그룹 4: 부위 식별 (갑옷재질+슬롯 / 무기는 subType만 / 방패는 중복 회피)
    --   갑옷  : [천][머리] 처럼 재질 + 슬롯
    --   무기  : [단검] / [한손 검] / [지팡이] / [활] (subType 만, 슬롯 생략 — subType 에 슬롯 정보 포함)
    --   방패  : [방패] (subType=방패 = 슬롯 중복 → 한 번만)
    --   기타  : 슬롯명만 ([반지] / [목] / [장신구] 등)
    local isWeapon = equipLoc == "INVTYPE_WEAPON"
                  or equipLoc == "INVTYPE_2HWEAPON"
                  or equipLoc == "INVTYPE_WEAPONMAINHAND"
                  or equipLoc == "INVTYPE_WEAPONOFFHAND"
                  or equipLoc == "INVTYPE_RANGED"
                  or equipLoc == "INVTYPE_RANGEDRIGHT"
    local isShield = equipLoc == "INVTYPE_SHIELD"

    -- subType 표시명 매핑 (WoW 기본 명칭과 다르게 보이고 싶은 케이스)
    local SUBTYPE_DISPLAY = {
        ["주먹 무기"] = "장착 무기",
        ["한손 검"]   = "한손 도검",
        ["양손 검"]   = "양손 도검",
    }

    local g4Parts = {}
    if isWeapon and subType and subType ~= "" then
        -- 무기 종류 (한손 검/양손 도끼/단검/지팡이/활/총/석궁/마법봉/장착 무기/전투검 등)
        local displaySubType = SUBTYPE_DISPLAY[subType] or subType
        table.insert(g4Parts, "[" .. displaySubType .. "]")
        -- 주무기/보조무기 전용 슬롯이면 추가 태그 (양손/일반 한손은 subType 에 정보 포함됨 → 생략)
        if equipLoc == "INVTYPE_WEAPONMAINHAND" then
            table.insert(g4Parts, "[주무기]")
        elseif equipLoc == "INVTYPE_WEAPONOFFHAND" then
            table.insert(g4Parts, "[보조무기]")
        end
    elseif subType and ARMOR_SUBTYPES[subType] then
        -- 갑옷 재질 (천/가죽/사슬/판금) 또는 방패
        table.insert(g4Parts, "[" .. subType .. "]")
    end
    -- 슬롯: 무기/방패는 subType 으로 충분 → 슬롯 생략. 그 외(갑옷/액세서리)는 슬롯 추가
    local slotKR = INVTYPE_KR[equipLoc]
    if slotKR and not isWeapon and not isShield then
        table.insert(g4Parts, "[" .. slotKR .. "]")
    end
    local g4 = table.concat(g4Parts, "")

    local function joinDash(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local s = select(i, ...)
            if s and s ~= "" then table.insert(parts, s) end
        end
        return table.concat(parts, " - ")
    end

    -- 티어 5부위(머리/어깨/가슴/손/다리) + 직업 제한: 부가 정보 전부 생략하고 [직업][부위 티어] 만 표시
    -- 어차피 티어 세트는 부위/직업으로 정해져 있으니 스탯/재질/보홈 등 다른 정보는 노이즈
    if isTierLike then
        return tierTag
    end

    -- 비-티어 직업 제한 아이템(전용 무기/방패/허리/손목/발/장신구 등): 풀 정보 + [직업][전용] 태그 추가
    if multiline then
        local line1 = joinDash(g1, g2, g4)
        local line2 = g3Full
        if classOnlyTag ~= "" then
            line2 = (line2 == "") and classOnlyTag or (line2 .. " " .. classOnlyTag)
        end
        if line1 == "" and line2 == "" then return "" end
        if line2 == "" then return line1 end
        if line1 == "" then return line2 end
        return line1 .. "\n" .. line2
    else
        -- 채팅 단일 라인: [2차] - [1차] - [재질+슬롯] - [풀네임 보홈/3차/파불] - [직업][전용]
        return joinDash(g1, g2, g4, g3Full, classOnlyTag)
    end
end

-- 설정값 로드 (SavedVariables 병합)
function MR.LoadSettings()
    if not MimRaidDB then
        MimRaidDB = {}
    end
    if not MimRaidDB.cfg then
        MimRaidDB.cfg = {}
    end

    -- DEFAULTS → cfg로 복사 후 SavedVariables 값으로 덮어쓰기
    for k, v in pairs(MR.DEFAULTS) do
        if MimRaidDB.cfg[k] ~= nil then
            MR.cfg[k] = MimRaidDB.cfg[k]
        else
            MR.cfg[k] = v
        end
    end

    -- 낙찰 완료 사운드 강제 갱신 (구버전 ID → 569593)
    local _oldSoundSold = { [567434] = true, [569454] = true }
    if _oldSoundSold[MR.cfg.soundSold] then
        MR.cfg.soundSold = MR.DEFAULTS.soundSold
        MimRaidDB.cfg.soundSold = MR.DEFAULTS.soundSold
    end

    -- GRACE 기간 마이그레이션: 구 기본값 (0.5초) 은 silence 제거 후 막판 입찰 누락을 유발
    -- → 1.0 미만 저장값은 새 기본값(2.0)으로 강제 업그레이드.
    if type(MR.cfg.bidGracePeriod) == "number" and MR.cfg.bidGracePeriod < 1.0 then
        MR.cfg.bidGracePeriod = MR.DEFAULTS.bidGracePeriod
        MimRaidDB.cfg.bidGracePeriod = MR.DEFAULTS.bidGracePeriod
    end

    -- 구버전 메시지 템플릿 강제 갱신 ([밈레이드경매] → [경매] 일괄 전환)
    if type(MR.cfg.msgSold) == "string" and MR.cfg.msgSold:find("[밈레이드경매]", 1, true) then
        MR.cfg.msgSold = MR.DEFAULTS.msgSold
    end
    if type(MR.cfg.msgNoWinner) == "string" and MR.cfg.msgNoWinner:find("[밈레이드경매]", 1, true) then
        MR.cfg.msgNoWinner = MR.DEFAULTS.msgNoWinner
    end
    if type(MR.cfg.msgCountdown) == "string" and MR.cfg.msgCountdown:find("[밈레이드경매]", 1, true) then
        MR.cfg.msgCountdown = MR.DEFAULTS.msgCountdown
    end
end

-- 설정값 저장
function MR.SaveSettings()
    if not MimRaidDB then MimRaidDB = {} end
    MimRaidDB.cfg = {}
    for k, v in pairs(MR.cfg) do
        MimRaidDB.cfg[k] = v
    end
end
