--------------------------------------------------------------------------------
-- MimRaid - TradeLogFrame.lua
-- 판매완료 탭(MR.TradePanel): 낙찰기록 직접 표시
-- 정산 탭(MR.SettlePanel): 수납골드 / 분배 계산 / 보고
-- 안팔린 아이템 탭(MR.FailedPanel): 유찰 목록
-- 기록 탭(MR.HistoryPanel): 레이드 완료 히스토리
-- 옵션 탭(MR.OptionsPanel): 카운트다운 설정
--------------------------------------------------------------------------------

---@diagnostic disable: undefined-global

local MR = MimRaid

local ROW_H      = 26
local LOG_ROW_H  = 30
local FONT   = "Fonts\\2002.TTF"
local GOLD_C = { r = 1,    g = 0.82, b = 0    }
local GRAY_C = { r = 0.6,  g = 0.6,  b = 0.6  }

local function applyBackdrop(frame, info, r, g, b, a, br, bg, bb, ba)
    frame:SetBackdrop(info)
    frame:SetBackdropColor(r or 0, g or 0, b or 0, a or 0.85)
    frame:SetBackdropBorderColor(br or 0.35, bg or 0.35, bb or 0.35, ba or 1)
end

local function createBtn(parent, text, w, h)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w or 70, h or 22)
    if btn.SetText then btn:SetText(text) end
    local fs = btn:GetFontString()
    if fs then fs:SetFont(FONT, 11) end
    return btn
end

local function createDivider(parent, yOffset)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    t:SetHeight(1)
    t:SetPoint("TOPLEFT",  parent, "TOPLEFT",  2, yOffset)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, yOffset)
    return t
end

--------------------------------------------------------------------------------
-- 플레이어 우클릭 컨텍스트 메뉴 (공유)
--------------------------------------------------------------------------------
-- 전투중 protected API 가드 (WoW 11.x 최근 패치에서 ADDON_ACTION_FORBIDDEN 강화).
-- ChatFrame_OpenChat / C_PartyInfo.InviteUnit / InitiateTrade 모두 전투중 차단됨.
local function _combatBlockedNotice(action)
    if InCombatLockdown and InCombatLockdown() then
        if MR.Print and MR.COLOR then
            MR.Print("전투 중에는 " .. action .. " 할 수 없습니다.", MR.COLOR.orange)
        end
        return true
    end
    return false
end

local function showPlayerMenu(name)
    if not name or name == "" or name == "?" then return end
    local shortName = name:match("^([^%-]+)") or name  -- 레이드 유닛 스캔용
    MenuUtil.CreateContextMenu(UIParent, function(_, rootDescription)
        rootDescription:CreateTitle(name)
        rootDescription:CreateButton("귓속말", function()
            if _combatBlockedNotice("귓속말 창 열기를") then return end
            ChatFrame_OpenChat("/w " .. name .. " ", DEFAULT_CHAT_FRAME)
        end)
        rootDescription:CreateButton("레이드/파티 초대", function()
            if _combatBlockedNotice("초대를") then return end
            C_PartyInfo.InviteUnit(name)
        end)
        -- 현재 레이드에 있을 때만 거래 메뉴 표시
        -- UnitName 은 secret-taintable → pcall 로 보호
        for i = 1, GetNumGroupMembers() do
            local ok, n = pcall(UnitName, "raid" .. i)
            if ok and n == shortName then
                local unitId = "raid" .. i
                rootDescription:CreateButton("거래 신청", function()
                    if _combatBlockedNotice("거래를") then return end
                    InitiateTrade(unitId)
                end)
                break
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- [판매완료] 패널 = MR.TradePanel  →  낙찰기록 직접 표시 (서브탭 없음)
--------------------------------------------------------------------------------
local TP = MR.TradePanel
local logRows = {}  -- 낙찰 기록 수에 따라 on-demand 생성

-- 헤더 (열별 개별 FontString — 비례 폰트에서도 정렬 유지)
local logHdrState = TP:CreateFontString(nil, "OVERLAY")
logHdrState:SetFont(FONT, 10)
logHdrState:SetTextColor(GRAY_C.r, GRAY_C.g, GRAY_C.b)
logHdrState:SetPoint("TOPLEFT", TP, "TOPLEFT", 2, -2)
logHdrState:SetWidth(20)
logHdrState:SetJustifyH("CENTER")
logHdrState:SetText("|cffffcc00?|r")

local logHdrStateBtn = CreateFrame("Button", nil, TP)
logHdrStateBtn:SetPoint("TOPLEFT",     logHdrState, "TOPLEFT",     -2,  2)
logHdrStateBtn:SetPoint("BOTTOMRIGHT", logHdrState, "BOTTOMRIGHT",  2, -2)
logHdrStateBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("거래 상태 라벨")
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff44ff44완납|r : 낙찰금액 전액 수령")
    GameTooltip:AddLine("|cffffaa00부분납|r : 일부만 수령")
    GameTooltip:AddLine("|cff888888미납|r : 아직 거래 전")
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffaaaaaa[디버그 모드 전용]|r")
    GameTooltip:AddLine("|cff66aaff완료|r : 거래 1건 추적용 audit 기록")
    GameTooltip:AddLine("|cff888888취소|r : 거래창 열고 취소된 기록")
    GameTooltip:Show()
end)
logHdrStateBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local logHdrName = TP:CreateFontString(nil, "OVERLAY")
logHdrName:SetFont(FONT, 10)
logHdrName:SetTextColor(GRAY_C.r, GRAY_C.g, GRAY_C.b)
logHdrName:SetPoint("TOPLEFT", TP, "TOPLEFT", 74, -2)   -- 데이터 행 nameText LEFT(74) 와 정렬
logHdrName:SetText("아이템명")

-- 헤더: 실제받은금액 (맨 오른쪽)
local logHdrPaid = TP:CreateFontString(nil, "OVERLAY")
logHdrPaid:SetFont(FONT, 10)
logHdrPaid:SetTextColor(GRAY_C.r, GRAY_C.g, GRAY_C.b)
logHdrPaid:SetPoint("TOPRIGHT", TP, "TOPRIGHT", -26, -2)
logHdrPaid:SetWidth(90)
logHdrPaid:SetJustifyH("RIGHT")
logHdrPaid:SetText("실제받은금액")

-- 헤더: 판매금액 (오른쪽 두 번째)
local logHdrBid = TP:CreateFontString(nil, "OVERLAY")
logHdrBid:SetFont(FONT, 10)
logHdrBid:SetTextColor(GRAY_C.r, GRAY_C.g, GRAY_C.b)
logHdrBid:SetPoint("TOPRIGHT", TP, "TOPRIGHT", -120, -2)
logHdrBid:SetWidth(80)
logHdrBid:SetJustifyH("RIGHT")
logHdrBid:SetText("판매금액")

local logHdrWinner = TP:CreateFontString(nil, "OVERLAY")
logHdrWinner:SetFont(FONT, 10)
logHdrWinner:SetTextColor(GRAY_C.r, GRAY_C.g, GRAY_C.b)
logHdrWinner:SetPoint("RIGHT", logHdrBid, "LEFT", -8, 0)
logHdrWinner:SetWidth(180)
logHdrWinner:SetJustifyH("CENTER")
logHdrWinner:SetText("구매자")

-- 스크롤
local logScroll = CreateFrame("ScrollFrame", nil, TP, "UIPanelScrollFrameTemplate")
logScroll:SetPoint("TOPLEFT",     TP, "TOPLEFT",  0,   -16)
logScroll:SetPoint("BOTTOMRIGHT", TP, "BOTTOMRIGHT", -22, 60)

local logChild = CreateFrame("Frame", nil, logScroll)
logChild:SetSize(1, LOG_ROW_H)
logScroll:SetScrollChild(logChild)

-- 낙찰 기록 행 lazy 생성 (#TradeLog 에 맞춰 필요한 만큼만)
local function createLogRow(i)
    if logRows[i] then return logRows[i] end

    local row = CreateFrame("Frame", nil, logChild, "BackdropTemplate")
    row:SetHeight(LOG_ROW_H)
    row:SetPoint("TOPLEFT",  logChild, "TOPLEFT",  0, -(i - 1) * LOG_ROW_H)
    row:SetPoint("TOPRIGHT", logChild, "TOPRIGHT", 0, -(i - 1) * LOG_ROW_H)
    if i % 2 == 0 then
        applyBackdrop(row, MR.BACKDROP_DARK, 0.1, 0.08, 0.04, 0.5, 0, 0, 0, 0)
    end
    row:Hide()

    -- 마우스 호버 하이라이트 (옅은 흰색 — 어디 가리키고 있는지 명확)
    local highlight = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    highlight:Hide()
    row.highlight = highlight

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)

    local stateIcon = row:CreateFontString(nil, "OVERLAY")
    stateIcon:SetFont(FONT, 13)
    stateIcon:SetPoint("LEFT", row, "LEFT", 23, 0)
    stateIcon:SetWidth(48)   -- "완납"/"부분납"(3글자)/"미납"/"완료"/"취소" 모두 수용
    stateIcon:SetJustifyH("CENTER")
    stateIcon:SetWordWrap(false)

    -- 오른쪽: 실제받은금액(90) → 판매금액(80) → 구매자(110) → 아이템명(나머지)
    local paidText = row:CreateFontString(nil, "OVERLAY")
    paidText:SetFont(FONT, 13)
    paidText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    paidText:SetWidth(90)
    paidText:SetJustifyH("RIGHT")
    paidText:SetWordWrap(false)

    local bidText = row:CreateFontString(nil, "OVERLAY")
    bidText:SetFont(FONT, 13)
    bidText:SetPoint("RIGHT", row, "RIGHT", -98, 0)
    bidText:SetWidth(80)
    bidText:SetJustifyH("RIGHT")
    bidText:SetWordWrap(false)

    local winnerText = row:CreateFontString(nil, "OVERLAY")
    winnerText:SetFont(FONT, 13)
    winnerText:SetTextColor(1, 1, 1)
    winnerText:SetPoint("RIGHT", bidText, "LEFT", -8, 0)
    winnerText:SetWidth(180)
    winnerText:SetJustifyH("CENTER")
    winnerText:SetWordWrap(false)

    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(FONT, 13)
    nameText:SetTextColor(GOLD_C.r, GOLD_C.g, GOLD_C.b)
    nameText:SetPoint("LEFT",  row,        "LEFT",  74, 0)   -- stateIcon 폭(48) + 시작(23) + 약간 갭
    nameText:SetPoint("RIGHT", winnerText, "LEFT",  -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)

    -- 아이템 툴팁 + 구매자 우클릭 메뉴
    local tipBtn = CreateFrame("Button", nil, row)
    tipBtn:SetAllPoints()
    tipBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tipBtn:SetScript("OnEnter", function(self)
        row.highlight:Show()
        if row._itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(row._itemLink)
            local entry = row._logIndex and MR.TradeLog[row._logIndex]
            if entry then
                local stateText
                if entry.state == MR.TRADE_STATE.DONE then
                    stateText = "|cff44ff44완납|r"
                elseif entry.state == MR.TRADE_STATE.PARTIAL then
                    stateText = "|cffffaa00부분납|r"
                else
                    stateText = "|cff888888미납|r"
                end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("거래 상태: " .. stateText)
            end
            GameTooltip:Show()
        end
    end)
    tipBtn:SetScript("OnLeave", function()
        row.highlight:Hide()
        GameTooltip:Hide()
    end)
    -- 행의 빈 공간에서 좌클릭 드래그 → 창 이동 위임
    if MR._attachDragForward then MR._attachDragForward(tipBtn) end
    tipBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            GameTooltip:Hide()
            local name = row._winnerName
            MenuUtil.CreateContextMenu(UIParent, function(_, rootDescription)
                if name and name ~= "" and name ~= "?" then
                    local shortName = name:match("^([^%-]+)") or name
                    rootDescription:CreateTitle(name)
                    rootDescription:CreateButton("귓속말", function()
                        if _combatBlockedNotice("귓속말 창 열기를") then return end
                        ChatFrame_OpenChat("/w " .. shortName .. " ", DEFAULT_CHAT_FRAME)
                    end)
                    rootDescription:CreateButton("레이드/파티 초대", function()
                        if _combatBlockedNotice("초대를") then return end
                        C_PartyInfo.InviteUnit(shortName)
                    end)
                    -- UnitName 은 secret-taintable → pcall 로 보호
                    for ri = 1, GetNumGroupMembers() do
                        local ok, n = pcall(UnitName, "raid" .. ri)
                        if ok and n == shortName then
                            local unitId = "raid" .. ri
                            rootDescription:CreateButton("거래 신청", function()
                                if _combatBlockedNotice("거래를") then return end
                                InitiateTrade(unitId)
                            end)
                            break
                        end
                    end
                end
            end)
        end
    end)

    row.icon       = icon
    row.stateIcon  = stateIcon
    row.nameText   = nameText
    row.winnerText = winnerText
    row.bidText    = bidText
    row.paidText   = paidText
    row.tipBtn     = tipBtn

    -- 보스 구분선 레이블 (separator 모드에서만 표시)
    local dividerLabel = row:CreateFontString(nil, "OVERLAY")
    dividerLabel:SetFont(FONT, 10)
    dividerLabel:SetTextColor(0.55, 0.55, 0.55)
    dividerLabel:SetAllPoints()
    dividerLabel:SetJustifyH("CENTER")
    dividerLabel:SetJustifyV("MIDDLE")
    dividerLabel:Hide()
    row.dividerLabel = dividerLabel

    logRows[i] = row
    return row
end




