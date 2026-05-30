--------------------------------------------------------------------------------
-- MimRaid - CalendarInvite.lua
-- 달력 초대(달초) 패널: 외부 프로그램에서 정리한 명단을 붙여넣어 와우 달력
-- 일정의 초대 명단을 일괄 자동 입력.
--
-- 단계 1: UI 골격 (탭/패널/입력박스/버튼/결과영역). 파싱과 달력 자동화는
--          이후 단계에서 구현. 현재는 버튼 누르면 안내만 출력.
--------------------------------------------------------------------------------

local MR = MimRaid
local CP = MR.CalendarPanel
if not CP then return end   -- AuctionFrame 미로드 시 안전 가드

local FONT = MR.FONT or "Fonts\\2002.TTF"

-- 상태 (단계별로 채워질 예정)
MR.CalendarInvite = MR.CalendarInvite or {}
local CI = MR.CalendarInvite
CI.parsed   = CI.parsed   or { date = nil, time = nil, title = nil, names = {} }
CI.results  = CI.results  or { successes = {}, failures = {} }
CI.rawText  = CI.rawText  or ""

--------------------------------------------------------------------------------
-- 파싱 로직 (단계 2)
-- 입력 형식 둘 다 지원:
--   ① 1줄: "2026-05-15 21:30 | 임시공대 | 닉네임-서버, 닉네임-서버, ..."
--   ② 여러 줄:
--       2026-05-15 21:30
--       임시공대
--       닉네임-서버, 닉네임-서버, ...
-- 빕봇 출력 그대로(`이름-서버 직업 전문화`) 던져도 작동:
--   - `-`(서버 구분자) 포함된 토큰만 캐릭명으로 인식
--   - 직업/전문화/대괄호/숫자 토큰은 자동으로 걸러짐
--------------------------------------------------------------------------------
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- 날짜+시간 문자열 → { date="YYYY-MM-DD", time="HH:MM", year, month, day, hour, min }
-- 못 찾으면 nil
local function tryParseDateTime(s)
    s = trim(s)
    if s == "" then return nil end

    -- YYYY-MM-DD HH:MM (구분자 - / . 허용, 자릿수 가변)
    local y, mo, d, h, mi = s:match("^(%d+)[-/.](%d+)[-/.](%d+)%s+(%d+):(%d+)")
    if y then
        y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
        if y and mo and d and h and mi then
            return {
                year = y, month = mo, day = d, hour = h, min = mi,
                date = string.format("%04d-%02d-%02d", y, mo, d),
                time = string.format("%02d:%02d", h, mi),
            }
        end
    end
    return nil
end

-- 토큰이 "이름-서버" 형식인가? (빕봇 강제 부착 규칙 가정)
-- 직업/전문화/대괄호/숫자 토큰은 false 반환되어 명단에서 자동 제외
local function isCharNameToken(tok)
    if not tok or tok == "" then return false end
    -- 대괄호/꺽쇠/괄호/특수기호 포함 시 제외
    if tok:find("[%[%]<>%(%)%*]") then return false end
    -- 숫자만이면 제외
    if tok:match("^[%d:%-%.]+$") then return false end
    -- '-' 포함 = 이름-서버 형식으로 간주
    if tok:find("-", 1, true) then return true end
    return false
end

-- 문자열에서 캐릭명 토큰만 골라 namesOut에 추가 (중복은 seen 으로 제거)
local function extractNames(s, namesOut, seen)
    if not s or s == "" then return end
    -- 콤마/세미콜론/공백/탭/파이프로 토큰 분리
    for tok in s:gmatch("[^,;|%s]+") do
        if isCharNameToken(tok) and not seen[tok] then
            seen[tok] = true
            table.insert(namesOut, tok)
        end
    end
end

-- 메인 파서
local function parseInput(text)
    local result = { date = nil, time = nil, title = nil, description = nil, names = {} }
    if not text or text == "" then return result end

    -- 전각 파이프(｜ U+FF5C, EF BD 9C) → 일반 ASCII | 로 정규화
    text = text:gsub("\239\189\156", "|")
    -- 연속된 파이프(외부 도구가 ||를 출력하는 경우) → 단일 |로 정규화
    -- 사용자가 의도한 빈 필드 (예: "날짜 | | 명단") 의미는 보존됨
    text = text:gsub("||+", "|")

    local seen = {}

    if text:find("|", 1, true) then
        -- ─── 1줄 모드 ──────────────────────────────────────────────────────
        -- | 갯수에 따라 의미 고정:
        --   2 토큰: 날짜 | 명단
        --   3 토큰: 날짜 | 제목 | 명단
        --   4+ 토큰: 날짜 | 제목 | 설명 | 명단 (4번째 이후 모두 명단)
        local firstLine = text:match("^[^\r\n]+") or text
        local restAfter = text:sub(#firstLine + 1)

        local parts = {}
        for p in (firstLine .. "|"):gmatch("([^|]*)|") do
            table.insert(parts, trim(p))
        end

        if parts[1] then
            local dt = tryParseDateTime(parts[1])
            if dt then result.date = dt.date; result.time = dt.time end
        end

        if #parts >= 4 then
            -- 4+ 토큰: 제목 / 설명 / 명단
            if parts[2] and parts[2] ~= "" then result.title       = parts[2] end
            if parts[3] and parts[3] ~= "" then result.description = parts[3] end
            for i = 4, #parts do
                extractNames(parts[i], result.names, seen)
            end
        elseif #parts == 3 then
            -- 3 토큰: 제목 / 명단 (설명 없음)
            if parts[2] and parts[2] ~= "" then result.title = parts[2] end
            extractNames(parts[3], result.names, seen)
        elseif #parts == 2 then
            -- 2 토큰: 명단만 (제목/설명 없음)
            extractNames(parts[2], result.names, seen)
        end

        -- 나머지 라인도 명단에 추가
        extractNames(restAfter, result.names, seen)
    else
        -- ─── 여러 줄 모드 ───────────────────────────────────────────────────
        local lines = {}
        for ln in text:gmatch("[^\r\n]+") do
            local t = trim(ln)
            if t ~= "" then table.insert(lines, t) end
        end

        local idx = 1
        -- 첫 줄: 날짜시간 시도
        if lines[idx] then
            local dt = tryParseDateTime(lines[idx])
            if dt then
                result.date = dt.date
                result.time = dt.time
                idx = idx + 1
            end
        end

        -- 다음 두 줄: 제목 → 설명 (각각 캐릭명 토큰 없을 때만 인정)
        local function lineHasNameTokens(ln)
            for tok in ln:gmatch("[^,;%s]+") do
                if isCharNameToken(tok) then return true end
            end
            return false
        end

        -- 제목 후보
        if lines[idx] and not lineHasNameTokens(lines[idx]) then
            result.title = lines[idx]
            idx = idx + 1
        end
        -- 설명 후보 (제목이 인식된 다음 줄에서만 시도)
        if result.title and lines[idx] and not lineHasNameTokens(lines[idx]) then
            result.description = lines[idx]
            idx = idx + 1
        end

        -- 나머지 모두 명단
        for i = idx, #lines do
            extractNames(lines[i], result.names, seen)
        end
    end

    return result
end

CI._parseInput = parseInput   -- 테스트/디버그용 노출

--------------------------------------------------------------------------------
-- 헬퍼: 버튼/배경
--------------------------------------------------------------------------------
local function createBtn(parent, text, w, h)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w or 100, h or 22)
    if btn.SetText then btn:SetText(text) end
    if btn.GetFontString and btn:GetFontString() then
        btn:GetFontString():SetFont(FONT, 12)
    end
    return btn
