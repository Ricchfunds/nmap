local datafiles = require "datafiles"
local coroutine = require "coroutine"
local nmap = require "nmap"
local os = require "os"
local stdnse = require "stdnse"
local string = require "string"
local table = require "table"
local target = require "target"
local unicode = require "unicode"
local ipOps = require "ipOps"
local rand = require "rand"
local outlib = require "outlib"

description = [[
Uses the Microsoft LLTD protocol to discover hosts on a local network.

For more information on the LLTD protocol please refer to
http://www.microsoft.com/whdc/connect/Rally/LLTD-spec.mspx
]]

---
-- @usage
-- nmap -e <interface> --script lltd-discovery
--
-- @args lltd-discovery.interface string specifying which interface to do lltd discovery on.  If not specified, all ethernet interfaces are tried.
-- @args lltd-discovery.timeout timespec specifying how long to listen for replies (default 30s)
--
-- @output
-- | lltd-discovery:
-- |   192.168.1.64
-- |     Hostname: acer-PC
-- |     Mac: 18:f4:6a:4f:de:a2 (Hon Hai Precision Ind. Co.)
-- |     IPv6: fe80:0000:0000:0000:0000:0000:c0a8:0134
-- |   192.168.1.33
-- |     Hostname: winxp-2b2955502
-- |     Mac: 08:00:27:79:fd:d2 (Cadmus Computer Systems)
-- |   192.168.1.22
-- |     Hostname: core
-- |     Mac: 08:00:27:57:30:7f (Cadmus Computer Systems)
-- |_  Use the newtargets script-arg to add the results as targets
--

author = {"Gorjan Petrovski", "Hani Benhabiles"}
license = "Same as Nmap--See https://nmap.org/book/man-legal.html"
categories = {"broadcast","discovery","safe"}


prerule = function()
  if not nmap.is_privileged() then
    nmap.registry[SCRIPT_NAME] = nmap.registry[SCRIPT_NAME] or {}
    if not nmap.registry[SCRIPT_NAME].rootfail then
      stdnse.verbose1("not running for lack of privileges.")
    end
    nmap.registry[SCRIPT_NAME].rootfail = true
    return nil
  end

  return true
end

--- Converts a 6 byte string into the familiar MAC address formatting
-- @param mac string containing the MAC address
-- @return formatted string suitable for printing
local function get_mac_addr( mac )
  local catch = function() return end
  local try = nmap.new_try(catch)
  local mac_prefixes = try(datafiles.parse_mac_prefixes())

  if mac:len() ~= 6 then
    return "Unknown"
  else
    local prefix = string.upper(string.format("%02x%02x%02x", mac:byte(1), mac:byte(2), mac:byte(3)))
    local manuf = mac_prefixes[prefix] or "Unknown"
    return string.format("%s (%s)", stdnse.format_mac(mac:sub(1,6)), manuf )
  end
end

--- Gets a raw ethernet buffer with LLTD information and returns the responding host's IP and MAC
local parseHello = function(data)
  -- HelloMsg = [
  --   ethernet_hdr = [mac_dst(6), mac_src(6), protocol(2)],
  --  lltd_demultiplex_hdr = [version(1), type_of_service(1), reserved(1), function(1)],
  --  base_hdr = [mac_dst(6), mac_src(6), seq_no(2)],
  --  up_hello_hdr = [ generation_number(2), current_mapper_address(6), apparent_mapper_address(6), tlv_list(var) ]
  --]

  --HelloStruct = {
  --  mac_src,
  --  sequence_number,
  --  generation_number,
  --  tlv_list(dict)
  --}
  local types = {"Host ID", "Characteristics", "Physical Medium", "Wireless Mode", "802.11 BSSID",
  "802.11 SSID", "IPv4 Address", "IPv6 Address", "802.11 Max Operational Rate",
  "Performance Counter Frequency", nil, "Link Speed", "802.11 RSSI", "Icon Image", "Machine Name",
  "Support Information", "Friendly Name", "Device UUID", "Hardware ID", "QoS Characteristics",
  "802.11 Physical Medium", "AP Association Table", "Detailed Icon Image", "Sees-List Working Set",
  "Component Table", "Repeater AP Lineage", "Repeater AP Table"}
  local mac = nil
  local ipv4 = nil
  local ipv6 = nil
  local hostname = nil

  local pos = 1
  pos = pos + 6
  local mac_src = data:sub(pos,pos+5)

  pos = pos + 24
  local seq_no = data:sub(pos,pos+1)

  pos = pos + 2
  local generation_no = data:sub(pos,pos+1)

  pos = pos + 14
  local tlv = data:sub(pos)

  local tlv_list = {}
  local p = 1
  while p < #tlv do
    local t = tlv:byte(p)
    if t == 0x00 then
      break
    else
      p = p + 1
      local l = tlv:byte(p)

      p = p + 1
      local v = tlv:sub(p,p+l-1)

      if t == 0x01 then
        -- Host ID (MAC Address)
        mac = get_mac_addr(v:sub(1,6))
      elseif t == 0x08 then
        ipv6 = ipOps.str_to_ip(v:sub(1,16))
      elseif t == 0x07 then
        -- IPv4 address
        ipv4 = ipOps.str_to_ip(v:sub(1,4))

        -- Machine Name (Hostname)
      elseif t == 0x0f then
        hostname = unicode.utf16to8(v)
      end

      p = p + l

      if ipv4 and ipv6 and mac and hostname then
        break
      end
    end
  end

  return ipv4, mac, ipv6, hostname