local function refreshLogPanel()
    local log = MR.TradeLog

    -- TradeLog 엔트리에 저장된 bossName 폴백 테이블 구성
    -- ItemList.Clear() 이후에도 판매완료 탭에서 보스 이름 유지
    local bossNameFromLog = {}
    for _, e in ipairs(log) do
        local g = e.bossGroup
        if g and g > 0 and e.bossName and not bossNameFromLog[g] then
            bossNameFromLog[g] = e.bossName
        end
    end

    -- 보스 그룹별로 묶어서 displayList 빌드 (B안)
    -- audit entry ([거래완료]/[거래취소]) 는 디버깅용 — MR.cfg.debugMode=true 일 때만 표시.
    -- 표시될 때도 일반 낙찰 entry 처럼 컬럼별로 분리 (구매자/받은골드/보낸골드).
    local showAudit = MR.cfg and MR.cfg.debugMode
    local groups = {}
    for idx, entry in ipairs(log) do
        local hide = (entry.tradeAuditType ~= nil) and not showAudit
        if not hide then
            local g = entry.bossGroup or 0
            groups[g] = groups[g] or {}
            table.insert(groups[g], { entry = entry, index = idx })
        end
    end
    local keys = {}
    for k in pairs(groups) do table.insert(keys, k) end
    table.sort(keys)
    local displayList = {}
    for _, g in ipairs(keys) do
        if g > 0 then
            table.insert(displayList, { isSeparator = true, bossGroup = g })
        end
        for _, it in ipairs(groups[g]) do
            table.insert(displayList, it)
        end
    end

    local rowCount = math.max(#displayList, #logRows)
    for i = 1, rowCount do
        local item = displayList[i]
        local row
        if item then
            row = createLogRow(i)
        else
            row = logRows[i]
        end

        if item and item.isSeparator then
            row:Show()
            row.icon:Hide()
            row.stateIcon:Hide()
            row.nameText:Hide()
            row.winnerText:Hide()
            row.bidText:Hide()
            row.paidText:Hide()
            if row.tipBtn then row.tipBtn:Hide() end
            row.dividerLabel:SetText(string.format(
                "────────── %s ──────────",
                (MR.ItemList.bossNames and MR.ItemList.bossNames[item.bossGroup])
                    or bossNameFromLog[item.bossGroup]
                    or (item.bossGroup .. "보스")))
            row.dividerLabel:Show()
        elseif item then
            local entry = item.entry
            row:Show()
            row.icon:Show()
            row.stateIcon:Show()
            row.nameText:Show()
            row.winnerText:Show()
            row.bidText:Show()
            row.paidText:Show()
            if row.tipBtn then row.tipBtn:Show() end
            row.dividerLabel:Hide()

            row._itemLink   = entry.itemLink
            row._winnerName = entry.winner
            row._logIndex   = item.index
            -- winnerText: row 재사용 시 위 audit row 의 영향이 남지 않도록 매번 폰트/색 명시.
            -- (audit/normal 분기에서 다른 SetText 만 호출하던 코드 → 시각적 폰트 차이 보고 대응)
            row.winnerText:SetFont(FONT, 13)
            row.winnerText:SetTextColor(1, 1, 1)
            row.winnerText:SetText(entry.winner or "")

            if entry.tradeAuditType then
                -- ── audit entry (디버그 모드 표시): 컬럼별 분리 ─────────────
                -- 아이콘: ◆ 마커 (audit 표시), 상태: 라벨, 아이템명: 라벨+아이템요약,
                -- 구매자: 거래대상, 판매금액: 받은골드, 실제받은금액: 보낸골드
                row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                row.icon:SetVertexColor(0.5, 0.7, 1.0)   -- 파란 톤 (audit 구분)
                local isCancel = (entry.tradeAuditType == "cancelled")
                -- 한글 와우 폰트(2002.TTF)가 ✕(U+2715)/✓ 등을 □로 렌더링 → 한글 2글자 라벨.
                row.stateIcon:SetText(isCancel and "|cff888888취소|r" or "|cff66aaff완료|r")

                -- itemName 컬럼: 아이템 요약만 (상태는 좌측 stateIcon "완/취" 로 표시).
                local recv = entry.tradeReceivedItems or {}
                local sent = entry.tradeSentItems or {}
                local itemSummary
                if #recv == 0 and #sent == 0 then
                    itemSummary = "|cff888888(골드만)|r"
                else
                    local first = (recv[1] and recv[1].link) or (sent[1] and sent[1].link)
                    local more  = (#recv + #sent) - 1
                    local cntTag = ""
                    if first and recv[1] and (recv[1].count or 1) > 1 then
                        cntTag = "x" .. recv[1].count
                    elseif first and sent[1] and (sent[1].count or 1) > 1 then
                        cntTag = "x" .. sent[1].count
                    end
                    itemSummary = (first or "?") .. cntTag
                    if more > 0 then itemSummary = itemSummary .. " 외 " .. more .. "개" end
                end
                row.nameText:SetText(itemSummary)

                -- 판매금액 = 받은 골드 / 실제받은금액 = 보낸 골드
                local recvG = math.floor((entry.tradeReceivedCopper or 0) / 10000)
                local sentG = math.floor((entry.tradeSentCopper     or 0) / 10000)
                if recvG > 0 then
                    row.bidText:SetText("|cff44ff44+" .. MR.FormatGold(recvG) .. "|r")
                else
                    row.bidText:SetText("|cff555555-|r")
                end
                if sentG > 0 then
                    row.paidText:SetText("|cffff8844-" .. MR.FormatGold(sentG) .. "|r")
                else
                    row.paidText:SetText("|cff555555-|r")
                end
            else
                -- ── 일반 낙찰 entry ─────────────────────────────────────────
                row.icon:SetVertexColor(1, 1, 1)   -- 색조 리셋 (audit 이후 일반 행 영향 방지)
                row.icon:SetTexture(entry.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
                -- "[골드 거래] 닉네임" → "[골드 거래]" 만 표시 (구매자 컬럼에 닉네임 이미 있음).
                -- 옛 SavedVariables 호환을 위해 표시 시점에 trim.
                local isGoldOnly = entry.itemName
                    and type(entry.itemName) == "string"
                    and entry.itemName:find("^%[골드 거래%]")
                if isGoldOnly then
                    row.nameText:SetText("|cffaaaaaa[골드 거래]|r")
                else
                    row.nameText:SetText(entry.itemName)
                end
                local paid = entry.paidGold or 0
                local bid  = entry.bid or 0
                -- 골드 거래는 "낙찰가" 개념이 없으므로 판매금액 컬럼 비움 (받은 금액만 표시).
                if isGoldOnly then
                    row.bidText:SetText("|cff555555-|r")
                else
                    row.bidText:SetText("|cffFFCC00" .. MR.FormatGold(bid) .. "|r")
                end
                if entry.state == MR.TRADE_STATE.DONE then
                    -- 한글 라벨 통일: 완납/부분납/미납 + audit 의 완료/취소
                    row.stateIcon:SetText("|cff44ff44완납|r")
                    if paid > bid and not isGoldOnly then
                        row.paidText:SetText("|cffff8844" .. MR.FormatGold(paid) .. "|r")
                    else
                        row.paidText:SetText("|cff44ff44" .. MR.FormatGold(paid) .. "|r")
                    end
                elseif entry.state == MR.TRADE_STATE.PARTIAL then
                    row.stateIcon:SetText("|cffffaa00부분납|r")
                    row.paidText:SetText("|cffff4444" .. MR.FormatGold(paid) .. "|r")
                else
                    row.stateIcon:SetText("|cff888888미납|r")
                    row.paidText:SetText("|cff888888-|r")
                end
            end
        elseif row then
            row:Hide()
        end
    end
    logChild:SetHeight(math.max(LOG_ROW_H * #displayList, 1))
end

--------------------------------------------------------------------------------
-- [정산] 패널 = MR.SettlePanel
-- 공대장 수납 총 골드 표시 + 분배 계산 + 보고
--------------------------------------------------------------------------------
local SP = MR.SettlePanel

--------------------------------------------------------------------------------
-- 안팔린 아이템 경고 배너 (FailedItems > 0 일 때 패널 최상단에 빨간 띠)
-- 분배 전 안팔린 아이템 누락 방지 — 시각 + EditBox 포커스 시 사운드 + 채팅 알림.
--------------------------------------------------------------------------------
local failedBanner = CreateFrame("Frame", nil, SP, "BackdropTemplate")
failedBanner:SetHeight(22)
failedBanner:SetPoint("TOPLEFT",  SP, "TOPLEFT",  4, -2)
failedBanner:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -4, -2)
failedBanner:SetFrameLevel(SP:GetFrameLevel() + 10)
applyBackdrop(failedBanner, MR.BACKDROP_DARK, 0.35, 0.05, 0.05, 0.97, 1, 0.4, 0.4, 1)

local failedBannerText = failedBanner:CreateFontString(nil, "OVERLAY")
failedBannerText:SetFont(FONT, 12, "OUTLINE")
failedBannerText:SetTextColor(1, 0.9, 0.9)
failedBannerText:SetPoint("CENTER", failedBanner, "CENTER", 0, 0)
failedBanner:Hide()

local function refreshFailedBanner()
    local n = MR.FailedItems and #MR.FailedItems or 0
    if n > 0 then
        failedBannerText:SetText(string.format(
            "[경고] 안팔린 아이템 %d개가 남아있습니다. 처리 후 분배하세요!", n))
        failedBanner:Show()
    else
        failedBanner:Hide()
    end
end

-- 안팔린 아이템 경고 팝업 (분배 EditBox 포커스 시 1회 표시)
StaticPopupDialogs["MIMRAID_FAILED_ITEMS_WARN"] = {
    text         = "안팔린 아이템 %d개가 남아있습니다.\n\n분배 전에 [안팔린 아이템] 탭에서 처리했는지 확인하세요.",
    button1      = "확인",
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- 알림 스로틀링: 같은 탭 방문 동안 한 번만. 다른 탭 갔다 오면(OnShow) 리셋.
-- 안팔린 아이템 0 되면 (다 처리됨) → 다음 발생 시 다시 알림 가능.
local _alertedThisVisit = false

if MR.FailedItems and MR.FailedItems.OnChange then
    MR.FailedItems.OnChange(function()
        refreshFailedBanner()
        if (MR.FailedItems and #MR.FailedItems or 0) == 0 then
            _alertedThisVisit = false
        end
    end)
end
SP:HookScript("OnShow", function()
    refreshFailedBanner()
    _alertedThisVisit = false   -- 탭 새로 진입할 때마다 알림 가능 상태로
end)
MR.RefreshFailedBanner = refreshFailedBanner

-- EditBox 포커스 시 호출 — 이번 탭 방문 첫 알림에서만 팝업/사운드/채팅 발사.
-- 이후 EditBox 다시 클릭해도 무반응 (스팸 방지). 다른 탭 갔다 오면 다시 1회 발사.
local function alertFailedItemsIfAny()
    local n = MR.FailedItems and #MR.FailedItems or 0
    if n <= 0 then return end
    if _alertedThisVisit then return end
    _alertedThisVisit = true

    StaticPopup_Show("MIMRAID_FAILED_ITEMS_WARN", n)
    MR.Print(string.format(
        "[경고] 안팔린 아이템 %d개. 분배 전 [안팔린 아이템] 탭에서 확인하세요!", n),
        MR.COLOR.red)
    if MR.cfg and MR.cfg.soundFailedAlert then
        pcall(PlaySoundFile, MR.cfg.soundFailedAlert, "Master")
    end
end
MR.AlertFailedItemsIfAny = alertFailedItemsIfAny

-- ── 섹션 1: 수납 총 골드 ─────────────────────────────────────────────────────
local totalGoldLabel = SP:CreateFontString(nil, "OVERLAY")
totalGoldLabel:SetFont(FONT, 16)
totalGoldLabel:SetTextColor(0.8, 0.8, 0.8)
totalGoldLabel:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, -8)
totalGoldLabel:SetText("아이템 판매 전체 골드:")

local totalGoldText = SP:CreateFontString(nil, "OVERLAY")
totalGoldText:SetFont(FONT, 22)
totalGoldText:SetTextColor(GOLD_C.r, GOLD_C.g, GOLD_C.b)
totalGoldText:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, -32)
totalGoldText:SetText("0골 |cff44ff44(자동계산)|r")

local varianceText = SP:CreateFontString(nil, "OVERLAY")
varianceText:SetFont(FONT, 11)
varianceText:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, -64)
varianceText:SetText("")

-- ── T-Raid 식 검증 (수령 - 송금 = 순수익) ────────────────────────────────
-- 모든 거래의 raw copper 값(tradeAuditType="complete") 을 합산해 좌측 의미분류 합과 비교.
-- 차이 발생 시 누락 의심 → 즉시 가시 경고. 섹션 1 우측 빈 공간에 컴팩트 배치.
local tradeAuditTitle = SP:CreateFontString(nil, "OVERLAY")
tradeAuditTitle:SetFont(FONT, 11)
tradeAuditTitle:SetTextColor(0.6, 0.85, 1.0)
tradeAuditTitle:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -8, -8)
tradeAuditTitle:SetText("T-Raid 식 검증")

local tradeAuditText = SP:CreateFontString(nil, "OVERLAY")
tradeAuditText:SetFont(FONT, 11)
tradeAuditText:SetTextColor(0.9, 0.9, 0.9)
tradeAuditText:SetJustifyH("RIGHT")
tradeAuditText:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -8, -22)
tradeAuditText:SetWidth(200)
tradeAuditText:SetSpacing(2)
tradeAuditText:SetText("(거래 기록 없음)")

createDivider(SP, -84)

-- ── 섹션 2: 총 골드 조정 금액 ────────────────────────────────────────────────
local adjustDesc = SP:CreateFontString(nil, "OVERLAY")
adjustDesc:SetFont(FONT, 12)
adjustDesc:SetTextColor(0.7, 0.7, 0.7)
adjustDesc:SetPoint("TOPLEFT",  SP, "TOPLEFT",  6, -94)
adjustDesc:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -6, -94)
adjustDesc:SetJustifyH("LEFT")
adjustDesc:SetText("영약/음식 등 지출 제외, 분배 골드 끝자리 맞추기 등 조정이 필요한 경우\n아래칸에 입력하세요. (마이너스 입력가능)")