end

local function applyBg(frame, r, g, b, a, br, bg, bb, ba)
    if MR.applyBackdrop and MR.BACKDROP_DARK then
        MR.applyBackdrop(frame, MR.BACKDROP_DARK, r, g, b, a, br, bg, bb, ba)
    end
end

--------------------------------------------------------------------------------
-- 1. 안내 헤더
--------------------------------------------------------------------------------
local title = CP:CreateFontString(nil, "OVERLAY")
title:SetFont(FONT, 13)
title:SetTextColor(1, 0.82, 0)
title:SetPoint("TOPLEFT", CP, "TOPLEFT", 8, -8)
title:SetText("달력에 공격대원 한번에 추가하기")

local desc = CP:CreateFontString(nil, "OVERLAY")
desc:SetFont(FONT, 13)
desc:SetTextColor(1.0, 0.55, 0.25)   -- 주황색: 주의 강조
desc:SetPoint("TOPLEFT",  title, "BOTTOMLEFT", 0, -6)
desc:SetPoint("TOPRIGHT", CP,    "TOPRIGHT",  -8, -28)
desc:SetJustifyH("LEFT")
desc:SetJustifyV("TOP")
desc:SetWordWrap(false)
desc:SetText("<주의!> 달력-우클릭-일정만들기로 창 연 후 [달력에 공격대원 추가하기] 클릭!")

-- 샘플 예시 (회색 안내, 주의 문구 바로 아래)
local sample = CP:CreateFontString(nil, "OVERLAY")
sample:SetFont(FONT, 10)
sample:SetTextColor(0.6, 0.6, 0.6)
sample:SetPoint("TOPLEFT",  desc, "BOTTOMLEFT", 0, -3)
sample:SetPoint("TOPRIGHT", desc, "BOTTOMRIGHT", 0, -3)
sample:SetJustifyH("LEFT")
sample:SetWordWrap(false)
sample:SetText("예) 밈주머니-아즈샤라, 글파괴자-아즈샤라, 홍길동-듀로탄")

--------------------------------------------------------------------------------
-- 2. 입력 영역 (멀티라인 EditBox + 스크롤)
--------------------------------------------------------------------------------
local INPUT_TOP = -68   -- 주의(1줄) + 샘플(1줄) 아래
local INPUT_H   = 55    -- 절반으로 축소 (사용자 요청: 모든 텍스트 다 보일 필요 없음)

local inputBox = CreateFrame("Frame", nil, CP, "BackdropTemplate")
inputBox:SetPoint("TOPLEFT",  CP, "TOPLEFT",  8, INPUT_TOP)
inputBox:SetPoint("TOPRIGHT", CP, "TOPRIGHT", -8, INPUT_TOP)
inputBox:SetHeight(INPUT_H)
-- 진한 배경 + 또렷한 금색 테두리 (포커스 안 됐을 때도 입력 영역이 명확히 보이도록)
applyBg(inputBox, 0.02, 0.02, 0.04, 1, 0.55, 0.45, 0.15, 1)

local inputScroll = CreateFrame("ScrollFrame", "MimRaidCalendarInputScroll", inputBox, "UIPanelScrollFrameTemplate")
inputScroll:SetPoint("TOPLEFT",     inputBox, "TOPLEFT",      6, -6)
inputScroll:SetPoint("BOTTOMRIGHT", inputBox, "BOTTOMRIGHT", -26, 6)

local inputEdit = CreateFrame("EditBox", nil, inputScroll)
inputEdit:SetMultiLine(true)
inputEdit:SetAutoFocus(false)
inputEdit:SetFontObject("ChatFontNormal")
inputEdit:SetWidth(inputScroll:GetWidth())
inputEdit:SetMaxLetters(4096)
inputEdit:SetText("")
inputEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
inputEdit:SetScript("OnTextChanged", function(self)
    local sw = inputScroll:GetWidth(); if sw and sw > 0 then self:SetWidth(sw) end
    inputScroll:UpdateScrollChildRect()
    -- 입력 변경 시 SavedVariables에 즉시 저장 (재접속/리로드 후에도 유지)
    if MimRaidDB then
        MimRaidDB.calendarInvite = MimRaidDB.calendarInvite or {}
        MimRaidDB.calendarInvite.rawText = self:GetText() or ""
    end
end)
inputScroll:SetScrollChild(inputEdit)
CI.inputEdit = inputEdit

-- SavedVariables 복원: ADDON_LOADED 후에 MimRaidDB가 채워지므로 지연 호출
local restoreFrame = CreateFrame("Frame")
restoreFrame:RegisterEvent("PLAYER_LOGIN")
restoreFrame:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if MimRaidDB and MimRaidDB.calendarInvite then
        local ci = MimRaidDB.calendarInvite
        if ci.rawText and ci.rawText ~= "" then
            inputEdit:SetText(ci.rawText)
        end
    end
end)

-- 비어 있을 때 안내 문구 (placeholder) — 클릭 시 사라지고 포커스
local placeholder = inputBox:CreateFontString(nil, "OVERLAY")
placeholder:SetFont(FONT, 11)
placeholder:SetTextColor(0.5, 0.5, 0.55)
placeholder:SetPoint("TOPLEFT", inputBox, "TOPLEFT", 12, -10)
placeholder:SetText("[ 여기에 명단을 붙여넣고 아래 [정리하기] 버튼을 누르세요 ]")
local function refreshPlaceholder()
    if (inputEdit:GetText() or "") == "" then placeholder:Show() else placeholder:Hide() end
