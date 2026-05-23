--------------------------------------------------------------------------------
-- MimRaid - AuctionFrame.lua
-- 메인 UI 프레임: 연속경매진행 | 판매완료 | 안팔린 아이템 | 정산  (가로 탭)
--------------------------------------------------------------------------------

---@diagnostic disable: undefined-global

local MR = MimRaid

local FRAME_W   = 680  -- 달력 초대 탭 추가로 우측 영역 확장 (구 600 → 680)
local FRAME_H   = 600
local ROW_H     = 48
local MAX_ROWS  = 50    -- 아이템 목록 최대 표시 행 수 (scrollFrame 내 미리 생성되는 행 프레임 수)
local FONT      = "Fonts\\2002.TTF"
local GOLD_CLR  = { r = 1,   g = 0.82, b = 0   }
local GRAY_CLR  = { r = 0.6, g = 0.6,  b = 0.6 }

--------------------------------------------------------------------------------
-- 헬퍼
--------------------------------------------------------------------------------
local function applyBackdrop(frame, info, r, g, b, a, br, bg, bb, ba)
    frame:SetBackdrop(info)
    frame:SetBackdropColor(r or 0, g or 0, b or 0, a or 0.85)
    frame:SetBackdropBorderColor(br or 0.35, bg or 0.35, bb or 0.35, ba or 1)
end
MR.applyBackdrop = applyBackdrop  -- 다른 파일에서도 동일 헬퍼 사용 가능

local function createDivider(parent, yOffset)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    t:SetHeight(1)
    t:SetPoint("TOPLEFT",  parent, "TOPLEFT",  6, yOffset)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, yOffset)
    return t
end

local function createBtn(name, parent, text, w, h)
    local btn = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    btn:SetSize(w or 80, h or 22)
    if btn.SetText then btn:SetText(text) end
    if btn.GetFontString then
        local fs = btn:GetFontString()
        if fs then fs:SetFont(FONT, 12) end
    end
    return btn
end

--------------------------------------------------------------------------------
-- 메인 프레임
--------------------------------------------------------------------------------
local mainFrame = CreateFrame("Frame", "MimRaidMainFrame", UIParent, "BackdropTemplate")
mainFrame:SetSize(FRAME_W, FRAME_H)
mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
mainFrame:SetFrameStrata("HIGH")   -- 액션바/전투 UI보다 위에 그리기
mainFrame:SetMovable(true)
mainFrame:EnableMouse(true)
mainFrame:SetClampedToScreen(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
mainFrame:SetScript("OnDragStop",  function(self)
    self:StopMovingOrSizing()
    MR.AuctionFrame.SavePosition()
end)
mainFrame:Hide()

-- 자식 프레임의 빈 영역에서 드래그해도 mainFrame 이동되도록 위임
-- (행/드랍존 등 EnableMouse(true) 영역은 드래그를 캡처해서 부모로 전파되지 않음)
local function attachDragForward(frame)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() mainFrame:StartMoving() end)
    frame:SetScript("OnDragStop",  function()
        mainFrame:StopMovingOrSizing()
        MR.AuctionFrame.SavePosition()
    end)
end
MR._attachDragForward = attachDragForward  -- 다른 파일(TradeLogFrame 등)에서도 사용

applyBackdrop(mainFrame, MR.BACKDROP, 0.05, 0.05, 0.08, 0.95, 0.4, 0.35, 0.1, 1)

-- ESC로 닫기
table.insert(UISpecialFrames, "MimRaidMainFrame")

--------------------------------------------------------------------------------
-- 타이틀 바
--------------------------------------------------------------------------------
local TITLE_BAR_H = 58
local titleBar = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
titleBar:SetHeight(TITLE_BAR_H)
titleBar:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  0, 0)
titleBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
applyBackdrop(titleBar, MR.BACKDROP_DARK, 0.1, 0.08, 0.02, 0.98, 0.5, 0.4, 0.1, 1)

-- 로고 아이콘
local titleLogo = titleBar:CreateTexture(nil, "OVERLAY")
titleLogo:SetSize(48, 48)
titleLogo:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
titleLogo:SetTexture("Interface\\AddOns\\MimRaid\\img\\mim_logo.png")
titleLogo:SetTexCoord(0.05, 0.95, 0.05, 0.95)

local titleText = titleBar:CreateFontString(nil, "OVERLAY")
titleText:SetFont(FONT, 13)
titleText:SetTextColor(GOLD_CLR.r, GOLD_CLR.g, GOLD_CLR.b)
titleText:SetPoint("TOPLEFT", titleLogo, "TOPRIGHT", 4, 0)
titleText:SetText("MimRaid  v" .. MR.VERSION)

-- 1행 가운데: 시작 던전 이름 (RaidTimer 시작 시점 캐시값, 고정 표시).
-- 첫 던전부터 누적 타이머 시작점 확인 용도 — 레이드 1번에 여러 던전 공략할 때 어디서부터 시간 흘렀는지.
-- 타이틀(MimRaid vX.X.X) 우측 ~ 출발시간 좌측 사이 영역에 가운데 정렬.
local startInstanceLine = titleBar:CreateFontString(nil, "OVERLAY")
startInstanceLine:SetFont(FONT, 11)
startInstanceLine:SetPoint("TOPLEFT", titleText, "TOPRIGHT", 16, 0)
startInstanceLine:SetWidth(220)
startInstanceLine:SetJustifyH("RIGHT")
startInstanceLine:SetTextColor(1.0, 0.82, 0.0)   -- 골드 톤
startInstanceLine:SetText("")

-- 1행 우측: 출발 시간 (시작던전 우측부터 닫기 버튼 좌측까지, 우측 정렬)
local startLine = titleBar:CreateFontString(nil, "OVERLAY")
startLine:SetFont(FONT, 11)
startLine:SetPoint("TOPLEFT",  startInstanceLine, "TOPRIGHT",  8, 0)
startLine:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -28, -7)
startLine:SetJustifyH("RIGHT")
startLine:SetText("")

-- 2행: 경과 시간 — 우측 고정, 고정 폭으로 버튼과 세로 중앙 정렬
-- RIGHT 앵커(세로 중앙) + SetWidth 로 텍스트 박스 크기 고정
local elapsedLine = titleBar:CreateFontString(nil, "OVERLAY")
elapsedLine:SetFont(FONT, 13)
elapsedLine:SetPoint("RIGHT", titleBar, "RIGHT", -28, -11)
elapsedLine:SetWidth(220)   -- 고정 폭: 경과시간 숫자 변동에 따른 좌측 흔들림 방지 (리셋버튼 위치 고정)
elapsedLine:SetJustifyH("LEFT")
elapsedLine:SetText("")

-- 2행: 시간리셋 버튼 — elapsedLine 바로 좌측에 세로 중앙 정렬
local timerResetBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
timerResetBtn:SetSize(72, 24)
timerResetBtn:SetPoint("RIGHT", elapsedLine, "LEFT", -8, 0)
timerResetBtn:SetText("시간리셋")
do
    local fs = timerResetBtn:GetFontString()
    if fs then fs:SetFont(FONT, 11) end
end
timerResetBtn:Hide()
timerResetBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("레이드 타이머 초기화", 1, 1, 1)
    GameTooltip:Show()
