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

//-------------------------------------------------------------------------
// Platform-specific captive portal detection handling
//-------------------------------------------------------------------------

// ----- iOS CAPTIVE PORTAL DETECTION -----
// 
// iOS captive portal detection specifically looks for this exact
// format for the success response with these exact headers.
// 
// Detection endpoints: 
// - /hotspot-detect.html
// - /success.html
//
// This MUST NOT be changed unless thoroughly tested with iOS.
//
IOS_SUCCESS_RESPONSE ::= """HTTP/1.1 200 OK
Content-Type: text/html
Cache-Control: no-store
Connection: close
Content-Length: 165

<html><head><meta http-equiv="refresh" content="0;url=/index.html" /><title>Success</title></head><body>Success - redirecting to portal...</body></html>
"""

// Improved HTML with nicer form and dropdown for networks
INDEX ::= """
<html>
<head>
<title>WiFi Setup</title>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
body{font-family:system-ui,-apple-system,sans-serif;max-width:600px;margin:0 auto;padding:15px;font-size:16px}
h1{color:#333;margin-bottom:15px}
select,input{width:100%;padding:10px;margin:8px 0 15px;border:1px solid #ccc;border-radius:6px;font-size:16px;-webkit-appearance:none;box-sizing:border-box}
.btn{background:#4CAF50;color:#fff;border:none;border-radius:6px;padding:12px;width:100%;font-size:16px;margin-top:10px;cursor:pointer}
.hidden{display:none}
label{display:block;font-weight:500}
@media(max-width:480px){body{padding:10px}}
</style>
</head>
<body>
<h1>WiFi Setup</h1>
<form method="POST" action="/">
<label for="nw">Available Networks:</label>
<select id="nw" name="network" onchange="hNC()">
<option value="custom">Custom...</option>
{{network-options}}
</select>
<div id="sc">
<label for="ss">Network Name:</label>
<input type="text" id="ss" name="ssid" autocorrect="off" autocapitalize="none">
</div>
<label for="pw">Password:</label>
<input type="password" id="pw" name="password" autocorrect="off" autocapitalize="none">
<input type="submit" class="btn" value="Connect">
</form>
<script>
function hNC(){
var d=document.getElementById("nw"),s=document.getElementById("ss"),c=document.getElementById("sc");
if(d.value==="custom"){s.value="";s.disabled=false;c.classList.remove("hidden")}
else{s.value=d.value;s.disabled=true;c.classList.add("hidden")}
}
window.onload=function(){hNC();}
</script>
</body>
</html>
"""

main:
  // We allow the setup container to start and eagerly terminate
  // if we don't need it yet. This makes it possible to have
  // the setup container installed always, but have it run with
  // the -D jag.disabled flag in development.
  if mode.RUNNING: return

  // When running in development we run for less time before we
  // back to trying out the app. This makes it faster to correct
  // things and retry, but it does mean that you have less time
  // to connect to the established WiFi.
  timeout := mode.DEVELOPMENT ? (Duration --s=30) : (Duration --m=5)
  
  // Use the original catch-unwind approach for stability
  catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR): run timeout

  // We're done trying to complete the setup. Go back to running
  // the application and let it choose when to re-initiate the
  // setup process.
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
            
        // Wait to ensure saved - this is an important fix from the original
        sleep --ms=5000
        
        network_sta.close
        log.info "WiFi connection saved successfully" --tags=credentials
        
        // Return to indicate success to main function
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
    log.debug "DNS server closing"
    socket.close

// Ultra-simplified HTTP handler that serves the setup page for all requests
direct_http_respond socket/tcp.ServerSocket access_points/List -> Map?:
  log.info "Starting complete captive portal handler"
  
  // Precompute iOS success response
  IOS_SUCCESS_BYTES := IOS_SUCCESS_RESPONSE.to_byte_array
  
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
        ios_detection := request_str.contains "hotspot-detect.html" or 
                         request_str.contains "success.html" or
                         request_str.contains "captive.apple.com"
                        
        if ios_detection:
          log.info "iOS detection request"
          write_exception := catch:
            client.out.write IOS_SUCCESS_BYTES
        
        // Check for form submission
        else if request_str.contains "POST" and request_str.contains "ssid=":
          log.info "Form submission detected"
          
          credentials := parse_form_submission request_str
          
          if credentials and credentials.get "ssid" --if_absent=(: null):
            log.info "Valid credentials extracted"
            client.close
            return credentials
          
          // Serve setup page for invalid credentials
          serve_main_page client access_points
        
        // Serve setup page for all other requests
        else:
          log.info "Regular request - serving main page"
          serve_main_page client access_points
      
      // For requests with no data, just serve the main page
      else:
        log.info "Empty request - serving main page"
        serve_main_page client access_points
      
      // Delay before closing
      sleep --ms=500
      
      // Close connection
      close_exception := catch:
        client.close
      
      // Delay after closing
      sleep --ms=100
      
    else:
      log.debug "No client - retry"
      sleep --ms=10

// Helper to serve the main page
serve_main_page client/tcp.Socket access_points/List -> none:
  // Create network options HTML
  network_options := access_points.map: | ap |
    signal_str := ap.rssi > -60 ? "Strong" : (ap.rssi < -75 ? "Weak" : "Good")
    "<option value=\"$(ap.ssid)\">$(ap.ssid) ($signal_str)</option>"
  
  // Substitute network options into the template
  content := INDEX.substitute: { "network-options": network_options.join "\n" }
  
  // Create HTTP response with the content
  headers := """HTTP/1.1 200 OK
Content-Type: text/html
Connection: close
Content-Length: $(content.size)

"""
  
  // Send headers and content
  exception := catch:
    client.out.write headers.to_byte_array
    client.out.write content.to_byte_array

// Helper to parse form submissions
parse_form_submission request_str/string -> Map?:
  // Check if we have form data
  form_data_start := request_str.index_of "\r\n\r\n"
  if form_data_start < 0: 
    form_data_start = request_str.index_of "ssid="
    if form_data_start < 0: return null
  else:
    form_data_start += 4  // Skip the \r\n\r\n
  
  // Extract the form data
  form_data := request_str[form_data_start..]
  
  // Extract parameters
  params := {:}
  pairs := form_data.split "&"
  pairs.do: | pair |
    key_value := pair.split "="
    if key_value.size == 2:
      key := key_value[0]
      value := key_value[1]
      // Simple URL decoding
      value = value.replace "+" " "
      params[key] = value
  
  // Extract SSID (either from network dropdown or direct input)
  ssid := ""
  
  // Get SSID from network dropdown if present
  network := params.get "network" --if_absent=(: null)
  if network and network != "custom":
    ssid = network
  else:
    // Otherwise get from ssid field
    ssid_param := params.get "ssid" --if_absent=(: null)
    if ssid_param: ssid = ssid_param
  
  // Get password
  password := params.get "password" --if_absent=(: "")
  
  // Return credentials if valid
  if ssid and ssid != "": return { "ssid": ssid, "password": password }
  return null

run_http network/net.Interface access_points/List -> Map:
  log.info "Starting captive portal web server"
  socket := network.tcp_listen 80
  result := direct_http_respond socket access_points
  socket.close
  if result: return result
  unreachable