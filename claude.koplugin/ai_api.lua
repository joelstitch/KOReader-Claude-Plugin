-- AI provider HTTP client
-- Sends requests to Anthropic, DeepSeek or MiniMax and returns the text response.
-- One shared transport; providers differ only in endpoint, auth headers,
-- request body shape and response parsing.

local ltn12  = require("ltn12")
local logger = require("logger")

local https_ok, https = pcall(require, "ssl.https")
local json_ok,  json  = pcall(require, "rapidjson")
if not json_ok then
    json_ok, json = pcall(require, "json")
end

local AIAPI = {}

-- Provider spec fields:
--   id            – registry key, also the stored setting value
--   label         – UI label for menus/toasts/dialog titles
--   key_setting   – field name in BOTH claude_settings.lua and claude_config.lua
--   endpoint      – full POST URL
--   model         – model id string
--   max_tokens    – response budget
--   max_bytes     – cap for book text loaded into context (bytes, not chars)
--   key_url       – where the user gets a key (shown in the Configure dialog)
--   build_headers(spec, api_key) -> header map (no Content-Type/Length,
--                                    the transport adds both)
--   build_body(spec, system_prompt, user_message) -> table for json.encode
--   parse(spec, parsed) -> text or (nil, errmsg)

local function bearer_headers(_, api_key)
    return { ["Authorization"] = "Bearer " .. api_key }
end

-- OpenAI-style: system as messages[1], user as messages[2];
-- text in choices[1].message.content
local function openai_body(self, system, user)
    return {
        model      = self.model,
        max_tokens = self.max_tokens,
        stream     = false,   -- explicit: we do not read SSE
        messages   = {
            { role = "system", content = system },
            { role = "user",   content = user },
        },
    }
end

local function openai_parse(_, p)
    local m = p.choices and p.choices[1] and p.choices[1].message
    if m and type(m.content) == "string" and m.content ~= "" then
        return m.content
    end
    if p.output_sensitive then
        return nil, "Response filtered (sensitive content)"
    end
    return nil, AIAPI._extract_error(p)
end

local function anthropic_body(self, system, user)
    return {
        model      = self.model,
        max_tokens = self.max_tokens,
        system     = system,
        messages   = { { role = "user", content = user } },
    }
end

local function anthropic_parse(_, p)
    local c = p.content
    if type(c) == "table" and type(c[1]) == "table"
            and type(c[1].text) == "string" and c[1].text ~= "" then
        return c[1].text
    end
    return nil, AIAPI._extract_error(p)
end

local PROVIDERS = {
    anthropic = {
        id          = "anthropic",
        label       = "Anthropic Claude",
        key_setting = "api_key",    -- legacy field name, kept for existing installs
        endpoint    = "https://api.anthropic.com/v1/messages",
        model       = "claude-sonnet-4-6",
        max_tokens  = 1024,
        max_bytes   = 150000,
        key_url     = "https://console.anthropic.com",
        build_headers = function(_, key)
            return {
                ["x-api-key"]         = key,
                ["anthropic-version"] = "2023-06-01",
            }
        end,
        build_body = anthropic_body,
        parse      = anthropic_parse,
    },
    deepseek = {
        id          = "deepseek",
        label       = "DeepSeek",
        key_setting = "deepseek_key",
        endpoint    = "https://api.deepseek.com/chat/completions",
        model       = "deepseek-v4-flash",
        max_tokens  = 2048,
        max_bytes   = 300000,
        key_url     = "https://platform.deepseek.com",
        build_headers = bearer_headers,
        build_body    = openai_body,
        parse         = openai_parse,
    },
    minimax = {
        id          = "minimax",
        label       = "MiniMax",
        key_setting = "minimax_key",
        -- International platform. CN users: replace with
        -- https://api.minimaxi.com/v1/chat/completions (keys are region-bound).
        endpoint    = "https://api.minimax.io/v1/chat/completions",
        model       = "MiniMax-M3",
        max_tokens  = 2048,
        max_bytes   = 300000,
        key_url     = "https://platform.minimax.io",
        build_headers = bearer_headers,
        parse         = openai_parse,
        build_body = function(self, system, user)
            local body = openai_body(self, system, user)
            body.max_tokens = nil               -- deprecated on MiniMax
            body.max_completion_tokens = self.max_tokens
            body.thinking = { type = "disabled" } -- M3 accepts this: clean prose,
                                                  -- no <think> blocks in content
            return body
        end,
    },
}