end

--- Creates an LLTD Quick Discovery packet with the source MAC address
-- @param mac_src - six byte long binary string
local QuickDiscoveryPacket = function(mac_src)
  local ethernet_hdr, demultiplex_hdr, base_hdr, discover_up_lev_hdr

  -- set up ethernet header = [ mac_dst, mac_src, protocol ]
  local mac_dst = "\xFF\xFF\xFF\xFF\xFF\xFF" -- broadcast
  local protocol = "\x88\xd9" -- LLTD ethertype

  ethernet_hdr = mac_dst .. mac_src .. protocol

  -- set up LLTD demultiplex header = [ version, type_of_service, reserved, function ]
  local lltd_version = 1 -- Fixed Value
  local lltd_type_of_service = 1 -- Type Of Service = Quick Discovery(0x01)
  local lltd_reserved = 0 -- Fixed value
  local lltd_function = 0 -- Function = QuickDiscovery->Discover (0x00)

  demultiplex_hdr = string.pack("BBBB", lltd_version, lltd_type_of_service, lltd_reserved, lltd_function )

  -- set up LLTD base header = [ mac_dst, mac_src, seq_num(xid) ]
  local lltd_seq_num = rand.random_string(2)

  base_hdr = mac_dst .. mac_src .. lltd_seq_num

  -- set up LLTD Upper Level Header = [ generation_number, number_of_stations, station_list ]
  local generation_number = rand.random_string(2)
  local number_of_stations = 0
  local station_list = string.rep("\0", 6*4)

  discover_up_lev_hdr = generation_number .. string.pack(">I2", number_of_stations) .. station_list

  -- put them all together and return
  return ethernet_hdr .. demultiplex_hdr .. base_hdr .. discover_up_lev_hdr
end

--- Runs a thread which discovers LLTD Responders on a certain interface
local LLTDDiscover = function(if_table, lltd_responders, timeout)
  local timeout_s = 3
  local condvar = nmap.condvar(lltd_responders)
  local pcap = nmap.new_socket()
  pcap:set_timeout(5000)

  local dnet = nmap.new_dnet()
  local try = nmap.new_try(function() dnet:ethernet_close() pcap:close() end)

  pcap:pcap_open(if_table.device, 256, false, "")
  try(dnet:ethernet_open(if_table.device))

  local packet = QuickDiscoveryPacket(if_table.mac)
  try( dnet:ethernet_send(packet) )
  stdnse.sleep(0.5)
  try( dnet:ethernet_send(packet) )

  local start = os.time()
  local start_s = os.time()
  while true do
    local status, plen, l2, l3, _ = pcap:pcap_receive()
    if status then
      local packet = l2..l3
      if stdnse.tohex(packet:sub(13,14)) == "88d9" then
        start_s = os.time()

        local ipv4, mac, ipv6, hostname = parseHello(packet)
        local result = {
          ipv4 = ipv4,
          hostname = hostname,
          mac = mac,
          ipv6 = ipv6,
        }
        if ipv4 then
          lltd_responders[ipv4] = outlib.sorted_by_key(result)
        elseif mac then
          lltd_responders[mac] = outlib.sorted_by_key(result)
        end
      else
        if os.time() - start_s > timeout_s then
          break
        end
      end
    else
      break
    end

    if os.time() - start > timeout then
      break
    end
  end
  dnet:ethernet_close()
  pcap:close()
  condvar("signal")
end

local function filter_interfaces (if_table)
  if if_table and if_table.up == "up" and if_table.link=="ethernet" then
    return if_table
  end
  return nil
end

action = function()
  local timeout = stdnse.parse_timespec(stdnse.get_script_args(SCRIPT_NAME..".timeout"))
  timeout = timeout or 30

  --get interface script-args, if any
  local interface_arg = stdnse.get_script_args(SCRIPT_NAME .. ".interface")
  local interface_opt = nmap.get_interface()

  -- interfaces list (decide which interfaces to broadcast on)
  local interfaces ={}
  if interface_opt or interface_arg then
    -- single interface defined
    local interface = interface_opt or interface_arg
    local if_table = filter_interfaces(nmap.get_interface_info(interface))
    if not if_table then
      stdnse.debug1("Interface not supported or not properly configured.")
      return false
    end
    interfaces[if_table.device] = if_table
  else
    local tmp_ifaces = nmap.list_interfaces()
    for _, if_table in ipairs(tmp_ifaces) do
      interfaces[if_table.device] = filter_interfaces(if_table)
    end
  end

  if not next(interfaces) then
    stdnse.debug1("No interfaces found.")
    return
  end

  local lltd_responders={}
  local threads ={}
  local condvar = nmap.condvar(lltd_responders)

  -- party time
  for dev, if_table in pairs(interfaces) do
    -- create a thread for each interface
    local co = stdnse.new_thread(LLTDDiscover, if_table, lltd_responders, timeout)
    threads[co]=true
  end

  repeat
    for thread in pairs(threads) do
      if coroutine.status(thread) == "dead" then threads[thread] = nil end
    end
    if ( next(threads) ) then
      condvar "wait"
    end
  until next(threads) == nil

  if target.ALLOW_NEW_TARGETS then
    local addrtype = nmap.address_family() == "inet" and "ipv4" or "ipv6"
    for key, info in pairs(lltd_responders) do
      if info[addrtype] then
        target.add(info[addrtype])
      end
    end
  end

  return outlib.sorted_by_key(lltd_responders)
end
