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

// Captive portal detection endpoints we handle:
// - iOS: /hotspot-detect.html, /success.html, /library/test/success.html
// - Android: /generate_204, /gen_204, /ncsi.txt
// - Windows: /connecttest.txt, /ncsi.txt
// - Samsung: /mobile/status.php
// - ChromeOS: /generate_204
//
// We handle all of these directly with appropriate responses in both
// our direct HTTP handler and the main HTTP server.
TEMPORARY_REDIRECTS ::= {
  // Other useful redirects can be added here
  "success": "/index.html",
}

// Success response used for iOS detection
DIRECT_SUCCESS_RESPONSE ::= """HTTP/1.1 200 OK
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

// Unified HTTP handler for direct responses and form handling
direct_http_respond socket/tcp.ServerSocket access_points/List -> Map?:
  log.info "Starting enhanced HTTP handler"
  result := null
  
  // Android expects a proper 204 response with specific headers
  ANDROID_204_RESPONSE ::= """HTTP/1.1 204 No Content
Cache-Control: no-cache, no-store, must-revalidate
Pragma: no-cache
Expires: 0
Content-Type: text/plain
Content-Length: 0
Connection: close

""".to_byte_array

  // Continue running until cancelled
  while true:
    client := null
    exception := catch:
      client = socket.accept
    
    if not client: continue
    
    // Process the client request
    handle_client_ := catch:
      // Read request data
      data := ByteArray 2048  // Larger buffer to handle form submissions
      bytes_read := 0
      client.read_bytes data 0 data.size --from=0
      bytes_read = data.size
      
      if bytes_read > 0:
        // Parse the request
        request_str := data.to_string
        
        // Extract the path and method for processing
        path := "unknown"
        method := "GET"
        
        if request_str.contains "GET " or request_str.contains "POST ":
          lines := request_str.split "\r\n"
          if lines.size > 0:
            first_line := lines[0]
            parts := first_line.split " "
            if parts.size > 1:
              method = parts[0]
              path = parts[1]
        
        log.debug "request: $method $path"
        
        // Handle detection endpoints first - keep this fast
        if path.contains "/generate_204" or 
           path.contains "/gen_204" or 
           path.contains "/mobile/status.php" or 
           path.contains "/connecttest.txt" or 
           path.contains "/ncsi.txt" or
           path.contains "/check_network_status.txt":
          // Return 204 No Content for Android/Windows
          log.debug "Captive portal check: sending 204"
          client.out.write ANDROID_204_RESPONSE
          
        else if path.contains "hotspot-detect.html" or 
                path.contains "success.html" or 
                path.contains "/library/test/success.html" or
                path.contains "/captive.apple.com":
          // iOS detection - send success response
          log.debug "iOS check: sending success"
          client.out.write DIRECT_SUCCESS_RESPONSE.to_byte_array
          
        // Handle normal pages - index and form submissions
        else if path == "/" or path == "/index.html":
          // Serve the main WiFi setup page
          serve_main_page client access_points
          
        else if method == "POST" and path.contains "?":
          // Handle form submission
          credentials := parse_form_submission request_str
          if credentials and credentials.get "ssid" --if_absent=(: null):
            log.info "Form submission received with valid credentials"
            return credentials
            
        else if request_str.contains "CONNECT ":
          // Cannot handle HTTPS requests - just close with an error
          log.debug "HTTPS request received (unsupported): $path"
          headers := """HTTP/1.1 400 Bad Request
Content-Type: text/plain
Connection: close
Content-Length: 31

Secure connections not supported
"""
          client.out.write headers.to_byte_array
          
        else:
          // Forward all other HTTP requests to the main page
          log.debug "Redirecting request to main page: $path"
          headers := """HTTP/1.1 302 Found
Location: /index.html
Cache-Control: no-cache
Connection: close
Content-Length: 0

