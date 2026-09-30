-- API dispatcher implemented in Lua.
-- Go exposes OpenWrt adapter functions:
-- openwrt_network_get_* / openwrt_network_set_*

local function response(http_status, code, message, data)
  return json.encode({
    httpStatus = http_status,
    code = code,
    message = message,
    data = data,
  })
end

local function ok(data)
  return response(200, 0, "ok", data)
end

local function fail(http_status, code, message, data)
  return response(http_status, code, message, data)
end

local function not_found()
  return fail(404, 1404, "not found", nil)
end

local function parse_body(body)
  if body == nil or body == "" then
    return {}
  end

  local success, payload = pcall(json.decode, body)
  if not success then
    return nil, tostring(payload)
  end
  if type(payload) ~= "table" then
    return nil, "request body must be a json object"
  end
  return payload
end

local function parse_query_param(query, key)
  if query == nil or query == "" or key == nil or key == "" then
    return nil
  end
  local pattern = key .. "=([^&]+)"
  return string.match(query, pattern)
end

local function parse_query_bool(query, key, default_value)
  local raw = parse_query_param(query, key)
  if raw == nil or raw == "" then
    return default_value == true
  end
  raw = string.lower(raw)
  if raw == "1" or raw == "true" or raw == "on" or raw == "yes" then
    return true
  end
  return false
end

local function split_path_and_query(path, query)
  path = path or ""
  query = query or ""
  if query ~= "" then
    return path, query
  end
  local qmark = string.find(path, "?", 1, true)
  if qmark == nil then
    return path, query
  end
  local base = string.sub(path, 1, qmark - 1)
  local tail = string.sub(path, qmark + 1)
  return base, tail
end

local function call_adapter(fn_name, payload)
  local fn = _G[fn_name]
  if fn == nil then
    return nil, "adapter function not found: " .. tostring(fn_name)
  end

  local success, raw
  if payload ~= nil then
    success, raw = pcall(fn, json.encode(payload))
  else
    success, raw = pcall(fn)
  end

  if not success then
    return nil, tostring(raw)
  end

  if type(raw) ~= "string" then
    return nil, "adapter must return json string"
  end

  local decode_ok, data = pcall(json.decode, raw)
  if not decode_ok then
    return nil, "adapter returned invalid json: " .. tostring(data)
  end

  return data, nil
end

local function adapter_ok(fn_name, payload)
  local data, err = call_adapter(fn_name, payload)
  if err ~= nil then
    return fail(500, 3001, "openwrt adapter failed", { detail = err })
  end
  return ok(data)
end

local function handle_network_get(path)
  if path == "/api/v1/network/wan" then
    return adapter_ok("openwrt_network_get_wan")
  end

  if path == "/api/v1/network/lan" then
    return adapter_ok("openwrt_network_get_lan")
  end

  if path == "/api/v1/network/dhcp" then
    return adapter_ok("openwrt_network_get_dhcp")
  end

  if path == "/api/v1/network/interfaces" then
    return adapter_ok("openwrt_network_get_interfaces")
  end

  if path == "/api/v1/network/dhcp/advanced" then
    return adapter_ok("openwrt_network_get_dhcp_advanced")
  end

  if path == "/api/v1/network/dhcp/hosts" then
    return adapter_ok("openwrt_network_get_dhcp_hosts")
  end

  if path == "/api/v1/network/dhcp/static" then
    return adapter_ok("openwrt_network_get_dhcp_static")
  end

  if path == "/api/v1/network/ipv6" then
    return adapter_ok("openwrt_network_get_ipv6")
  end

  if path == "/api/v1/network/routes" then
    return adapter_ok("openwrt_network_get_routes")
  end

  if path == "/api/v1/network/port-forward" then
    return adapter_ok("openwrt_network_get_port_forward")
  end

  if path == "/api/v1/network/dmz" then
    return adapter_ok("openwrt_network_get_dmz")
  end

  if path == "/api/v1/network/upnp" then
    return adapter_ok("openwrt_network_get_upnp")
  end

  if path == "/api/v1/network/upnp/mappings" then
    return adapter_ok("openwrt_network_get_upnp_mappings")
  end

  if path == "/api/v1/network/ddns" then
    return adapter_ok("openwrt_network_get_ddns")
  end

  if path == "/api/v1/network/ddns/providers" then
    return adapter_ok("openwrt_network_get_ddns_providers")
  end

  return nil
end

local function handle_network_post(path, body)
  local payload, parse_err = parse_body(body)
  if payload == nil then
    return fail(400, 2002, "invalid request body", { detail = parse_err })
  end

  if path == "/api/v1/network/dhcp/static" then
    return adapter_ok("openwrt_network_add_dhcp_static", payload)
  end

  if path == "/api/v1/network/dhcp/hosts" then
    return adapter_ok("openwrt_network_add_dhcp_hosts", payload)
  end

  if path == "/api/v1/network/port-forward" then
    return adapter_ok("openwrt_network_add_port_forward", payload)
  end

  if path == "/api/v1/network/routes" then
    return adapter_ok("openwrt_network_add_route", payload)
  end

  if path == "/api/v1/network/ddns/test" then
    return adapter_ok("openwrt_network_test_ddns")
  end

  if path == "/api/v1/network/diagnostics/ping" then
    return adapter_ok("openwrt_network_diagnostics_ping", payload)
  end

  if path == "/api/v1/network/diagnostics/dns" then
    return adapter_ok("openwrt_network_diagnostics_dns", payload)
  end

  if path == "/api/v1/network/diagnostics/route" then
    return adapter_ok("openwrt_network_diagnostics_route", payload)
  end

  return nil
