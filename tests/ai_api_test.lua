-- Test harness for claude.koplugin/ai_api.lua
-- Runs on plain Lua 5.1/LuaJIT with NO external deps and NO real API calls.
-- Every dependency of ai_api.lua is stubbed via package.preload, and the
-- module is reloaded per scenario to exercise its load-time guards.
--
--   lua5.1 tests/ai_api_test.lua        (or luajit)

local PLUGIN_DIR = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = PLUGIN_DIR .. "/../claude.koplugin/?.lua;" .. package.path

-- ── Deterministic mini JSON encoder (valid JSON for our controlled inputs) ────

local function mini_json_encode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return string.format("%.14g", v) end
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        if v[1] ~= nil then
            local parts = {}
            for i = 1, #v do parts[#parts + 1] = mini_json_encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = string.format("%q", tostring(k))
                .. ":" .. mini_json_encode(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("mini_json_encode: unsupported type " .. t)
end

-- ── Scenario state, visible to the stubs through closures ─────────────────────

local state = {
    http_ok        = true,
    http_code      = 200,
    resp_body      = "",
    decode_fixture = nil,   -- table returned by json.decode
    decode_error   = nil,   -- error string thrown by json.decode
    captured       = nil,   -- request table handed to https.request
    captured_body  = nil,   -- request body drained from the ltn12 source
}

local function stub_json()
    return {
        encode = mini_json_encode,
        decode = function(raw)
            if state.decode_error then error(state.decode_error) end
            return state.decode_fixture
        end,
    }
end

package.preload["logger"] = function()
    return { warn = function() end, info = function() end }
end

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(s)
                local sent = false
                return function()
                    if sent then return nil end
                    sent = true
                    return s
                end
            end,
        },
        sink = {
            table = function(t)
                return function(chunk)
                    if chunk then t[#t + 1] = chunk end
                end
            end,
        },
    }
end

local function stub_https()
    return {
        request = function(req)
            state.captured = req
            local body = ""
            if type(req.source) == "function" then
                local chunk
                repeat
                    chunk = req.source()
                    if chunk then body = body .. chunk end
                until chunk == nil
            end
            state.captured_body = body
            if req.sink then req.sink(state.resp_body) end
            return state.http_ok, state.http_code
        end,
    }
end

package.preload["ssl.https"] = stub_https
package.preload["rapidjson"] = stub_json
package.preload["json"]      = stub_json

-- ── Harness plumbing ───────────────────────────────────────────────────────────

local passed, failed = 0, 0

local function check(name, cond, extra)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (extra and ("  [" .. extra .. "]") or ""))
    end
end

local function reset_loaded()
    package.loaded["ai_api"] = nil
    package.loaded["rapidjson"] = nil
    package.loaded["json"] = nil
    package.loaded["ssl.https"] = nil
end

-- Runs one query scenario: (re)loads the module with the given stubs active.
-- disable_* flags simulate the corresponding module being absent.
local function fresh_query(overrides, provider, key, sys, user)
    reset_loaded()
    if overrides.disable_rapidjson then package.preload["rapidjson"] = nil
    else package.preload["rapidjson"] = stub_json end
    if overrides.disable_json then package.preload["json"] = nil
    else package.preload["json"] = stub_json end
    if overrides.disable_https then package.preload["ssl.https"] = nil
    else package.preload["ssl.https"] = stub_https end
    if overrides.http_ok == false then state.http_ok = false else state.http_ok = true end
    state.http_code      = overrides.http_code or 200
    state.resp_body      = overrides.resp_body or ""
    state.decode_fixture = overrides.decode_fixture
    state.decode_error   = overrides.decode_error
    state.captured       = nil
    state.captured_body  = nil
    local AIAPI = require("ai_api")
    return AIAPI:query(provider, key, sys, user)
end

local SYS = "system prompt"
local USR = "user message"

local function assert_body_matches(name, expected)
    check(name .. " body shape", state.captured_body == mini_json_encode(expected),
        "got " .. tostring(state.captured_body))
end

-- ── Registry checks ────────────────────────────────────────────────────────────

reset_loaded()
local AIAPI = require("ai_api")

check("getProvider('') is nil", AIAPI:getProvider("") == nil)
check("getProvider('anthropic') exists", type(AIAPI:getProvider("anthropic")) == "table")
check("getProvider('minimax') exists", type(AIAPI:getProvider("minimax")) == "table")
local ids = AIAPI:listProviderIds()
check("listProviderIds order", #ids == 3 and ids[1] == "anthropic"
    and ids[2] == "deepseek" and ids[3] == "minimax")
check("getLabel unknown -> AI", AIAPI:getLabel("nope") == "AI")
check("getLabel minimax", AIAPI:getLabel("minimax") == "MiniMax")
check("unknown provider query fails",
    select(2, AIAPI:query("bogus", "k", SYS, USR)):find("Unknown AI provider", 1, true) ~= nil)

-- ── Anthropic ──────────────────────────────────────────────────────────────────