-- Explicit menu order (never iterate the map directly: hash order is arbitrary)
local PROVIDER_ORDER = { "anthropic", "deepseek", "minimax" }

AIAPI.providers = PROVIDERS

-- Extracts a human-readable message from all known error shapes:
-- Anthropic + OpenAI-style {error = {message = ...}} and
-- MiniMax base_resp = {status_code, status_msg} (present even on HTTP 200).
function AIAPI._extract_error(parsed)
    if type(parsed) ~= "table" then return nil end
    if type(parsed.error) == "table"
            and type(parsed.error.message) == "string"
            and parsed.error.message ~= "" then
        return parsed.error.message
    end
    if type(parsed.base_resp) == "table" then
        local msg  = parsed.base_resp.status_msg
        local code = parsed.base_resp.status_code
        if msg and msg ~= "" then
            return tostring(code or "") .. ": " .. msg
        end
    end
    return nil
end

function AIAPI:getProvider(provider_id)
    return PROVIDERS[tostring(provider_id or "")]
end

function AIAPI:listProviderIds()
    return PROVIDER_ORDER
end

function AIAPI:getLabel(provider_id)
    local spec = AIAPI:getProvider(provider_id)
    return spec and spec.label or "AI"
end

-- query(provider_id, api_key, system_prompt, user_message)
-- Returns: ok (bool), text_or_error (string)
function AIAPI:query(provider_id, api_key, system_prompt, user_message)
    local spec = AIAPI:getProvider(provider_id)
    if not spec then
        return false, "Unknown AI provider: " .. tostring(provider_id)
    end
    if type(api_key) ~= "string" or api_key == "" then
        return false, spec.label .. ": no API key configured. "
            .. "Go to Tools -> AI Assistant -> Configure API Key"
    end
    if not https_ok then
        return false, "SSL/HTTPS not available on this device"
    end
    if not json_ok then
        return false, "JSON module (rapidjson) not available"
    end

    local enc_ok, body = pcall(json.encode, spec.build_body(spec, system_prompt, user_message))
    if not enc_ok then
        return false, "Failed to encode request: " .. tostring(body)
    end

    local headers = spec.build_headers(spec, api_key)
    headers["Content-Type"]   = "application/json"
    headers["Content-Length"] = tostring(#body)

    local chunks = {}
    local req_ok, code = https.request({
        url     = spec.endpoint,
        method  = "POST",
        headers = headers,
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(chunks),
        timeout = 60,
    })

    if not req_ok then
        logger.warn("AIAPI: connection error:", code)
        return false, "Connection failed: " .. tostring(code)
    end

    local raw = table.concat(chunks)

    if code ~= 200 then
        logger.warn("AIAPI: HTTP", code, (raw or ""):sub(1, 300))
        local p_ok, p = pcall(json.decode, raw)
        if p_ok and type(p) == "table" and AIAPI._extract_error(p) then
            return false, "API error: " .. AIAPI._extract_error(p)
        end
        return false, "API returned HTTP " .. tostring(code)
    end

    local p_ok, parsed = pcall(json.decode, raw)
    if not p_ok or type(parsed) ~= "table" then
        return false, "Failed to parse API response"
    end

    local text, err = spec.parse(spec, parsed)
    if text then
        return true, text
    end
    return false, err or "Unexpected response format"
end

return AIAPI
