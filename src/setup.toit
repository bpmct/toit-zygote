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

// These redirects help with Android captive portal detection
TEMPORARY_REDIRECTS ::= {
  "generate_204": "/",    // Used by Android captive portal detection.
  "gen_204": "/",         // Used by Android captive portal detection.
}

// Simple response for direct detection success
DIRECT_SUCCESS_RESPONSE ::= """
HTTP/1.1 200 OK
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
<form>
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

// Let's skip the direct responder - it's causing compile issues

run_http network/net.Interface access_points/List -> Map:
  // Open the TCP socket for HTTP
  socket := network.tcp_listen 80
  
  // Use the regular HTTP server
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

  // Create the network options dropdown items
  network_options := access_points.map: | ap |
    // Mark signal strength
    signal_strength := "Good"
    if ap.rssi > -60: signal_strength = "Strong"
    else if ap.rssi < -75: signal_strength = "Weak"
    
    // Build the select option
    "<option value=\"$(ap.ssid)\">$(ap.ssid) ($signal_strength)</option>"
  
  // Set up the HTML content with our substitutions
  substitutions := {
    "network-options": network_options.join "\n"
  }
  writer.headers.set "Content-Type" "text/html"
  writer.write (INDEX.substitute: substitutions[it])

  // Check if we have form parameters
  if query.parameters.is_empty: return null
  
  // Handle form submission from dropdown or manual entry
  ssid := ""
  
  // Check if using the dropdown selection
  network := query.parameters.get "network" --if_absent=: null
  if network and network != "custom":
    ssid = network.trim
  else:
    // Using manual entry
    ssid_param := query.parameters.get "ssid" --if_absent=: null
    if ssid_param: ssid = ssid_param.trim
  
  // Get the password
  password := query.parameters.get "password" --if_absent=: ""
  
  // Return if we have valid credentials
  if ssid != "": return { "ssid": ssid, "password": password }
  return null