local adjustLabel = SP:CreateFontString(nil, "OVERLAY")
adjustLabel:SetFont(FONT, 11)
adjustLabel:SetTextColor(1, 1, 1)
adjustLabel:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, -136)
adjustLabel:SetText("골드 조정 금액")

local adjustBox = CreateFrame("EditBox", "MimRaidAdjustBox", SP, "InputBoxTemplate")
adjustBox:SetSize(110, 20)
adjustBox:SetPoint("LEFT", adjustLabel, "RIGHT", 8, 0)
adjustBox:SetAutoFocus(false)
adjustBox:SetMaxLetters(10)

local adjustUnit = SP:CreateFontString(nil, "OVERLAY")
adjustUnit:SetFont(FONT, 11)
adjustUnit:SetTextColor(0.8, 0.8, 0.8)
adjustUnit:SetPoint("LEFT", adjustBox, "RIGHT", 4, 0)
adjustUnit:SetText("골드")

createDivider(SP, -166)

-- ── 섹션 3: 분배 인원 ────────────────────────────────────────────────────────
local memberDesc = SP:CreateFontString(nil, "OVERLAY")
memberDesc:SetFont(FONT, 12)
memberDesc:SetTextColor(0.7, 0.7, 0.7)
memberDesc:SetPoint("TOPLEFT",  SP, "TOPLEFT",  6, -176)
memberDesc:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -6, -176)
memberDesc:SetJustifyH("LEFT")
memberDesc:SetText("분배에 참여할 공대 인원수를 입력하세요. (기본값: 현재 공대 인원)")

local memberLabel = SP:CreateFontString(nil, "OVERLAY")
memberLabel:SetFont(FONT, 11)
memberLabel:SetTextColor(1, 1, 1)
memberLabel:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, -204)
memberLabel:SetText("분배 인원")

local memberBox = CreateFrame("EditBox", "MimRaidMemberBox", SP, "InputBoxTemplate")
memberBox:SetSize(60, 20)
memberBox:SetPoint("LEFT", memberLabel, "RIGHT", 8, 0)
memberBox:SetAutoFocus(false)
memberBox:SetMaxLetters(3)
memberBox:SetNumeric(true)
-- 최초 기본값: 1 (OnTextChanged 후크 설정 전에 미리 세팅 → 저장 트리거 안 됨).
-- LoadSettleAdjust 가 저장된 값이 있으면 덮어씀.
memberBox:SetText("1")

local memberUnit = SP:CreateFontString(nil, "OVERLAY")
memberUnit:SetFont(FONT, 11)
memberUnit:SetTextColor(0.8, 0.8, 0.8)
memberUnit:SetPoint("LEFT", memberBox, "RIGHT", 4, 0)
memberUnit:SetText("명")

-- ── 끝자리 정리 (1인당을 천 단위로 올림/내림) ────────────────────────────
-- 골드 조정 금액 영역 오른쪽에 statusFs + 3 버튼 배치 (우측 정렬).
-- adjustBox 는 건드리지 않음. 내부 상태 _settleRpp 가 1인당 값을 직접 보유 (천 단위 클린).
-- 올리기: 1인당을 다음 천 단위로 +1000. 내리기: -1000. 기본: 자연값으로 초기화.
-- statusFs 는 effectiveGold 와 (perPerson × members) 의 차이로 공대장 부담 표시.
local _settleRpp = nil   -- nil = 자연값 사용

local function _adjustRpp(direction)
    -- direction: -1 = 내리기, 0 = 기본(자연값 복원), +1 = 올리기
    if direction == 0 then
        _settleRpp = nil
    else
        local members = tonumber(memberBox:GetText()) or 0
        if members <= 0 then return end

        local bidTotal = 0
        if MR.TradeLog and MR.TRADE_STATE then
            for _, entry in ipairs(MR.TradeLog) do
                if entry.state == MR.TRADE_STATE.DONE
                    or entry.state == MR.TRADE_STATE.PARTIAL then
                    bidTotal = bidTotal + (entry.bid or 0)
                end
            end
        end

        local currentAdjust = tonumber(adjustBox:GetText()) or 0
        local effectiveGold = bidTotal + currentAdjust
        if effectiveGold <= 0 then return end

        local natural = math.floor(effectiveGold / members)
        local current = _settleRpp or natural

        if direction < 0 then
            _settleRpp = math.floor((current - 1) / 1000) * 1000
        else
            _settleRpp = math.ceil((current + 1) / 1000) * 1000
        end
        if _settleRpp < 0 then _settleRpp = 0 end
    end
    -- 영속성: 캐릭터별 SavedVariables 에 저장 (리로드 후 복원)
    if MR.GetCharData then
        local cdata = MR.GetCharData()
        cdata.settleRpp = _settleRpp
    end
    if MR.RefreshSettlePanel then MR.RefreshSettlePanel() end
end

-- 상태 표시 (statusFs): 버튼 위쪽, adjustDesc 의 우측 빈 공간에 배치
local statusFs = SP:CreateFontString(nil, "OVERLAY")
statusFs:SetFont(FONT, 12)
statusFs:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -8, -118)
statusFs:SetWidth(200)
statusFs:SetJustifyH("RIGHT")
statusFs:SetWordWrap(false)
statusFs:SetText("")

local function _makeRppBtn(label, direction, anchorTo)
    local btn = CreateFrame("Button", nil, SP, "UIPanelButtonTemplate")
    btn:SetSize(52, 20)
    if anchorTo then
        btn:SetPoint("RIGHT", anchorTo, "LEFT", -2, 0)
    else
        btn:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -8, -136)
    end
    btn:SetText(label)
    local fs = btn:GetFontString()
    if fs then fs:SetFont(FONT, 11) end
    btn:SetScript("OnClick", function() _adjustRpp(direction) end)
    return btn
end

-- 우측 정렬: 내리기 (가장 오른쪽) ← 기본 ← 올리기 (가장 왼쪽)
local btnDown  = _makeRppBtn("내리기", -1, nil)
local btnReset = _makeRppBtn("기본",    0, btnDown)
local btnUp    = _makeRppBtn("올리기", 1, btnReset)

-- refreshSettlePanel 에서 접근하기 위해 노출
MR._settleStatusFs = statusFs
MR._settleGetRpp   = function() return _settleRpp end

createDivider(SP, -234)