end
inputEdit:HookScript("OnTextChanged", refreshPlaceholder)
inputEdit:HookScript("OnEditFocusGained", function() placeholder:Hide() end)
inputEdit:HookScript("OnEditFocusLost",  refreshPlaceholder)
refreshPlaceholder()

-- 빈 영역(테두리 안쪽) 클릭해도 EditBox 포커스
inputBox:EnableMouse(true)
inputBox:SetScript("OnMouseDown", function() inputEdit:SetFocus() end)
inputScroll:EnableMouse(true)
inputScroll:SetScript("OnMouseDown", function() inputEdit:SetFocus() end)

-- 포커스 시 테두리 색 강조
inputEdit:HookScript("OnEditFocusGained", function()
    if MR.applyBackdrop then
        MR.applyBackdrop(inputBox, MR.BACKDROP_DARK, 0.02, 0.02, 0.04, 1, 1.0, 0.85, 0.30, 1)
    end
end)
inputEdit:HookScript("OnEditFocusLost", function()
    if MR.applyBackdrop then
        MR.applyBackdrop(inputBox, MR.BACKDROP_DARK, 0.02, 0.02, 0.04, 1, 0.55, 0.45, 0.15, 1)
    end
end)

--------------------------------------------------------------------------------
-- 3. 버튼 행: [정리하기] [지우기]
--------------------------------------------------------------------------------
local BTN_ROW_Y = INPUT_TOP - INPUT_H - 8

local parseBtn = createBtn(CP, "정리하기", 90, 24)
parseBtn:SetPoint("TOPLEFT", CP, "TOPLEFT", 8, BTN_ROW_Y)

local clearBtn = createBtn(CP, "지우기", 80, 24)
clearBtn:SetPoint("LEFT", parseBtn, "RIGHT", 8, 0)
clearBtn:SetScript("OnClick", function()
    inputEdit:SetText("")
    inputEdit:ClearFocus()
    CI.parsed  = { date = nil, time = nil, title = nil, description = nil, names = {} }
    CI.results = { successes = {}, failures = {} }
    if MimRaidDB then
        MimRaidDB.calendarInvite = MimRaidDB.calendarInvite or {}
        MimRaidDB.calendarInvite.rawText = ""
    end
    if MR.RefreshCalendarPanel then MR.RefreshCalendarPanel() end
end)

parseBtn:SetScript("OnClick", function()
    local text = inputEdit:GetText() or ""
    CI.rawText = text
    CI.parsed  = parseInput(text)
    CI.results = { successes = {}, failures = {} }

    if MR.RefreshCalendarPanel then MR.RefreshCalendarPanel() end

    local p = CI.parsed
    local n = #p.names
    if MR.Print then
        if n == 0 then
            MR.Print("[달초] 명단이 비어있습니다. 입력란을 확인해주세요.",
                MR.COLOR and MR.COLOR.red or {1,0.4,0.4})
        else
            MR.Print(string.format("[달초] 정리 완료. 인원 %d명", n),
                MR.COLOR and MR.COLOR.green or {0.4,1,0.4})
        end
    end
end)

--------------------------------------------------------------------------------
-- 4. 정리 결과 요약 영역 (인원 카운트만)
--------------------------------------------------------------------------------
local SUMMARY_Y = BTN_ROW_Y - 28

local summaryBox = CreateFrame("Frame", nil, CP, "BackdropTemplate")
summaryBox:SetPoint("TOPLEFT",  CP, "TOPLEFT",   8, SUMMARY_Y)
summaryBox:SetPoint("TOPRIGHT", CP, "TOPRIGHT", -8, SUMMARY_Y)
summaryBox:SetHeight(24)
applyBg(summaryBox, 0.05, 0.05, 0.08, 0.9, 0.28, 0.22, 0.08, 1)

local sumCount = summaryBox:CreateFontString(nil, "OVERLAY")
sumCount:SetFont(FONT, 12)
sumCount:SetTextColor(0.6, 0.9, 0.6)
sumCount:SetPoint("LEFT",  summaryBox, "LEFT",  8, 0)
sumCount:SetPoint("RIGHT", summaryBox, "RIGHT", -8, 0)
sumCount:SetJustifyH("LEFT")
sumCount:SetText("인원: 0명")

CI.sumCount = sumCount

--------------------------------------------------------------------------------
-- 5. 명단 스크롤 + 결과(성공/실패) 영역
--------------------------------------------------------------------------------
local LIST_Y     = SUMMARY_Y - 46   -- summary(24) + 헤더(18) + 여백(4)
local BOTTOM_GAP = 50   -- 하단 [달력 일정 만들기] 버튼 영역
local HEADER_Y   = SUMMARY_Y - 28   -- 헤더 라인 위치

-- 컬럼 헤더 (캐릭터명 / 서버명)
local headerFrame = CreateFrame("Frame", nil, CP)
headerFrame:SetPoint("TOPLEFT",  CP, "TOPLEFT",   8, HEADER_Y)
headerFrame:SetPoint("TOPRIGHT", CP, "TOPRIGHT", -8, HEADER_Y)
headerFrame:SetHeight(18)

local hdrName = headerFrame:CreateFontString(nil, "OVERLAY")
hdrName:SetFont(FONT, 11)
hdrName:SetTextColor(1, 0.82, 0)
hdrName:SetPoint("LEFT", headerFrame, "LEFT", 6 + 30 + 8, 0)   -- idxText 폭 30 + 마진
hdrName:SetText("캐릭터명")

local hdrServer = headerFrame:CreateFontString(nil, "OVERLAY")
hdrServer:SetFont(FONT, 11)
hdrServer:SetTextColor(1, 0.82, 0)
hdrServer:SetPoint("LEFT", headerFrame, "LEFT", 6 + 30 + 8 + 170 + 8, 0)
hdrServer:SetText("서버명")

local listBox = CreateFrame("Frame", nil, CP, "BackdropTemplate")
listBox:SetPoint("TOPLEFT",     CP, "TOPLEFT",      8, LIST_Y)
listBox:SetPoint("BOTTOMRIGHT", CP, "BOTTOMRIGHT", -8, BOTTOM_GAP)
applyBg(listBox, 0.03, 0.03, 0.05, 0.85, 0.28, 0.22, 0.08, 1)

local listScroll = CreateFrame("ScrollFrame", "MimRaidCalendarListScroll", listBox, "UIPanelScrollFrameTemplate")
listScroll:SetPoint("TOPLEFT",     listBox, "TOPLEFT",      6, -6)
listScroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -26, 6)