end)
timerResetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
StaticPopupDialogs["MIMRAID_TIMER_RESET_CONFIRM"] = {
    text      = "레이드 타이머를 초기화합니다.\n\n출발 시각과 경과 시간이 모두 사라집니다.\n계속하시겠습니까?",
    button1   = "초기화",
    button2   = "취소",
    OnAccept  = function()
        if MR.RaidTimer and MR.RaidTimer.Reset then
            MR.RaidTimer.Reset()
            startLine:SetText("")
            startInstanceLine:SetText("")
            elapsedLine:SetText("")
            timerResetBtn:Hide()
            MR.Print("레이드 타이머 초기화", MR.COLOR.gray)
        end
    end,
    timeout   = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
timerResetBtn:SetScript("OnClick", function()
    StaticPopup_Show("MIMRAID_TIMER_RESET_CONFIRM")
end)

-- 2행: 던전/레이드 이름 + (M+ 활성시) 단수 — elapsedLine/리셋버튼 좌측 영역, 가운데 정렬
-- 형식: "사론의 구덩이 +14 단"  (M+) / "맨소러스의 권능"  (레이드/일반 던전)
-- 인스턴스 밖이면 마지막 텍스트 그대로 유지
local mplusLine = titleBar:CreateFontString(nil, "OVERLAY")
mplusLine:SetFont(FONT, 13)
mplusLine:SetPoint("LEFT",  titleBar, "LEFT", 56, -11)
mplusLine:SetPoint("RIGHT", timerResetBtn, "LEFT", -8, 0)
mplusLine:SetJustifyH("CENTER")
mplusLine:SetTextColor(1.0, 0.82, 0.0)   -- 골드 톤
mplusLine:SetText("")

local function _mplusUpdate()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then
        return  -- 인스턴스 밖에서는 마지막 진입 던전명 유지 (지우지 않음)
    end
    if instanceType ~= "raid" and instanceType ~= "party" and instanceType ~= "scenario" then
        return  -- pvp/arena 등은 무관
    end
    local name = GetInstanceInfo()
    if not name or name == "" then return end
    local level
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        level = C_ChallengeMode.GetActiveKeystoneInfo()
    end
    -- 단수는 5인(M+)에서만 부착. 레이드는 이름만.
    if instanceType == "party" and level and level > 0 then
        mplusLine:SetText(string.format("[현재 던전] %s +%d 단", name, level))
    else
        mplusLine:SetText("[현재 던전] " .. name)
    end
end

-- 외부(슬래시 커맨드 등)에서 길이 시뮬레이션용으로 접근 — /mr mplustest 참고
MR._mplusLine = mplusLine

local _mplusFrame = CreateFrame("Frame")
_mplusFrame:RegisterEvent("CHALLENGE_MODE_START")
_mplusFrame:RegisterEvent("CHALLENGE_MODE_RESET")
_mplusFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
_mplusFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
_mplusFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
_mplusFrame:SetScript("OnEvent", function(_, event)
    if event == "CHALLENGE_MODE_RESET" or event == "CHALLENGE_MODE_COMPLETED" then
        -- 리셋/완료 직후엔 API 가 잠시 stale 할 수 있어 짧은 지연 후 재확인
        C_Timer.After(0.5, _mplusUpdate)
    end
    _mplusUpdate()
end)

local _timerAcc = 0
local WEEKDAY_KR = { "일", "월", "화", "수", "목", "금", "토" }

titleBar:SetScript("OnUpdate", function(_, elapsed)
    _timerAcc = _timerAcc + elapsed
    if _timerAcc < 1 then return end
    _timerAcc = 0
    local t = MR.RaidTimer and MR.RaidTimer.GetElapsed and MR.RaidTimer.GetElapsed()
    if not t then
        startLine:SetText("|cff444444출발 시간 :  - - -|r")
        startInstanceLine:SetText("")
        elapsedLine:SetText("|cff444444경과 :  - - -|r")
        timerResetBtn:Hide()
        return
    end
    -- 시작 던전 이름 (RaidTimer 시작 시점에 GetInstanceInfo 로 캐시된 값)
    local startInstance = MR.RaidTimer.GetInstanceName and MR.RaidTimer.GetInstanceName()
    startInstanceLine:SetText(startInstance or "")
    -- 출발 시간: YYYY년 MM월 DD일(요일) HH시 MM분 SS초
    local startT = MR.RaidTimer.GetStartTime and MR.RaidTimer.GetStartTime()
    if startT then
        local d = date("*t", startT)
        -- 명시적 2줄 (1줄: 날짜+요일 / 2줄: 시간) — 폭에 따른 wrap 흔들림 방지
        startLine:SetText(string.format(
            "출발 시간 :  %04d년 %02d월 %02d일(%s)\n%02d시 %02d분 %02d초",
            d.year, d.month, d.day, WEEKDAY_KR[d.wday] or "?", d.hour, d.min, d.sec))
    else
        startLine:SetText("")
    end
    -- 경과 시간: (DD일) HH시간 MM분 SS초
    local totalSec  = math.floor(t)
    local s         = totalSec % 60
    local totalMin  = math.floor(totalSec / 60)
    local m         = totalMin % 60
    local totalHour = math.floor(totalMin / 60)
    local h         = totalHour % 24
    local days      = math.floor(totalHour / 24)
    local elapsedStr
    if days > 0 then
        elapsedStr = string.format(
            "경과 :  %d일  %02d시간 %02d분 %02d초", days, h, m, s)
    else
        elapsedStr = string.format(
            "경과 :  %02d시간 %02d분 %02d초", h, m, s)
    end
    if MR.RaidTimer.frozenElapsed then
        elapsedLine:SetTextColor(0.6, 0.6, 0.6)
        startLine:SetTextColor(0.6, 0.6, 0.6)
    else
        elapsedLine:SetTextColor(0.4, 1, 0.4)
        startLine:SetTextColor(0.85, 0.85, 0.85)
    end
    elapsedLine:SetText(elapsedStr)
    timerResetBtn:Show()
end)

-- 닫기 버튼
local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
closeBtn:SetSize(22, 22)
closeBtn:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -2, -4)
closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

createDivider(mainFrame, -TITLE_BAR_H)


--------------------------------------------------------------------------------
-- 가로 탭 바  경매 | 판매완료 | 안팔린 아이템 | 정산
-- 활성 탭: 금색 테두리 + 금색 텍스트 + 하단 인디케이터 바
-- 비활성 탭: 어두운 배경 + 회색 텍스트, 호버 시 약간 밝아짐
--------------------------------------------------------------------------------
local TAB_BAR_H = 32

-- 일시정지 상태 배너 (보스 전투중 / 공대장 로딩 시 표시)
-- 탭 바 위에 떠다니는 빨간 띠. 일시정지 사유 변할 때마다 MR.UpdateStatusBanner() 호출됨.
local statusBanner = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
statusBanner:SetHeight(20)
statusBanner:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  0, -TITLE_BAR_H)
statusBanner:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -TITLE_BAR_H)
statusBanner:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
applyBackdrop(statusBanner, MR.BACKDROP_DARK, 0.30, 0.05, 0.05, 0.95, 1, 0.4, 0.4, 1)
statusBanner:Hide()

local statusBannerText = statusBanner:CreateFontString(nil, "OVERLAY")
statusBannerText:SetFont(FONT, 12, "OUTLINE")
statusBannerText:SetTextColor(1, 0.85, 0.85)
statusBannerText:SetPoint("CENTER", statusBanner, "CENTER", 0, 0)
statusBannerText:SetText("")

-- 외부(Auction.lua)에서 호출 → 일시정지 사유에 맞는 배너 표시/숨김
function MR.UpdateStatusBanner()
    local reason = MR.Auction and MR.Auction.GetPauseReason and MR.Auction.GetPauseReason()
    if reason == "encounter" then
        statusBannerText:SetText("ㅡ 보스 전투중 대기 ㅡ")
        statusBanner:Show()
    elseif reason == "loading" then
        statusBannerText:SetText("ㅡ 공대장 로딩 대기 ㅡ")
        statusBanner:Show()
    else
        statusBanner:Hide()
    end
end

-- 탭 바 전체 배경
local tabBar = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
tabBar:SetHeight(TAB_BAR_H)
tabBar:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  0, -TITLE_BAR_H)
tabBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -TITLE_BAR_H)
applyBackdrop(tabBar, MR.BACKDROP_DARK, 0.04, 0.04, 0.06, 1, 0.28, 0.22, 0.06, 1)

-- 색상 상수
local ACT_BG    = { 0.14, 0.11, 0.03 }
local ACT_BD    = { 0.85, 0.70, 0.15 }
local INACT_BG  = { 0.05, 0.04, 0.07 }
local INACT_BD  = { 0.22, 0.20, 0.12 }
local INACT_TXT = { 0.55, 0.50, 0.35 }

-- 흐름 탭 목록 (균등 배분 대상)
local allTabs = {}

-- 우측 고정 탭 폭 / 흐름탭-우측탭 사이 빈 공간
local HIST_W    = 80
local OPT_W     = 46
local CAL_W     = 70   -- 달력 초대 탭 폭
local ARROW_W   = 18   -- 흐름 탭 사이 화살표 구분자 폭
local FLOW_GAP  = 80   -- 흐름 탭 끝과 우측 탭 사이 시각적 여백

-- 흐름 탭 사이 화살표 구분자 (클릭 불가 FontString)
local flowArrows = {}

