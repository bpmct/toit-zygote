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

// ----- ANDROID CAPTIVE PORTAL DETECTION -----
//
// Android detection endpoints that need special handling:
// - /generate_204
// - /gen_204
// 
// Other detection endpoints that may need handling:
// - /mobile/status.php (Samsung)
// - /connecttest.txt (Windows/Android)
// - /ncsi.txt (Windows)

// General redirects to handle various platform detection mechanisms
TEMPORARY_REDIRECTS ::= {
  "generate_204": "/",        // Android
  "gen_204": "/",             // Android
  "success": "/index.html",   // iOS
  "example.com": "/index.html", // Example.com domains
  "connectivitycheck": "/index.html", // Android connectivity check
}

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

// Direct HTTP handler for captive portal detection and other requests
direct_http_respond socket/tcp.ServerSocket access_points/List -> Map?:
  log.info "Starting direct HTTP handler for captive portal detection"
  
  // Android detection responses
  
  // 204 No Content response for Android captive portal detection
  // Android expects this specific response for generate_204 endpoints
  ANDROID_204_RESPONSE ::= """HTTP/1.1 204 No Content
Cache-Control: no-cache
Connection: close
Content-Length: 0

""".to_byte_array

  // Redirect response for other Android detection endpoints
  ANDROID_REDIRECT_RESPONSE ::= """HTTP/1.1 302 Found
Location: /index.html
Cache-Control: no-cache
Connection: close
Content-Length: 0

""".to_byte_array

  // Default redirect for all other URLs
  DEFAULT_REDIRECT_RESPONSE ::= """HTTP/1.1 302 Found
Location: /index.html
Cache-Control: no-cache
Connection: close
Content-Length: 0

""".to_byte_array
  
  while true:
    // Accept a client connection
    client := null
    exception := catch:
      client = socket.accept
    
    if not client: continue
    
    // Read request data with improved error handling
    data := ByteArray 2048
    bytes_read := 0
    exception = catch:
      try:
        client.read_bytes data 0 data.size --from=0
        bytes_read = data.size
      catch error:
        log.debug "Socket read error: $error"
        bytes_read = 0
    
    if bytes_read > 0:
      // Parse the request with improved error handling
      request_str := ""
      exception = catch:
        request_str = data.to_string
      
      // Extract the path and method for processing
      path := "unknown"
      method := "GET"
      
      try:
        if request_str.contains "GET " or request_str.contains "POST ":
          lines := request_str.split "\r\n"
          if lines.size > 0:
            first_line := lines[0]
            parts := first_line.split " "
            if parts.size > 1:
              method = parts[0]
              path = parts[1]
      catch error:
        log.debug "Error parsing request: $error"
        // Keep default path and method
      
      log.debug "direct handler request: $method $path"
      
      // ----- Handle platform detection endpoints -----
      
      // iOS detection - success response
      if path.contains "hotspot-detect.html" or path.contains "success.html":
        log.info "iOS detection: sending success page"
        client.out.write IOS_SUCCESS_RESPONSE.to_byte_array
      
      // Android detection - special handling
      else if path.contains "/generate_204" or path.contains "/gen_204":
        log.info "Android detection (204): $path - sending 204 response"
        client.out.write ANDROID_204_RESPONSE
        
      // Other Android detection - redirect to index
      else if path.contains "/mobile/status.php" or path.contains "connectivitycheck.gstatic.com":
        log.info "Android detection (redirect): $path - redirecting to index"
        client.out.write ANDROID_REDIRECT_RESPONSE
      
      // Windows/Other detection
      else if path.contains "/connecttest.txt" or path.contains "/ncsi.txt":
        log.info "Windows/Other detection: $path - redirecting to index"
        client.out.write ANDROID_REDIRECT_RESPONSE
      
      // ----- Handle regular browsing -----
      
      // Serve main page directly
      else if path == "/" or path == "/index.html":
        serve_main_page client access_points
      
      // Form submission
      else if method == "POST" and path.contains "?":
        // Handle form submission
        credentials := parse_form_submission request_str
        if credentials and credentials.get "ssid" --if_absent=(: null):
          log.info "Form submission received with valid credentials"
          return credentials
      
      // Common domains - redirect to index
      else if path.contains "example.com" or path.contains "www." or path.contains "captive." or path.contains "clients3.google.com":
        log.info "Common domain request: $path - redirecting to index"
        client.out.write DEFAULT_REDIRECT_RESPONSE
        
      // All other requests - redirect to index
      else:
        log.debug "Other request: $path - redirecting to index"
        client.out.write DEFAULT_REDIRECT_RESPONSE
    
    // Always close the client socket with improved error handling
    if client:
      try:
        // Add a small delay before closing to ensure proper response delivery
        sleep --ms=10
        client.close
      catch error:
        log.debug "Error closing socket: $error"
  
  return null  // Should never reach here

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
  // Use only the direct HTTP handler for everything
  log.info "Starting captive portal web server"
  
  // Open the TCP socket for HTTP
  socket := network.tcp_listen 80
  
  // Get result from the direct handler - now it handles everything
  result := direct_http_respond socket access_points
  
  // Clean up and return
  socket.close
  
  // Return the credentials if we got them
  if result: return result
  
  unreachable