-- 한글 숫자 읽기 (1750000 → "백칠십오만"). 분배금은 보통 999만 이하지만 억/조까지 지원.
-- BIG 단위(만/억/조/경)는 노란색 색상코드로 감싸 가독성 향상.
local function koreanNumber(n)
    n = math.floor(tonumber(n) or 0)
    if n == 0 then return "영" end
    local negative = n < 0
    if negative then n = -n end
    local DIG = { [0] = "", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구" }
    local BIG = { [0] = "", "만", "억", "조", "경" }
    local BIG_CLR_L, BIG_CLR_R = "|cffffd100", "|r"
    local function chunkStr(c)
        local s  = ""
        local d3 = math.floor(c / 1000) % 10
        local d2 = math.floor(c / 100)  % 10
        local d1 = math.floor(c / 10)   % 10
        local d0 = c % 10
        if d3 > 0 then s = s .. ((d3 == 1) and "" or DIG[d3]) .. "천" end
        if d2 > 0 then s = s .. ((d2 == 1) and "" or DIG[d2]) .. "백" end
        if d1 > 0 then s = s .. ((d1 == 1) and "" or DIG[d1]) .. "십" end
        if d0 > 0 then s = s .. DIG[d0] end
        return s
    end
    local parts, idx = {}, 0
    while n > 0 do
        local chunk = n % 10000
        n = math.floor(n / 10000)
        if chunk > 0 then
            local s = chunkStr(chunk)
            if idx == 1 and s == "일" then s = "" end  -- 일만 → 만
            if idx >= 1 then
                s = s .. BIG_CLR_L .. BIG[idx] .. BIG_CLR_R
            end
            table.insert(parts, 1, s)
        end
        idx = idx + 1
    end
    local r = table.concat(parts, " ")
    return negative and ("마이너스 " .. r) or r
end

-- ── 섹션 4: 분배 결과 (N인당 분배골드, 1~5행) ──────────────────────────────
-- 각 행: [라벨] [EditBox] [골드] [(한글발음)]  — 라벨과 숫자 가까이 붙임.
-- EditBox: 읽기 전용, 클릭 시 포커스+전체선택. Ctrl+C 로 복사 → 거래창 Ctrl+V.
-- 행 사이 구분선. 모든 행 동일 크기.
-- 한글 폭: "구백구십구만 구천구백구십구골드" = 최장 16자 → 13pt에서 ~210px 확보.
local settleBoxes   = {}   -- [n] = { eb, kor }
local SETTLE_ROW_H  = 24
local SETTLE_ROW_GAP = 8
local SETTLE_START_Y = -246

for n = 1, 5 do
    local y       = SETTLE_START_Y - (n - 1) * (SETTLE_ROW_H + SETTLE_ROW_GAP)
    local labelPx = 15
    local valuePx = 17
    local unitPx  = 14
    local korPx   = 11    -- "이천사백구십구만 구천구백구십오 골드" (최장 ~18자) 안 짤리도록
    local boxW    = 140   -- 최대 "49,950,000" 수준까지 대비 (999만 × N캐릭 분배)
    local korW    = 260   -- 최장 한글 발음 + " 골드" 공간 확보

    -- 라벨
    local lb = SP:CreateFontString(nil, "OVERLAY")
    lb:SetFont(FONT, labelPx)
    lb:SetTextColor(0.85, 0.85, 0.85)
    lb:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, y - math.floor((SETTLE_ROW_H - labelPx) / 2))
    lb:SetText(string.format("%d인당 분배 골드:", n))

    -- EditBox (라벨 바로 오른쪽)
    local eb = CreateFrame("EditBox", nil, SP, "BackdropTemplate")
    eb:SetAutoFocus(false)
    eb:SetTextInsets(4, 4, 2, 2)
    eb:SetJustifyH("RIGHT")
    eb:SetSize(boxW, SETTLE_ROW_H - 2)
    eb:SetPoint("LEFT", lb, "RIGHT", 6, 0)
    applyBackdrop(eb, MR.BACKDROP_DARK, 0.05, 0.05, 0.03, 0.9, 0.5, 0.4, 0.2, 1)
    local ebFont = CreateFont("MimRaidSettleBoxFont" .. n)
    ebFont:SetFont(FONT, valuePx, "")
    ebFont:SetTextColor(1, 0.85, 0.2)
    eb:SetFontObject(ebFont)
    eb:SetText("0")
    eb._mrValue = "0"
    eb:SetScript("OnTextChanged", function(self, userChanged)
        if userChanged then self:SetText(self._mrValue or "0") end
    end)
    eb:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
        alertFailedItemsIfAny()  -- 안팔린 아이템 있으면 채팅 + 사운드 경고
    end)
    eb:SetScript("OnEscapePressed",   function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed",    function(self) self:ClearFocus() end)
    eb:SetScript("OnMouseDown", function(self)
        self:SetFocus()
        self:HighlightText()
    end)

    -- "골드" 단위 (EditBox 오른쪽)
    local unit = SP:CreateFontString(nil, "OVERLAY")
    unit:SetFont(FONT, unitPx)
    unit:SetTextColor(GOLD_C.r, GOLD_C.g, GOLD_C.b)
    unit:SetPoint("LEFT", eb, "RIGHT", 4, 0)
    unit:SetText("골드")

    -- 한글 발음 (골드 오른쪽, 고정폭 확보)
    local kor = SP:CreateFontString(nil, "OVERLAY")
    kor:SetFont(FONT, korPx)
    kor:SetTextColor(0.65, 0.65, 0.65)
    kor:SetPoint("LEFT", unit, "RIGHT", 6, 0)
    kor:SetWidth(korW)
    kor:SetJustifyH("LEFT")
    kor:SetWordWrap(false)
    kor:SetText("")

    -- 행 사이 구분선 (n >= 2 → 이 행 위쪽에 구분선)
    if n >= 2 then
        createDivider(SP, y + math.floor(SETTLE_ROW_GAP / 2))
    end

    settleBoxes[n] = { eb = eb, kor = kor }
end

-- 5인당 행 아래 "분배 골드 최종" 요약 EditBox (복사해서 레이드 채팅에 붙여넣기)
local _settleSummaryBottomY
do
    local lastY = SETTLE_START_Y - 4 * (SETTLE_ROW_H + SETTLE_ROW_GAP) - SETTLE_ROW_H
    local y = lastY - 12
    local lb = SP:CreateFontString(nil, "OVERLAY")
    lb:SetFont(FONT, 13)
    lb:SetTextColor(0.85, 0.85, 0.85)
    lb:SetPoint("TOPLEFT", SP, "TOPLEFT", 6, y - 4)
    lb:SetText("분배 골드 최종:")

    local eb = CreateFrame("EditBox", nil, SP, "BackdropTemplate")
    eb:SetAutoFocus(false)
    eb:SetTextInsets(6, 4, 2, 2)
    eb:SetJustifyH("LEFT")
    eb:SetHeight(SETTLE_ROW_H - 2)
    eb:SetPoint("LEFT", lb, "RIGHT", 6, 0)
    eb:SetPoint("RIGHT", SP, "RIGHT", -6, 0)
    applyBackdrop(eb, MR.BACKDROP_DARK, 0.05, 0.05, 0.03, 0.9, 0.5, 0.4, 0.2, 1)
    local ebFont = CreateFont("MimRaidSummaryBoxFont")
    ebFont:SetFont(FONT, 13, "")
    ebFont:SetTextColor(1, 0.85, 0.2)
    eb:SetFontObject(ebFont)
    eb:SetText("")
    eb._mrValue = ""
    eb:SetScript("OnTextChanged", function(self, userChanged)
        if userChanged then self:SetText(self._mrValue or "") end
    end)
    eb:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
        alertFailedItemsIfAny()   -- 안팔린 아이템 있으면 채팅 + 사운드 + 팝업 경고
    end)
    eb:SetScript("OnEscapePressed",   function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed",    function(self) self:ClearFocus() end)
    eb:SetScript("OnMouseDown", function(self)
        self:SetFocus()
        self:HighlightText()
    end)
    settleBoxes.summary = eb
    _settleSummaryBottomY = y - SETTLE_ROW_H - 4
end

-- 요약 박스 아래 경고 문구 (한 줄)
do
    local hint = SP:CreateFontString(nil, "OVERLAY")
    hint:SetFont(FONT, 12)
    hint:SetTextColor(1.0, 0.55, 0.25)   -- 주황색
    hint:SetPoint("TOPLEFT",  SP, "TOPLEFT",   6, _settleSummaryBottomY - 6)
    hint:SetPoint("TOPRIGHT", SP, "TOPRIGHT", -6, _settleSummaryBottomY - 6)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(false)
    hint:SetText("※ 분배 골드 숫자 박스 클릭시 안팔린 아이템 체크됩니다. 다른 탭 갔다오면 초기화됩니다.")
end

-- 마지막 계산값 보관 (거래시 자동 파티 분배금 입력용)
local lastSettlement = nil
function MR.GetSettlement() return lastSettlement end

-- ── 정산 자동 갱신 ──────────────────────────────────────────────────────────
local function refreshSettlePanel()
    if not memberBox then return end
    -- 현재 세션 시작 시간 (RaidTimer 미시작이면 nil → 전체 합산 폴백)
    local sessionStart = MR.RaidTimer and MR.RaidTimer.startTime
    local bidTotal  = 0
    local paidTotal = 0
    for _, entry in ipairs(MR.TradeLog) do
        if entry.state == MR.TRADE_STATE.DONE or entry.state == MR.TRADE_STATE.PARTIAL then
            -- 세션 시작 후 거래만 합산 (옛 세션 잔재 제외)
            if not sessionStart or (entry.timestamp and entry.timestamp >= sessionStart) then
                bidTotal  = bidTotal  + (entry.bid      or 0)
                paidTotal = paidTotal + (entry.paidGold or 0)
            end
        end
    end

    local adjustVal     = tonumber(adjustBox:GetText()) or 0
    local effectiveGold = bidTotal + adjustVal

    local adjustTag = " |cff44ff44(자동계산)|r"
    if adjustVal > 0 then
        adjustTag = string.format(" |cff44ff44(+%d골 조정)|r", adjustVal)
    elseif adjustVal < 0 then
        adjustTag = string.format(" |cffff8800(%d골 조정)|r", adjustVal)
    end
    totalGoldText:SetText(MR.FormatGold(effectiveGold) .. adjustTag)

    -- 오차 표시 (낙찰금액 기준 vs 실제 받은 금액)
    local variance = paidTotal - bidTotal
    if variance == 0 then
        varianceText:SetText("")
    elseif variance > 0 then
        varianceText:SetText(string.format(
            "|cffff8800실제금액 오차: +%s  판매완료 탭을 확인해주세요.|r",
            MR.FormatGold(variance)))
    else
        varianceText:SetText(string.format(
            "|cffff4444실제금액 오차: %s  판매완료 탭을 확인해주세요.|r",
            MR.FormatGold(variance)))
    end

    -- T-Raid 식 검증: 거래 단위 raw copper 합산 (의미분류 무관)
    --   수령 합계  = Σ tradeReceivedCopper (complete audit entry, 세션 필터)
    --   송금 합계  = Σ tradeSentCopper
    --   순 수익    = 수령 - 송금  (= 의미분류 paidTotal 과 일치해야 정합)
    --   차이       = 순수익 - paidTotal  (0 이면 정합, 아니면 누락 의심)
    local receivedCopper, sentCopper = 0, 0
    local auditCount = 0
    for _, entry in ipairs(MR.TradeLog) do
        if entry.tradeAuditType == "complete" then
            if not sessionStart or (entry.timestamp and entry.timestamp >= sessionStart) then
                receivedCopper = receivedCopper + (entry.tradeReceivedCopper or 0)
                sentCopper     = sentCopper     + (entry.tradeSentCopper     or 0)
                auditCount     = auditCount + 1
            end
        end
    end
    if auditCount == 0 then
        tradeAuditText:SetText("|cff888888(거래 기록 없음)|r")
    else
        local receivedG = math.floor(receivedCopper / 10000)
        local sentG     = math.floor(sentCopper / 10000)
        local netG      = receivedG - sentG   -- 표시는 안 함, 차이 계산용
        local diff      = netG - paidTotal
        local lines = {
            string.format("|cffaaaaaa받은 골드:|r %s", MR.FormatGold(receivedG)),
            string.format("|cffaaaaaa준 골드:|r %s",   MR.FormatGold(sentG)),
        }
        if diff == 0 then
            table.insert(lines, "|cff44ff44정합 OK|r")
        else
            table.insert(lines, string.format(
                "|cffff4444차이: %s 누락 의심|r", MR.FormatGold(diff)))
        end
        tradeAuditText:SetText(table.concat(lines, "\n"))
    end

    -- 분배 계산 (1~5인당 EditBox + 한글 발음 업데이트)
    -- 끝자리 정리 버튼이 클릭됐으면 _settleRpp 가 1인당 값을 직접 지정 (천 단위 클린).
    -- 아니면 자연값 (floor(effectiveGold / members)).
    local members     = tonumber(memberBox:GetText()) or 0
    local natural     = (members > 0) and math.floor(effectiveGold / members) or 0
    local rppOverride = MR._settleGetRpp and MR._settleGetRpp() or nil
    local perPerson   = rppOverride or natural

    for n = 1, 5 do
        local v = perPerson * n
        local s = tostring(v)
        local row = settleBoxes[n]
        if row then
            row.eb._mrValue = s
            row.eb:SetText(s)
            row.kor:SetText(v > 0 and ("(" .. koreanNumber(v) .. " |cffffd100골드|r)") or "")
        end
    end

    -- 공통 콤마 포맷 헬퍼
    local function withCommas(n)
        local s = tostring(math.floor(n))
        local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (r:gsub("^,", ""))
    end

    -- 공대 공지용 한 줄 요약
    if settleBoxes.summary then
        local text = string.format("1인당 %s 골드, 파티당 %s 골드 입니다.",
            withCommas(perPerson), withCommas(perPerson * 5))
        settleBoxes.summary._mrValue = text
        settleBoxes.summary:SetText(text)
    end

    -- 끝자리 정리 상태 표시 (statusFs): 공대장의 추가 부담 / 회수 금액
    if MR._settleStatusFs then
        if rppOverride and members > 0 then
            local delta = effectiveGold - perPerson * members
            if delta > 0 then
                MR._settleStatusFs:SetText(string.format(
                    "|cff44ff44[남는 금액]|r %s 골", withCommas(delta)))
            elseif delta < 0 then
                MR._settleStatusFs:SetText(string.format(
                    "|cffff8800[공대장 추가]|r %s 골", withCommas(-delta)))
            else
                MR._settleStatusFs:SetText("|cff888888정확히 맞음|r")
            end
        else
            MR._settleStatusFs:SetText("")
        end
    end

    lastSettlement = {
        totalGold   = effectiveGold,
        memberCount = members,
        perPerson   = perPerson,
    }

    -- 자동 저장: 거래/정산이 바뀔 때마다 현재 세션 레코드 덮어쓰기
    if MR.RaidHistory and MR.RaidHistory.UpsertCurrent then
        MR.RaidHistory.UpsertCurrent(members, effectiveGold, perPerson)
    end
end

MR.RefreshSettlePanel = refreshSettlePanel

-- 분배 인원은 100% 수동. 자동 채움 (초기/로스터 변경) 없음 → 사용자가 명시한 값만 유지.
memberBox:SetScript("OnTextChanged", function(self)
    -- 영속성: 모든 변경을 저장 (리로드/재시작 후에도 그대로)
    if MR.GetCharData then
        local cdata = MR.GetCharData()
        cdata.settleMembers = tonumber(self:GetText()) or 0
    end
    refreshSettlePanel()
end)
memberBox:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
memberBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

adjustBox:SetScript("OnEnterPressed",  function(self)
    self:ClearFocus()
    refreshSettlePanel()
    if memberBox then memberBox:SetFocus() end
end)
adjustBox:SetScript("OnTabPressed", function()
    if memberBox then memberBox:SetFocus() end
end)
adjustBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
adjustBox:SetScript("OnTextChanged", function(self)
    -- 영속성: 변경된 값을 캐릭터별 SavedVariables 에 저장 (리로드 후 복원)
    if MR.GetCharData then
        local cdata = MR.GetCharData()
        cdata.settleAdjust = tonumber(self:GetText()) or 0
    end
    refreshSettlePanel()
end)

-- ADDON_LOADED 에서 호출 → 저장된 골드 조정 금액 + 분배 인원 + 끝자리 정리 상태 복원
function MR.LoadSettleAdjust()
    if not MR.GetCharData then return end
    local cdata = MR.GetCharData()
    if cdata.settleAdjust and cdata.settleAdjust ~= 0 then
        adjustBox:SetText(tostring(cdata.settleAdjust))
    end
    if cdata.settleMembers and cdata.settleMembers > 0 then
        memberBox:SetText(tostring(cdata.settleMembers))
    end
    if cdata.settleRpp then
        _settleRpp = cdata.settleRpp
    end
    if MR.RefreshSettlePanel then MR.RefreshSettlePanel() end
end

-- 골드 분배 탭의 수동 입력값 (조정 금액 / 분배 인원 / 끝자리 정리) 모두 초기화.
-- MIMRAID_RESET_CONFIRM 팝업의 OnAccept 에서 호출됨 (레이드 초기화 시 함께 비우기).
-- 모든 단계 pcall 로 보호 — 한 부분 실패해도 나머지 진행.
function MR.ResetSettleInputs()
    if MR.GetCharData then
        local ok, cdata = pcall(MR.GetCharData)
        if ok and cdata then
            cdata.settleMembers = nil
            cdata.settleAdjust  = nil
            cdata.settleRpp     = nil
        end
    end
    _settleRpp = nil
    pcall(function() if adjustBox then adjustBox:SetText("") end end)
    pcall(function() if memberBox then memberBox:SetText("1") end end)
    if MR.RefreshSettlePanel then pcall(MR.RefreshSettlePanel) end
end

--------------------------------------------------------------------------------
-- [안팔린 아이템] 패널 = MR.FailedPanel
--------------------------------------------------------------------------------
local FP = MR.FailedPanel
local FAILED_MAX = 50
local failedRows = {}

local announceFailedBtn = createBtn(FP, "선택된 아이템 링크하기", 160, 22)
announceFailedBtn:SetPoint("TOPRIGHT", FP, "TOPRIGHT", -22, -2)

-- 전체 선택/해제 체크박스
local failedMasterCheck = CreateFrame("CheckButton", nil, FP, "UICheckButtonTemplate")
failedMasterCheck:SetSize(20, 20)
failedMasterCheck:SetPoint("TOPLEFT", FP, "TOPLEFT", 2, -24)
failedMasterCheck:SetChecked(true)
do local fs = failedMasterCheck:GetFontString(); if fs then fs:SetText("") end end
failedMasterCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("전체 선택 / 해제", 1, 1, 1)
    GameTooltip:Show()
end)
failedMasterCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

local failedHeaderName = FP:CreateFontString(nil, "OVERLAY")
failedHeaderName:SetFont(FONT, 10)
failedHeaderName:SetTextColor(GRAY_C.r, GRAY_C.g, GRAY_C.b)
failedHeaderName:SetPoint("TOPLEFT", FP, "TOPLEFT", 48, -30)
failedHeaderName:SetText("아이템명")

local failedScroll = CreateFrame("ScrollFrame", nil, FP, "UIPanelScrollFrameTemplate")
failedScroll:SetPoint("TOPLEFT",     FP, "TOPLEFT",  0,   -44)
failedScroll:SetPoint("BOTTOMRIGHT", FP, "BOTTOMRIGHT", -22, 60)

local failedChild = CreateFrame("Frame", nil, failedScroll)
failedChild:SetSize(1, ROW_H * FAILED_MAX)
failedScroll:SetScrollChild(failedChild)

for i = 1, FAILED_MAX do
    local row = CreateFrame("Frame", nil, failedChild, "BackdropTemplate")
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT",  failedChild, "TOPLEFT",  0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", failedChild, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    if i % 2 == 0 then
        applyBackdrop(row, MR.BACKDROP_DARK, 0.12, 0.06, 0.06, 0.5, 0, 0, 0, 0)
    end
    row:Hide()

    local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    checkbox:SetSize(20, 20)
    checkbox:SetPoint("LEFT", row, "LEFT", 2, 0)
    checkbox:SetChecked(true)
    do local fs = checkbox:GetFontString(); if fs then fs:SetText("") end end
    checkbox:SetScript("OnClick", function()
        -- 개별 토글 시 마스터 체크박스는 "모두 선택" 여부 반영
        local allChecked = true
        for j = 1, FAILED_MAX do
            local r = failedRows[j]
            if r and r:IsShown() and r.checkbox:IsShown()
                and not r.checkbox:GetChecked()
            then
                allChecked = false
                break
            end
        end
        failedMasterCheck:SetChecked(allChecked)
    end)
    row.checkbox = checkbox

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_H - 4, ROW_H - 4)
    icon:SetPoint("LEFT", row, "LEFT", 24, 0)

    -- 창 너비에 맞춰 동적으로 늘어나는 컬럼 레이아웃
    local delBtn = createBtn(row, "삭제", 62, ROW_H - 4)
    delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    -- 이름은 아이콘 우측부터 삭제 버튼 직전까지 가능한 한 넓게 사용
    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(FONT, 13)
    nameText:SetPoint("LEFT",  row, "LEFT",   48, 0)
    nameText:SetPoint("RIGHT", delBtn, "LEFT", -8, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)

    row.icon      = icon
    row.nameText  = nameText
    row.delBtn    = delBtn

    -- 마우스 호버 하이라이트
    local highlight = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    highlight:Hide()
    row.highlight = highlight

    -- 보스 구분선 레이블 (separator 모드에서만 표시)
    local dividerLabel = row:CreateFontString(nil, "OVERLAY")
    dividerLabel:SetFont(FONT, 10)
    dividerLabel:SetTextColor(0.55, 0.55, 0.55)
    dividerLabel:SetAllPoints()
    dividerLabel:SetJustifyH("CENTER")
    dividerLabel:SetJustifyV("MIDDLE")
    dividerLabel:Hide()
    row.dividerLabel = dividerLabel

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self._isSeparator then self.highlight:Show() end
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
    -- 행의 빈 공간에서 좌클릭 드래그 → 창 이동 위임
    if MR._attachDragForward then MR._attachDragForward(row) end

    failedRows[i] = row