-- 탭 너비/위치 재계산
-- 좌측 흐름 탭: (totalW - HIST_W - OPT_W - CAL_W - FLOW_GAP) 균등 배분
-- 우측 고정 탭(좌→우): 기록 / 옵션 / 달력 초대
--   tabCalendar 가장 우측 → 그 좌측 tabOptions → 그 좌측 tabHistory
local tabHistory, tabOptions, tabCalendar  -- 전방 선언 (makeTab 이후 실제 할당)
local function updateTabLayout()
    local totalW = tabBar:GetWidth()
    if not totalW or totalW <= 0 then return end

    -- 우측 탭 고정 배치 (오른쪽 끝부터: 달력 → 옵션 → 기록)
    if tabCalendar then
        tabCalendar:ClearAllPoints()
        tabCalendar:SetWidth(CAL_W)
        tabCalendar:SetPoint("TOPRIGHT", tabBar, "TOPRIGHT", 0, 0)
    end
    if tabOptions then
        tabOptions:ClearAllPoints()
        tabOptions:SetWidth(OPT_W)
        tabOptions:SetPoint("TOPRIGHT", tabBar, "TOPRIGHT", -CAL_W, 0)
    end
    if tabHistory then
        tabHistory:ClearAllPoints()
        tabHistory:SetWidth(HIST_W)
        tabHistory:SetPoint("TOPRIGHT", tabBar, "TOPRIGHT", -CAL_W - OPT_W, 0)
    end

    -- 좌측 흐름 탭 배치 (탭 사이 화살표 포함)
    local n = #allTabs
    if n == 0 then return end
    local arrowTotalW = math.max(0, n - 1) * ARROW_W
    local flowW = totalW - HIST_W - OPT_W - CAL_W - FLOW_GAP
    local tabW  = math.floor((flowW - arrowTotalW) / n)
    local x = 0
    for i, tab in ipairs(allTabs) do
        tab:ClearAllPoints()
        local w = (i == n) and (flowW - x) or tabW
        tab:SetPoint("TOPLEFT", tabBar, "TOPLEFT", x, 0)
        tab:SetWidth(w)
        x = x + w
        if i < n and flowArrows[i] then
            flowArrows[i]:ClearAllPoints()
            flowArrows[i]:SetPoint("TOPLEFT", tabBar, "TOPLEFT", x, -1)
            flowArrows[i]:SetSize(ARROW_W, TAB_BAR_H - 2)
            x = x + ARROW_W
        end
    end
end

-- 탭 생성 헬퍼 (addToFlow=false 이면 균등 배분 제외)
local function makeTab(label, fontSize, addToFlow)
    local tab = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
    tab:SetHeight(TAB_BAR_H)
    tab:SetWidth(1)   -- 임시값, updateTabLayout에서 확정
    tab:SetPoint("TOPLEFT", tabBar, "TOPLEFT", 0, 0)
    tab:EnableMouse(true)
    applyBackdrop(tab, MR.BACKDROP_DARK,
        INACT_BG[1], INACT_BG[2], INACT_BG[3], 1,
        INACT_BD[1], INACT_BD[2], INACT_BD[3], 1)

    local fs = tab:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, fontSize or 11)
    fs:SetTextColor(INACT_TXT[1], INACT_TXT[2], INACT_TXT[3])
    fs:SetPoint("CENTER", tab, "CENTER", 0, 1)
    fs:SetText(label)
    tab._label = fs

    -- 활성 탭 하단 금색 인디케이터 바
    local bar = tab:CreateTexture(nil, "OVERLAY")
    bar:SetColorTexture(ACT_BD[1], ACT_BD[2], ACT_BD[3], 1)
    bar:SetHeight(2)
    bar:SetPoint("BOTTOMLEFT",  tab, "BOTTOMLEFT",  1, 0)
    bar:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -1, 0)
    bar:Hide()
    tab._bar = bar

    tab._active = false
    if addToFlow ~= false then table.insert(allTabs, tab) end

    tab:SetScript("OnEnter", function(self)
        if not self._active then
            applyBackdrop(self, MR.BACKDROP_DARK, 0.09, 0.07, 0.11, 1, 0.32, 0.28, 0.16, 1)
            self._label:SetTextColor(0.80, 0.74, 0.50)
        end
    end)
    tab:SetScript("OnLeave", function(self)
        if not self._active then
            applyBackdrop(self, MR.BACKDROP_DARK,
                INACT_BG[1], INACT_BG[2], INACT_BG[3], 1,
                INACT_BD[1], INACT_BD[2], INACT_BD[3], 1)
            self._label:SetTextColor(INACT_TXT[1], INACT_TXT[2], INACT_TXT[3])
        end
    end)
    -- 탭 위에서도 좌클릭 드래그하면 창 이동 (단순 클릭으로 탭 전환은 그대로 동작)
    attachDragForward(tab)

    return tab
end

local function setTabActive(tab, active)
    tab._active = active
    if active then
        applyBackdrop(tab, MR.BACKDROP_DARK,
            ACT_BG[1], ACT_BG[2], ACT_BG[3], 1,
            ACT_BD[1], ACT_BD[2], ACT_BD[3], 1)
        tab._label:SetTextColor(GOLD_CLR.r, GOLD_CLR.g, GOLD_CLR.b)
        tab._bar:Show()
    else
        applyBackdrop(tab, MR.BACKDROP_DARK,
            INACT_BG[1], INACT_BG[2], INACT_BG[3], 1,
            INACT_BD[1], INACT_BD[2], INACT_BD[3], 1)
        tab._label:SetTextColor(INACT_TXT[1], INACT_TXT[2], INACT_TXT[3])
        tab._bar:Hide()
    end
end

local function makeArrow()
    local fs = tabBar:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, 11)
    fs:SetTextColor(0.42, 0.38, 0.22)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    fs:SetText(">")
    table.insert(flowArrows, fs)
end

local tabAuction = makeTab("경매대기",      12)
makeArrow()
local tabTrade   = makeTab("판매완료",      11)
makeArrow()
local tabFailed  = makeTab("안팔린 아이템", 10)
makeArrow()
local tabSettle  = makeTab("골드 분배",     10)
tabHistory       = makeTab("레이드 완료\n기록", 9, false)   -- 우측 고정, 2줄 라벨 + 작은 폰트
tabOptions       = makeTab("옵션",          11, false)  -- 우측 고정, 전방선언에 할당
tabCalendar      = makeTab("달력 초대",     10, false)  -- 우측 고정 (가장 오른쪽), 전방선언에 할당
updateTabLayout()  -- 초기 배치

createDivider(mainFrame, -TITLE_BAR_H - TAB_BAR_H - 1)

--------------------------------------------------------------------------------
-- 탭 패널 컨테이너
--------------------------------------------------------------------------------
local PANEL_Y = -(TITLE_BAR_H + TAB_BAR_H + 4)

MR.AuctionPanel = CreateFrame("Frame", "MimRaidAuctionPanel", mainFrame)
MR.AuctionPanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.AuctionPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)

MR.TradePanel = CreateFrame("Frame", "MimRaidTradePanel", mainFrame)
MR.TradePanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.TradePanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)
MR.TradePanel:Hide()

MR.FailedPanel = CreateFrame("Frame", "MimRaidFailedPanel", mainFrame)
MR.FailedPanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.FailedPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)
MR.FailedPanel:Hide()

MR.SettlePanel = CreateFrame("Frame", "MimRaidSettlePanel", mainFrame)
MR.SettlePanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.SettlePanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)
MR.SettlePanel:Hide()

-- 옵션 패널: 스크롤 가능 (섹션이 많아질 수 있음)
-- BOTTOM 여백 40px — 메인프레임 바닥의 +/- 폰트 조절 버튼과 겹치지 않도록
MR.OptionsPanel = CreateFrame("ScrollFrame", "MimRaidOptionsPanel", mainFrame, "UIPanelScrollFrameTemplate")
MR.OptionsPanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.OptionsPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -26, 40)
MR.OptionsPanel:Hide()

-- 콘텐츠 높이 확장 — 마지막 섹션(귓말 설명) 아래에 추가 여백 확보 (스크롤 끝까지 가도 깔끔)
MR.OptionsPanelContent = CreateFrame("Frame", nil, MR.OptionsPanel)
MR.OptionsPanelContent:SetSize(FRAME_W - 30, 940)
MR.OptionsPanel:SetScrollChild(MR.OptionsPanelContent)

MR.HistoryPanel = CreateFrame("Frame", "MimRaidHistoryPanel", mainFrame)
MR.HistoryPanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.HistoryPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)
MR.HistoryPanel:Hide()

-- 달력 초대 패널 (CalendarInvite.lua 에서 내용 채움)
MR.CalendarPanel = CreateFrame("Frame", "MimRaidCalendarPanel", mainFrame)
MR.CalendarPanel:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  4, PANEL_Y)
MR.CalendarPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)
MR.CalendarPanel:Hide()

--------------------------------------------------------------------------------
-- 하단 공통 컨트롤 (모든 탭에서 보임)
--  - 우하단 리사이즈 그립 (스케일 0.7~1.5)
--  - 중앙 하단 폰트 크기 조절 -/+ 버튼
--------------------------------------------------------------------------------
local resizeGrip = CreateFrame("Button", nil, mainFrame)
resizeGrip:SetSize(16, 16)
resizeGrip:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -2, 2)
resizeGrip:SetFrameLevel(mainFrame:GetFrameLevel() + 10)

