-- AI Assistant KOReader Plugin (Anthropic Claude / DeepSeek / MiniMax)
-- Explains highlighted text and provides Q&A about the current book.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local TextViewer      = require("ui/widget/textviewer")
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local Dispatcher      = require("dispatcher")
local Device          = require("device")
local logger          = require("logger")
local _               = require("gettext")
local AIAPI           = require("ai_api")

local Screen = Device.screen

-- Rejects empty/whitespace keys and the config-file placeholder, case-insensitively.
local function isUsableKey(s)
    if type(s) ~= "string" then return false end
    local trimmed = s:gsub("^%s+", ""):gsub("%s+$", "")
    return trimmed ~= "" and trimmed:upper() ~= "YOUR_API_KEY_HERE"
end

local ClaudePlugin = WidgetContainer:extend{
    name        = "claude",
    is_doc_only = false,
}

-- ── Init ──────────────────────────────────────────────────────────────────────

function ClaudePlugin:init()
    -- Persistent settings (stores the provider and API keys between sessions)
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/claude_settings.lua")
    self.provider  = self:_normalizeProvider(self.settings:readSetting("provider"))
    self.book_text  = nil
    self.book_title = ""

    -- Register actions users can assign to gestures / hardware buttons
    -- (IDs stay "claude_*" so existing bindings keep working)
    Dispatcher:registerAction("claude_ask_about_book", {
        category = "none",
        event    = "ClaudeAskAboutBook",
        title    = _("AI: Ask about Book"),
        reader   = true,
    })
    Dispatcher:registerAction("claude_explain_selection", {
        category = "none",
        event    = "ClaudeExplainSelection",
        title    = _("AI: Explain Selection"),
        reader   = true,
    })

    self.ui.menu:registerToMainMenu(self)
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function ClaudePlugin:addToMainMenu(menu_items)
    menu_items.claude_ai = {
        text         = _("AI Assistant"),
        sorting_hint = "tools",
        sub_item_table = {
            -- "Ask <provider>" – the main search-like Q&A entry
            {
                text_func    = function()
                    return string.format(_("Ask %s"), self:_providerLabel())
                end,
                help_text    = _("Ask the AI any question about the book you're reading"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback     = function() self:showBookQADialog() end,
            },
            {
                text         = _("Explain Highlighted Text"),
                help_text    = _("Get the AI to explain the currently selected text"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback     = function() self:explainCurrentSelection() end,
            },
            {
                text_func    = function()
                    return string.format(_("Load Book into %s"), self:_providerLabel())
                end,
                help_text    = _("Read the full book so the AI can answer detailed questions"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback     = function() self:loadBookText() end,
            },
            {
                text_func = function()
                    return _("AI Provider: ") .. self:_providerLabel()
                end,
                sub_item_table = self:_providerMenuItems(),
            },
            {   -- visual separator
                text             = _("──────────────"),
                enabled_func     = function() return false end,
                callback         = function() end,
                hold_callback    = function() end,
            },
            {
                text     = _("Configure API Key"),
                callback = function() self:showApiKeyDialog() end,
            },
        },
    }
end

-- Radio-style provider picker (KOReader pattern: checked_func shows the tick,
-- callback saves the choice)
function ClaudePlugin:_providerMenuItems()
    local rows = {}
    for _i, id in ipairs(AIAPI:listProviderIds()) do
        local spec = AIAPI:getProvider(id)
        table.insert(rows, {
            text         = _(spec.label),
            checked_func = function() return self.provider == id end,
            callback     = function(touchmenu_instance)
                self.provider = id
                self.settings:saveSetting("provider", id)
                self.settings:flush()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        })
    end
    return rows
end

-- ── Reader events ─────────────────────────────────────────────────────────────

function ClaudePlugin:onReaderReady()
    self.book_text  = nil
    self.book_title = ""

    if self.ui.document then
        local ok, props = pcall(function() return self.ui.document:getProps() end)
        if ok and props then
            self.book_title = props.title or ""
        end
    end

    -- Try to inject an "Ask <provider>" button into the text-selection popup.
    -- addToHighlightDialog is available in KOReader 2023+; we wrap in pcall
    -- so older builds simply skip this and users rely on the menu instead.
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        pcall(function()
            self.ui.highlight:addToHighlightDialog(
                "claude_explain",
                function(dlg)
                    return {
                        text     = string.format(_("Ask %s"), self:_providerLabel()),
                        callback = function()
                            local text = ""
                            if dlg.selected_text then
                                text = type(dlg.selected_text) == "table"
                                    and (dlg.selected_text.text or "")
                                    or  tostring(dlg.selected_text)
                            end
                            UIManager:close(dlg)
                            if text ~= "" then self:explainText(text) end
                        end,
                    }
                end
            )
        end)
    end
end

function ClaudePlugin:onCloseDocument()
    self.book_text  = nil
    self.book_title = ""
end

-- Dispatcher callbacks (users can bind these to gestures/buttons)
function ClaudePlugin:onClaudeAskAboutBook()    self:showBookQADialog() end
function ClaudePlugin:onClaudeExplainSelection() self:explainCurrentSelection() end

-- ── Explain highlighted text ──────────────────────────────────────────────────

function ClaudePlugin:explainCurrentSelection()
    if not self:checkApiKey() then return end
    local text = self:_getSelectedText()
    if text == "" then
        UIManager:show(InfoMessage:new{
            text    = _("No text selected.\nHighlight a word or sentence, then use this option."),
            timeout = 3,
        })
        return
    end
    self:explainText(text)
end

function ClaudePlugin:explainText(text)
    if not self:checkApiKey() then return end

    local label   = self:_providerLabel()
    local loading = InfoMessage:new{ text = string.format(_("Asking %s…"), label) }
    UIManager:show(loading)

    local system_prompt = [[You are a reading assistant inside an e-reader application.
When the user highlights text from their book, identify what it is and respond concisely:
• Person's name  → 2-3 sentence biography or character description
• Place name     → brief description of the location or setting
• Foreign/rare word or phrase → definition + translation if needed
• Technical term or concept  → plain-language explanation
• A passage or quote         → explain meaning and context
Keep your answer under 150 words. Do not repeat the highlighted text at the start of your reply.]]

    local ok, response = AIAPI:query(
        self.provider,
        self:_providerKey(),
        system_prompt,
        'Explain this text from the book I\'m reading: "' .. text .. '"'
    )
    UIManager:close(loading)

    if ok then
        UIManager:show(TextViewer:new{
            title  = label,
            text   = "\226\128\156" .. text .. "\226\128\157\n\n" .. response,
            height = math.floor(Screen:getHeight() * 0.72),
            width  = math.floor(Screen:getWidth()  * 0.92),
        })
    else
        UIManager:show(InfoMessage:new{
            text    = label .. _(" error: ") .. response,
            timeout = 5,
        })
    end
end

-- ── Load book text ────────────────────────────────────────────────────────────

function ClaudePlugin:loadBookText()
    if not self.ui.document then return end

    local page_count = self.ui.document:getPageCount()
    UIManager:show(InfoMessage:new{
        text    = string.format(_("Loading %d pages into %s context…"),
                                page_count, self:_providerLabel()),
        timeout = 2,
    })

    local parts     = {}
    local total_len = 0
    local max_bytes = self:_bookMaxBytes()
    -- #text counts bytes, not characters – intentional: byte caps bound the
    -- token count consistently across scripts (CJK is ~3 bytes per character).

    for page = 1, page_count do
        local ok, text = pcall(function()
            return self.ui.document:getPageText(page)
        end)
        if ok and text and text ~= "" then
            table.insert(parts, text)
            total_len = total_len + #text
        end
        if total_len >= max_bytes then
            table.insert(parts, string.format(
                "\n\n[Book truncated at page %d of %d to fit context window]",
                page, page_count))
            break
        end
    end

    self.book_text = table.concat(parts, "\n\n")

    UIManager:show(InfoMessage:new{
        text    = string.format(
            _("Book loaded! %d bytes of text ready.\nNow use 'Ask %s' to ask questions."),
            #self.book_text, self:_providerLabel()),
        timeout = 4,
    })
end

-- ── Book Q&A ──────────────────────────────────────────────────────────────────

function ClaudePlugin:showBookQADialog()
    if not self:checkApiKey() then return end

    if self.book_text then
        self:_showQAInput()
    else
        UIManager:show(ConfirmBox:new{
            text = _(
                "Load the full book first so the AI can give accurate answers?\n\n"
                .. "Tap 'Load Book' to read it now, or 'Skip' to ask using ")
                .. self:_providerLabel()
                .. _("'s general knowledge."),
            ok_text     = _("Load Book"),
            cancel_text = _("Skip"),
            ok_callback = function()
                self:loadBookText()
                self:_showQAInput()
            end,
            cancel_callback = function()
                self:_showQAInput()
            end,
        })
    end
end

function ClaudePlugin:_showQAInput()
    local display_title = (self.book_title ~= "") and self.book_title or _("current book")
    local dialog
    dialog = InputDialog:new{
        title       = string.format(_("Ask %s 🔍"), self:_providerLabel()),
        description = _("Book: ") .. display_title,
        input_hint  = _("e.g. Who is the main character? What happens in chapter 3?"),
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text             = _("Ask"),
                    is_enter_default = true,
                    callback         = function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        if q and q ~= "" then self:askAboutBook(q) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ClaudePlugin:askAboutBook(question)
    local label   = self:_providerLabel()
    local loading = InfoMessage:new{ text = string.format(_("Asking %s…"), label) }
    UIManager:show(loading)

    local title = (self.book_title ~= "") and self.book_title or "the book"
    local system_prompt

    if self.book_text then
        system_prompt = string.format(
            'You are a helpful reading assistant. The user is reading "%s".\n\n'
            .. 'FULL BOOK TEXT:\n%s\n\n'
            .. 'Answer questions accurately based on the book content. '
            .. 'Cite specific details or passages when relevant.',
            title,
            self.book_text:sub(1, self:_bookMaxBytes()))
    else
        system_prompt = string.format(
            'You are a helpful reading assistant. '
            .. 'The user is reading "%s". '
            .. 'Answer their question using your general knowledge of this book. '
            .. 'If you are unsure, say so.',
            title)
    end

    local ok, response = AIAPI:query(self.provider, self:_providerKey(), system_prompt, question)
    UIManager:close(loading)

    if ok then
        UIManager:show(TextViewer:new{
            title  = label,
            text   = "Q: " .. question .. "\n\n" .. response,
            height = math.floor(Screen:getHeight() * 0.82),
            width  = math.floor(Screen:getWidth()  * 0.92),
        })
    else
        UIManager:show(InfoMessage:new{
            text    = _("Error: ") .. response,
            timeout = 5,
        })
    end
end

-- ── API-key settings dialog ───────────────────────────────────────────────────

function ClaudePlugin:showApiKeyDialog()
    local spec  = AIAPI:getProvider(self.provider)
    local label = self:_providerLabel()
    local dialog
    dialog = InputDialog:new{
        title       = label .. _(" API Key"),
        description = _("Get your key at: ") .. (spec and spec.key_url or "")
                   .. _("\nOr edit claude_config.lua in the plugin folder."),
        input       = self:_providerKey(),
        input_type  = "string",
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local key = dialog:getInputText()
                        UIManager:close(dialog)
                        if isUsableKey(key) then
                            self.settings:saveSetting(spec.key_setting, key)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{
                                text    = string.format(_("%s API key saved!"), label),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ── Provider state ────────────────────────────────────────────────────────────

-- Keys are read lazily: LuaSettings (saved from the UI) wins,
-- claude_config.lua is the fallback. Placeholders are rejected (isUsableKey).
function ClaudePlugin:_providerKey()
    local spec = AIAPI:getProvider(self.provider)
    if not spec then return "" end
    local key = self.settings:readSetting(spec.key_setting) or ""
    if not isUsableKey(key) then
        local cfg_ok, cfg = pcall(require, "claude_config")
        if cfg_ok and cfg and type(cfg) == "table" then
            local cand = cfg[spec.key_setting]
            if isUsableKey(cand) then key = cand end
        end
    end
    return key
end

function ClaudePlugin:_providerLabel()
    return AIAPI:getLabel(self.provider)
end

function ClaudePlugin:_bookMaxBytes()
    local spec = AIAPI:getProvider(self.provider)
    return spec and spec.max_bytes or 150000
end

-- Unknown/empty provider ids fall back to Anthropic and repair the stored setting.
function ClaudePlugin:_normalizeProvider(id)
    if AIAPI:getProvider(id) then return id end
    if self.settings then
        self.settings:saveSetting("provider", "anthropic")
        self.settings:flush()
    end
    return "anthropic"
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

function ClaudePlugin:_getSelectedText()
    if not self.ui.highlight then return "" end
    local sel = self.ui.highlight.selected_text
    if not sel then return "" end
    if type(sel) == "table"  then return sel.text or "" end
    if type(sel) == "string" then return sel end
    return ""
end

function ClaudePlugin:checkApiKey()
    if isUsableKey(self:_providerKey()) then
        return true
    end
    UIManager:show(InfoMessage:new{
        text    = self:_providerLabel()
               .. _(": no API key configured.\nTools → AI Assistant → AI Provider to switch, ")
               .. _("or Configure API Key to add one."),
        timeout = 4,
    })
    return false
end

return ClaudePlugin