end

--------------------------------------------------------------------------------
-- 유찰 아이템 채팅 링크: 분류 없이 한 줄에 쭉 링크
--------------------------------------------------------------------------------
local CHAT_MAX  = 250  -- 255자 한도 전에 여유분 확보

local function sendFailedToChat()
    local list = MR.FailedItems
    if not list or #list == 0 then
        MR.Print("안팔린 아이템이 없습니다.", MR.COLOR.yellow)
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

    -- 동일 아이템이 N개 미판매면 "[링크] x N" 형식으로 표시
    local pieces = {}
    for i = 1, FAILED_MAX do
        local row = failedRows[i]
        if row and row:IsShown() and row._entry
            and row.checkbox:IsShown() and row.checkbox:GetChecked()
            and row._entry.itemLink
        then
            local qty = row._entry.quantity or 1
            local linkPiece = (qty > 1) and (row._entry.itemLink .. " x " .. qty) or row._entry.itemLink
            table.insert(pieces, linkPiece)
        end
    end
    if #pieces == 0 then
        MR.Print("선택된 아이템이 없습니다.", MR.COLOR.yellow)
        return
    end

    PlaySound(SOUNDKIT.RAID_WARNING, "Dialog")
    send("[경매] 안팔린 아이템 목록 살펴보세요")
    local line = ""
    for _, piece in ipairs(pieces) do
        local seg = (line == "") and piece or ("  " .. piece)
        if #line + #seg > CHAT_MAX then
            send(line)
            line = piece
        else
            line = line .. seg
        end
    end
    if line ~= "" then send(line) end
end

announceFailedBtn:SetScript("OnClick", sendFailedToChat)

-- 마스터 체크박스: 전체 행 토글
failedMasterCheck:SetScript("OnClick", function(self)
    local checked = self:GetChecked() and true or false
    for i = 1, FAILED_MAX do
        local r = failedRows[i]
        if r and r:IsShown() and r.checkbox:IsShown() then
            r.checkbox:SetChecked(checked)
        end
    end
end)