local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
gripTex:SetAllPoints()
gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

resizeGrip:SetScript("OnEnter", function(self)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("드래그: 창 크기 조절\n우클릭: 기본 크기로 초기화")
    GameTooltip:Show()
end)
resizeGrip:SetScript("OnLeave", function()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    GameTooltip:Hide()
end)

resizeGrip:RegisterForClicks("RightButtonUp")
resizeGrip:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        mainFrame:SetScale(1.0)
        if MimRaidDB then MimRaidDB.frameScale = 1.0 end
    end
end)

resizeGrip:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    self._startX, self._startY = GetCursorPosition()
    self._startScale = mainFrame:GetScale()
    self:SetScript("OnUpdate", function(grip)
        local x, y = GetCursorPosition()
        local dx = x - grip._startX
        local dy = grip._startY - y          -- 커서가 아래로 내려가면 양수
        local newScale = math.max(0.3, math.min(2.0, grip._startScale + (dx + dy) / 400))
        mainFrame:SetScale(newScale)
    end)
end)
resizeGrip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    if MimRaidDB then MimRaidDB.frameScale = mainFrame:GetScale() end
end)

-- 폰트 크기 조절 버튼 (중앙 하단)
local fontMinusBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
fontMinusBtn:SetSize(48, 30)
fontMinusBtn:SetPoint("BOTTOM", mainFrame, "BOTTOM", -60, 6)
fontMinusBtn:SetText("-")
if fontMinusBtn:GetFontString() then fontMinusBtn:GetFontString():SetFont(FONT, 18) end
fontMinusBtn:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
fontMinusBtn:SetScript("OnClick", function()
    if MR.AdjustFontSize then MR.AdjustFontSize(-1) end
end)
fontMinusBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("글꼴 크기 줄이기")
    GameTooltip:Show()
end)
fontMinusBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local fontPlusBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
fontPlusBtn:SetSize(48, 30)
fontPlusBtn:SetPoint("BOTTOM", mainFrame, "BOTTOM", 60, 6)
fontPlusBtn:SetText("+")
if fontPlusBtn:GetFontString() then fontPlusBtn:GetFontString():SetFont(FONT, 18) end
fontPlusBtn:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
fontPlusBtn:SetScript("OnClick", function()
    if MR.AdjustFontSize then MR.AdjustFontSize(1) end
end)
fontPlusBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("글꼴 크기 키우기")
    GameTooltip:Show()
end)
fontPlusBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function switchTab(tab)
    MR.AuctionPanel:Hide()
    MR.TradePanel:Hide()
    MR.FailedPanel:Hide()
    MR.SettlePanel:Hide()
    MR.OptionsPanel:Hide()
    MR.HistoryPanel:Hide()
    MR.CalendarPanel:Hide()
    setTabActive(tabAuction,  false)
    setTabActive(tabTrade,    false)
    setTabActive(tabFailed,   false)
    setTabActive(tabSettle,   false)
    setTabActive(tabHistory,  false)
    setTabActive(tabOptions,  false)
    setTabActive(tabCalendar, false)

    if tab == "auction" then
        MR.AuctionPanel:Show()
        setTabActive(tabAuction, true)
    elseif tab == "trade" then
        MR.TradePanel:Show()
        setTabActive(tabTrade, true)
    elseif tab == "failed" then
        MR.FailedPanel:Show()
        setTabActive(tabFailed, true)
    elseif tab == "settle" then
        MR.SettlePanel:Show()
        setTabActive(tabSettle, true)
        if MR.RefreshSettlePanel then MR.RefreshSettlePanel() end
    elseif tab == "history" then
        MR.HistoryPanel:Show()
        setTabActive(tabHistory, true)
        if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end
    elseif tab == "calendar" then
        MR.CalendarPanel:Show()
        setTabActive(tabCalendar, true)
        if MR.RefreshCalendarPanel then MR.RefreshCalendarPanel() end
    else  -- "options"
        MR.OptionsPanel:Show()
        setTabActive(tabOptions, true)
        if MR.RefreshOptionsPanel then MR.RefreshOptionsPanel() end
    end
end

tabAuction:SetScript("OnClick",  function() switchTab("auction")  end)
tabTrade:SetScript("OnClick",    function() switchTab("trade")    end)
tabFailed:SetScript("OnClick",   function() switchTab("failed")   end)
tabSettle:SetScript("OnClick",   function() switchTab("settle")   end)
tabHistory:SetScript("OnClick",  function() switchTab("history")  end)
tabOptions:SetScript("OnClick",  function() switchTab("options")  end)
tabCalendar:SetScript("OnClick", function() switchTab("calendar") end)
switchTab("auction")   -- 기본 탭 초기화

if not MR.AuctionFrame then MR.AuctionFrame = {} end

-- 전방 선언: 아래에서 생성되는 스크롤 프레임 참조를 클로저에서 사용하기 위함
local scrollFrame, scrollChild

--------------------------------------------------------------------------------
-- 경매진행 탭 내용
--------------------------------------------------------------------------------
local AP = MR.AuctionPanel

-- ── 현재 경매 상태 영역 ──────────────────────────────────────────────────────
local statusArea = CreateFrame("Frame", nil, AP, "BackdropTemplate")
statusArea:SetHeight(82)
statusArea:SetPoint("TOPLEFT",  AP, "TOPLEFT",  0, 0)
statusArea:SetPoint("TOPRIGHT", AP, "TOPRIGHT", 0, 0)
applyBackdrop(statusArea, MR.BACKDROP_DARK, 0.08, 0.06, 0.02, 0.9, 0.3, 0.25, 0.05, 1)

-- 아이템 아이콘
local curIcon = statusArea:CreateTexture(nil, "ARTWORK")
curIcon:SetSize(40, 40)
curIcon:SetPoint("LEFT", statusArea, "LEFT", 6, 0)
curIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

