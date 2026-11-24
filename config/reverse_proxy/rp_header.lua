-- SPDX-License-Identifier: Apache-2.0
-- header_filter_by_lua_file for LNMP reverse proxy managed sites.

local h = ngx.header
local upstream_host = tostring(ngx.var.rp_upstream_host or "")
local public_host = tostring(ngx.var.rp_public_host or "")
local public_origin = tostring(ngx.var.rp_public_origin or "")

local function escape(s)
  return (tostring(s):gsub("([%[%]%.%/%)%(%)%+%-%?%*%^%$%%])", "%%%1"))
end

-- Rewrite Location headers that point at the upstream origin.
if h.location and upstream_host ~= "" then
  local uh = escape(upstream_host)
  local loc = tostring(h.location)
  loc = loc:gsub("https://" .. uh, function()
    return public_origin
  end)
  loc = loc:gsub("http://" .. uh, function()
    return public_origin
  end)
  loc = loc:gsub("//" .. uh, function()
    return "//" .. public_host
  end)
  h.location = loc
end

-- Rewrite Domain attributes on Set-Cookie. Never invent a Domain for
-- __Host- cookies; only replace an existing exact match.
local cookies = h.set_cookie
if cookies and upstream_host ~= "" then
  if type(cookies) == "string" then
    cookies = { cookies }
  end
  local out = {}
  local uh = upstream_host:lower()
  for i, c in ipairs(cookies) do
    out[i] = tostring(c):gsub("([Dd]omain%s*=%s*)([^;%s]+)", function(prefix, dom)
      if dom:lower() == uh then
        return prefix .. public_host
      end
      return prefix .. dom
    end)
  end
  h.set_cookie = out
end

-- Decide whether the body rewriter may run. Compression is passed through:
-- Lua would see compressed bytes and could not rewrite them safely.
local content_type = tostring(h.content_type or ""):lower()
local content_encoding = h.content_encoding
local body_ok = false
if not content_encoding then
  if content_type:match("^text/")
    or content_type:match("^application/javascript")
    or content_type:match("^application/json")
    or content_type:match("^application/xml") then
    body_ok = true
  end
end

ngx.ctx.rp_body_ok = body_ok
if body_ok then
  h.content_length = nil
end