local function refreshFailedPanel()
    local list = MR.FailedItems

    -- 보스 그룹별로 묶어서 displayList 빌드 (B안)
    -- bossGroup 오름차순 → 각 그룹 시작에 separator 삽입 (group 0 제외)
    local groups = {}
    for idx, entry in ipairs(list) do
        local g = entry.bossGroup or 0
        groups[g] = groups[g] or {}
        table.insert(groups[g], { entry = entry, index = idx })
    end
    local keys = {}
    for k in pairs(groups) do table.insert(keys, k) end
    table.sort(keys)
    local displayList = {}
    for _, g in ipairs(keys) do
        if g > 0 then
            table.insert(displayList, { isSeparator = true, bossGroup = g })
        end
        for _, item in ipairs(groups[g]) do
            table.insert(displayList, item)
        end
    end

    for i = 1, FAILED_MAX do
        local row  = failedRows[i]
        local item = displayList[i]

        if item and item.isSeparator then
            row:Show()
            row._entry = nil
            row.checkbox:Hide()
            row.icon:Hide()
            row.nameText:Hide()
            row.delBtn:Hide()
            row.dividerLabel:SetText(string.format(
                "────────── %s ──────────",
                (MR.ItemList.bossNames and MR.ItemList.bossNames[item.bossGroup])
                    or (item.bossGroup .. "보스")))
            row.dividerLabel:Show()
            row:EnableMouse(false)
        elseif item then
            local entry = item.entry
            local idx   = item.index
            row:Show()
            row._entry = entry
            row.checkbox:Show()
            row.icon:Show()
            row.nameText:Show()
            row.delBtn:Show()
            row.dividerLabel:Hide()
            row:EnableMouse(true)

            row.checkbox:SetChecked(true)
            row._itemLink = entry.itemLink
            row.icon:SetTexture(entry.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            local qty = entry.quantity or 1
            local qtyTag = (qty > 1) and (" |cffff9900x" .. qty .. "|r") or ""
            local link = entry.itemLink
            if link then
                local color = link:match("|cff(%x%x%x%x%x%x)|H")
                local name  = link:match("|h%[(.-)%]|h")
                if color and name then
                    row.nameText:SetText("|cff" .. color .. name .. "|r" .. qtyTag)
                else
                    row.nameText:SetText((entry.itemName or "?") .. qtyTag)
                end
            else
                row.nameText:SetText((entry.itemName or "?") .. qtyTag)
            end
            row.delBtn:SetScript("OnClick", function()
                MR.FailedItems.Remove(idx)
            end)
        else
            row:Hide()
            row._entry = nil
        end
    end
    failedChild:SetHeight(math.max(ROW_H * #displayList, 1))
    announceFailedBtn:SetEnabled(#list > 0)
    failedMasterCheck:SetChecked(true)   -- 갱신 시 마스터도 기본 체크
end

--------------------------------------------------------------------------------
-- 콜백 등록
--------------------------------------------------------------------------------
MR.TradeLog.OnChange(refreshLogPanel)
MR.TradeLog.OnChange(function()
    -- refreshSettlePanel 은 RaidHistory UpsertCurrent 도 같이 호출하므로
    -- 정산 패널 가시성과 무관하게 항상 실행 (UI 갱신은 가벼움)
    refreshSettlePanel()
end)
MR.FailedItems.OnChange(refreshFailedPanel)


--------------------------------------------------------------------------------
-- [기록] 패널 = MR.HistoryPanel
-- 세션 행 클릭 → 아이템 목록 펼치기/접기, 아이템 호버 → 툴팁
--------------------------------------------------------------------------------
local HP = MR.HistoryPanel

-- 헤더 좌측: 전체 선택 체크박스 (세션 행의 체크박스와 x 좌표 정렬)
local histSelectAllBtn = CreateFrame("CheckButton", nil, HP, "UICheckButtonTemplate")
histSelectAllBtn:SetSize(20, 20)
histSelectAllBtn:SetPoint("TOPLEFT", HP, "TOPLEFT", 2, -4)

local histTitle = HP:CreateFontString(nil, "OVERLAY")
histTitle:SetFont(FONT, 12)
histTitle:SetTextColor(1, 0.82, 0)
histTitle:SetPoint("LEFT", histSelectAllBtn, "RIGHT", 4, 0)
histTitle:SetText("거래 완료 기록")

local histCountText = HP:CreateFontString(nil, "OVERLAY")
histCountText:SetFont(FONT, 10)
histCountText:SetTextColor(0.55, 0.55, 0.55)
histCountText:SetPoint("RIGHT", HP, "TOPRIGHT", -6, -10)
histCountText:SetText("")

local histDivider = HP:CreateTexture(nil, "ARTWORK")
histDivider:SetHeight(1)
histDivider:SetColorTexture(0.3, 0.27, 0.1, 0.8)
histDivider:SetPoint("TOPLEFT",  HP, "TOPLEFT",  0, -24)
histDivider:SetPoint("TOPRIGHT", HP, "TOPRIGHT", 0, -24)

-- 기록 없음 안내
local histEmpty = HP:CreateFontString(nil, "OVERLAY")
histEmpty:SetFont(FONT, 11)
histEmpty:SetTextColor(0.5, 0.5, 0.5)
histEmpty:SetPoint("CENTER", HP, "CENTER", 0, 20)
histEmpty:SetText("저장된 거래 기록이 없습니다.\n거래가 완료될 때마다 자동으로 저장됩니다.")
histEmpty:SetJustifyH("CENTER")
histEmpty:Hide()

-- 스크롤 영역
local histScroll = CreateFrame("ScrollFrame", "MimRaidHistoryScroll", HP, "UIPanelScrollFrameTemplate")
histScroll:SetPoint("TOPLEFT",     HP, "TOPLEFT",  0, -28)
histScroll:SetPoint("BOTTOMRIGHT", HP, "BOTTOMRIGHT", -22, 30)

local histChild = CreateFrame("Frame", nil, histScroll)
histChild:SetSize(histScroll:GetWidth() or 300, 1)
histScroll:SetScrollChild(histChild)

-- 세션/아이템 행 풀 (동적 생성)
local sessPool = {}
local itemPool = {}
local expandedSessions = {}   -- [startTime] = true
local selectedSessions = {}   -- [startTime] = true (거래기록 보고 선택)

-- 전체 선택/해제 체크박스
histSelectAllBtn:SetScript("OnClick", function(self)
    local checked = self:GetChecked() and true or false
    local history = MR.RaidHistory and MR.RaidHistory.GetAll() or {}
    for _, rec in ipairs(history) do
        local k = rec.startTime or rec.id
        if k then selectedSessions[k] = checked end
    end
    if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end
end)

local SESS_H = 36
local ITEM_H = 22

local function makeSessRow()
    local row = CreateFrame("Button", nil, histChild, "BackdropTemplate")
    row:SetHeight(SESS_H)
    row:Hide()

    -- 선택 체크박스 (좌측 최외곽, 독립 클릭 영역)
    local checkBtn = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    checkBtn:SetSize(20, 20)
    checkBtn:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.checkBtn = checkBtn

    local expandText = row:CreateFontString(nil, "OVERLAY")
    expandText:SetFont(FONT, 11)
    expandText:SetTextColor(0.8, 0.8, 0.5)
    expandText:SetPoint("LEFT", checkBtn, "RIGHT", 2, 0)
    expandText:SetWidth(14)
    expandText:SetJustifyH("CENTER")
    row.expandText = expandText

    local dateText = row:CreateFontString(nil, "OVERLAY")
    dateText:SetFont(FONT, 10)
    dateText:SetTextColor(0.65, 0.65, 0.65)
    dateText:SetPoint("TOPLEFT", row, "TOPLEFT", 42, -5)
    row.dateText = dateText

    local instText = row:CreateFontString(nil, "OVERLAY")
    instText:SetFont(FONT, 12)
    instText:SetTextColor(1, 0.82, 0)
    instText:SetPoint("TOPLEFT", row, "TOPLEFT", 42, -20)
    row.instText = instText

    local salesText = row:CreateFontString(nil, "OVERLAY")
    salesText:SetFont(FONT, 10)
    salesText:SetTextColor(0.6, 0.9, 0.6)
    salesText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    salesText:SetJustifyH("RIGHT")
    row.salesText = salesText

    local goldText = row:CreateFontString(nil, "OVERLAY")
    goldText:SetFont(FONT, 10)
    goldText:SetTextColor(1, 0.82, 0)
    goldText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -20)
    goldText:SetJustifyH("RIGHT")
    row.goldText = goldText

    row:SetScript("OnEnter", function(self)
        applyBackdrop(self, MR.BACKDROP_DARK, 0.12, 0.10, 0.05, 0.9, 0.38, 0.32, 0.12, 1)
    end)
    row:SetScript("OnLeave", function(self)
        if self._bd then applyBackdrop(self, MR.BACKDROP_DARK,
            self._bd[1], self._bd[2], self._bd[3], self._bd[4],
            0.25, 0.22, 0.10, 1) end
    end)
    -- 행의 빈 공간에서 좌클릭 드래그 → 창 이동 위임 (단순 클릭으로 펼침/접힘은 그대로 동작)
    if MR._attachDragForward then MR._attachDragForward(row) end
    return row
end

local function makeItemRow()
    local row = CreateFrame("Frame", nil, histChild, "BackdropTemplate")
    row:SetHeight(ITEM_H)
    row:Hide()

    local bidText = row:CreateFontString(nil, "OVERLAY")
    bidText:SetFont(FONT, 10)
    bidText:SetTextColor(1, 0.9, 0.2)
    bidText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    bidText:SetWidth(60)
    bidText:SetJustifyH("RIGHT")
    row.bidText = bidText

    -- 닉네임: 너비 줄이고 우측 정렬 → 이름이 골드 쪽으로 붙어 빈 공간 제거
    local winnerText = row:CreateFontString(nil, "OVERLAY")
    winnerText:SetFont(FONT, 10)
    winnerText:SetTextColor(0.75, 0.85, 1.0)
    winnerText:SetPoint("RIGHT", bidText, "LEFT", -6, 0)
    winnerText:SetWidth(130)
    winnerText:SetJustifyH("RIGHT")
    winnerText:SetWordWrap(false)
    row.winnerText = winnerText

    -- 거래 시각 (YYYY-MM-DD HH:MM): 너비 늘려서 폰트 확대 시에도 1줄 유지
    local timeText = row:CreateFontString(nil, "OVERLAY")
    timeText:SetFont(FONT, 10)
    timeText:SetTextColor(0.55, 0.55, 0.55)
    timeText:SetPoint("RIGHT", winnerText, "LEFT", -6, 0)
    timeText:SetWidth(140)
    timeText:SetJustifyH("RIGHT")
    timeText:SetWordWrap(false)
    row.timeText = timeText

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = icon

    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(FONT, 10)
    nameText:SetTextColor(0.85, 0.85, 0.85)
    nameText:SetPoint("LEFT",  row,       "LEFT",  22,  0)
    nameText:SetPoint("RIGHT", timeText,  "LEFT",  -4,  0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameText = nameText

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self._itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self._itemLink)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            GameTooltip:Hide()
            showPlayerMenu(self._winnerName)
        end
    end)
    -- 행의 빈 공간에서 좌클릭 드래그 → 창 이동 위임
    if MR._attachDragForward then MR._attachDragForward(row) end
    return row
end

-- 하단 버튼: 선택 기록 삭제 (좌측 하단)
local histClearBtn = createBtn(HP, "선택 기록 삭제", 120, 24)
histClearBtn:SetPoint("BOTTOMLEFT", HP, "BOTTOMLEFT", 4, 4)

StaticPopupDialogs["MIMRAID_CLEAR_HISTORY2"] = {
    text      = "선택한 거래 기록을 삭제합니다.\n삭제된 기록은 복구할 수 없습니다.\n\n계속하시겠습니까?",
    button1   = "예, 영구 삭제합니다",
    button2   = "취소",
    OnAccept  = function()
        if MimRaidDB and MR.GetCharData then
            local history = MR.GetCharData().history
            if history then
                for i = #history, 1, -1 do
                    local rec = history[i]
                    local key = rec.startTime or rec.id
                    if selectedSessions[key] then
                        table.remove(history, i)
                        expandedSessions[key] = nil
                        selectedSessions[key] = nil
                    end
                end
            end
        end
        MR.Print("선택한 거래 기록 삭제 완료", MR.COLOR.gray)
        if MR.RefreshHistoryPanel then MR.RefreshHistoryPanel() end
    end,
    timeout   = 0,
    whileDead = true,
}

histClearBtn:SetScript("OnClick", function()
    local cnt = 0
    for _ in pairs(selectedSessions) do cnt = cnt + 1 end
    -- false 값도 잡히므로 실제 true만 세기
    cnt = 0
    for _, v in pairs(selectedSessions) do if v then cnt = cnt + 1 end end
    if cnt == 0 then
        MR.Print("선택된 거래 기록이 없습니다.", MR.COLOR.gray)
        return
    end
    StaticPopup_Show("MIMRAID_CLEAR_HISTORY2")
end)

-- 선택 거래 기록 보고 (우측 하단)
local histReportBtn = createBtn(HP, "선택 거래 기록 보고", 160, 24)
histReportBtn:SetPoint("BOTTOMRIGHT", HP, "BOTTOMRIGHT", -4, 4)

-- "26년4월18일오후3시" 형식
local function formatKoreanStartTime(t)
    if not t then return "" end
    local d = date("*t", t)
    local ampm = (d.hour < 12) and "오전" or "오후"
    local h12  = d.hour % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d년%d월%d일%s%d시", d.year % 100, d.month, d.day, ampm, h12)
end

-- 한 record를 공대 채팅용 라인 배열로 변환
local function buildReportLines(rec)
    local lines = {}
    table.insert(lines, "ㅡ 밈레이드 아이템 경매 기록 ㅡ")
    table.insert(lines, string.format("ㅡ %s <%s> ㅡ",
        rec.instance or "알 수 없음", formatKoreanStartTime(rec.startTime)))

    -- 보스 그룹별 분류 (출현 순서 유지)
    local byBoss, orderedGroups = {}, {}
    for _, sale in ipairs(rec.sales or {}) do
        local bg = sale.bossGroup or 0
        if not byBoss[bg] then
            byBoss[bg] = {}
            table.insert(orderedGroups, bg)
        end
        table.insert(byBoss[bg], sale)
    end
    -- 0(월드드랍)은 뒤로, 나머지는 번호 오름차순
    table.sort(orderedGroups, function(a, b)
        if a == 0 then return false end
        if b == 0 then return true end
        return a < b
    end)

    local bossNames = rec.bossNames or {}
    local bossCount = 0
    for _, bg in ipairs(orderedGroups) do
        local header
        if bg == 0 then
            header = "ㅡ 기타 ㅡ"
        else
            bossCount = bossCount + 1
            local name = bossNames[bg] or bossNames[tostring(bg)]
            header = name and string.format("ㅡ %d넴 %s ㅡ", bg, name)
                          or string.format("ㅡ %d넴 ㅡ", bg)
        end
        table.insert(lines, header)
        for _, sale in ipairs(byBoss[bg]) do
            local link  = (MR.CleanItemLink and MR.CleanItemLink(sale.itemLink or ""))
                or sale.itemLink or "?"
            local short = MR.BaseName(sale.winner or "?") or "?"
            table.insert(lines, string.format("%s %s %s",
                link, short, MR.FormatGold(sale.bid or 0)))
        end
    end

    -- 요약
    local duration = (rec.endTime or rec.startTime or 0) - (rec.startTime or 0)
    if duration < 0 then duration = 0 end
    local h = math.floor(duration / 3600)
    local m = math.floor((duration % 3600) / 60)
    local durText = (h > 0) and string.format("%d시간 %d분", h, m)
                             or string.format("%d분", m)
    table.insert(lines, string.format("ㅁ %d 보스 / 경과시간 %s", bossCount, durText))
    table.insert(lines, string.format("ㅁ 총골드 : %s", MR.FormatGold(rec.totalGold or 0)))
    table.insert(lines, string.format("ㅁ 1인당 분배 골드 : %s", MR.FormatGold(rec.perPerson or 0)))
    table.insert(lines, "ㅡ 밈레이드 아이템 경매 기록 종료 ㅡ")
    return lines
end

histReportBtn:SetScript("OnClick", function()
    if not MR.SendChat then
        MR.Print("채팅 전송 기능을 사용할 수 없습니다.", MR.COLOR.red)
        return
    end

    -- 선택된 세션을 startTime 오름차순으로 수집
    local selected = {}
    for _, rec in ipairs(MR.RaidHistory.GetAll()) do
        local key = rec.startTime or rec.id
        if selectedSessions[key] then
            table.insert(selected, rec)
        end
    end
    if #selected == 0 then
        MR.Print("선택된 거래 기록이 없습니다. 보고할 항목에 체크해주세요.", MR.COLOR.gray)
        return
    end
    table.sort(selected, function(a, b)
        return (a.startTime or 0) < (b.startTime or 0)
    end)

    for idx, rec in ipairs(selected) do
        local lines = buildReportLines(rec)
        for _, line in ipairs(lines) do
            if line == "ㅡ 밈레이드 아이템 경매 기록 ㅡ" then
                MR.SendChat(line, "RAID_WARNING")
            else
                MR.SendChat(line)
            end
        end
        if idx < #selected then
            MR.SendChat(" ")  -- 세션 간 빈 줄
        end
    end
end)

-- 갱신 함수
function MR.RefreshHistoryPanel()
    local history = MR.RaidHistory.GetAll()
    local total   = #history
    histCountText:SetText("총 " .. total .. "회")

    if total == 0 then
        histEmpty:Show()
        for _, r in ipairs(sessPool) do r:Hide() end
        for _, r in ipairs(itemPool) do r:Hide() end
        histChild:SetHeight(1)
        histClearBtn:SetEnabled(false)
        histSelectAllBtn:SetChecked(false)
        return
    end

    histEmpty:Hide()
    histClearBtn:SetEnabled(true)

    local sessUsed = 0
    local itemUsed = 0
    local yOff     = 0
    local sessCount = 0

    local function getSess()
        sessUsed = sessUsed + 1
        if not sessPool[sessUsed] then sessPool[sessUsed] = makeSessRow() end
        return sessPool[sessUsed]
    end
    local function getItem()
        itemUsed = itemUsed + 1
        if not itemPool[itemUsed] then itemPool[itemUsed] = makeItemRow() end
        return itemPool[itemUsed]
    end

    -- 최신순
    local todayStr = date("%Y-%m-%d")
    for i = total, 1, -1 do
        local rec = history[i]
        local row = getSess()
        sessCount = sessCount + 1

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  histChild, "TOPLEFT",  0, -yOff)
        row:SetPoint("TOPRIGHT", histChild, "TOPRIGHT", 0, -yOff)

        local key = rec.startTime or rec.id
        -- 오늘 날짜 레코드는 기본 체크 (아직 한 번도 토글 안 했을 때만)
        if selectedSessions[key] == nil and rec.date == todayStr then
            selectedSessions[key] = true
        end

        local isExpanded = expandedSessions[key]
        row.expandText:SetText(isExpanded and "▼" or "▶")
        row.dateText:SetText((rec.date or "") .. "  " .. (rec.time or ""))
        row.instText:SetText(rec.instance or "알 수 없음")
        local dist = rec.distributions or {}
        local distStr = ""
        if #dist > 0 then
            local distTotal = 0
            for _, d in ipairs(dist) do distTotal = distTotal + (d.gold or 0) end
            distStr = string.format("  분배 %d건 %s", #dist, MR.FormatGold(distTotal))
        end
        local contribs = rec.contributions or {}
        local contribStr = ""
        if #contribs > 0 then
            local contribTotal = 0
            for _, c in ipairs(contribs) do contribTotal = contribTotal + (c.gold or 0) end
            contribStr = string.format("  |cff44ff44골드거래 %d건 %s|r", #contribs, MR.FormatGold(contribTotal))
        end
        row.salesText:SetText(string.format(
            "판매아이템 %d건 / 분배인원 %d명%s%s",
            #(rec.sales or {}), rec.memberCount or 0, distStr, contribStr))

        local totalStr = "총 " .. MR.FormatGold(rec.totalGold or 0)
        local perStr = (rec.perPerson and rec.perPerson > 0)
            and (" / 1인당 분배 " .. MR.FormatGold(rec.perPerson)) or ""
        row.goldText:SetText(totalStr .. perStr)

        -- 체크박스 상태 연결
        row.checkBtn:SetChecked(selectedSessions[key] == true)
        row.checkBtn:SetScript("OnClick", function(self)
            selectedSessions[key] = self:GetChecked() and true or false
            -- 전체 선택 상태 재계산
            local allSel = true
            local hist = MR.RaidHistory and MR.RaidHistory.GetAll() or {}
            for _, r in ipairs(hist) do
                local k = r.startTime or r.id
                if not (k and selectedSessions[k]) then allSel = false; break end
            end
            histSelectAllBtn:SetChecked(allSel)
        end)

        -- 홀짝 배경
        local br, bg, bb, ba
        if sessCount % 2 == 0 then
            br, bg, bb, ba = 0.08, 0.06, 0.03, 0.85
        else
            br, bg, bb, ba = 0.05, 0.04, 0.02, 0.85
        end
        applyBackdrop(row, MR.BACKDROP_DARK, br, bg, bb, ba, 0.25, 0.22, 0.10, 1)
        row._bd = { br, bg, bb, ba }

        row:SetScript("OnClick", function()
            expandedSessions[key] = not expandedSessions[key]
            MR.RefreshHistoryPanel()
        end)
        row:Show()
        yOff = yOff + SESS_H + 1

        -- 펼쳤을 때 아이템 행
        if isExpanded then
            for _, sale in ipairs(rec.sales or {}) do
                local irow = getItem()
                irow:ClearAllPoints()
                irow:SetPoint("TOPLEFT",  histChild, "TOPLEFT",  0, -yOff)
                irow:SetPoint("TOPRIGHT", histChild, "TOPRIGHT", 0, -yOff)

                irow._itemLink   = sale.itemLink
                irow._winnerName = sale.winner
                local _, _, _, _, itemIcon = C_Item.GetItemInfoInstant(sale.itemLink or "")
                irow.icon:SetTexture(itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
                irow.nameText:SetText(sale.itemName or "?")
                irow.timeText:SetText(sale.time and date("%Y-%m-%d %H:%M", sale.time) or "")
                irow.winnerText:SetText(sale.winner or "?")
                irow.bidText:SetText(MR.FormatGold(sale.bid or 0))

                -- 짝수 행 배경
                if itemUsed % 2 == 0 then
                    applyBackdrop(irow, MR.BACKDROP_DARK, 0.07, 0.07, 0.07, 0.6, 0, 0, 0, 0)
                else
                    irow:SetBackdrop(nil)
                end
                irow:Show()
                yOff = yOff + ITEM_H
            end
            -- 골드 거래 행 (아이템 없이 골드만 거래된 기록)
            for _, contrib in ipairs(rec.contributions or {}) do
                local irow = getItem()
                irow:ClearAllPoints()
                irow:SetPoint("TOPLEFT",  histChild, "TOPLEFT",  0, -yOff)
                irow:SetPoint("TOPRIGHT", histChild, "TOPRIGHT", 0, -yOff)
                irow._itemLink   = nil
                irow._winnerName = contrib.source
                local goldAmt   = contrib.gold or 0
                local goldColor = goldAmt >= 0 and "|cff44ff44" or "|cffff4444"
                irow.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
                irow.nameText:SetText(goldColor .. "[아이템 없이 골드거래]|r")
                irow.timeText:SetText(contrib.time and date("%Y-%m-%d %H:%M", contrib.time) or "")
                irow.winnerText:SetText(contrib.source or "?")
                irow.bidText:SetText(goldColor .. MR.FormatGold(goldAmt) .. "|r")
                applyBackdrop(irow, MR.BACKDROP_DARK, 0.04, 0.10, 0.04, 0.7, 0, 0, 0, 0)
                irow:Show()
                yOff = yOff + ITEM_H
            end
            -- 목록 하단 여백
            yOff = yOff + 4
        end
    end

    -- 미사용 행 숨기기
    for i = sessUsed + 1, #sessPool do sessPool[i]:Hide() end
    for i = itemUsed + 1, #itemPool do itemPool[i]:Hide() end

    histChild:SetHeight(math.max(yOff, 1))
    local sw = histScroll:GetWidth()
    if sw and sw > 0 then histChild:SetWidth(sw) end

    -- 전체 선택 체크박스 상태 동기화
    local allSel = true
    for _, r in ipairs(history) do
        local k = r.startTime or r.id
        if not (k and selectedSessions[k]) then allSel = false; break end
    end
    histSelectAllBtn:SetChecked(allSel)
    -- 동적 생성된 행들에 폰트 스케일 즉시 적용
    if MR.RefreshFontSizes then MR.RefreshFontSizes() end
end


--------------------------------------------------------------------------------
-- [옵션] 패널 = MR.OptionsPanel
--------------------------------------------------------------------------------
local OP = MR.OptionsPanelContent  -- 스크롤 가능한 content 프레임


-- ── 홈페이지 링크 ────────────────────────────────────────────────────────────
local cafeLabel = OP:CreateFontString(nil, "OVERLAY")
cafeLabel:SetFont(FONT, 11)
cafeLabel:SetTextColor(0.6, 0.8, 1)
cafeLabel:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -6)
cafeLabel:SetText("네이버 밈줌 카페  |cff4488ffhttps://cafe.naver.com/mimzoom|r")

-- URL 복사용 팝업 EditBox (Ctrl+C 로 복사)
local urlPopup = CreateFrame("Frame", nil, OP, "BackdropTemplate")
urlPopup:SetSize(340, 36)
urlPopup:SetPoint("TOPLEFT", cafeLabel, "BOTTOMLEFT", 0, -4)
urlPopup:SetFrameStrata("DIALOG")
applyBackdrop(urlPopup, MR.BACKDROP_DARK, 0.05, 0.05, 0.1, 0.98, 0.4, 0.6, 1, 1)
urlPopup:Hide()

local urlHint = urlPopup:CreateFontString(nil, "OVERLAY")
urlHint:SetFont(FONT, 9)
urlHint:SetTextColor(0.6, 0.6, 0.6)
urlHint:SetPoint("TOPLEFT", urlPopup, "TOPLEFT", 6, -2)
urlHint:SetText("Ctrl+C 로 복사, 한번 더 누르면 복사창이 닫힙니다.")

local CAFE_URL = "https://cafe.naver.com/mimzoom"

local urlBox = CreateFrame("EditBox", nil, urlPopup)
urlBox:SetSize(328, 18)
urlBox:SetPoint("BOTTOMLEFT", urlPopup, "BOTTOMLEFT", 6, 4)
urlBox:SetFont(FONT, 11, "")
urlBox:SetAutoFocus(false)
urlBox:SetText(CAFE_URL)

-- 사용자가 내용을 수정하면 즉시 원래 URL로 복원
local _urlResetting = false
urlBox:SetScript("OnTextChanged", function(self)
    if _urlResetting then return end
    _urlResetting = true
    self:SetText(CAFE_URL)
    self:HighlightText()
    _urlResetting = false
end)
urlBox:SetScript("OnEscapePressed", function() urlPopup:Hide() end)

-- 라벨 클릭으로 팝업 토글
local cafeLinkBtn = CreateFrame("Button", nil, OP)
cafeLinkBtn:SetHeight(16)
cafeLinkBtn:SetPoint("TOPLEFT",  cafeLabel, "TOPLEFT",  0, 0)
cafeLinkBtn:SetPoint("BOTTOMRIGHT", cafeLabel, "BOTTOMRIGHT", 0, 0)
cafeLinkBtn:SetScript("OnClick", function()
    if urlPopup:IsShown() then
        urlPopup:Hide()
    else
        urlBox:SetText(CAFE_URL)  -- 열 때마다 URL 초기화
        urlPopup:Show()
        urlBox:SetFocus()
        urlBox:HighlightText()
    end
end)
cafeLinkBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("클릭하면 주소 복사 창이 열립니다.", 1, 1, 1)
    GameTooltip:Show()
end)
cafeLinkBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

createDivider(OP, -22)

-- ── 섹션 1: 입찰 단위 설정 ───────────────────────────────────────────────────
local secBid = OP:CreateFontString(nil, "OVERLAY")
secBid:SetFont(FONT, 12)
secBid:SetTextColor(1, 0.82, 0)
secBid:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -28)
secBid:SetText("입찰 단위 설정")
createDivider(OP, -44)

local goldUnitPrefix = OP:CreateFontString(nil, "OVERLAY")
goldUnitPrefix:SetFont(FONT, 11)
goldUnitPrefix:SetTextColor(1, 1, 1)
goldUnitPrefix:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -58)
goldUnitPrefix:SetText("입찰 숫자 1 =")

local goldUnitBox = CreateFrame("EditBox", "MimRaidOptGoldUnit", OP, "InputBoxTemplate")
goldUnitBox:SetSize(70, 20)
goldUnitBox:SetPoint("LEFT", goldUnitPrefix, "RIGHT", 6, 0)
goldUnitBox:SetAutoFocus(false)
goldUnitBox:SetNumeric(true)
goldUnitBox:SetMaxLetters(7)

local goldUnitSuffix = OP:CreateFontString(nil, "OVERLAY")
goldUnitSuffix:SetFont(FONT, 11)
goldUnitSuffix:SetTextColor(0.7, 0.7, 0.7)
goldUnitSuffix:SetPoint("LEFT", goldUnitBox, "RIGHT", 4, 0)
goldUnitSuffix:SetText("골드")

local goldUnitDesc = OP:CreateFontString(nil, "OVERLAY")
goldUnitDesc:SetFont(FONT, 10)
goldUnitDesc:SetTextColor(0.5, 0.5, 0.5)
goldUnitDesc:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -84)
goldUnitDesc:SetWordWrap(false)
goldUnitDesc:SetText("")

-- ── 섹션 2: 살펴보기 ────────────────────────────────────────────────────────
createDivider(OP, -104)
local secPreview = OP:CreateFontString(nil, "OVERLAY")
secPreview:SetFont(FONT, 12)
secPreview:SetTextColor(1, 0.82, 0)
secPreview:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -114)
secPreview:SetText("살펴보기")
createDivider(OP, -130)