local curIconBtn = CreateFrame("Frame", nil, statusArea)
curIconBtn:SetSize(40, 40)
curIconBtn:SetPoint("LEFT", statusArea, "LEFT", 6, 0)
curIconBtn:EnableMouse(true)
curIconBtn:SetScript("OnEnter", function()
    local item = MR.Auction.itemIndex and MR.ItemList[MR.Auction.itemIndex]
    if item and item.itemLink then
        GameTooltip:SetOwner(curIconBtn, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(item.itemLink)
        GameTooltip:Show()
    end
end)
curIconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- 아이템 이름
local curItemName = statusArea:CreateFontString(nil, "OVERLAY")
curItemName:SetFont(FONT, 13)
curItemName:SetTextColor(GOLD_CLR.r, GOLD_CLR.g, GOLD_CLR.b)
curItemName:SetPoint("TOPLEFT",  statusArea, "TOPLEFT", 52, -8)
curItemName:SetPoint("TOPRIGHT", statusArea, "TOPRIGHT", -6, -8)
curItemName:SetJustifyH("LEFT")
curItemName:SetText("경매 대기 중...")

-- 최고 입찰 정보
local curBidText = statusArea:CreateFontString(nil, "OVERLAY")
curBidText:SetFont(FONT, 11)
curBidText:SetTextColor(1, 1, 0.4)
curBidText:SetPoint("TOPLEFT",  statusArea, "TOPLEFT",  52, -32)
curBidText:SetPoint("TOPRIGHT", statusArea, "TOPRIGHT", -6, -32)
curBidText:SetJustifyH("LEFT")
curBidText:SetWordWrap(false)
curBidText:SetText("")

-- 상태 표시 (IDLE / 대기중 / 카운트 / 낙찰)
local stateText = statusArea:CreateFontString(nil, "OVERLAY")
stateText:SetFont(FONT, 12)
stateText:SetPoint("TOPLEFT", statusArea, "TOPLEFT", 52, -54)
stateText:SetPoint("TOPRIGHT", statusArea, "TOPRIGHT", -6, -54)
stateText:SetJustifyH("LEFT")
stateText:SetWordWrap(true)
stateText:SetText("")

createDivider(AP, -84)

-- ── 보스 탭 필터 ─────────────────────────────────────────────────────────────
local selectedBossGroup = 0   -- 0 = 전체
local MAX_BOSS_TABS = 6
local bossTabBtns = {}

local bossTabAll = createBtn(nil, AP, "전체", 38, 20)
bossTabAll:SetPoint("TOPLEFT", AP, "TOPLEFT", 2, -87)
bossTabAll:Disable()

for i = 1, MAX_BOSS_TABS do
    local btn = createBtn(nil, AP, i .. "보스", 40, 20)
    btn:SetPoint("TOPLEFT", AP, "TOPLEFT", 42 + (i - 1) * 42, -87)
    btn:Hide()
    bossTabBtns[i] = btn
end

local listCountText = AP:CreateFontString(nil, "OVERLAY")
listCountText:SetFont(FONT, 10)
listCountText:SetTextColor(GRAY_CLR.r, GRAY_CLR.g, GRAY_CLR.b)
listCountText:SetPoint("TOPRIGHT", AP, "TOPRIGHT", -4, -89)
listCountText:SetText("")

-- ── 드래그앤드롭 존 ──────────────────────────────────────────────────────────
-- 높이 45 — 24 너무 얇고 60 너무 두꺼웠음. 중간값 사용.
local dropZone = CreateFrame("Frame", "MimRaidDropZone", AP, "BackdropTemplate")
dropZone:SetHeight(45)
dropZone:SetPoint("TOPLEFT",  AP, "TOPLEFT",   2, -112)
dropZone:SetPoint("TOPRIGHT", AP, "TOPRIGHT", -2, -112)
applyBackdrop(dropZone, MR.BACKDROP_DARK, 0.04, 0.12, 0.04, 0.75, 0.25, 0.45, 0.25, 0.9)
dropZone:EnableMouse(true)
-- 빈 공간에서 좌클릭 드래그하면 mainFrame 이동 (커서 아이템 드롭은 OnReceiveDrag로 별도 처리)
attachDragForward(dropZone)

local dropLabel = dropZone:CreateFontString(nil, "OVERLAY")
dropLabel:SetFont(FONT, 11)
dropLabel:SetTextColor(0.45, 0.75, 0.45)
dropLabel:SetPoint("CENTER", dropZone, "CENTER", 0, 0)
dropLabel:SetText("[ 아이템을 여기에 드래그하여 수동으로 추가 ]")

-- 아이템 툴팁에 루팅 거래 타이머 라인(예: "... 앞으로 %s 동안 거래할 수 있습니다...")이 있는지 검사
-- 상수 BIND_TRADE_TIME_REMAINING은 전체 문장에 %s가 박힌 형태라 prefix 매칭이 어려워,
-- 언어 공통 키워드 조합으로 판정한다.
local function hasTradeTimer(bag, slot)
    if not C_TooltipInfo then return false end
    if not bag or not slot then return false end
    local data = C_TooltipInfo.GetBagItem(bag, slot)
    if not data then return false end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        TooltipUtil.SurfaceArgs(data)
    end
    for _, line in ipairs(data.lines or {}) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            TooltipUtil.SurfaceArgs(line)
        end
        local txt = line.leftText
        if txt and (
            (txt:find("거래", 1, true) and (txt:find("시간", 1, true) or txt:find("분", 1, true))) or
            txt:find("trade this item", 1, true)
        ) then
            return true
        end
    end
    return false
end

-- 커서에 올라가 있는 아이템의 가방 슬롯 찾기 (isLocked 플래그로 판별)
local function findCursorBagSlot()
    if not C_Container or not C_Container.GetContainerItemInfo then return nil end
    local maxBag = (NUM_BAG_SLOTS or 4)
    for bag = 0, maxBag do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.isLocked then
                return bag, slot
            end
        end
    end
    return nil
end

-- 커서에 있는 아이템이 귀속됐는지 확인
-- 귀속이어도 "거래 가능 시간 남음"이면 경매 허용 (false 반환)
local function isCursorItemBound(itemLink)
    local bag, slot = findCursorBagSlot()
    if bag and slot then
        local ok, loc = pcall(function() return ItemLocation:CreateFromBagAndSlot(bag, slot) end)
        if ok and loc and C_Item.DoesItemExist(loc) then
            if not C_Item.IsBound(loc) then return false end
            return not hasTradeTimer(bag, slot)
        end
    end
    -- 폴백: bindType 1(BoP)/4(퀘스트)는 귀속으로 처리 (개별 거래 타이머 확인 불가)
    ---@diagnostic disable-next-line: deprecated
    local _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemLink or "")
    return bindType == 1 or bindType == 4
end

local function handleDrop()
    local infoType, itemID, itemLink = GetCursorInfo()
    if infoType == "item" then
        -- itemLink이 nil인 경우(캐시 미로드) itemID로 보완
        if not itemLink and itemID then
            ---@diagnostic disable-next-line: deprecated
            local _, link = GetItemInfo(itemID)
            itemLink = link
        end
        if itemLink then
            if isCursorItemBound(itemLink) then
                MR.Print("귀속된 아이템은 경매에 추가할 수 없습니다.", MR.COLOR.red)
                ClearCursor()
                return
            end
            -- COUNTDOWN/SOLD 상태에서 드롭 차단
            -- SOLD 직후 2초 안에 드롭하면 FailedItems·ItemList 양쪽에 동시 등록되는 버그 방지
            local acState = MR.Auction and MR.Auction.state
            if acState == MR.AUCTION_STATE.COUNTDOWN or acState == MR.AUCTION_STATE.SOLD then
                MR.Print("경매가 마무리되는 중입니다. 잠시 후 다시 추가해 주세요.", MR.COLOR.yellow)
                ClearCursor()
                return
            end
            MR.ItemList.Add(itemLink, "manual", "auto", nil, 0)
        else
            MR.Print("아이템 정보를 불러오는 중입니다. 잠시 후 다시 시도해주세요.", MR.COLOR.yellow)
        end
        ClearCursor()
    elseif CursorHasItem() then
        MR.Print("아이템만 추가할 수 있습니다.", MR.COLOR.red)
        ClearCursor()
    end
end

dropZone:SetScript("OnReceiveDrag", handleDrop)
dropZone:SetScript("OnEnter", function(self)
    if CursorHasItem() then
        applyBackdrop(self, MR.BACKDROP_DARK, 0.05, 0.25, 0.05, 0.9, 0.3, 0.9, 0.3, 1)
        dropLabel:SetTextColor(0.3, 1, 0.3)
    end
end)
dropZone:SetScript("OnLeave", function(self)
    applyBackdrop(self, MR.BACKDROP_DARK, 0.04, 0.12, 0.04, 0.75, 0.25, 0.45, 0.25, 0.9)
    dropLabel:SetTextColor(0.45, 0.75, 0.45)
end)

createDivider(AP, -160)

-- 전체 링크 대상 마스터 체크박스 (행별 linkCheck 일괄 토글)
-- dropZone(상단 -112~-157, 높이 45) 아래로 충분히 분리 (8px 여유)
local linkMasterCheck = CreateFrame("CheckButton", nil, AP, "UICheckButtonTemplate")
linkMasterCheck:SetSize(18, 18)
linkMasterCheck:SetPoint("TOPLEFT", AP, "TOPLEFT", 2, -165)
linkMasterCheck:SetChecked(true)
do local fs = linkMasterCheck:GetFontString(); if fs then fs:SetText("") end end
linkMasterCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("전체 링크 대상 토글", 1, 1, 1)
    GameTooltip:Show()
