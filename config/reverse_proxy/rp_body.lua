-- SPDX-License-Identifier: Apache-2.0
-- body_filter_by_lua_file for LNMP reverse proxy managed sites.
--
-- All string/state logic lives in rp_rewrite.lua so it can be tested without
-- nginx. This file is only the ngx.arg / ngx.ctx adapter.

local rewrite = assert(loadfile(tostring(ngx.var.rp_rewrite_module)))()

local state = ngx.ctx.rp_state
if not state then
  state = rewrite.new_state()
  ngx.ctx.rp_state = state
end

local chunk = ngx.arg[1] or ""
local eof = ngx.arg[2] or false

if not ngx.ctx.rp_body_ok then
  ngx.arg[1] = chunk
  return
end

local out = rewrite.process_chunk(state, chunk, eof, {
  upstream_origin = ngx.var.rp_upstream_origin,
  public_origin = ngx.var.rp_public_origin,
  public_host = ngx.var.rp_public_host,
  watermark = ngx.var.rp_rewrite_watermark,
  max_bytes = ngx.var.rp_rewrite_max_bytes,
  min_overlap = ngx.var.rp_rewrite_min_overlap,
})

ngx.arg[1] = out
