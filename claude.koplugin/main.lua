-- Claude AI KOReader Plugin
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
local ClaudeAPI       = require("claude_api")

local Screen = Device.screen

local ClaudePlugin = WidgetContainer:extend{
    name        = "claude",
    is_doc_only = false,
}

-- ── Init ──────────────────────────────────────────────────────────────────────

function ClaudePlugin:init()
    -- Persistent settings (stores the API key between sessions)
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/claude_settings.lua")
    self.api_key   = self.settings:readSetting("api_key") or ""
    self.book_text  = nil
    self.book_title = ""

    -- If the API key wasn't set via the UI, try reading claude_config.lua
    if self.api_key == "" then
        local cfg_ok, cfg = pcall(require, "claude_config")
        if cfg_ok and cfg and type(cfg.api_key) == "string"
                and cfg.api_key ~= "your-api-key-here" and cfg.api_key ~= "" then
            self.api_key = cfg.api_key
        end
    end

    -- Register actions users can assign to gestures / hardware buttons
    Dispatcher:registerAction("claude_ask_about_book", {
        category = "none",
        event    = "ClaudeAskAboutBook",
        title    = _("Claude: Ask about Book"),
        reader   = true,
    })
    Dispatcher:registerAction("claude_explain_selection", {
        category = "none",
        event    = "ClaudeExplainSelection",
        title    = _("Claude: Explain Selection"),
        reader   = true,
    })

    self.ui.menu:registerToMainMenu(self)
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function ClaudePlugin:addToMainMenu(menu_items)
    menu_items.claude_ai = {
        text         = _("Claude AI"),
        sorting_hint = "tools",
        sub_item_table = {
            -- "Ask Claude" – the main search-like Q&A entry
            {
                text         = _("Ask Claude "),
                help_text    = _("Ask Claude any question about the book you're reading"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback     = function() self:showBookQADialog() end,
            },
            {
                text         = _("Explain Highlighted Text"),
                help_text    = _("Get Claude to explain the currently selected text"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback     = function() self:explainCurrentSelection() end,
            },
            {
                text         = _("Load Book into Claude"),
                help_text    = _("Read the full book so Claude can answer detailed questions"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback     = function() self:loadBookText() end,
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

    -- Try to inject an "Ask Claude" button into the text-selection popup.
    -- addToHighlightDialog is available in KOReader 2023+; we wrap in pcall
    -- so older builds simply skip this and users rely on the menu instead.
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        pcall(function()
            self.ui.highlight:addToHighlightDialog(
                "claude_explain",
                function(dlg)
                    return {
                        text     = _("Ask Claude"),
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

    local loading = InfoMessage:new{ text = _("Asking Claude…") }
    UIManager:show(loading)

    local system_prompt = [[You are a reading assistant inside an e-reader application.
When the user highlights text from their book, identify what it is and respond concisely:
• Person's name  → 2-3 sentence biography or character description
• Place name     → brief description of the location or setting
• Foreign/rare word or phrase → definition + translation if needed
• Technical term or concept  → plain-language explanation
• A passage or quote         → explain meaning and context
Keep your answer under 150 words. Do not repeat the highlighted text at the start of your reply.]]

    local ok, response = ClaudeAPI:query(
        self.api_key,
        system_prompt,
        'Explain this text from the book I\'m reading: "' .. text .. '"'
    )
    UIManager:close(loading)

    if ok then
        UIManager:show(TextViewer:new{
            title  = _("Claude AI"),
            text   = "\226\128\156" .. text .. "\226\128\157\n\n" .. response,
            height = math.floor(Screen:getHeight() * 0.72),
            width  = math.floor(Screen:getWidth()  * 0.92),
        })
    else
        UIManager:show(InfoMessage:new{
            text    = _("Claude error: ") .. response,
            timeout = 5,
        })
    end
end

-- ── Load book text ────────────────────────────────────────────────────────────

function ClaudePlugin:loadBookText()
    if not self.ui.document then return end

    local page_count = self.ui.document:getPageCount()
    UIManager:show(InfoMessage:new{
        text    = string.format(_("Loading %d pages into Claude context…"), page_count),
        timeout = 2,
    })

    local parts     = {}
    local total_len = 0
    local MAX_CHARS = 150000   -- ~37 K tokens – fits comfortably in Claude's window

    for page = 1, page_count do
        local ok, text = pcall(function()
            return self.ui.document:getPageText(page)
        end)
        if ok and text and text ~= "" then
            table.insert(parts, text)
            total_len = total_len + #text
        end
        if total_len >= MAX_CHARS then
            table.insert(parts, string.format(
                "\n\n[Book truncated at page %d of %d to fit context window]",
                page, page_count))
            break
        end
    end

    self.book_text = table.concat(parts, "\n\n")

    UIManager:show(InfoMessage:new{
        text    = string.format(
            _("Book loaded! %d characters ready.\nNow use 'Ask Claude' to ask questions."),
            #self.book_text),
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
                "Load the full book first so Claude can give accurate answers?\n\n"
                .. "Tap 'Load Book' to read it now, or 'Skip' to ask using "
                .. "Claude's general knowledge."),
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
        title       = _("Ask Claude 🔍"),
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
    local loading = InfoMessage:new{ text = _("Asking Claude…") }
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
            self.book_text:sub(1, 150000))
    else
        system_prompt = string.format(
            'You are a helpful reading assistant. '
            .. 'The user is reading "%s". '
            .. 'Answer their question using your general knowledge of this book. '
            .. 'If you are unsure, say so.',
            title)
    end

    local ok, response = ClaudeAPI:query(self.api_key, system_prompt, question)
    UIManager:close(loading)

    if ok then
        UIManager:show(TextViewer:new{
            title  = _("Claude"),
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
    local dialog
    dialog = InputDialog:new{
        title       = _("Claude API Key"),
        description = _("Get your key at: console.anthropic.com\nOr edit claude_config.lua in the plugin folder."),
        input       = self.api_key,
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
                        if key and key ~= "" then
                            self.api_key = key
                            self.settings:saveSetting("api_key", key)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{
                                text    = _("API key saved!"),
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
    if not self.api_key or self.api_key == "" then
        UIManager:show(InfoMessage:new{
            text    = _("Claude AI: no API key configured.\nMenu → Claude AI → Configure API Key"),
            timeout = 4,
        })
        return false
    end
    return true
end

return ClaudePlugin