end)
linkMasterCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- 스크롤 프레임 (전방 선언된 변수에 할당)
-- dropZone 45 + 마스터 체크박스 -165 위치에 맞춰 -183 으로 조정
scrollFrame = CreateFrame("ScrollFrame", "MimRaidItemScrollFrame", AP, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT",     AP, "TOPLEFT",  0,  -183)
scrollFrame:SetPoint("BOTTOMRIGHT", AP, "BOTTOMRIGHT", -22, 74)

scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(FRAME_W - 30, ROW_H * MAX_ROWS)
scrollFrame:SetScrollChild(scrollChild)

-- 아이템 행 생성 (MAX_ROWS개 미리 생성, 내용만 교체)
local itemRows = {}
for i = 1, MAX_ROWS do
    local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT",  scrollChild, "TOPLEFT",  0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    row:Hide()

    if i % 2 == 0 then
        applyBackdrop(row, MR.BACKDROP_DARK, 0.12, 0.10, 0.04, 0.5, 0, 0, 0, 0)
    end

    -- 마우스 호버 하이라이트
    local highlight = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    highlight:Hide()
    row.highlight = highlight

    -- 링크 대상 선택 체크박스: "경매대기 아이템 링크하기" 버튼에서 이 상태를 참조
    local linkCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    linkCheck:SetSize(18, 18)
    linkCheck:SetPoint("LEFT", row, "LEFT", 2, 0)
    linkCheck:SetChecked(true)
    do local fs = linkCheck:GetFontString(); if fs then fs:SetText("") end end
    linkCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("체크: 링크 대상", 1, 1, 1)
        GameTooltip:Show()
    end)
    linkCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- 행 체크 변동 시 마스터 체크박스 상태 동기화 (모두 체크면 on, 하나라도 해제면 off)
    linkCheck:SetScript("OnClick", function()
        local allChecked = true
        for j = 1, MAX_ROWS do
            local r = itemRows[j]
            if r and r:IsShown() and r.linkCheck and r.linkCheck:IsShown()
                and not r.linkCheck:GetChecked()
            then
                allChecked = false
                break
            end
        end
        linkMasterCheck:SetChecked(allChecked)
    end)

    -- (자동/수동 토글 modeBtn 제거 — 모든 아이템 기본 자동경매. 단일 경매는 "이 아이템만 경매" 버튼 사용)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_H - 4, ROW_H - 4)
    icon:SetPoint("LEFT", linkCheck, "RIGHT", 2, 0)

    -- 개별경매 버튼: 해당 아이템만 경매, 연속 진행 없음
    local removeBtn = createBtn(nil, row, "삭제", 62, ROW_H - 4)
    removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    do local fs = removeBtn:GetFontString(); if fs then fs:SetFont(FONT, 10) end end

    local startBtn = createBtn(nil, row, "이 아이템만 경매", 110, ROW_H - 4)
    startBtn:SetPoint("RIGHT", removeBtn, "LEFT", -4, 0)
    do local fs = startBtn:GetFontString(); if fs then fs:SetFont(FONT, 10) end end

    -- 이름은 행 위쪽으로, 요약(summary) 두 줄은 그 아래쪽에 배치 (ROW_H=48, 3줄 레이아웃)
    -- 이름 top 을 행 top 에 맞춰 위쪽 정렬 (아이콘 top 보다 살짝 아래)
    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(FONT, 11)
    nameText:SetTextColor(GOLD_CLR.r, GOLD_CLR.g, GOLD_CLR.b)
    nameText:SetPoint("TOPLEFT",  icon, "TOPRIGHT", 4, 0)
    -- RIGHT anchor는 refreshItemList에서 variantLabel 표시 여부에 따라 동적으로 설정
    nameText:SetPoint("RIGHT", startBtn, "LEFT", -4, 0)
    nameText:SetHeight(15)
    nameText:SetJustifyH("LEFT")
    nameText:SetJustifyV("TOP")
    nameText:SetWordWrap(false)

    -- 1차/2차/홈 요약 라벨 — 두 줄을 별도 FontString 으로 분리.
    -- ("\n" 단일 FontString 시도가 일부 빌드에서 렌더링되지 않아 두 줄을 따로 만듦)
    local summaryLine1 = row:CreateFontString(nil, "OVERLAY")
    summaryLine1:SetFont(FONT, 11)
    summaryLine1:SetTextColor(0.78, 0.78, 0.78)
    summaryLine1:SetPoint("TOPLEFT", nameText,    "BOTTOMLEFT", 0, -1)
    summaryLine1:SetPoint("RIGHT",   row,         "RIGHT",      -180, 0)
    summaryLine1:SetHeight(14)
    summaryLine1:SetJustifyH("LEFT")
    summaryLine1:SetWordWrap(false)
    summaryLine1:Hide()

    local summaryLine2 = row:CreateFontString(nil, "OVERLAY")
    summaryLine2:SetFont(FONT, 11)
    summaryLine2:SetTextColor(0.78, 0.78, 0.78)
    summaryLine2:SetPoint("TOPLEFT", summaryLine1, "BOTTOMLEFT", 0, -1)
    summaryLine2:SetPoint("RIGHT",   row,          "RIGHT",      -180, 0)
    summaryLine2:SetHeight(14)
    summaryLine2:SetJustifyH("LEFT")
    summaryLine2:SetWordWrap(false)
    summaryLine2:Hide()

    -- 추가옵션 카테고리 라벨: 변형(bonus 차이) + 특수 카테고리일 때만 표시
    -- startBtn 바로 왼쪽에 위치
    local variantLabel = row:CreateFontString(nil, "OVERLAY")
    variantLabel:SetDrawLayer("OVERLAY", 7)
    variantLabel:SetFont(FONT, 10)
    variantLabel:SetTextColor(1, 0.82, 0)
    variantLabel:SetPoint("RIGHT", startBtn, "LEFT", -6, 0)
    variantLabel:SetWidth(140)
    variantLabel:SetHeight(14)
    variantLabel:SetJustifyH("RIGHT")
    variantLabel:SetWordWrap(false)
    variantLabel:Hide()

    local countLabel = row:CreateFontString(nil, "OVERLAY")
    countLabel:SetFont(FONT, 9)
    countLabel:SetTextColor(0.55, 0.55, 0.55)
    countLabel:SetWidth(80)
    countLabel:SetJustifyH("CENTER")
    countLabel:SetWordWrap(false)
    countLabel:SetPoint("CENTER", row, "CENTER", 0, 0)
    countLabel:Hide()

    row.linkCheck    = linkCheck
    row.icon         = icon
    row.nameText     = nameText
    row.summaryLine1 = summaryLine1
    row.summaryLine2 = summaryLine2
    row.startBtn     = startBtn
    row.removeBtn    = removeBtn
    row.variantLabel = variantLabel
    row.countLabel   = countLabel

    -- 보스 구분선 레이블 (separator 모드에서만 표시)
    local dividerLabel = row:CreateFontString(nil, "OVERLAY")
    dividerLabel:SetFont(FONT, 10)
    dividerLabel:SetTextColor(0.55, 0.55, 0.55)
    dividerLabel:SetAllPoints()
    dividerLabel:SetJustifyH("CENTER")
    dividerLabel:SetJustifyV("MIDDLE")
    dividerLabel:Hide()
    row.dividerLabel = dividerLabel

    -- 아이콘/이름 영역 호버 시 아이템 상세 툴팁 + 행 하이라이트
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        self.highlight:Show()
        if self._itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self._itemLink)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.highlight:Hide()
        GameTooltip:Hide()
    end)

    -- 행의 빈 공간(체크박스/버튼 외)에서 드래그하면 창 이동
    attachDragForward(row)

    itemRows[i] = row
end

-- ── 하단 버튼 영역 ───────────────────────────────────────────────────────────
-- 경매시작/중지 토글 버튼
local autoStartBtn = CreateFrame("Button", nil, AP, "UIPanelButtonTemplate")
autoStartBtn:SetSize(130, 64)
autoStartBtn:SetPoint("BOTTOMLEFT", AP, "BOTTOMLEFT", 6, 4)
autoStartBtn:SetText("|cffffcc00▶  경매시작|r")
do local fs = autoStartBtn:GetFontString(); if fs then fs:SetFont(FONT, 14) end end

autoStartBtn:SetScript("OnClick", function()
    if MR.Auction.sequential then
        MR.Auction.StopSequential()
    else
        MR.Auction.StartSequential()
    end
end)

local function updateAutoStartBtn()
    if MR.Auction.sequential then
        autoStartBtn:SetText("|cffffcc00■  경매중지|r")
    else
        autoStartBtn:SetText("|cffffcc00▶  경매시작|r")
    end
end

-- ── 경매 대기 아이템 전체 채팅 링크 (안팔린 아이템과 동일 방식) ───────────────
local ITEM_LIST_CHAT_MAX = 250

local function sendItemListToChat()
    if not MR.ItemList or #MR.ItemList == 0 then
        MR.Print("경매 대기 아이템이 없습니다.", MR.COLOR.yellow)
        return
    end

    local function send(msg)
        if IsInRaid() then
            MR.SafeSendChat(msg, MR.cfg.auctionChannel or "RAID")
        elseif GetNumGroupMembers() > 0 then
            MR.SafeSendChat(msg, "PARTY")
        else
            MR.Print("[채팅] " .. msg, MR.COLOR.white)
        end
    end

    -- 행 단위 체크박스 상태를 기준으로 링크 대상 선별
    -- (변형 엔트리는 모든 variant 링크를 풀어서 나열: 라소크 ×3 의 linkA/B/C 등)
    local links = {}
    for i = 1, MAX_ROWS do
        local row = itemRows[i]
        if row and row:IsShown() and row._entry
            and row.linkCheck and row.linkCheck:IsShown() and row.linkCheck:GetChecked()
        then
            local entry = row._entry
            if entry.itemLinks and #entry.itemLinks > 0 then
                for _, l in ipairs(entry.itemLinks) do
                    if l then table.insert(links, l) end
                end
            elseif entry.itemLink then
                table.insert(links, entry.itemLink)
            end
        end
    end
    if #links == 0 then
        MR.Print("선택된 아이템이 없습니다.", MR.COLOR.yellow)
        return
    end

    PlaySound(SOUNDKIT.RAID_WARNING, "Dialog")
    send("[경매] 경매 대기 아이템 목록 살펴보세요")
    local line = ""
    for _, link in ipairs(links) do
        local piece = (line == "") and link or (" " .. link)
        if #line + #piece > ITEM_LIST_CHAT_MAX then
            send(line)
            line = link
        else
            line = line .. piece
        end
    end
    if line ~= "" then send(line) end