local listChild = CreateFrame("Frame", nil, listScroll)
listChild:SetSize(1, 1)
listScroll:SetScrollChild(listChild)
CI.listChild = listChild

-- 명단 비어있을 때 안내
local emptyText = listChild:CreateFontString(nil, "OVERLAY")
emptyText:SetFont(FONT, 11)
emptyText:SetTextColor(0.5, 0.5, 0.5)
emptyText:SetPoint("TOPLEFT", listChild, "TOPLEFT", 8, -8)
emptyText:SetText("(명단이 없습니다. 위 입력란에 붙여넣고 [정리하기]를 누르세요)")
CI.emptyText = emptyText

-- listChild 너비를 listScroll 너비에 맞춤 (이래야 행 RIGHT anchor가 제대로 동작)
local function syncListChildWidth()
    local w = listScroll:GetWidth()
    if w and w > 0 then listChild:SetWidth(w) end
end
listScroll:SetScript("OnSizeChanged", function() syncListChildWidth() end)
syncListChildWidth()

-- 한국 와우 서버 목록 (서버 드롭다운에 사용)
local KR_SERVERS = {
    "아즈샤라", "가로나", "굴단", "노르간논", "달라란", "말퓨리온", "세나리우스",
    "줄진", "하이잘", "헬스크림", "데스윙", "듀로탄", "렉사르", "불타는 군단",
    "스톰레이지", "알렉스트라자", "와일드해머", "윈드러너",
}

-- 명단 행 풀 (on-demand 생성, 재사용)
local rowPool = {}
local ROW_H = 28   -- 가독성/터치 위해 키움

-- "이름-서버" 문자열 → 이름, 서버 분리 (첫 - 기준)
local function splitNameServer(full)
    if not full or full == "" then return "", "" end
    local n, s = full:match("^([^%-]+)%-(.+)$")
    if n then return n, s end
    return full, ""
end

-- 같은 공대/파티 멤버일 경우 직업 코드 반환 (예: "MAGE"). 아니면 nil.
-- C_Calendar API가 임의 캐릭터의 직업을 알려주지 않으므로 그룹 멤버 한정.
local function lookupClassFile(name)
    if not name or name == "" then return nil end
    local short = name:match("^([^%-]+)") or name
    local inRaid = IsInRaid and IsInRaid()
    local prefix = inRaid and "raid" or "party"
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    -- UnitName/UnitClass 가 보스 컨텍스트에서 secret-taint 값을 반환할 수 있어 pcall 보호.
    -- taint 된 string 에 :match 직접 호출 시 ADDON_ACTION_FORBIDDEN.
    for i = 1, n do
        local unit = prefix .. i
        local ok, unitName = pcall(UnitName, unit)
        if ok and unitName then
            local ok2, uShort = pcall(function() return unitName:match("^([^%-]+)") or unitName end)
            if ok2 and uShort == short then
                local ok3, classFile = pcall(function() return select(2, UnitClass(unit)) end)
                if ok3 then return classFile end
            end
        end
    end
    -- 본인 (파티/레이드 인덱스에 자기 안 들어가는 케이스 대비)
    local okP, playerName = pcall(UnitName, "player")
    if okP and playerName then
        local okM, myShort = pcall(function() return playerName:match("^([^%-]+)") end)
        if okM and myShort == short then
            local okC, classFile = pcall(function() return select(2, UnitClass("player")) end)
            if okC then return classFile end
        end
    end
    return nil
end

-- 이름 + 서버 → "이름-서버" (서버 없으면 이름만)
local function combineNameServer(name, server)
    name   = (name   or ""):gsub("^%s*(.-)%s*$", "%1")
    server = (server or ""):gsub("^%s*(.-)%s*$", "%1")
    if name == "" then return "" end
    if server == "" then return name end
    return name .. "-" .. server
end

-- 정리된 명단 → 입력란 텍스트 동기화 (행 편집/삭제 시 호출)
local function syncInputFromNames()
    local names = (CI.parsed and CI.parsed.names) or {}
    local text = table.concat(names, ", ")
    inputEdit:SetText(text)
    if MimRaidDB then
        MimRaidDB.calendarInvite = MimRaidDB.calendarInvite or {}
        MimRaidDB.calendarInvite.rawText = text
    end
end

