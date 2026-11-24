-- SPDX-License-Identifier: Apache-2.0
-- Pure-Lua helpers for the LNMP reverse proxy body rewriter.
--
-- This file deliberately avoids ngx.* so it can be exercised directly with
-- luajit/lua. rp_body.lua is only the nginx glue layer around this module.

local M = {}

M.VERSION = "1.0"

-- Escape a literal string for use in a Lua pattern.
function M.escape(s)
  return (tostring(s):gsub("([%[%]%.%/%)%(%)%+%-%?%*%^%$%%])", "%%%1"))
end

-- Rewrite upstream origins in a text segment.
--
-- upstream_origin is the normalized base URL of B, for example
-- "https://b.example.com:8443". public_origin is A's base URL. public_host is
-- A's host name, used for protocol-relative URLs.
function M.rewrite_text(text, upstream_origin, public_origin, public_host)
  text = tostring(text)
  upstream_origin = tostring(upstream_origin or "")
  public_origin = tostring(public_origin or "")
  public_host = tostring(public_host or "")

  local scheme_end = upstream_origin:find("://", 1, true)
  local upstream_host = upstream_origin
  if scheme_end then
    upstream_host = upstream_origin:sub(scheme_end + 3)
  end
  local uh = M.escape(upstream_host)

  if uh ~= "" then
    text = text:gsub("https://" .. uh, function()
      return public_origin
    end)
    text = text:gsub("http://" .. uh, function()
      return public_origin
    end)
    text = text:gsub("//" .. uh, function()
      return "//" .. public_host
    end)
  end

  return text
end

-- Find the earliest position in buf[from..stop] that could start one of the
-- literal patterns handled by rewrite_text(). This is intentionally
-- conservative: any "//" is treated as a possible match start.
function M.find_min_start(buf, from, stop)
  if from < 1 then
    from = 1
  end
  if stop > #buf then
    stop = #buf
  end
  if from > stop then
    return nil
  end

  local best
  for _, p in ipairs({ "https://", "http://", "//" }) do
    local pos = string.find(buf, p, from, true)
    if pos and pos <= stop and (not best or pos < best) then
      best = pos
    end
  end
  return best
end

function M.new_state()
  return {
    buf = "",
    total = 0,
    skip = false,
  }
end

-- Process one body-filter chunk.
--
-- state   : table from new_state(), reused across calls for one response
-- chunk   : string for this filter call (may be empty)
-- eof     : boolean, true when ngx.arg[2] is true
-- opts    : table with upstream_origin / public_origin / public_host /
--           watermark / max_bytes / min_overlap
--
-- Returns the string to send downstream for this call ("" means hold).
function M.process_chunk(state, chunk, eof, opts)
  chunk = chunk or ""
  opts = opts or {}

  if state.skip then
    return chunk
  end

  state.buf = state.buf .. chunk
  state.total = state.total + #chunk

  local max_bytes = tonumber(opts.max_bytes) or (8 * 1024 * 1024)
  if state.total > max_bytes then
    local out = M.rewrite_text(
      state.buf,
      opts.upstream_origin,
      opts.public_origin,
      opts.public_host
    )
    state.buf = ""
    state.skip = true
    return out
  end

  local upstream_origin = tostring(opts.upstream_origin or "")
  local min_overlap = tonumber(opts.min_overlap) or 64
  local overlap = math.max(min_overlap, #upstream_origin + 16)
  local watermark = tonumber(opts.watermark) or (1024 * 1024)

  local out = {}
  local n = #state.buf
  if n >= watermark + 2 * overlap then
    local cut = n - overlap
    while true do
      if cut < 1 then
        cut = nil
        break
      end
      local from = math.max(1, cut - overlap + 1)
      local p = M.find_min_start(state.buf, from, cut)
      if not p then
        break
      end
      if p - 1 < watermark then
        cut = nil
        break
      end
      cut = p - 1
    end

    if cut and cut >= watermark then
      out[#out + 1] = M.rewrite_text(
        state.buf:sub(1, cut),
        upstream_origin,
        opts.public_origin,
        opts.public_host
      )
      state.buf = state.buf:sub(cut + 1)
    end
  end

  if eof and state.buf ~= "" then
    out[#out + 1] = M.rewrite_text(
      state.buf,
      upstream_origin,
      opts.public_origin,
      opts.public_host
    )
    state.buf = ""
  end

  return table.concat(out)
end

return M
