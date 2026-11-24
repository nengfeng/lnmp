-- SPDX-License-Identifier: Apache-2.0
-- header_filter_by_lua_file for LNMP reverse proxy managed sites.

local h = ngx.header
local upstream_origin = tostring(ngx.var.rp_upstream_origin or "")
local upstream_host = tostring(ngx.var.rp_upstream_host or "")
local public_host = tostring(ngx.var.rp_public_host or "")
local public_origin = tostring(ngx.var.rp_public_origin or "")

local function escape(s)
  return (tostring(s):gsub("([%[%]%.%/%)%(%)%+%-%?%*%^%$%%])", "%%%1"))
end

local origin_scheme_end = upstream_origin:find("://", 1, true)
local origin_host = upstream_origin
if origin_scheme_end then
  origin_host = upstream_origin:sub(origin_scheme_end + 3)
end
local uh = escape(origin_host)

local function replace_bounded(s, prefix_pat, replacement)
  local pat = "(" .. prefix_pat .. uh .. ")"
  local out = {}
  local search = 1
  while search <= #s do
    local st, en = s:find(pat, search, false)
    if not st then
      out[#out + 1] = s:sub(search)
      break
    end

    local port_end = en
    if s:sub(en + 1, en + 1) == ":" then
      local j = en + 2
      while s:sub(j, j):match("%d") do
        j = j + 1
      end
      if j > en + 2 then
        port_end = j - 1
      end
    end

    local nxt = s:sub(port_end + 1, port_end + 1)
    local ok = false
    if nxt == "" then
      ok = true
    elseif nxt:match("^[A-Za-z0-9_~-]") then
      ok = false
    elseif nxt == "." then
      local after = s:sub(port_end + 2, port_end + 2)
      if after == "" then
        ok = true
      elseif after:match("^[A-Za-z0-9_-]") then
        ok = false
      else
        ok = true
      end
    else
      ok = true
    end

    if ok then
      out[#out + 1] = s:sub(search, st - 1)
      out[#out + 1] = replacement
    else
      out[#out + 1] = s:sub(search, port_end)
    end
    search = port_end + 1
  end
  return table.concat(out)
end

-- Rewrite Location headers that point at the upstream origin. The port is
-- consumed with the host so an upstream port never leaks onto A.
if h.location and uh ~= "" then
  local loc = tostring(h.location)
  loc = replace_bounded(loc, "https?://", public_origin)
  loc = replace_bounded(loc, "//", "//" .. public_host)
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
      local dom_l = dom:lower()
      local dom_host = dom_l:gsub("^%.", ""):match("^([^:]+)") or dom_l
      if dom_host == uh then
        local repl = public_host
        if dom_l:sub(1, 1) == "." then
          repl = "." .. public_host
        end
        return prefix .. repl
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