local function getOrCreateRow(i)
    if rowPool[i] then return rowPool[i] end

    local row = CreateFrame("Frame", nil, listChild)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT",  listChild, "TOPLEFT",  0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", listChild, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    -- 행의 빈 영역에서 드래그 → 창 이동 (FontString 위주라 자유롭게 잡힘)
    row:EnableMouse(true)
    if MR._attachDragForward then MR._attachDragForward(row) end

    if i % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
    end

    -- 실패 표시용 빨간 배경 (기본 숨김; 초대 실패 시 보임)
    -- 빨간 텍스트는 죽음의 기사 직업색과 헷갈리므로 배경으로 강조
    local failBg = row:CreateTexture(nil, "BORDER")
    failBg:SetAllPoints()
    failBg:SetColorTexture(0.55, 0.05, 0.05, 0.45)
    failBg:Hide()

    local idxText = row:CreateFontString(nil, "OVERLAY")
    idxText:SetFont(FONT, 11)
    idxText:SetTextColor(0.55, 0.55, 0.55)
    idxText:SetPoint("LEFT", row, "LEFT", 6, 0)
    idxText:SetWidth(30)
    idxText:SetJustifyH("RIGHT")

    -- 삭제 버튼 (X) — 가장 우측, 키움
    local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delBtn:SetSize(28, 22)
    delBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    delBtn:SetText("X")
    if delBtn.GetFontString and delBtn:GetFontString() then
        delBtn:GetFontString():SetFont(FONT, 12)
        delBtn:GetFontString():SetTextColor(1, 0.5, 0.5)
    end
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("이 항목 삭제", 1, 1, 1)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    delBtn:SetScript("OnClick", function(self)
        local idx = self:GetParent()._idx
        if not idx or not CI.parsed or not CI.parsed.names[idx] then return end
        table.remove(CI.parsed.names, idx)
        CI.results = { successes = {}, failures = {} }
        syncInputFromNames()
        if MR.RefreshCalendarPanel then MR.RefreshCalendarPanel() end
    end)

    -- 수정/저장 버튼 (키움)
    local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    editBtn:SetSize(56, 22)
    editBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
    editBtn:SetText("수정")
    if editBtn.GetFontString and editBtn:GetFontString() then
        editBtn:GetFontString():SetFont(FONT, 11)
    end

    -- 상태 텍스트 (성공/실패)
    local statusText = row:CreateFontString(nil, "OVERLAY")
    statusText:SetFont(FONT, 10)
    statusText:SetPoint("RIGHT", editBtn, "LEFT", -8, 0)
    statusText:SetWidth(110)
    statusText:SetJustifyH("RIGHT")
    statusText:SetWordWrap(false)

    -- 이름 표시 FontString (캐릭명, 흰색)
    local nameDisplay = row:CreateFontString(nil, "OVERLAY")
    nameDisplay:SetFont(FONT, 12)
    nameDisplay:SetTextColor(0.9, 0.9, 0.9)
    nameDisplay:SetPoint("LEFT", idxText, "RIGHT", 8, 0)
    nameDisplay:SetWidth(170)
    nameDisplay:SetJustifyH("LEFT")
    nameDisplay:SetWordWrap(false)

    -- 서버 표시 FontString (회색)
    local serverDisplay = row:CreateFontString(nil, "OVERLAY")
    serverDisplay:SetFont(FONT, 11)
    serverDisplay:SetTextColor(0.55, 0.6, 0.7)
    serverDisplay:SetPoint("LEFT", nameDisplay, "RIGHT", 8, 0)
    serverDisplay:SetWidth(130)
    serverDisplay:SetJustifyH("LEFT")
    serverDisplay:SetWordWrap(false)

    -- 편집용 EditBox (캐릭명만, FontString 위 겹침)
    local nameEdit = CreateFrame("EditBox", nil, row)
    nameEdit:SetFont(FONT, 12, "")
    nameEdit:SetTextColor(1, 1, 0.6)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(32)
    nameEdit:SetAllPoints(nameDisplay)
    nameEdit:Hide()

    -- 서버 드롭다운 버튼 (편집 모드에서만 표시, KR 서버 18개 선택)
    local serverDropdown = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    serverDropdown:SetSize(130, 22)
    serverDropdown:SetPoint("LEFT", nameDisplay, "RIGHT", 8, 0)
    serverDropdown:SetText("선택...")
    if serverDropdown.GetFontString and serverDropdown:GetFontString() then
        serverDropdown:GetFontString():SetFont(FONT, 11)
    end
    serverDropdown:Hide()
    serverDropdown:SetScript("OnClick", function(self)
        if not MenuUtil or not MenuUtil.CreateContextMenu then return end
        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            rootDescription:CreateTitle("서버 선택")
            for _, srv in ipairs(KR_SERVERS) do
                rootDescription:CreateButton(srv, function()
                    self:SetText(srv)
                    row._serverValue = srv
                end)
            end
        end)
    end)

    -- 편집 모드 ON/OFF 헬퍼
    local function enterEditMode()
        local idx = row._idx
        if not idx or not CI.parsed or not CI.parsed.names[idx] then return end
        local n, s = splitNameServer(CI.parsed.names[idx])
        nameEdit:SetText(n)
        serverDropdown:SetText(s ~= "" and s or "선택...")
        row._serverValue = s
        nameDisplay:Hide()
        serverDisplay:Hide()
        nameEdit:Show()
        serverDropdown:Show()
        editBtn:SetText("저장")
        nameEdit:SetFocus()
        nameEdit:HighlightText()
        row._editing = true
    end

    local function commitEdit()
        local idx = row._idx
        if not idx or not CI.parsed or not CI.parsed.names then return end
        local serverVal = row._serverValue or ""
        local combined = combineNameServer(nameEdit:GetText(), serverVal)
        if combined == "" then
            table.remove(CI.parsed.names, idx)
        else
            CI.parsed.names[idx] = combined
        end
        CI.results = { successes = {}, failures = {} }
        syncInputFromNames()
        nameEdit:Hide()
        serverDropdown:Hide()
        nameDisplay:Show()
        serverDisplay:Show()
        editBtn:SetText("수정")
        row._editing = false
        if MR.RefreshCalendarPanel then MR.RefreshCalendarPanel() end
    end

    local function cancelEdit()
        nameEdit:Hide()
        serverDropdown:Hide()
        nameDisplay:Show()
        serverDisplay:Show()
        editBtn:SetText("수정")
        row._editing = false
    end

    editBtn:SetScript("OnClick", function()
        if row._editing then commitEdit() else enterEditMode() end
    end)
    nameEdit:SetScript("OnEnterPressed",  function() commitEdit() end)
    nameEdit:SetScript("OnEscapePressed", cancelEdit)

    row.idxText        = idxText
    row.nameDisplay    = nameDisplay
    row.serverDisplay  = serverDisplay
    row.nameEdit       = nameEdit
    row.serverDropdown = serverDropdown
    row.editBtn        = editBtn
    row.statusText     = statusText
    row.delBtn         = delBtn
    row.failBg         = failBg
    rowPool[i] = row
    return row
end
CI._rowPool = rowPool

--------------------------------------------------------------------------------
-- 6. 달력 자동화 로직 (단계 3)
--------------------------------------------------------------------------------
-- 메시지 출력 헬퍼
local function logMsg(msg, color)
    if MR.Print then MR.Print("[달초] " .. msg, color) end
end
local COL = MR.COLOR or {}
local C_RED    = COL.red    or { r = 1.0, g = 0.3, b = 0.3 }
local C_GREEN  = COL.green  or { r = 0.3, g = 1.0, b = 0.3 }
local C_YELLOW = COL.yellow or { r = 1.0, g = 1.0, b = 0.3 }
local C_GRAY   = COL.gray   or { r = 0.7, g = 0.7, b = 0.7 }

-- 1) Blizzard_Calendar UI 로드/표시 보장
local function ensureCalendarReady()
    -- Blizzard_Calendar 애드온 로드
    if Calendar_LoadUI then
        pcall(Calendar_LoadUI)
    elseif LoadAddOn then
        pcall(LoadAddOn, "Blizzard_Calendar")
    elseif C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "Blizzard_Calendar")
    end

    -- 서버 데이터 요청
    if C_Calendar and C_Calendar.OpenCalendar then
        pcall(C_Calendar.OpenCalendar)
    end

    -- 달력 창 표시 (이미 떠있으면 그대로)
    if _G.CalendarFrame and _G.CalendarFrame.IsShown then
        if not _G.CalendarFrame:IsShown() then
            if Calendar_Show then
                pcall(Calendar_Show)
            elseif ToggleCalendar then
                pcall(ToggleCalendar)
            end
        end
    elseif ToggleCalendar then
        pcall(ToggleCalendar)
    end

    return _G.CalendarFrame ~= nil