end

local function handle_network_put(path, body)
  local payload, parse_err = parse_body(body)
  if payload == nil then
    return fail(400, 2002, "invalid request body", { detail = parse_err })
  end

  if path == "/api/v1/network/wan" then
    return adapter_ok("openwrt_network_set_wan", payload)
  end

  if path == "/api/v1/network/lan" then
    return adapter_ok("openwrt_network_set_lan", payload)
  end

  if path == "/api/v1/network/dhcp" then
    return adapter_ok("openwrt_network_set_dhcp", payload)
  end

  if path == "/api/v1/network/interfaces" then
    return adapter_ok("openwrt_network_set_interfaces", payload)
  end

  if path == "/api/v1/network/dhcp/advanced" then
    return adapter_ok("openwrt_network_set_dhcp_advanced", payload)
  end

  if path == "/api/v1/network/ipv6" then
    return adapter_ok("openwrt_network_set_ipv6", payload)
  end

  if path == "/api/v1/network/dmz" then
    return adapter_ok("openwrt_network_set_dmz", payload)
  end

  if path == "/api/v1/network/upnp" then
    return adapter_ok("openwrt_network_set_upnp", payload)
  end

  if path == "/api/v1/network/ddns" then
    return adapter_ok("openwrt_network_set_ddns", payload)
  end

  local port_forward_prefix = "/api/v1/network/port-forward/"
  if string.sub(path, 1, #port_forward_prefix) == port_forward_prefix then
    local rule_id = string.sub(path, #port_forward_prefix + 1)
    if rule_id == nil or rule_id == "" then
      return fail(400, 2003, "rule id is required", nil)
    end
    payload.id = rule_id
    return adapter_ok("openwrt_network_update_port_forward", payload)
  end

  local routes_prefix = "/api/v1/network/routes/"
  if string.sub(path, 1, #routes_prefix) == routes_prefix then
    local route_id = string.sub(path, #routes_prefix + 1)
    if route_id == nil or route_id == "" then
      return fail(400, 2003, "route id is required", nil)
    end
    payload.id = route_id
    return adapter_ok("openwrt_network_update_route", payload)
  end

  return nil
end

local function handle_network_patch(path, body)
  local payload, parse_err = parse_body(body)
  if payload == nil then
    return fail(400, 2002, "invalid request body", { detail = parse_err })
  end

  local port_forward_prefix = "/api/v1/network/port-forward/"
  if string.sub(path, 1, #port_forward_prefix) == port_forward_prefix then
    local rule_id = string.sub(path, #port_forward_prefix + 1)
    if rule_id == nil or rule_id == "" then
      return fail(400, 2003, "rule id is required", nil)
    end
    payload.id = rule_id
    return adapter_ok("openwrt_network_toggle_port_forward", payload)
  end

  return nil
end

local function handle_network_delete(path)
  local static_prefix = "/api/v1/network/dhcp/static/"
  if string.sub(path, 1, #static_prefix) == static_prefix then
    local binding_id = string.sub(path, #static_prefix + 1)
    if binding_id == nil or binding_id == "" then
      return fail(400, 2003, "binding id is required", nil)
    end
    return adapter_ok("openwrt_network_delete_dhcp_static", { id = binding_id })
  end

  local host_map_prefix = "/api/v1/network/dhcp/hosts/"
  if string.sub(path, 1, #host_map_prefix) == host_map_prefix then
    local mapping_id = string.sub(path, #host_map_prefix + 1)
    if mapping_id == nil or mapping_id == "" then
      return fail(400, 2003, "mapping id is required", nil)
    end
    return adapter_ok("openwrt_network_delete_dhcp_hosts", { id = mapping_id })
  end

  local port_forward_prefix = "/api/v1/network/port-forward/"
  if string.sub(path, 1, #port_forward_prefix) == port_forward_prefix then
    local rule_id = string.sub(path, #port_forward_prefix + 1)
    if rule_id == nil or rule_id == "" then
      return fail(400, 2003, "rule id is required", nil)
    end
    return adapter_ok("openwrt_network_delete_port_forward", { id = rule_id })
  end

  local routes_prefix = "/api/v1/network/routes/"
  if string.sub(path, 1, #routes_prefix) == routes_prefix then
    local route_id = string.sub(path, #routes_prefix + 1)
    if route_id == nil or route_id == "" then
      return fail(400, 2003, "route id is required", nil)
    end
    return adapter_ok("openwrt_network_delete_route", { id = route_id })
  end

  return nil
end

local function handle_wifi_get(path, query)
  query = query or ""

  if path == "/api/v1/wifi/settings" then
    return adapter_ok("openwrt_wifi_get_settings")
  end

  if path == "/api/v1/wifi/mlo" then
    return adapter_ok("openwrt_wifi_get_mlo")
  end

  local channels_prefix = "/api/v1/wifi/channels/"
  if string.sub(path, 1, #channels_prefix) == channels_prefix then
    local band = string.sub(path, #channels_prefix + 1)
    if band == nil or band == "" then
      band = "2.4g"
    end
    return adapter_ok("openwrt_wifi_get_channels", {
      band = band,
      force = parse_query_bool(query, "force", false),
    })
  end

  if path == "/api/v1/wifi/channels" then
    local band = parse_query_param(query, "band") or "2.4g"
    return adapter_ok("openwrt_wifi_get_channels", {
      band = band,
      force = parse_query_bool(query, "force", false),
    })
  end

  if path == "/api/v1/wifi/runtime-channels" then
    return adapter_ok("openwrt_wifi_get_runtime_channels")
  end

  if path == "/api/v1/wifi/signal" then
    return adapter_ok("openwrt_wifi_get_signal")
  end

  local uplink_scan_prefix = "/api/v1/wifi/uplink/"
  if string.sub(path, 1, #uplink_scan_prefix) == uplink_scan_prefix and string.sub(path, -5) == "/scan" then
    local band = string.sub(path, #uplink_scan_prefix + 1, #path - 5)
    if band == nil or band == "" then
      return fail(400, 2003, "band is required", nil)
    end
    return adapter_ok("openwrt_wifi_scan_uplink", { band = band })
  end

  local uplink_prefix = "/api/v1/wifi/uplink/"
  if string.sub(path, 1, #uplink_prefix) == uplink_prefix then
    local band = string.sub(path, #uplink_prefix + 1)
    if band == nil or band == "" then
      return fail(400, 2003, "band is required", nil)
    end
    return adapter_ok("openwrt_wifi_get_uplink", { band = band })
  end

  return nil
end

local function handle_wifi_put(path, body)
  local payload, parse_err = parse_body(body)
  if payload == nil then
    return fail(400, 2002, "invalid request body", { detail = parse_err })
  end

  local band_prefix = "/api/v1/wifi/band/"
  if string.sub(path, 1, #band_prefix) == band_prefix then
    local band = string.sub(path, #band_prefix + 1)
    if band == nil or band == "" then
      return fail(400, 2003, "band is required", nil)
    end
    payload.band = band
    return adapter_ok("openwrt_wifi_update_band", payload)
  end

  if path == "/api/v1/wifi/mlo" then
    return adapter_ok("openwrt_wifi_set_mlo", payload)
  end

  local uplink_prefix = "/api/v1/wifi/uplink/"
  if string.sub(path, 1, #uplink_prefix) == uplink_prefix then
    local band = string.sub(path, #uplink_prefix + 1)
    if band == nil or band == "" then
      return fail(400, 2003, "band is required", nil)
    end
    payload.band = band
    return adapter_ok("openwrt_wifi_set_uplink", payload)
  end

  return nil
end

local function handle_wifi_post(path, body)
  local payload, parse_err = parse_body(body)
  if payload == nil then
    return fail(400, 2002, "invalid request body", { detail = parse_err })
  end

  if path == "/api/v1/wifi/optimize-channel" then
    payload.band = payload.band or "2.4g"
    payload.force = true
    return adapter_ok("openwrt_wifi_optimize_channel", payload)
  end

  if path == "/api/v1/wifi/channels/scan" then
    payload.band = payload.band or "2.4g"
    payload.force = true
    return adapter_ok("openwrt_wifi_get_channels", payload)
  end

  return nil
end

function higoros_dispatch(method, path, query, body)
  path, query = split_path_and_query(path, query)
  query = query or ""
  body = body or ""

  if method == "GET" and path == "/api/v1/health" then
    return ok({
      service = "higorosd",
      runtime = "go-vm+lua-api",
      status = "up",
      now = os.time(),
    })
  end

  if method == "GET" then
    local wifi_result = handle_wifi_get(path, query)
    if wifi_result ~= nil then
      return wifi_result
    end

    local result = handle_network_get(path)
    if result ~= nil then
      return result
    end
  end

  if method == "PUT" then
    local wifi_result = handle_wifi_put(path, body)
    if wifi_result ~= nil then
      return wifi_result
    end

    local result = handle_network_put(path, body)
    if result ~= nil then
      return result
    end
  end

  if method == "POST" then
    local wifi_result = handle_wifi_post(path, body)
    if wifi_result ~= nil then
      return wifi_result
    end

    local result = handle_network_post(path, body)
    if result ~= nil then
      return result
    end
  end

  if method == "PATCH" then
    local result = handle_network_patch(path, body)
    if result ~= nil then
      return result
    end
  end

  if method == "DELETE" then
    local result = handle_network_delete(path)
    if result ~= nil then
      return result
    end
  end

  return not_found()
end
