-- Claude API HTTP client
-- Sends requests to api.anthropic.com/v1/messages and returns the text response.

local ltn12  = require("ltn12")
local logger = require("logger")

local https_ok, https = pcall(require, "ssl.https")
local json_ok,  json  = pcall(require, "rapidjson")
if not json_ok then
    json_ok, json = pcall(require, "json")
end

local ClaudeAPI = {}
ClaudeAPI.API_URL = "https://api.anthropic.com/v1/messages"
ClaudeAPI.MODEL   = "claude-sonnet-4-6"

-- query(api_key, system_prompt, user_message)
-- Returns: ok (bool), text_or_error (string)
function ClaudeAPI:query(api_key, system_prompt, user_message)
    if not api_key or api_key == "" then
        return false, "No API key configured. Go to Menu → Claude AI → Configure API Key"
    end
    if not https_ok then
        return false, "SSL/HTTPS not available on this device"
    end
    if not json_ok then
        return false, "JSON module (rapidjson) not available"
    end

    local enc_ok, body = pcall(json.encode, {
        model      = self.MODEL,
        max_tokens = 1024,
        system     = system_prompt,
        messages   = {{ role = "user", content = user_message }},
    })
    if not enc_ok then
        return false, "Failed to encode request: " .. tostring(body)
    end

    local chunks = {}
    local req_ok, code = https.request({
        url    = self.API_URL,
        method = "POST",
        headers = {
            ["Content-Type"]      = "application/json",
            ["x-api-key"]         = api_key,
            ["anthropic-version"] = "2023-06-01",
            ["Content-Length"]    = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(chunks),
    })

    if not req_ok then
        logger.warn("ClaudeAPI: connection error:", code)
        return false, "Connection failed: " .. tostring(code)
    end

    local raw = table.concat(chunks)

    if code ~= 200 then
        logger.warn("ClaudeAPI: HTTP", code, raw:sub(1, 300))
        local p_ok, p = pcall(json.decode, raw)
        if p_ok and p and p.error then
            return false, "API error: " .. (p.error.message or tostring(code))
        end
        return false, "API returned HTTP " .. tostring(code)
    end

    local p_ok, parsed = pcall(json.decode, raw)
    if not p_ok or type(parsed) ~= "table" then
        return false, "Failed to parse API response"
    end

    if parsed.content and parsed.content[1] and parsed.content[1].text then
        return true, parsed.content[1].text
    end

    if parsed.error then
        return false, parsed.error.message or "Unknown API error"
    end

    return false, "Unexpected response format"
end

return ClaudeAPI