end

-- 2) 달력 표시 월을 타겟으로 이동 + 새 일정 UI 열기
-- 와우 빌드별로 함수 이름이 달라서 여러 경로를 차례로 시도
local function openNewEventOn(year, month, day)
    if not (C_Calendar and C_DateAndTime) then return false, "Calendar API 없음" end

    local now
    local ok = pcall(function() now = C_DateAndTime.GetCurrentCalendarTime() end)
    if not ok or not now or not now.year or not now.month then
        return false, "현재 달력 시간 조회 실패"
    end

    local nowMonths    = now.year * 12 + (now.month - 1)
    local targetMonths = year * 12 + (month - 1)
    local monthOffset  = targetMonths - nowMonths

    -- 표시 월 이동
    if C_Calendar.SetAbsMonth then
        pcall(C_Calendar.SetAbsMonth, month, year)
    end

    local function logPath(name)
        if MR.Print then
            MR.Print("[달초] 새 일정 열기 경로: " .. name,
                MR.COLOR and MR.COLOR.gray or {0.7,0.7,0.7})
        end
    end

    -- ── 시도 1: C_Calendar.OpenNewEvent (modern API) ──
    if C_Calendar.OpenNewEvent then
        local ok2 = pcall(C_Calendar.OpenNewEvent, monthOffset, day)
        if ok2 then logPath("C_Calendar.OpenNewEvent"); return true end
    end

    -- 빈 이벤트 생성 후, 날짜 바인딩 + UI 표시 (중요: UI 안 띄우면 사용자가 [만들기] 누를 곳이 없음)
    local function bindDateAndShowUI()
        -- 날짜 명시 바인딩
        if C_Calendar.EventSetDate then
            pcall(C_Calendar.EventSetDate, month, day, year)
        end
        -- 일정 만들기 UI 다이얼로그 강제 표시
        if _G.CalendarCreateEventFrame then
            pcall(function() _G.CalendarCreateEventFrame:Show() end)
            if _G.CalendarCreateEventFrame_Update then
                pcall(_G.CalendarCreateEventFrame_Update)
            end
            return _G.CalendarCreateEventFrame:IsShown()
        end
        return false
    end

    -- ── 시도 2: C_Calendar.CreatePlayerEvent + UI 표시 ──
    if C_Calendar.CreatePlayerEvent then
        local ok2 = pcall(C_Calendar.CreatePlayerEvent)
        if ok2 then
            local shown = bindDateAndShowUI()
            logPath("C_Calendar.CreatePlayerEvent" .. (shown and " + UI 표시" or " (UI 미표시)"))
            return true
        end
    end
    if C_Calendar.CreateEvent then
        local ok2 = pcall(C_Calendar.CreateEvent)
        if ok2 then
            local shown = bindDateAndShowUI()
            logPath("C_Calendar.CreateEvent" .. (shown and " + UI 표시" or " (UI 미표시)"))
            return true
        end
    end

    -- ── 시도 3: 달력 UI 의 day button 을 찾아 컨텍스트 트리거 ──
    local cf = _G.CalendarFrame
    if cf then
        local buttons = cf.dayButtons or cf.DayButtons
        if buttons then
            for i = 1, 42 do
                local db = buttons[i]
                if db and db.monthOffset == monthOffset and db.day == day then
                    if _G.CalendarFrame_OpenEvent then
                        local ok2 = pcall(_G.CalendarFrame_OpenEvent, db, nil)
                        if ok2 and _G.CalendarCreateEventFrame and _G.CalendarCreateEventFrame:IsShown() then
                            logPath("CalendarFrame_OpenEvent(dayButton)")
                            return true
                        end
                    end
                    break
                end
            end
        end
    end

    -- ── 시도 4: CalendarCreateEventFrame 직접 표시 ──
    if _G.CalendarCreateEventFrame then
        _G.CalendarCreateEventFrame:Show()
        if _G.CalendarCreateEventFrame_Update then
            pcall(_G.CalendarCreateEventFrame_Update)
        end
        if _G.CalendarCreateEventFrame:IsShown() then
            logPath("CalendarCreateEventFrame:Show() 직접")
            return true
        end
    end

    return false, "달력 새 일정 함수를 찾을 수 없음 (이 빌드에서는 자동화 불가)"
end

-- 3) 일정 메타데이터 채우기 (제목/시간/설명)
-- API 우선, 안 되면 UI 위젯 직접 조작 fallback
local function fillEventMeta(eventTitle, hour24, minute, description)
    local diag = {}

    -- ── 제목 ──────────────────────────────────────────────────────────
    if eventTitle and eventTitle ~= "" then
        local apiOK = false
        if C_Calendar and C_Calendar.EventSetTitle then
            local ok = pcall(C_Calendar.EventSetTitle, eventTitle)
            if ok then apiOK = true end
        end
        -- UI fallback: 제목 EditBox 에 직접 SetText
        local titleEdit = _G.CalendarCreateEventTitleEdit
        if titleEdit and titleEdit.SetText then
            pcall(function() titleEdit:SetText(eventTitle) end)
            -- 포커스 변경 이벤트로 내부 상태 갱신 유도
            if titleEdit.GetScript and titleEdit:GetScript("OnTextChanged") then
                pcall(titleEdit:GetScript("OnTextChanged"), titleEdit)
            end
            table.insert(diag, "Title:UI" .. (apiOK and "+API" or ""))
        elseif apiOK then
            table.insert(diag, "Title:API")
        else
            table.insert(diag, "Title:✗")
        end
    end

    -- ── 시간 ──────────────────────────────────────────────────────────
    -- 주의: EventSetTime API 호출은 UI dropdown 과 내부 데이터를 desync 시켜
    -- 사용자가 dropdown 클릭 시 GameTime_ComputeMilitaryTime nil 오류 유발.
    -- → 시간은 자동 설정하지 않고, 사용자에게 다이얼로그에서 직접 입력하도록 안내.
    if hour24 and minute then
        table.insert(diag, string.format("Time:수동(%02d:%02d)", hour24, minute))
    end

    -- ── 설명 ──────────────────────────────────────────────────────────
    if description and description ~= "" then
        local apiOK = false
        if C_Calendar and C_Calendar.EventSetDescription then
            local ok = pcall(C_Calendar.EventSetDescription, description)
            if ok then apiOK = true end
        end
        local descBoxEdit = _G.CalendarCreateEventDescriptionEdit
                         or _G.CalendarCreateEventDescriptionContainer
                         and _G.CalendarCreateEventDescriptionContainer.EditBox
        if descBoxEdit and descBoxEdit.SetText then
            pcall(function() descBoxEdit:SetText(description) end)
            if descBoxEdit.GetScript and descBoxEdit:GetScript("OnTextChanged") then
                pcall(descBoxEdit:GetScript("OnTextChanged"), descBoxEdit)
            end
            table.insert(diag, "Desc:UI" .. (apiOK and "+API" or ""))
        elseif apiOK then
            table.insert(diag, "Desc:API")
        else
            table.insert(diag, "Desc:✗")
        end
    end

    -- 전체 UI 새로고침
    if _G.CalendarCreateEventFrame_Update then
        pcall(_G.CalendarCreateEventFrame_Update)
    end

    -- 진단 로그
    if MR.Print and #diag > 0 then
        MR.Print("[달초] 메타 적용: " .. table.concat(diag, ", "),
            MR.COLOR and MR.COLOR.gray or {0.7,0.7,0.7})
    end
