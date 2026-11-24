-- SPDX-License-Identifier: Apache-2.0
-- Pure-Lua tests for config/reverse_proxy/rp_rewrite.lua.
-- Run with luajit or lua: tools/test_reverse_proxy_lua.lua

local root = "."
if arg and arg[0] then
  root = arg[0]:match("^(.*)/tools/") or "."
end
package.path = root .. "/config/reverse_proxy/?.lua;" .. package.path

local m = require("rp_rewrite")

local pass, fail = 0, 0
local function ok(msg)
  pass = pass + 1
  print("  [PASS] " .. msg)
end
local function ko(msg)
  fail = fail + 1
  print("  [FAIL] " .. msg)
end
local function eq(got, want, msg)
  if got == want then
    ok(msg)
  else
    ko(msg .. " (got [" .. tostring(got) .. "], want [" .. tostring(want) .. "])")
  end
end

local opts = {
  upstream_origin = "https://b.example.com:8443",
  public_origin = "https://a.example.com",
  public_host = "a.example.com",
  watermark = 16,
  max_bytes = 8 * 1024 * 1024,
  min_overlap = 64,
}

local function process_all(body, chunks, overrides)
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  if overrides then
    for k, v in pairs(overrides) do o[k] = v end
  end
  local st = m.new_state()
  local out = {}
  for i, c in ipairs(chunks) do
    out[#out + 1] = m.process_chunk(st, c, i == #chunks, o)
  end
  return table.concat(out)
end

-- Basic literal rewriting.
eq(
  m.rewrite_text("x https://b.example.com:8443/a y //b.example.com:8443/z", opts.upstream_origin, opts.public_origin, opts.public_host),
  "x https://a.example.com/a y //a.example.com/z",
  "literal scheme and protocol-relative replacement"
)

eq(
  m.rewrite_text("x http://[::1]:8080/a y", "http://[::1]:8080", "http://a.example", "a.example"),
  "x http://a.example/a y",
  "IPv6-literal upstream escaping"
)

-- Every two-chunk split of a body must match one-shot rewriting.
local full = "head https://b.example.com:8443/path tail http://b.example.com:8443/x //b.example.com:8443/y end"
local expected = m.rewrite_text(full, opts.upstream_origin, opts.public_origin, opts.public_host)
local split_ok = true
for split = 1, #full - 1 do
  local got = process_all(full, { full:sub(1, split), full:sub(split + 1) })
  if got ~= expected then
    split_ok = false
    ko("two-chunk split at " .. split)
    break
  end
end
if split_ok then ok("all two-chunk splits match one-shot rewrite") end

-- One-byte chunks.
local one_byte = {}
for i = 1, #full do
  one_byte[#one_byte + 1] = full:sub(i, i)
end
eq(process_all(full, one_byte), expected, "one-byte chunks match one-shot rewrite")

-- Watermark flushing with a body long enough to cross the watermark.
local long_body = ("abc//b.example.com:8443/defhttps://b.example.com:8443/ghi"):rep(8)
expected = m.rewrite_text(long_body, opts.upstream_origin, opts.public_origin, opts.public_host)
local wm_ok = true
math.randomseed(1234)
for trial = 1, 200 do
  local chunks = {}
  local i = 1
  while i <= #long_body do
    local n = math.random(1, 7)
    chunks[#chunks + 1] = long_body:sub(i, i + n - 1)
    i = i + n
  end
  local got = process_all(long_body, chunks, { watermark = 16, max_bytes = 100000 })
  if got ~= expected then
    wm_ok = false
    ko("watermark trial " .. trial)
    break
  end
end
if wm_ok then ok("watermark flushing matches one-shot rewrite") end

-- eof chunk is non-empty and carries the last part of a URL.
eq(
  process_all("abhttps://b.example.com:8443/cd", { "ab", "https://b.example.com:8443/", "cd" }),
  "abhttps://a.example.com/cd",
  "eof chunk appended before final rewrite"
)

-- Empty intermediate/eof chunks.
local expected_full = m.rewrite_text(full, opts.upstream_origin, opts.public_origin, opts.public_host)
eq(
  process_all(full, { "", full:sub(1, 10), "", full:sub(11), "" }),
  expected_full,
  "empty chunks do not lose data"
)

-- Over-max passthrough keeps the tail verbatim.
local prefix = string.rep("abcdefghij", 40) -- 400 bytes, no URL markers
local tail = "TAIL-MARKER-0123456789"
local over_body = prefix .. tail
local over_got = process_all(over_body, { over_body }, { watermark = 16, max_bytes = 100 })
if over_got:sub(-#tail) == tail then
  ok("over-max tail preserved verbatim")
else
  ko("over-max tail lost")
end

print()
print("Lua reverse proxy tests: " .. pass .. " passed, " .. fail .. " failed")
if fail ~= 0 then
  os.exit(1)
end