local previewPrefix = OP:CreateFontString(nil, "OVERLAY")
previewPrefix:SetFont(FONT, 11)
previewPrefix:SetTextColor(1, 1, 1)
previewPrefix:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -140)
previewPrefix:SetText("경매 시작 후")

local previewBox = CreateFrame("EditBox", "MimRaidOptPreview", OP, "InputBoxTemplate")
previewBox:SetSize(36, 20)
previewBox:SetPoint("LEFT", previewPrefix, "RIGHT", 6, 0)
previewBox:SetAutoFocus(false)
previewBox:SetNumeric(true)
previewBox:SetMaxLetters(2)

local previewSuffix = OP:CreateFontString(nil, "OVERLAY")
previewSuffix:SetFont(FONT, 11)
previewSuffix:SetTextColor(0.7, 0.7, 0.7)
previewSuffix:SetPoint("LEFT", previewBox, "RIGHT", 4, 0)
previewSuffix:SetText("초 살펴보기 후 입찰 시작 (0이면 생략)")

-- ── 섹션 3: 카운트다운 설정 ──────────────────────────────────────────────────
createDivider(OP, -170)
local secCountdown = OP:CreateFontString(nil, "OVERLAY")
secCountdown:SetFont(FONT, 12)
secCountdown:SetTextColor(1, 0.82, 0)
secCountdown:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -180)
secCountdown:SetText("카운트다운 설정")
createDivider(OP, -196)

local silencePrefix = OP:CreateFontString(nil, "OVERLAY")
silencePrefix:SetFont(FONT, 11)
silencePrefix:SetTextColor(1, 1, 1)
silencePrefix:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -206)
silencePrefix:SetText("마지막 입찰이 올라오고")

local silenceBox = CreateFrame("EditBox", "MimRaidOptSilence", OP, "InputBoxTemplate")
silenceBox:SetSize(36, 20)
silenceBox:SetPoint("LEFT", silencePrefix, "RIGHT", 6, 0)
silenceBox:SetAutoFocus(false)
silenceBox:SetNumeric(true)
silenceBox:SetMaxLetters(2)

local silenceSuffix = OP:CreateFontString(nil, "OVERLAY")
silenceSuffix:SetFont(FONT, 11)
silenceSuffix:SetTextColor(0.7, 0.7, 0.7)
silenceSuffix:SetPoint("LEFT", silenceBox, "RIGHT", 4, 0)
silenceSuffix:SetText("초 뒤 카운트다운 시작")

local countLabel = OP:CreateFontString(nil, "OVERLAY")
countLabel:SetFont(FONT, 11)
countLabel:SetTextColor(1, 1, 1)
countLabel:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -236)
countLabel:SetText("카운트:")

local countFromBox = CreateFrame("EditBox", "MimRaidOptCountFrom", OP, "InputBoxTemplate")
countFromBox:SetSize(50, 20)
countFromBox:SetPoint("LEFT", countLabel, "RIGHT", 8, 0)
countFromBox:SetAutoFocus(false)
countFromBox:SetNumeric(true)
countFromBox:SetMaxLetters(5)

local countFromSuffix = OP:CreateFontString(nil, "OVERLAY")
countFromSuffix:SetFont(FONT, 11)
countFromSuffix:SetTextColor(0.7, 0.7, 0.7)
countFromSuffix:SetPoint("LEFT", countFromBox, "RIGHT", 4, 0)
countFromSuffix:SetText("부터 카운트")

local stepLabel = OP:CreateFontString(nil, "OVERLAY")
stepLabel:SetFont(FONT, 11)
stepLabel:SetTextColor(1, 1, 1)
stepLabel:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -264)
stepLabel:SetText("카운트 1당:")

local stepDelayBox = CreateFrame("EditBox", "MimRaidOptStepDelay", OP, "InputBoxTemplate")
stepDelayBox:SetSize(50, 20)
stepDelayBox:SetPoint("LEFT", stepLabel, "RIGHT", 8, 0)
stepDelayBox:SetAutoFocus(false)
stepDelayBox:SetNumeric(true)
stepDelayBox:SetMaxLetters(5)

local stepDelaySuffix = OP:CreateFontString(nil, "OVERLAY")
stepDelaySuffix:SetFont(FONT, 11)
stepDelaySuffix:SetTextColor(0.7, 0.7, 0.7)
stepDelaySuffix:SetPoint("LEFT", stepDelayBox, "RIGHT", 4, 0)
stepDelaySuffix:SetText("초 대기")

createDivider(OP, -290)
local currentValText = OP:CreateFontString(nil, "OVERLAY")
currentValText:SetFont(FONT, 10)
currentValText:SetTextColor(0.5, 0.5, 0.5)
currentValText:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -298)
currentValText:SetText("")

-- ── 섹션 4: 자동 주사위 ──────────────────────────────────────────────────────
createDivider(OP, -318)
local secAutoRoll = OP:CreateFontString(nil, "OVERLAY")
secAutoRoll:SetFont(FONT, 12)
secAutoRoll:SetTextColor(1, 0.82, 0)
secAutoRoll:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -328)
secAutoRoll:SetText("자동 주사위 굴리기")
createDivider(OP, -344)

local autoRollCheck = CreateFrame("CheckButton", "MimRaidOptAutoRoll", OP, "UICheckButtonTemplate")
autoRollCheck:SetSize(20, 20)
autoRollCheck:SetPoint("TOPLEFT", OP, "TOPLEFT", 4, -362)

local autoRollLabel = OP:CreateFontString(nil, "OVERLAY")
autoRollLabel:SetFont(FONT, 11)
autoRollLabel:SetTextColor(1, 1, 1)
autoRollLabel:SetPoint("LEFT", autoRollCheck, "RIGHT", 2, 0)
autoRollLabel:SetText("공대장/부공대장일 때 아이템 자동 수령 (주사위/전리품 골드)")

local autoRollDesc = OP:CreateFontString(nil, "OVERLAY")
autoRollDesc:SetFont(FONT, 10)
autoRollDesc:SetTextColor(0.5, 0.5, 0.5)
-- 폭 고정(SetWidth)을 빼고 좌우 anchor 로 패널 폭에 맞춤 → 폰트 확대 시에도 우측 공간 활용
autoRollDesc:SetPoint("TOPLEFT",  OP, "TOPLEFT",  28, -384)
autoRollDesc:SetPoint("TOPRIGHT", OP, "TOPRIGHT", -8, -384)
autoRollDesc:SetText("주사위 창이 열릴 때 공대원에게 아래 채팅을 자동 전송합니다.\n공격대에서 공대장 또는 부공대장일 때만 동작합니다. (파티/개인 인던 미동작)")
autoRollDesc:SetWordWrap(true)
autoRollDesc:SetJustifyH("LEFT")

-- 폰트 스케일 시 autoRollDesc(2줄, 자동 줄바꿈) 가 커져도 겹치지 않도록 -460 으로 내림
local autoRollMsgBg = CreateFrame("Frame", nil, OP, "BackdropTemplate")
autoRollMsgBg:SetSize(400, 44)
autoRollMsgBg:SetPoint("TOPLEFT", OP, "TOPLEFT", 28, -460)
autoRollMsgBg:SetBackdrop(MR.BACKDROP_DARK)
autoRollMsgBg:SetBackdropColor(0, 0, 0, 0.5)

local autoRollMsgBox = CreateFrame("EditBox", "MimRaidOptAutoRollMsg", autoRollMsgBg)
autoRollMsgBox:SetPoint("TOPLEFT", autoRollMsgBg, "TOPLEFT", 6, -4)
autoRollMsgBox:SetPoint("BOTTOMRIGHT", autoRollMsgBg, "BOTTOMRIGHT", -6, 4)
autoRollMsgBox:SetFont(FONT, 11, "")
autoRollMsgBox:SetMaxLetters(200)
autoRollMsgBox:SetAutoFocus(false)
autoRollMsgBox:SetMultiLine(true)

-- 수정 시 자동 저장 (userInput=true 일 때만; SetText로 인한 초기 로드는 무시)
autoRollMsgBox:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    MR.cfg.autoRollMsg = strtrim(self:GetText())
    MR.SaveSettings()
