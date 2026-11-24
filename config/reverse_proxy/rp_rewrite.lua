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

-- Return the host portion of an origin without its explicit port.
-- IPv6 literals keep their brackets.
function M.host_without_port(origin)
  local s = tostring(origin or "")
  local scheme_end = s:find("://", 1, true)
  if scheme_end then
    s = s:sub(scheme_end + 3)
  end
  if s:sub(1, 1) == "[" then
    local close = s:find("]", 2, true)
    if close then
      return s:sub(1, close)
    end
    return s
  end
  local port_sep = s:find(":", 1, true)
  if port_sep then
    return s:sub(1, port_sep - 1)
  end
  return s
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

  -- Match the host without assuming its explicit port: bodies may use
  -- https://b.example.com/x while the configured upstream is :8443.
  local uh = M.escape(M.host_without_port(upstream_origin))

  if uh ~= "" then
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

        -- Consume an explicit numeric port together with the host so an
        -- upstream port can never leak onto A's public origin.
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
          -- A period is a valid sentence end, but not when it starts another
          -- domain label (b.example.com.evil.com).
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

    text = replace_bounded(text, "https?://", public_origin)
    text = replace_bounded(text, "//", "//" .. public_host)
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