end

local announceItemListBtn = createBtn(nil, AP, "경매대기 아이템 링크하기", 160, 22)
announceItemListBtn:SetPoint("BOTTOMRIGHT", AP, "BOTTOMRIGHT", -22, 8)
announceItemListBtn:SetScript("OnClick", sendItemListToChat)

-- 마스터 체크박스: 모든 행 토글 (separator 행 제외)
linkMasterCheck:SetScript("OnClick", function(self)
    local checked = self:GetChecked() and true or false
    for i = 1, MAX_ROWS do
        local r = itemRows[i]
        if r and r:IsShown() and r.linkCheck and r.linkCheck:IsShown() then
            r.linkCheck:SetChecked(checked)
        end
    end
end)


--------------------------------------------------------------------------------
-- 아이템 목록 UI 갱신 (보스 탭 필터 포함)
--------------------------------------------------------------------------------

local refreshBossTabs   -- forward declaration

local function refreshItemList()
    local displayList = {}

    -- 정렬 키 계산: baseID(itemID)별 최소 groupNumber
    -- 같은 아이템이 여러 그룹(예: 보홈 + 일반)으로 분리된 경우, baseID 묶음 전체를
    -- 그 중 가장 우선순위 높은(=작은) groupNumber 기준으로 정렬하기 위해 사용
    local function getBaseID(link)
        if not link then return 0 end
        return tonumber(link:match("item:(%d+)")) or 0
    end
    local minGroupByBase = {}
    for _, entry in ipairs(MR.ItemList) do
        local bid = getBaseID(entry.itemLink)
        local g   = entry.groupNumber or 4
        if not minGroupByBase[bid] or g < minGroupByBase[bid] then
            minGroupByBase[bid] = g
        end
    end

    -- bossGroup별로 entries 분류 + 출현 순서 보존
    local byBossGroup = {}
    local bgOrder     = {}
    for idx, entry in ipairs(MR.ItemList) do
        local bg = entry.bossGroup or 0
        if not byBossGroup[bg] then
            byBossGroup[bg] = {}
            table.insert(bgOrder, bg)
        end
        table.insert(byBossGroup[bg], { entry = entry, index = idx })
    end
    table.sort(bgOrder)

    -- 각 bossGroup 내 정렬: minGroupByBase → baseID → groupNumber
    for _, entries in pairs(byBossGroup) do
        table.sort(entries, function(a, b)
            local ba  = getBaseID(a.entry.itemLink)
            local bb  = getBaseID(b.entry.itemLink)
            local mga = minGroupByBase[ba] or 4
            local mgb = minGroupByBase[bb] or 4
            if mga ~= mgb then return mga < mgb end
            if ba  ~= bb  then return ba  < bb  end
            return (a.entry.groupNumber or 4) < (b.entry.groupNumber or 4)
        end)
    end

    if selectedBossGroup == 0 then
        for _, bg in ipairs(bgOrder) do
            if bg > 0 then
                table.insert(displayList, { isSeparator = true, bossGroup = bg })
            end
            for _, item in ipairs(byBossGroup[bg]) do
                table.insert(displayList, item)
            end
        end
    else
        local entries = byBossGroup[selectedBossGroup]
        if entries then
            if selectedBossGroup > 0 then
                table.insert(displayList, { isSeparator = true, bossGroup = selectedBossGroup })
            end
            for _, item in ipairs(entries) do
                table.insert(displayList, item)
            end
        end
    end

    listCountText:SetText(string.format("%d개 (판매안됨 %d)", #MR.ItemList, #MR.FailedItems))
    announceItemListBtn:SetEnabled(#MR.ItemList > 0)
    MR.Debug(string.format(
        "refreshItemList: #itemList=%d #failedItems=%d #displayList=%d selectedBoss=%s",
        #MR.ItemList, #MR.FailedItems, #displayList, tostring(selectedBossGroup)))
    refreshBossTabs()

    for i = 1, MAX_ROWS do
        local item = displayList[i]
        local row  = itemRows[i]

        if item and item.isSeparator then
            -- 보스 구분선 행
            row:Show()
            row.icon:Hide()
            row.nameText:Hide()
            if row.summaryLine1 then row.summaryLine1:Hide() end
            if row.summaryLine2 then row.summaryLine2:Hide() end
            row.startBtn:Hide()
            row.removeBtn:Hide()
            row.variantLabel:Hide()
            row.countLabel:Hide()
            if row.linkCheck then row.linkCheck:Hide() end
            row._entry = nil
            row.dividerLabel:SetText(string.format(
                "────────── %s ──────────",
                (MR.ItemList.bossNames and MR.ItemList.bossNames[item.bossGroup])
                    or (item.bossGroup .. "보스")))
            row.dividerLabel:Show()
            row:EnableMouse(false)
        elseif item then
            local entry   = item.entry
            local listIdx = item.index
            row:Show()
            row.icon:Show()
            row.nameText:Show()
            row.startBtn:Show()
            row.removeBtn:Show()
            row.dividerLabel:Hide()
            if row.linkCheck then row.linkCheck:Show() end
            row:EnableMouse(true)

            row._entry = entry

            row.icon:SetTexture(entry.texture or "Interface\\Icons\\INV_Misc_QuestionMark")

            -- 수량 뱃지: ×2, ×3
            local qtySuffix = (entry.quantity and entry.quantity > 1)
                and string.format(" |cffff9900×%d|r", entry.quantity) or ""
            -- 재경매 횟수: nameText 끝에 인라인으로 (별도 countLabel 은 summary 와 겹쳐서 숨김)
            local countSuffix = (entry.auctionCount and entry.auctionCount > 0)
                and string.format(" |cff888888[재경매 %d회]|r", entry.auctionCount) or ""
            row.nameText:SetText(entry.itemName .. qtySuffix .. countSuffix)
            row._itemLink = entry.itemLink

            -- 1차/2차/홈 요약 — 3단계 동적 레이아웃 (이름과 옵션 폰트 동일):
            --   Tier 1: 16/16 한 줄 (기본)
            --   Tier 2: 14/14 한 줄 (옵션 좀 많을 때)
            --   Tier 3: 14/14 두 줄 (옵션 매우 많을 때 fallback)
            -- entry._testSummary 가 있으면 BuildItemSummary 대신 그 값 사용 (/mr uitest 검증용)
            if row.summaryLine1 and row.summaryLine2 then
                local summary = entry._testSummary
                    or ((MR.BuildItemSummary and entry.itemLink)
                        and MR.BuildItemSummary(entry.itemLink, true) or "")
                if summary ~= "" then
                    local l1, l2 = summary:match("^(.-)\n(.*)$")
                    if not l1 then l1, l2 = summary, "" end
                    local oneLine = (l2 ~= "") and (l1 .. " - " .. l2) or l1

                    local function applyFonts(size, h)
                        row.nameText:SetFont(FONT, size)
                        row.nameText:SetHeight(h)
                        row.summaryLine1:SetFont(FONT, size)
                        row.summaryLine1:SetHeight(h)
                        row.summaryLine2:SetFont(FONT, size)
                        row.summaryLine2:SetHeight(h)
                    end

                    -- Tier 1: 16 한 줄
                    applyFonts(16, 18)
                    row.summaryLine1:SetText(oneLine)
                    row.summaryLine1:Show()
                    local availW  = row.summaryLine1:GetWidth() or 0
                    local stringW = row.summaryLine1:GetStringWidth() or 0

                    if availW > 0 and stringW > (availW - 4) then
                        -- Tier 2: 14 한 줄
                        applyFonts(14, 16)
                        row.summaryLine1:SetText(oneLine)
                        stringW = row.summaryLine1:GetStringWidth() or 0
                        if stringW > (availW - 4) then
                            -- Tier 3: 14 두 줄 (라인 높이 압축)
                            applyFonts(14, 14)
                            row.summaryLine1:SetText(l1)
                            if l2 ~= "" then
                                row.summaryLine2:SetText(l2)
                                row.summaryLine2:Show()
                            else
                                row.summaryLine2:Hide()
                            end
                        else
                            row.summaryLine2:Hide()
                        end
                    else
                        row.summaryLine2:Hide()
                    end
                else
                    row.summaryLine1:Hide()
                    row.summaryLine2:Hide()
                end
            end

            -- countLabel 은 더 이상 사용 안 함 (재경매 횟수는 nameText 인라인으로 합쳐짐)
            local hasCount = false

            -- 카테고리 라벨: summary 가 표시될 때는 중복(보석홈/파불/광피 등)이 되므로 생략.
            -- summary 가 없는 아이템(장비 외 등)에서만 catLabel 표시.
            local hasSummary = row.summaryLine1 and row.summaryLine1:IsShown()
            local catLabel = (not hasSummary) and MR.BuildCategoryLabel
                and MR.BuildCategoryLabel(entry.itemLinks or entry.itemLink) or ""
            if catLabel ~= "" then
                row.variantLabel:SetText(catLabel)
                row.variantLabel:Show()
                row.nameText:ClearAllPoints()
                row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 4, 0)
                row.nameText:SetPoint("RIGHT",   row.variantLabel, "LEFT", -4, 0)
            else
                row.variantLabel:Hide()
                row.nameText:ClearAllPoints()
                row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 4, 0)
                row.nameText:SetPoint("RIGHT",   row.startBtn, "LEFT", -4, 0)
            end

            -- 재경매 횟수 레이블 (row 중앙 고정, 위치는 생성 시 설정)
            if hasCount then
                row.countLabel:SetText(string.format("|cff888888[재경매 %d회]|r", entry.auctionCount))
                row.countLabel:Show()
            else
                row.countLabel:Hide()
            end

            -- 개별경매: sequential 플래그 해제 후 해당 아이템만 경매
            row.startBtn:SetEnabled(MR.Auction.state == MR.AUCTION_STATE.IDLE)
            row.startBtn:SetScript("OnClick", function()
                MR.Auction.sequential = false
                MR.Auction.Start(listIdx)
            end)

            row.removeBtn:SetScript("OnClick", function()
                MR.ItemList.Remove(listIdx)
            end)
        else
            row:Hide()
        end
    end

    local neededH = ROW_H * math.max(#displayList, 1)
    MR.Debug(string.format(
        "refreshItemList SCROLL: rows=%d childH=%.0f",
        #displayList, neededH))
    scrollChild:SetHeight(neededH)
end

refreshBossTabs = function()
    local maxGroup = 0
    for _, entry in ipairs(MR.ItemList) do
        if entry.bossGroup and entry.bossGroup > maxGroup then
            maxGroup = entry.bossGroup
        end
    end
    for i = 1, MAX_BOSS_TABS do
        if i <= maxGroup then
            bossTabBtns[i]:Show()
            if selectedBossGroup == i then bossTabBtns[i]:Disable()
            else bossTabBtns[i]:Enable() end
        else
            bossTabBtns[i]:Hide()
        end
    end
    if selectedBossGroup == 0 then bossTabAll:Disable()
    else bossTabAll:Enable() end
end

bossTabAll:SetScript("OnClick", function()
    selectedBossGroup = 0
    refreshItemList()
end)
for i = 1, MAX_BOSS_TABS do
    local grp = i
    bossTabBtns[i]:SetScript("OnClick", function()
        selectedBossGroup = grp
        refreshItemList()
    end)
end

--------------------------------------------------------------------------------
-- 경매 상태 UI 갱신
--------------------------------------------------------------------------------
local STATE_LABEL = {
    [MR.AUCTION_STATE.IDLE]      = "|cff888888● 대기 중|r",
    [MR.AUCTION_STATE.WAITING]   = "|cffffff00● 입찰 대기|r",
    [MR.AUCTION_STATE.COUNTDOWN] = "|cffff8800● 카운트 중|r",
    [MR.AUCTION_STATE.SOLD]      = "|cff00ff00● 판매완료!|r",
}

local function refreshAuctionStatus()
    local ac = MR.Auction
    local item = ac.itemIndex and MR.ItemList[ac.itemIndex]

    if item then
        curIcon:SetTexture(item.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        local catLabel = MR.BuildCategoryLabel
            and MR.BuildCategoryLabel(item.itemLinks or item.itemLink) or ""
        curItemName:SetText(item.itemName .. (catLabel ~= "" and (" " .. catLabel) or ""))
    else
        curIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        curItemName:SetText("경매 대기 중...")
    end

    -- 입찰 현황 표시 (다중 낙찰 슬롯 지원)
    if ac.state == MR.AUCTION_STATE.IDLE then
        curBidText:SetText("")
    elseif ac.winnerSlots and ac.winnerSlots > 1 then
        -- 다중 낙찰: 상위 N명 + 예상 균일가 (N등 입찰가)
        local sorted = {}
        for name, bids in pairs(ac.allPlayerBids or {}) do
            if type(bids) == "table" then
                for _, b in ipairs(bids) do
                    table.insert(sorted, { name = name, bid = b })
                end
            else
                -- 하위호환: 스칼라 값 (구 저장값)
                table.insert(sorted, { name = name, bid = bids })
            end
        end
        table.sort(sorted, function(a, b) return a.bid > b.bid end)
        if #sorted > 0 then
            local slots  = ac.winnerSlots
            local winN   = math.min(slots, #sorted)
            local uPrice = sorted[winN].bid
            local parts  = {}
            for i = 1, winN do
                table.insert(parts, string.format("%d위:%s(%s)",
                    i, MR.BaseName(sorted[i].name), MR.FormatGold(sorted[i].bid)))
            end
            curBidText:SetText(string.format("×%d 입찰: %s  →예상가 %s",
                slots, table.concat(parts, "  "), MR.FormatGold(uPrice)))
        else
            curBidText:SetText(string.format("×%d 경매 중 (입찰자 없음)", ac.winnerSlots))
        end
    elseif ac.topBidder and ac.topBid > 0 then
        curBidText:SetText(string.format("최고입찰: %s  %s",
            ac.topBidder, MR.FormatGold(ac.topBid)))
    else
        curBidText:SetText("입찰자 없음")
    end

    if ac.state == MR.AUCTION_STATE.SOLD and (not ac.topBidder or ac.topBid == 0) then
        stateText:SetText("|cffaaaaaa● 입찰자 없음\n경매완료 - 안팔린 아이템으로 이동|r")
    else
        stateText:SetText(STATE_LABEL[ac.state] or "")
    end

    local isIdle = (ac.state == MR.AUCTION_STATE.IDLE)

    -- 버튼 토글: 경매시작(녹색) ↔ 경매중지(빨강)
    updateAutoStartBtn()
    autoStartBtn:SetEnabled(ac.sequential or isIdle)

    -- 개별경매 버튼: IDLE 이고 sequential 아닐 때만 활성
    for i = 1, MAX_ROWS do
        if itemRows[i]:IsShown() then
            itemRows[i].startBtn:SetEnabled(isIdle and not ac.sequential)
        end
    end

    refreshItemList()
end

--------------------------------------------------------------------------------
-- 콜백 등록
--------------------------------------------------------------------------------
MR.Auction.OnUpdate(refreshAuctionStatus)
MR.ItemList.OnChange(refreshItemList)

--------------------------------------------------------------------------------
-- 위치 저장/복원 (SavedVariables)
--------------------------------------------------------------------------------
-- MR.AuctionFrame은 상단에서 이미 초기화됨, 필드만 추가
MR.AuctionFrame.SwitchTab = switchTab

function MR.AuctionFrame.SavePosition()
    if not MimRaidDB then return end
    MimRaidDB.frameX = mainFrame:GetLeft()
    MimRaidDB.frameY = mainFrame:GetTop()
end

function MR.AuctionFrame.RestorePosition()
    if not MimRaidDB then return end
    local x, y = MimRaidDB.frameX, MimRaidDB.frameY
    if x and y then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    end
end

function MR.AuctionFrame.RestoreScale()
    if MimRaidDB and MimRaidDB.frameScale then
        mainFrame:SetScale(math.max(0.3, math.min(2.0, MimRaidDB.frameScale)))
    end
end

-- ADDON_LOADED 후 위치 복원
mainFrame:RegisterEvent("ADDON_LOADED")
mainFrame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" and addonName == "MimRaid" then
        MR.AuctionFrame.RestoreScale()
        MR.AuctionFrame.RestorePosition()
        -- UI 레이아웃 완료 후 scrollChild 너비 확정 및 목록 갱신
        C_Timer.After(0, function()
            local sw = scrollFrame:GetWidth()
            if sw and sw > 0 then scrollChild:SetWidth(sw) end
            refreshItemList()
        end)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
