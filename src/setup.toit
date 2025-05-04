// Copyright (C) 2023 Kasper Lund.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import log
import monitor

import encoding.url

import net
import net.tcp
import net.udp
import net.wifi

import http
import dns_simple_server as dns

import .mode as mode

CAPTIVE_PORTAL_SSID     ::= "mywifi"
CAPTIVE_PORTAL_PASSWORD ::= "12345678"

TEMPORARY_REDIRECTS ::= {
  "generate_204": "/",    // Used by Android captive portal detection.
  "gen_204": "/",         // Used by Android captive portal detection.
}

INDEX ::= """
<html>
  <head>
    <title>WiFi settings</title>
  </head>
  <body>
    <h1>Update WiFi settings</h1>
    <form>
      <label for="ssid">SSID:</label><br>
      <input type="text" id="ssid" name="ssid" autocorrect="off" autocapitalize="none"><br>
      <label for="password">Password:</label><br>
      <input type="text" id="password" name="password" autocorrect="off" autocapitalize="none"><br>
      <br>
      <input type="submit" value="Update">
    </form>
    <p>
    {{access-points}}
  <body>
<html>
"""

main:
  // We should only run when the device is in setup mode (RUNNING is false)
  if mode.RUNNING: return
  run (Duration --s=900)  // 15 minutes

run timeout/Duration:
  log.info "scanning for wifi access points"
  channels := ByteArray 12: it + 1
  access_points := wifi.scan channels
  access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi

  log.info "establishing wifi in AP mode ($CAPTIVE_PORTAL_SSID)"
  while true:
    network_ap := wifi.establish
        --ssid=CAPTIVE_PORTAL_SSID
        --password=CAPTIVE_PORTAL_PASSWORD
    credentials/Map? := null

    portal_exception := catch:
      credentials = (with_timeout timeout: run_captive_portal network_ap access_points)

    if portal_exception: log.info "Captive portal timed out, restarting..."

    try:
      network_ap.close
    finally:
      // Ensure we always continue to the next iteration if no credentials
      if not credentials: continue

    if credentials:
      exception := catch:
        log.info "connecting to wifi in STA mode" --tags=credentials
        network_sta := wifi.open
            --save
            --ssid=credentials["ssid"]
            --password=credentials["password"]
        network_sta.close
        log.info "connecting to wifi in STA mode => success" --tags=credentials
        return
      log.warn "connecting to wifi in STA mode => failed" --tags=credentials

run_captive_portal network/net.Interface access_points/List -> Map:
  results := Task.group --required=1 [
    :: run_dns network,
    :: run_http network access_points,
  ]
  return results[1]  // Return the result from the HTTP server at index 1.

run_dns network/net.Interface -> none:
  device_ip_address := network.address
  socket := network.udp_open --port=53
  hosts := dns.SimpleDnsServer device_ip_address  // Answer the device IP to all queries.

  try:
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      response := hosts.lookup datagram.data
      if not response: continue
      socket.send (udp.Datagram response datagram.address)
  finally:
    socket.close

run_http network/net.Interface access_points/List -> Map:
  socket := network.tcp_listen 80
  server := http.Server
  result/Map? := null
  try:
    server.listen socket:: | request writer |
      result = handle_http_request request writer access_points
      if result: socket.close
  finally:
    if result: return result
    socket.close
  unreachable

handle_http_request request/http.Request writer/http.ResponseWriter access_points/List -> Map?:
  query := url.QueryString.parse request.path
  resource := query.resource
  if resource == "/": resource = "index.html"
  if resource == "/hotspot-detect.html": resource = "index.html"  // Needed for iPhones.
  if resource.starts_with "/": resource = resource[1..]

  TEMPORARY_REDIRECTS.get resource --if_present=:
    writer.headers.set "Location" it
    writer.write_headers 302
    return null

  if resource != "index.html":
    writer.headers.set "Content-Type" "text/plain"
    writer.write_headers 404
    writer.write "Not found: $resource"
    return null

  substitutions := {
    "access-points": (access_points.map: "$it.ssid<br>").join "\n"
  }
  writer.headers.set "Content-Type" "text/html"
  writer.write (INDEX.substitute: substitutions[it])

  if query.parameters.is_empty: return null
  ssid := query.parameters["ssid"].trim
  password := query.parameters["password"].trim
  return { "ssid": ssid, "password": password }