local ok, err = fresh_query({
    decode_fixture = { content = { { type = "text", text = "hello" } } },
}, "anthropic", "sk-ant-test", SYS, USR)
check("anthropic success", ok == true and err == "hello")
check("anthropic URL", state.captured.url == "https://api.anthropic.com/v1/messages")
check("anthropic x-api-key header", state.captured.headers["x-api-key"] == "sk-ant-test")
check("anthropic version header", state.captured.headers["anthropic-version"] == "2023-06-01")
check("anthropic no Bearer header", state.captured.headers["Authorization"] == nil)
check("anthropic Content-Length", state.captured.headers["Content-Length"] == tostring(#state.captured_body))
assert_body_matches("anthropic", {
    model = "claude-sonnet-4-6",
    max_tokens = 1024,
    system = SYS,
    messages = { { role = "user", content = USR } },
})

ok, err = fresh_query({
    http_code = 401,
    decode_fixture = { error = { type = "authentication_error", message = "invalid x-api-key" } },
}, "anthropic", "sk-ant-test", SYS, USR)
check("anthropic 401 surfaces error.message", ok == false
    and err:find("invalid x-api-key", 1, true) ~= nil)

-- ── DeepSeek ───────────────────────────────────────────────────────────────────

ok, err = fresh_query({
    decode_fixture = { choices = { { message = { role = "assistant", content = "hi" } } } },
}, "deepseek", "sk-ds-test", SYS, USR)
check("deepseek success", ok == true and err == "hi")
check("deepseek URL", state.captured.url == "https://api.deepseek.com/chat/completions")
check("deepseek Bearer header", state.captured.headers["Authorization"] == "Bearer sk-ds-test")
check("deepseek no x-api-key header", state.captured.headers["x-api-key"] == nil)
assert_body_matches("deepseek", {
    model = "deepseek-v4-flash",
    max_tokens = 2048,
    stream = false,
    messages = {
        { role = "system", content = SYS },
        { role = "user", content = USR },
    },
})

-- ── MiniMax ────────────────────────────────────────────────────────────────────

ok, err = fresh_query({
    decode_fixture = {
        choices = { { message = { content = "ok" } } },
        base_resp = { status_code = 0, status_msg = "success" },
    },
}, "minimax", "sk-api-mm-test", SYS, USR)
check("minimax success", ok == true and err == "ok")
check("minimax URL", state.captured.url == "https://api.minimax.io/v1/chat/completions")
check("minimax Bearer header", state.captured.headers["Authorization"] == "Bearer sk-api-mm-test")
assert_body_matches("minimax", {
    model = "MiniMax-M3",
    stream = false,
    max_completion_tokens = 2048,
    thinking = { type = "disabled" },
    messages = {
        { role = "system", content = SYS },
        { role = "user", content = USR },
    },
})

ok, err = fresh_query({
    decode_fixture = { choices = {}, base_resp = { status_code = 1004, status_msg = "not authorized" } },
}, "minimax", "sk-api-mm-test", SYS, USR)
check("minimax 200-with-base_resp error", ok == false
    and err:find("not authorized", 1, true) ~= nil)

ok, err = fresh_query({
    decode_fixture = {
        choices = { { message = { content = "" } } },
        output_sensitive = true,
        base_resp = { status_code = 0, status_msg = "" },
    },
}, "minimax", "sk-api-mm-test", SYS, USR)
check("minimax output_sensitive flagged", ok == false
    and err:find("sensitive", 1, true) ~= nil)

-- ── Transport edges ────────────────────────────────────────────────────────────

ok, err = fresh_query({
    decode_fixture = { choices = { { message = { content = "" } } } },
}, "deepseek", "sk-ds-test", SYS, USR)
check("openai empty content -> unexpected format", ok == false
    and err == "Unexpected response format")

ok, err = fresh_query({
    http_ok = false,
    http_code = "connection refused",
}, "anthropic", "sk-ant-test", SYS, USR)
check("connection failure", ok == false and err:find("Connection failed", 1, true) ~= nil)

ok, err = fresh_query({
    http_code = 500,
    resp_body = "<html>oops</html>",
    decode_error = "JSON syntax error",
}, "anthropic", "sk-ant-test", SYS, USR)
check("HTTP 500 garbage body -> generic message", ok == false
    and err == "API returned HTTP 500")

ok, err = fresh_query({
    decode_error = "truncated JSON",
}, "anthropic", "sk-ant-test", SYS, USR)
check("truncated JSON on 200", ok == false
    and err == "Failed to parse API response")

ok, err = fresh_query({
    decode_fixture = nil,   -- decode "succeeds" but returns nil
}, "anthropic", "sk-ant-test", SYS, USR)
check("decode returns nil", ok == false and err == "Failed to parse API response")

ok, err = fresh_query({
    decode_fixture = { choices = { { message = { content = "hi" } } } },
}, "deepseek", "", SYS, USR)
check("empty key names provider", ok == false and err:find("DeepSeek", 1, true) ~= nil)

-- ── Module load-time guards ────────────────────────────────────────────────────

ok, err = fresh_query({
    disable_rapidjson = true,   -- simulate rapidjson missing; fall back to json
    decode_fixture = { choices = { { message = { content = "fb" } } } },
}, "deepseek", "sk-ds-test", SYS, USR)
check("rapidjson missing -> json fallback works", ok == true and err == "fb")

ok, err = fresh_query({
    disable_https = true,       -- simulate missing LuaSec
}, "anthropic", "sk-ant-test", SYS, USR)
check("no ssl.https gate", ok == false
    and err:find("SSL/HTTPS not available", 1, true) ~= nil)

ok, err = fresh_query({
    disable_rapidjson = true,
    disable_json      = true,   -- no JSON module at all
}, "anthropic", "sk-ant-test", SYS, USR)
check("no JSON module gate", ok == false
    and err:find("JSON module", 1, true) ~= nil)

-- ── Summary ────────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