"""
          client.out.write headers.to_byte_array
    
    // Always close the client socket
    clean_up_ := catch:
      if client: client.close

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
  client.out.write headers.to_byte_array
  client.out.write content.to_byte_array

// Helper to parse form submissions
parse_form_submission request_str/string -> Map?:
  // Extract query string
  query_start := request_str.index_of "?"
  if query_start < 0: return null
  
  // Get the part after the ?
  query_string := request_str[query_start + 1..]
  
  // Cut at the first space if there is one
  end_marker := query_string.index_of " "
  if end_marker > 0:
    query_string = query_string[..end_marker]
  
  // Parse parameters
  params := {:}  // Using map literal syntax
  param_pairs := query_string.split "&"
  param_pairs.do: | pair |
    key_value := pair.split "="
    if key_value.size == 2:
      key := key_value[0]
      value := url.decode key_value[1]
      params[key] = value
  
  // Extract credentials
  ssid := ""
  
  // Get SSID (either from network dropdown or direct input)
  network := params.get "network" --if_absent=(: null)
  if network and network != "custom":
    ssid = network.trim
  else:
    ssid_param := params.get "ssid" --if_absent=(: null)
    if ssid_param: ssid = ssid_param.trim
  
  // Get password
  pw := params.get "password" --if_absent=(: "")
  
  // Return credentials if valid
  if ssid != "": return { "ssid": ssid, "password": pw }
  return null

run_http network/net.Interface access_points/List -> Map:
  // Revert to using both HTTP server and direct handler
  log.info "Starting captive portal web server"
  
  // Open the TCP socket for HTTP
  socket := network.tcp_listen 80
  
  // Start a separate task for direct detection - primarily for iOS/Android detection
  direct_task := task::
    direct_http_respond socket access_points
  
  // Use the standard HTTP server as fallback
  server := http.Server
  result := null
  
  try:
    server.listen socket:: | request writer |
      // Handle this particular request using the original handler
      creds := handle_http_request request writer access_points
      if creds:
        direct_task.cancel
        // If we got credentials, note them and stop listening
        result = creds
        socket.close
  finally:
    // Make sure to cancel tasks when we're done
    exception := catch:
      direct_task.cancel
    
    if result: return result
    socket.close
  
  unreachable

// Standard HTTP handler used by the HTTP server
handle_http_request request/http.Request writer/http.ResponseWriter access_points/List -> Map?:
  query := url.QueryString.parse request.path
  resource := query.resource
  
  // Handle various captive portal detection endpoints directly
  if resource == "/generate_204" or 
     resource == "/gen_204" or 
     resource == "/mobile/status.php" or 
     resource == "/connecttest.txt" or
     resource == "/ncsi.txt" or
     resource == "/check_network_status.txt":
    // Android expects specific headers with the 204 response
    writer.headers.set "Cache-Control" "no-cache, no-store, must-revalidate"
    writer.headers.set "Pragma" "no-cache"
    writer.headers.set "Expires" "0"
    writer.headers.set "Content-Type" "text/plain"
    writer.headers.set "Content-Length" "0"
    writer.write_headers 204
    return null
    
  if resource == "/": resource = "index.html"
  if resource == "/hotspot-detect.html" or 
     resource == "/success.html" or 
     resource == "/library/test/success.html" or
     resource == "/captive.apple.com": 
    resource = "index.html"  // iOS detection - serve main page

  // Handle redirects
  TEMPORARY_REDIRECTS.get resource --if_present=(:|redirect_to|
    writer.headers.set "Location" redirect_to
    writer.write_headers 302
    return null
  )

  // For unrecognized paths, redirect to index.html
  if resource != "index.html":
    writer.headers.set "Location" "/index.html"
    writer.write_headers 302
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
  writer.headers.set "Content-Type" "text/html"
  writer.write (INDEX.substitute: { "network-options": network_options.join "\n" })

  // Check if we have form parameters
  if query.parameters.is_empty: return null
  
  // Handle form submission
  ssid := ""
  
  // Check dropdown selection first
  network := query.parameters.get "network" --if_absent=(: null)
  if network and network != "custom":
    ssid = network.trim
  else:
    // Check manual entry
    ssid_param := query.parameters.get "ssid" --if_absent=(: null)
    if ssid_param: ssid = ssid_param.trim
  
  // Get password
  pw := query.parameters.get "password" --if_absent=(: "")
  
  // Return credentials if valid
  if ssid != "": return { "ssid": ssid, "password": pw }
  return null