end

-- 4) 명단 일괄 초대
-- 와우 서버의 invite rate limit 회피용 2초 간격 throttle.
-- "이미 초대된 사람" (와우 달력에서 수동 추가/이전 호출/organizer 자동포함) 은 EventInvite 호출
-- 자체를 스킵해 2초 wait 도 안 함 (rate limit 무관). 매 step 직전에 invitees 새로 스캔하므로
-- 와우 달력 UI 에서 수동 추가/삭제도 즉시 반영. 성공/실패는 checkResults 가 실제 invitee 명단
-- 기준으로 판정하므로 스킵된 사람도 자동 성공 처리됨.
local INVITE_INTERVAL = 2.0  -- 실측 안정값 (1.0s/1.5s 절반 실패, 2.0s 전부 성공)
local function inviteAll(names, onComplete)
    if not (C_Calendar and C_Calendar.EventInvite) then
        if onComplete then onComplete(false, "EventInvite 함수 없음") end
        return
    end
    local total = #names
    local i = 1
    local invitedCount = 0   -- 실제 EventInvite 호출 횟수
    local skippedCount = 0   -- 이미 초대돼있어서 스킵된 횟수

    -- 현재 이벤트의 초대 명단을 set 으로 반환. 모든 API 호출 pcall 보호 (안전 최우선).
    -- WoW 환경에 따라 same-realm 사람이 짧은이름/풀네임 어느 쪽으로 오는지 다를 수 있어
    -- set 에 양쪽 다 등록 (입력도 양쪽 다 체크).
    local function refreshAlreadyInvited()
        local set = {}
        if not (C_Calendar and C_Calendar.GetNumInvites) then return set end
        local n = 0
        local ok = pcall(function() n = C_Calendar.GetNumInvites() or 0 end)
        if not ok or type(n) ~= "number" or n <= 0 then return set end
        for j = 1, n do
            local info
            local okI = pcall(function() info = C_Calendar.EventGetInvite(j) end)
            if okI and info and info.name then
                set[info.name] = true
                local okM, short = pcall(function() return info.name:match("^([^%-]+)") end)
                if okM and short and short ~= "" then set[short] = true end
            end
        end
        return set
    end

    local function step()
        -- while + return 패턴: 스킵 연속 처리 시 재귀 회피 (스택 안전)
        while i <= total do
            local name = names[i]
            if not name or name == "" then
                -- 빈 이름 방어 → 다음
                i = i + 1
            else
                local short
                pcall(function() short = name:match("^([^%-]+)") end)

                local already = refreshAlreadyInvited()
                if already[name] or (short and already[short]) then
                    -- 이미 초대됨 → 즉시 스킵 (2초 wait 없음, EventInvite 호출 없음 → rate limit 무관)
                    skippedCount = skippedCount + 1
                    if CI.sumCount then
                        CI.sumCount:SetText(string.format(
                            "초대 진행 중: %d/%d (신규 %d / 스킵 %d)",
                            i, total, invitedCount, skippedCount))
                    end
                    i = i + 1
                    -- loop 계속 → 다음 이름 즉시 검사
                else
                    -- 신규 초대 → EventInvite + 2초 wait
                    pcall(C_Calendar.EventInvite, name)
                    invitedCount = invitedCount + 1

                    if CI.sumCount then
                        CI.sumCount:SetText(string.format(
                            "초대 진행 중: %d/%d (신규 %d / 스킵 %d)",
                            i, total, invitedCount, skippedCount))
                    end
                    if (i % 5 == 0 or i == total) and MR.Print then
                        MR.Print(string.format(
                            "[달초] 진행 중... %d/%d (신규 %d / 스킵 %d)",
                            i, total, invitedCount, skippedCount),
                            MR.COLOR and MR.COLOR.gray or {0.7,0.7,0.7})
                    end

                    i = i + 1
                    C_Timer.After(INVITE_INTERVAL, step)
                    return   -- 다음 step 은 timer 콜백에서 진입
                end
            end
        end

        -- 종료: 모든 이름 처리 완료
        if MR.Print then
            MR.Print(string.format(
                "[달초] 완료: 신규 초대 %d명 / 스킵 %d명 (이미 초대됨)",
                invitedCount, skippedCount),
                MR.COLOR and MR.COLOR.gold or {1, 0.82, 0})
        end
        if onComplete then onComplete(true) end
    end
    step()
end

-- 5) 결과 검증: 실제 등록된 명단을 읽어 요청 명단과 비교
local function checkResults(requested)
    local actual = {}
    if C_Calendar and C_Calendar.GetNumInvites then
        local n = 0
        pcall(function() n = C_Calendar.GetNumInvites() or 0 end)
        for i = 1, n do
            local info
            pcall(function() info = C_Calendar.EventGetInvite(i) end)
            if info and info.name then
                actual[info.name] = true
                -- 서버명 없는 형태도 매칭에 도움이 되도록 양쪽 키 등록
                local short = info.name:match("^([^%-]+)")
                if short then actual[short] = true end
            end
        end
    end

    local successes, failures = {}, {}
    for _, name in ipairs(requested) do
        local short = name:match("^([^%-]+)")
        if actual[name] or (short and actual[short]) then
            table.insert(successes, name)
        else
            table.insert(failures, { name = name, reason = "이름/서버 확인" })
        end
    end
    return successes, failures
end

CI._ensureCalendarReady = ensureCalendarReady   -- 디버그용 노출
CI._openNewEventOn      = openNewEventOn
CI._inviteAll           = inviteAll
CI._checkResults        = checkResults

