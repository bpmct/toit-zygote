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

import esp32
import .mode as mode

CAPTIVE_PORTAL_SSID     ::= "mywifi"
CAPTIVE_PORTAL_PASSWORD ::= "12345678"

// A minimal HTML page that will work on any device
MINIMAL_SETUP_PAGE ::= """
<html>
<head>
<title>WiFi Setup</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body { font-family: sans-serif; max-width: 500px; margin: 0 auto; padding: 20px; }
h1 { color: #333; }
label { display: block; margin-top: 15px; font-weight: bold; }
input, select { width: 100%; padding: 8px; margin-top: 5px; border: 1px solid #ccc; border-radius: 4px; }
input[type=submit] { background-color: #4CAF50; color: white; border: none; cursor: pointer; margin-top: 20px; }
input[type=submit]:hover { background-color: #45a049; }
</style>
</head>
<body>
<h1>WiFi Setup</h1>
<form method="POST" action="/">
<label for="ssid">WiFi Name:</label>
<input type="text" id="ssid" name="ssid">
<label for="password">Password:</label>
<input type="password" id="password" name="password">
<input type="submit" value="Connect">
</form>
</body>
</html>
"""

main:
  if mode.RUNNING: return
  timeout := mode.DEVELOPMENT ? (Duration --s=30) : (Duration --m=5)
  catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR): run timeout
  log.info "Setup completed or timed out, returning to application mode"
  mode.run_application

run timeout/Duration:
  log.info "Setup container started, scanning for WiFi access points"
  channels := ByteArray 12: it + 1
  access_points := wifi.scan channels
  access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi

  log.info "Establishing WiFi in AP mode ($CAPTIVE_PORTAL_SSID)"
  while true:
    network_ap := wifi.establish
        --ssid=CAPTIVE_PORTAL_SSID
        --password=CAPTIVE_PORTAL_PASSWORD
    credentials/Map? := null
    try:
      with_timeout timeout: credentials = run_captive_portal network_ap access_points
    finally:
      network_ap.close

    if credentials:
      exception := catch:
        log.info "Connecting to WiFi in STA mode" --tags=credentials
        network_sta := wifi.open
            --save
            --ssid=credentials["ssid"]
            --password=credentials["password"]
        sleep --ms=5000
        network_sta.close
        log.info "WiFi connection saved successfully" --tags=credentials
        return
      log.warn "WiFi connection failed" --tags=credentials

run_captive_portal network/net.Interface access_points/List -> Map:
  results := Task.group --required=1 [
    :: run_dns network,
    :: run_http network access_points,
  ]
  return results[1]  // Return the result from the HTTP server at index 1.

run_dns network/net.Interface -> none:
  device_ip_address := network.address
  log.info "DNS server starting with IP: $device_ip_address"
  socket := network.udp_open --port=53
  hosts := dns.SimpleDnsServer device_ip_address  // Answer the device IP to all queries.

  try:
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      log.debug "DNS query received"
      response := hosts.lookup datagram.data
      if not response: continue
      log.debug "Sending DNS response"
      socket.send (udp.Datagram response datagram.address)
  finally:
    socket.close

// Ultra-simplified HTTP handler that serves the setup page for all requests
direct_http_respond socket/tcp.ServerSocket access_points/List -> Map?:
  log.info "Starting ultra-simplified page-serving HTTP handler"
  
  // Pre-compute page response
  setup_page := MINIMAL_SETUP_PAGE
  headers := """HTTP/1.1 200 OK
Content-Type: text/html
Connection: close
Content-Length: $(setup_page.size)

"""
  complete_response := (headers + setup_page).to_byte_array
  
  // iOS Detection special response
  IOS_SUCCESS := """HTTP/1.1 200 OK
Content-Type: text/html
Cache-Control: no-store
Connection: close
Content-Length: 45

<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>
""".to_byte_array
  
  while true:
    log.debug "Waiting for connection..."
    client := socket.accept
    
    if client:
      log.info "Client connection established!"
      
      // Read a bit of the request just to check for iOS detection or form submission
      request_bytes := ByteArray 256
      bytes_read := 0
      read_exception := catch:
        in := client.in
        if in:
          bytes := in.read --max-size=256
          if bytes:
            bytes_read = bytes.size
            bytes.size.repeat: | i |
              request_bytes[i] = bytes[i]
      
      // Process the request if there's data
      if bytes_read > 0:
        request_str := ""
        str_exception := catch:
          request_str = request_bytes.to_string
        
        // Check for iOS detection
        if request_str.contains "hotspot-detect.html" or request_str.contains "success.html":
          log.info "iOS detection request"
          write_exception := catch:
            client.out.write IOS_SUCCESS
        
        // Check for form submission
        else if request_str.contains "POST" and request_str.contains "ssid=":
          log.info "Form submission detected"
          
          // Extract SSID and password (very simple parsing)
          ssid_start := request_str.index_of "ssid="
          pw_start := request_str.index_of "password="
          
          if ssid_start >= 0 and pw_start >= 0:
            // Get the SSID (from ssid= to & or end)
            ssid_start += 5  // skip "ssid="
            ssid_end := request_str.index_of "&" ssid_start
            if ssid_end < 0: ssid_end = request_str.size
            ssid := request_str[ssid_start..ssid_end]
            
            // Get the password (from password= to & or end)
            pw_start += 9  // skip "password="
            pw_end := request_str.index_of "&" pw_start
            if pw_end < 0: pw_end = request_str.size
            password := request_str[pw_start..pw_end]
            
            // Simple URL decoding for plus signs
            ssid = ssid.replace "+" " "
            password = password.replace "+" " "
            
            // Close connection and return credentials
            if ssid and ssid != "":
              log.info "Valid credentials extracted"
              client.close
              return { "ssid": ssid, "password": password }
          
          // Send page response for invalid form data
          write_exception := catch:
            client.out.write complete_response
          
        // Serve setup page for all other requests
        else:
          log.info "Regular request - serving setup page"
          write_exception := catch:
            client.out.write complete_response
      
      // For requests with no data, just serve the page
      else:
        log.info "Empty request - serving setup page"
        write_exception := catch:
          client.out.write complete_response
      
      // Delay before closing
      sleep --ms=500
      
      // Close connection
      close_exception := catch:
        client.close
      
      // Delay after closing
      sleep --ms=100
      
    else:
      sleep --ms=10

run_http network/net.Interface access_points/List -> Map:
  log.info "Starting captive portal web server"
  socket := network.tcp_listen 80
  result := direct_http_respond socket access_points
  socket.close
  if result: return result
  unreachable