end)

autoRollCheck:SetScript("OnClick", function(self)
    MR.cfg.autoRollEnabled = self:GetChecked() and true or false
    MR.SaveSettings()
end)

-- ── 섹션 5: 동일 아이템 경매 그룹 구성 ───────────────────────────────────────
-- 같은 그룹 번호끼리 하나의 경매로 묶음. 좌클릭: 다음 그룹, 우클릭: 이전 그룹
-- 자동 주사위 섹션 폰트 스케일 대응 위해 +42px 아래로 시프트
createDivider(OP, -528)
local secGroups = OP:CreateFontString(nil, "OVERLAY")
secGroups:SetFont(FONT, 12)
secGroups:SetTextColor(1, 0.82, 0)
secGroups:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -538)
secGroups:SetText("동일 아이템 경매 그룹 구성")
createDivider(OP, -554)

local groupsHint = OP:CreateFontString(nil, "OVERLAY")
groupsHint:SetFont(FONT, 10)
groupsHint:SetTextColor(0.6, 0.6, 0.6)
groupsHint:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, -560)
groupsHint:SetText("같은 그룹 번호끼리 하나의 경매로 묶입니다. 칩 좌클릭: 다음 그룹, 우클릭: 이전 그룹")

-- 그룹 컬럼 4개 (1차~4차 경매)
local GROUP_COL_W = 124
local GROUP_COL_H = 140
local GROUP_COL_SPACING = 6
local GROUP_START_Y = -582

local groupColumns = {}
for i = 1, 4 do
    local col = CreateFrame("Frame", nil, OP, "BackdropTemplate")
    col:SetSize(GROUP_COL_W, GROUP_COL_H)
    col:SetPoint("TOPLEFT", OP, "TOPLEFT",
        6 + (i - 1) * (GROUP_COL_W + GROUP_COL_SPACING), GROUP_START_Y)
    applyBackdrop(col, MR.BACKDROP_DARK, 0.05, 0.05, 0.08, 0.9, 0.3, 0.3, 0.35, 1)

    local title = col:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 11)
    title:SetTextColor(1, 0.82, 0)
    title:SetPoint("TOP", col, "TOP", 0, -4)
    title:SetText(i .. "차 경매")

    groupColumns[i] = col
end

-- 6개 카테고리 칩
local CHIP_H = 20
local CHIP_W = 116
local CATEGORY_CHIPS = {
    { cfgKey = "auctionGroupSocket",     label = "보석 홈",   color = { 0.4, 1.0, 0.4 } },
    { cfgKey = "auctionGroupAvoidance",  label = "광역회피",  color = { 0.6, 0.9, 1.0 } },
    { cfgKey = "auctionGroupLeech",      label = "생기흡수",  color = { 1.0, 0.6, 0.6 } },
    { cfgKey = "auctionGroupIndestruct", label = "파괴 불가", color = { 0.9, 0.9, 0.6 } },
    { cfgKey = "auctionGroupSpeed",      label = "이동 속도", color = { 0.8, 0.8, 1.0 } },
    { cfgKey = "auctionGroupNormal",     label = "일반 템",   color = { 0.7, 0.7, 0.7 } },
}

local chipFrames = {}

local function repositionChips()
    local colCounts = { 0, 0, 0, 0 }
    for i, chip in ipairs(chipFrames) do
        local info = CATEGORY_CHIPS[i]
        local g = MR.cfg[info.cfgKey] or 4
        if g < 1 or g > 4 then g = 4 end
        colCounts[g] = colCounts[g] + 1
        chip:ClearAllPoints()
        chip:SetPoint("TOP", groupColumns[g], "TOP", 0, -20 - (colCounts[g] - 1) * (CHIP_H + 2))
    end
end

for i, info in ipairs(CATEGORY_CHIPS) do
    local chip = CreateFrame("Button", nil, OP, "BackdropTemplate")
    chip:SetSize(CHIP_W, CHIP_H)
    applyBackdrop(chip, MR.BACKDROP_DARK, info.color[1] * 0.3, info.color[2] * 0.3, info.color[3] * 0.3, 0.85, info.color[1], info.color[2], info.color[3], 1)
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local label = chip:CreateFontString(nil, "OVERLAY")
    label:SetFont(FONT, 11)
    label:SetTextColor(info.color[1], info.color[2], info.color[3])
    label:SetPoint("CENTER", chip, "CENTER", 0, 0)
    label:SetText(info.label)

    chip:SetScript("OnClick", function(_, button)
        local cur = MR.cfg[info.cfgKey] or 4
        if button == "RightButton" then
            cur = cur - 1
            if cur < 1 then cur = 4 end
        else
            cur = cur + 1
            if cur > 4 then cur = 1 end
        end
        MR.cfg[info.cfgKey] = cur
        MR.SaveSettings()
        repositionChips()
        if MR.ItemList.RecalcGroupNumbers then MR.ItemList.RecalcGroupNumbers() end
    end)

    chipFrames[i] = chip
end

-- 프리셋 버튼
local function applyPreset(s, a, l, ind, sp, n)
    MR.cfg.auctionGroupSocket     = s
    MR.cfg.auctionGroupAvoidance  = a
    MR.cfg.auctionGroupLeech      = l
    MR.cfg.auctionGroupIndestruct = ind
    MR.cfg.auctionGroupSpeed      = sp
    MR.cfg.auctionGroupNormal     = n
    MR.SaveSettings()
    repositionChips()
    if MR.ItemList.RecalcGroupNumbers then MR.ItemList.RecalcGroupNumbers() end
end

local presetY = GROUP_START_Y - GROUP_COL_H - 10

-- 1번: 보홈 / 광피·생흡 (기본) — DEFAULTS 와 동일 배치
local presetDefaultBtn = CreateFrame("Button", nil, OP, "UIPanelButtonTemplate")
presetDefaultBtn:SetSize(150, 22)
presetDefaultBtn:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, presetY)
presetDefaultBtn:SetText("보홈·광피생흡 (기본)")
if presetDefaultBtn:GetFontString() then presetDefaultBtn:GetFontString():SetFont(FONT, 11) end
presetDefaultBtn:SetScript("OnClick", function() applyPreset(1, 2, 2, 3, 3, 3) end)

-- 2번: 보홈만 따로
local presetSocketBtn = CreateFrame("Button", nil, OP, "UIPanelButtonTemplate")
presetSocketBtn:SetSize(90, 22)
presetSocketBtn:SetPoint("LEFT", presetDefaultBtn, "RIGHT", 6, 0)
presetSocketBtn:SetText("보홈만 따로")
if presetSocketBtn:GetFontString() then presetSocketBtn:GetFontString():SetFont(FONT, 11) end
presetSocketBtn:SetScript("OnClick", function() applyPreset(1, 2, 2, 2, 2, 2) end)

-- 3번: 보홈 / 광피 / 생흡 각각
local presetEachBtn = CreateFrame("Button", nil, OP, "UIPanelButtonTemplate")
presetEachBtn:SetSize(140, 22)
presetEachBtn:SetPoint("LEFT", presetSocketBtn, "RIGHT", 6, 0)
presetEachBtn:SetText("보홈/광피/생흡 각각")
if presetEachBtn:GetFontString() then presetEachBtn:GetFontString():SetFont(FONT, 11) end
presetEachBtn:SetScript("OnClick", function() applyPreset(1, 2, 3, 4, 4, 4) end)

-- 4번: 전부 묶음
local presetAllBtn = CreateFrame("Button", nil, OP, "UIPanelButtonTemplate")
presetAllBtn:SetSize(80, 22)
presetAllBtn:SetPoint("LEFT", presetEachBtn, "RIGHT", 6, 0)
presetAllBtn:SetText("전부 묶음")
if presetAllBtn:GetFontString() then presetAllBtn:GetFontString():SetFont(FONT, 11) end
presetAllBtn:SetScript("OnClick", function() applyPreset(4, 4, 4, 4, 4, 4) end)

-- ── 섹션 6: 거래내역 귓말 ──────────────────────────────────────────────────
local whisperSectionY = presetY - 40
local secWhisper = OP:CreateFontString(nil, "OVERLAY")
secWhisper:SetFont(FONT, 12)
secWhisper:SetTextColor(1, 0.82, 0)
secWhisper:SetPoint("TOPLEFT", OP, "TOPLEFT", 6, whisperSectionY)
secWhisper:SetText("거래내역 귓말")
createDivider(OP, whisperSectionY - 16)

local whisperCheck = CreateFrame("CheckButton", "MimRaidOptTradeWhisper", OP, "UICheckButtonTemplate")
whisperCheck:SetSize(20, 20)
whisperCheck:SetPoint("TOPLEFT", OP, "TOPLEFT", 4, whisperSectionY - 34)

local whisperLabel = OP:CreateFontString(nil, "OVERLAY")
whisperLabel:SetFont(FONT, 11)
whisperLabel:SetTextColor(1, 1, 1)
whisperLabel:SetPoint("LEFT", whisperCheck, "RIGHT", 2, 0)
whisperLabel:SetText("거래 완료 시 상대방에게 거래내역 귓말 전송")

local whisperDesc = OP:CreateFontString(nil, "OVERLAY")
whisperDesc:SetFont(FONT, 10)
whisperDesc:SetTextColor(0.5, 0.5, 0.5)
-- 좌우 anchor 로 패널 폭에 맞춤 (폰트 확대 시 우측 공간 활용)
whisperDesc:SetPoint("TOPLEFT",  OP, "TOPLEFT",  28, whisperSectionY - 58)
whisperDesc:SetPoint("TOPRIGHT", OP, "TOPRIGHT", -8, whisperSectionY - 58)
whisperDesc:SetText("거래가 성사되면 받은골드와 보낸골드 및 아이템 내역을 상대방에게 귓말로 보냅니다.\n길이가 길어지면 2번에 나눠서 보냅니다.")
whisperDesc:SetWordWrap(true)
whisperDesc:SetJustifyH("LEFT")

whisperCheck:SetScript("OnClick", function(self)
    MR.cfg.tradeWhisperEnabled = self:GetChecked() and true or false
    MR.SaveSettings()
end)

--------------------------------------------------------------------------------
-- 옵션 패널: 값 로드 / 저장 핸들러
--------------------------------------------------------------------------------
local function refreshOptionsPanel()
    goldUnitBox:SetText(tostring(MR.cfg.goldUnit or 10000))
    goldUnitDesc:SetText("현재: 입찰 1 = " .. MR.FormatGold(MR.cfg.goldUnit or 10000))

    previewBox:SetText(tostring(MR.cfg.previewTime or 0))
    silenceBox:SetText(tostring(MR.cfg.silenceTimeout or 3))
    countFromBox:SetText(tostring(MR.cfg.countdownFrom or 5))
    stepDelayBox:SetText(tostring(MR.cfg.countdownStepDelay or 2))
    currentValText:SetText(string.format(
        "현재: 살펴보기 %d초 → 침묵 %d초 → %d부터 카운트 → 카운트당 %d초",
        MR.cfg.previewTime or 0,
        MR.cfg.silenceTimeout or 3,
        MR.cfg.countdownFrom or 5,
        MR.cfg.countdownStepDelay or 2))

    autoRollCheck:SetChecked(MR.cfg.autoRollEnabled and true or false)
    autoRollMsgBox:SetText(MR.cfg.autoRollMsg or MR.DEFAULTS.autoRollMsg)
    whisperCheck:SetChecked(MR.cfg.tradeWhisperEnabled ~= false)
    repositionChips()
end

-- 옵션 탭 열릴 때 값 채우기
OP:SetScript("OnShow", function() refreshOptionsPanel() end)

-- goldUnit 저장
goldUnitBox:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v and v > 0 then
        MR.cfg.goldUnit = v
        MR.SaveSettings()
        goldUnitDesc:SetText("현재: 입찰 1 = " .. MR.FormatGold(v))
    else
        self:SetText(tostring(MR.cfg.goldUnit or 10000))
    end
end)

-- 현재 설정 표시 헬퍼 (모든 입력 박스 핸들러에서 공통 호출)
local function refreshCurrentValText()
    currentValText:SetText(string.format(
        "현재: 살펴보기 %d초 → 침묵 %d초 → %d부터 카운트 → 카운트당 %d초",
        MR.cfg.previewTime or 0,
        MR.cfg.silenceTimeout or 3,
        MR.cfg.countdownFrom or 5,
        MR.cfg.countdownStepDelay or 2))
end

-- previewTime 저장
previewBox:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v and v >= 0 then
        MR.cfg.previewTime = v
        MR.SaveSettings()
        refreshCurrentValText()
    else
        self:SetText(tostring(MR.cfg.previewTime or 0))
    end
end)

-- silenceTimeout 저장
silenceBox:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v and v >= 0 then
        MR.cfg.silenceTimeout = v
        MR.SaveSettings()
        refreshCurrentValText()
    else
        self:SetText(tostring(MR.cfg.silenceTimeout or 3))
    end
end)

-- countdownFrom 저장
countFromBox:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v and v >= 1 then
        MR.cfg.countdownFrom = v
        MR.SaveSettings()
        refreshCurrentValText()
    else
        self:SetText(tostring(MR.cfg.countdownFrom or 5))
    end
end)

-- countdownStepDelay 저장
-- 스크롤 child 너비 초기화 (프레임 레이아웃 완료 후)
C_Timer.After(0, function()
    local lw = logScroll:GetWidth()
    if lw and lw > 0 then logChild:SetWidth(lw) end
    local fw = failedScroll:GetWidth()
    if fw and fw > 0 then failedChild:SetWidth(fw) end
    local sw = histScroll:GetWidth()
    if sw and sw > 0 then histChild:SetWidth(sw) end
end)

stepDelayBox:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v and v >= 1 then
        MR.cfg.countdownStepDelay = v
        MR.SaveSettings()
        refreshCurrentValText()
    else
        self:SetText(tostring(MR.cfg.countdownStepDelay or 2))
    end
end)