--------------------------------------------------------------------------------
-- 6-2. 하단: [달력 일정 만들기] 버튼
--------------------------------------------------------------------------------
local createBtnBig = createBtn(CP, "달력에 공격대원 추가하기", 220, 30)
createBtnBig:SetPoint("BOTTOMRIGHT", CP, "BOTTOMRIGHT", -8, 8)
if createBtnBig.GetFontString and createBtnBig:GetFontString() then
    createBtnBig:GetFontString():SetFont(FONT, 13)
    createBtnBig:GetFontString():SetTextColor(1, 0.95, 0.5)
end

local function runAutoInvite()
    local p = CI.parsed
    if not p or not p.names or #p.names == 0 then
        logMsg("명단이 비어있습니다. 먼저 [정리하기] 버튼을 눌러주세요.", C_RED)
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        logMsg("전투 중에는 사용할 수 없습니다. 전투 종료 후 다시 시도해주세요.", C_RED)
        return
    end

    -- 사용자가 와우 달력에서 직접 [새 일정 만들기] 다이얼로그를 연 상태여야 함
    -- (날짜/시간/제목/설명은 사용자가 직접 입력. 우리는 명단만 넣음)
    local createFrame = _G.CalendarCreateEventFrame
    if not (createFrame and createFrame:IsShown()) then
        logMsg("와우 달력의 [새 일정 만들기] 창을 먼저 열어주세요. (달력 > 우클릭 > 일정만들기)",
            C_RED)
        return
    end

    -- 명단만 추가 + 결과 검증
    logMsg(string.format("초대 진행 중... (%d명)", #p.names), C_GRAY)
    inviteAll(p.names, function()
        C_Timer.After(1.0, function()
            local s, f = checkResults(p.names)
            CI.results.successes = s
            CI.results.failures  = f
            if MR.RefreshCalendarPanel then MR.RefreshCalendarPanel() end

            local color = (#f == 0) and C_GREEN or C_YELLOW
            logMsg(string.format(
                "자동 입력 완료. 성공 %d명 / 실패 %d명. 다이얼로그에서 [만들기] 버튼을 눌러주세요.",
                #s, #f), color)
        end)
    end)
end

createBtnBig:SetScript("OnClick", runAutoInvite)
CI._runAutoInvite = runAutoInvite

-- (이전 버전의 하단 힌트는 +/- 폰트 버튼과 겹쳐서 상단 desc 로 이전됨)

--------------------------------------------------------------------------------
-- 7. 패널 새로고침 (다음 단계에서 명단/결과 표시 채울 예정)
--------------------------------------------------------------------------------
function MR.RefreshCalendarPanel()
    local p = CI.parsed or {}
    local r = CI.results or { successes = {}, failures = {} }
    local n = (p.names and #p.names) or 0

    -- 인원 텍스트: 결과(성공/실패) 정보가 있으면 같이 표시
    local nSucc = (r.successes and #r.successes) or 0
    local nFail = (r.failures  and #r.failures)  or 0
    if nSucc > 0 or nFail > 0 then
        sumCount:SetText(string.format(
            "인원: %d명  (|cff66ff66성공 %d|r / |cffff6666실패 %d|r)",
            n, nSucc, nFail))
    else
        sumCount:SetText(string.format("인원: %d명", n))
    end

    if n == 0 then
        emptyText:Show()
    else
        emptyText:Hide()
    end

    -- 명단 행 갱신 (단계 3에서 statusText 에 ✓/✗ 채워질 예정)
    -- 실패자(이름→사유) 빠른 조회용 맵
    local failMap = {}
    if r.failures then
        for _, f in ipairs(r.failures) do failMap[f.name] = f.reason or "실패" end
    end
    local succSet = {}
    if r.successes then
        for _, name in ipairs(r.successes) do succSet[name] = true end
    end

    local maxRows = math.max(n, #rowPool)
    for i = 1, maxRows do
        local nm = (i <= n) and p.names[i] or nil
        if nm then
            local row = getOrCreateRow(i)
            row._idx = i
            row.idxText:SetText(tostring(i))

            -- 이름/서버 분리 표시
            local nmStr, srvStr = splitNameServer(nm)
            if not row._editing then
                row.nameDisplay:SetText(nmStr)
                row.serverDisplay:SetText(srvStr ~= "" and srvStr or "")
                -- 편집 모드 아닐 때만 동기화 (편집 중이면 사용자 입력 보존)
                row.nameEdit:SetText(nmStr)
                row.serverDropdown:SetText(srvStr ~= "" and srvStr or "선택...")
                row._serverValue = srvStr
            end

            -- 직업 색상 적용 (그룹 멤버일 때만)
            local classFile = lookupClassFile(nm)
            local classColor = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
            local defaultR, defaultG, defaultB = 0.9, 0.9, 0.9

            -- 실패 / 성공 / 기본 상태별 표시
            if failMap[nm] then
                -- 실패: 빨간 배경 (글자는 직업색 유지, 빨간 텍스트는 DK 직업색과 헷갈리므로 안 씀)
                row.failBg:Show()
                if classColor then
                    row.nameDisplay:SetTextColor(classColor.r, classColor.g, classColor.b)
                else
                    row.nameDisplay:SetTextColor(defaultR, defaultG, defaultB)
                end
                row.serverDisplay:SetTextColor(0.7, 0.7, 0.75)
                row.statusText:SetTextColor(1, 0.85, 0.85)
                row.statusText:SetText(failMap[nm])
            elseif succSet[nm] then
                row.failBg:Hide()
                if classColor then
                    row.nameDisplay:SetTextColor(classColor.r, classColor.g, classColor.b)
                else
                    row.nameDisplay:SetTextColor(0.7, 1.0, 0.7)
                end
                row.serverDisplay:SetTextColor(0.55, 0.6, 0.7)
                row.statusText:SetTextColor(0.55, 0.85, 0.55)
                row.statusText:SetText("성공")
            else
                row.failBg:Hide()
                if classColor then
                    row.nameDisplay:SetTextColor(classColor.r, classColor.g, classColor.b)
                else
                    row.nameDisplay:SetTextColor(defaultR, defaultG, defaultB)
                end
                row.serverDisplay:SetTextColor(0.55, 0.6, 0.7)
                row.statusText:SetText("")
            end
            row:Show()
        else
            local row = rowPool[i]
            if row then
                row._idx = nil
                row:Hide()
            end
        end
    end

    listChild:SetHeight(math.max(n * ROW_H, 1))
    syncListChildWidth()
end

MR.RefreshCalendarPanel()
