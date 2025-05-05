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
MAX_SETUP_TIMEOUT       ::= Duration --m=30  // 30 minutes timeout instead of 15
MAX_CONNECTION_RETRIES  ::= 3

// Global variable to share credentials between tasks
GLOBAL_CREDENTIALS/Map? := null

// Ultra-minimal response for iOS captive portal detection
// This time include a meta refresh to automatically redirect to the portal
IOS_RESPONSE ::= """
<html><head><meta http-equiv="refresh" content="0;url=/portal.html" /><title>Success</title></head><body>Success</body></html>
"""

// Simplified HTML to reduce memory usage
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
.msg{padding:10px;margin:10px 0;border-radius:4px;background:#f8f9fa;border-left:3px solid #17a2b8}
.hidden{display:none}
label{display:block;font-weight:500}
@media(max-width:480px){body{padding:10px}}
</style>
</head>
<body>
<h1>WiFi Setup</h1>
{{status-message}}
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
<label for="st">Security:</label>
<select id="st" name="security_type" onchange="hSC()">
<option value="password">Password Protected</option>
<option value="open">Open Network</option>
</select>
<div id="pc">
<label for="pw">Password:</label>
<input type="password" id="pw" name="password" autocorrect="off" autocapitalize="none">
</div>
<input type="submit" class="btn" value="Connect">
</form>
<script>
function hNC(){
var d=document.getElementById("nw"),s=document.getElementById("ss"),c=document.getElementById("sc");
if(d.value==="custom"){s.value="";s.disabled=false;c.classList.remove("hidden")}
else{s.value=d.value;s.disabled=true;c.classList.add("hidden")}
}
function hSC(){
var t=document.getElementById("st"),p=document.getElementById("pc");
p.style.display=t.value==="open"?"none":"block";
}
window.onload=function(){
hNC();hSC();
}
</script>
</body>
</html>
"""

main:
  run MAX_SETUP_TIMEOUT  // Use the longer timeout constant

run timeout/Duration:
  log.info "*** STARTING DIRECT WIFI CONFIG FLOW ***"
  channels := ByteArray 12: it + 1
  access_points := wifi.scan channels
  access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi

  log.info "establishing wifi in AP mode ($CAPTIVE_PORTAL_SSID)"
  
  // ADDING GLOBAL CREDENTIALS HOLDER
  GLOBAL_CREDENTIALS = null
  
  captive_portal_task := task::
    log.info ">>> STARTING CAPTIVE PORTAL TASK"
    
    // Setup AP mode network
    network_ap := wifi.establish
        --ssid=CAPTIVE_PORTAL_SSID
        --password=CAPTIVE_PORTAL_PASSWORD
    log.info ">>> AP MODE ESTABLISHED IN BACKGROUND TASK"
    
    // Run captive portal
    log.info ">>> RUNNING CAPTIVE PORTAL IN BACKGROUND TASK"
    credentials := null
    
    portal_exception := catch:
      credentials = run_captive_portal network_ap access_points ""
    
    log.info ">>> CAPTIVE PORTAL FINISHED IN BACKGROUND TASK"
    
    if portal_exception:
      log.info ">>> CAPTIVE PORTAL EXCEPTION: $portal_exception"
    
    // Clean up AP mode
    log.info ">>> CLOSING AP MODE IN BACKGROUND TASK"
    close_exception := catch:
      network_ap.close
      log.info ">>> AP MODE CLOSED SUCCESSFULLY IN BACKGROUND TASK"
    
    if close_exception:
      log.error ">>> ERROR CLOSING AP MODE IN BACKGROUND TASK: $close_exception"
    
    // If we have credentials, store them globally
    if credentials:
      log.info ">>> STORING CREDENTIALS GLOBALLY IN BACKGROUND TASK"
      GLOBAL_CREDENTIALS = credentials
  
  // Wait for credentials to be acquired from captive portal
  max_wait_time_ms := 300000  // 5 minutes in ms
  interval := 100  // Check every 100ms
  iterations := max_wait_time_ms / interval
  
  log.info ">>> MAIN THREAD WAITING FOR CREDENTIALS (MAX WAIT: $max_wait_time_ms MS)"
  
  i := 0
  while i < iterations:
    if GLOBAL_CREDENTIALS:
      log.info ">>> CREDENTIALS RECEIVED IN MAIN THREAD"
      break
    
    sleep --ms=interval
    log.info ">>> WAITING FOR CREDENTIALS..."
    i++
  
  // If we didn't get credentials, exit setup
  if not GLOBAL_CREDENTIALS:
    log.info ">>> NO CREDENTIALS RECEIVED, EXITING SETUP"
    return
  
  // We have credentials! Use them to connect
  credentials := GLOBAL_CREDENTIALS
  ssid := credentials["ssid"]
  password := credentials["password"]
  
  log.info ">>> CREDENTIALS RECEIVED, CONNECTING TO WIFI: $ssid"
  
  wifi_exception := catch:
    log.info ">>> OPENING WIFI IN STA MODE"
    
    // Open WiFi with credentials and --save flag to persist to flash memory
    network_sta := wifi.open
        --save
        --ssid=ssid
        --password=password
    
    // Log connection status if successful
    log.info ">>> WIFI CONNECTION ESTABLISHED SUCCESSFULLY"
        
    // Wait to ensure credentials are saved to flash
    log.info ">>> WAITING 5 SECONDS TO ENSURE CREDENTIALS ARE SAVED..."
    sleep --ms=5000
    
    // Close connection properly
    network_sta.close
    log.info ">>> WIFI CONNECTION SAVED SUCCESSFULLY"
    
    // Exit setup mode and return to application container
    log.info ">>> WIFI SETUP COMPLETE - RETURNING TO APPLICATION MODE"
    mode.run_application
    
    log.info ">>> THIS LINE SHOULD NEVER PRINT - EXECUTION SHOULD BE TERMINATED BY mode.run_application"
  
  if wifi_exception:
    log.error ">>> WIFI CONNECTION FAILED: $wifi_exception"

run_captive_portal network/net.Interface access_points/List status_message/string="" -> Map:
  log.info "Starting captive portal with DNS and HTTP servers"
  
  log.info ">>> STARTING TASK GROUP WITH DNS AND HTTP SERVERS"
  // Start DNS and HTTP servers as parallel tasks
  results := Task.group --required=1 [
    :: run_dns network,
    :: run_http network access_points status_message,
  ]
  
  log.info ">>> TASK GROUP COMPLETED"
  
  // The HTTP server will return credentials when form is submitted
  credentials := results[1]
  log.info ">>> EXTRACTED CREDENTIALS FROM HTTP SERVER RESULT"
  
  // Log what we received from the HTTP server
  if credentials:
    log.info "*** CAPTIVE PORTAL RECEIVED CREDENTIALS ***"
    log.info "Credentials: SSID=$(credentials["ssid"]), password length=$(credentials["password"].size)"
    log.info ">>> RETURNING CREDENTIALS FROM run_captive_portal TO main run FUNCTION"
  else:
    log.warn "Captive portal did not receive any credentials"
  
  // Return the credentials to the main run function
  return credentials

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

// Create a separate simple HTTP handler that just responds to captive portal detection
// without going through the full server processing
direct_http_respond socket/tcp.ServerSocket -> none:
  log.info "Starting direct HTTP responder for faster iOS detection"
  
  while true:
    // Accept a client connection
    client := null
    exception := catch:
      client = socket.accept
    
    if not client: continue
    
    // Get peer for logging
    peer := "unknown"
    exception = catch:
      peer = client.peer.to_string
    
    log.info "Direct client connection from $peer"
    
    // Read request data - minimal parsing to identify iOS detection
    data := ByteArray 1024
    bytes_read := 0
    exception = catch:
      bytes_read = client.read data
    
    if bytes_read > 0:
      // Convert data to string and check for iOS detection paths
      request_str := ""
      exception = catch:
        request_str = data.to_string
      
      log.info "Got raw request: $(request_str.size) bytes"
      
      is_ios_detection := false
      
      if request_str.contains "GET /hotspot-detect.html" or 
         request_str.contains "GET /library/test/success.html" or
         request_str.contains "CaptiveNetworkSupport":
        is_ios_detection = true
      
      if is_ios_detection:
        log.info "Sending direct iOS response"
        
        // Send a minimal HTTP response directly
        response := """
HTTP/1.1 200 OK
Content-Type: text/html
Connection: close
Content-Length: $(IOS_RESPONSE.size)

$IOS_RESPONSE"""
        
        exception = catch:
          client.write response.to_byte_array
        
        log.info "Sent iOS response directly"
      else:
        log.info "Not an iOS detection request, closing"
    
    // Always close the client socket
    if client:
      exception = catch:
        client.close

run_http network_interface/net.Interface access_points/List status_message/string="" -> Map:
  log.info "*** SIMPLIFIED HTTP SERVER STARTING ***"
  
  // Open TCP socket on port 80
  socket := network_interface.tcp_listen 80
  
  // Start a task that directly handles captive portal detection
  // This bypasses HTTP server overhead for faster response times
  task::
    direct_http_respond socket
  
  // A short delay to allow the direct responder to initialize
  sleep --ms=100
  
  // Create the HTTP server
  server := http.Server
  
  // Create network options HTML for the dropdown
  network_options := access_points.map: | ap |
    str := "Good"
    if ap.rssi > -60: str = "Strong"
    else if ap.rssi < -75: str = "Weak"
    "<option value=\"$(ap.ssid)\">$(ap.ssid) ($str)</option>"
  
  // Prepare the main portal page HTML with substitutions
  substitutions := {
    "network-options": network_options.join "\n",
    "status-message": status_message != "" ? "<div class=\"msg\">$status_message</div>" : ""
  }
  
  // Substitute values into the template
  portal_html := INDEX.substitute: substitutions[it]
  
  // Initialize the result map that will hold credentials when available
  result := null
  
  log.info "Starting HTTP server loop - waiting for form submission"
  
  // Create a flag to indicate if we have a form submission
  have_form_submission := false
  
  // Start a background task to check for form submission and force socket closure
  cancel_task := task::
    log.info ">>> STARTING FORM SUBMISSION MONITORING TASK"
    while true:
      if have_form_submission:
        log.info ">>> FORM SUBMISSION DETECTED - FORCE CLOSING SOCKET"
        error := catch:
          socket.close
          log.info ">>> MONITORING TASK: SOCKET CLOSED SUCCESSFULLY"
        
        if error:
          log.error ">>> MONITORING TASK: FAILED TO CLOSE SOCKET: $error"
        
        log.info ">>> MONITORING TASK COMPLETED"
        break
      
      // Check every 100ms
      sleep --ms=100
  
  try:
    // Start the HTTP server and handle requests
    server.listen socket:: | request writer |
      // Skip flag checking here - now handled by background task
      // Skip processing connect requests
      if request.method == "CONNECT":
        log.debug "Skipping CONNECT request"
      else:
        path := request.path
        log.info "Request: $path"
        
        // Handle iOS captive portal detection (backup for the direct handler)
        if path == "/hotspot-detect.html" or path == "/library/test/success.html":
          log.info "Sending iOS detection response (from regular server)"
          writer.headers.set "Content-Type" "text/html"
          writer.headers.set "Connection" "close"
          writer.write IOS_RESPONSE
        
        // Handle the explicit portal page request
        else if path == "/portal.html":
          log.info "Showing portal page"
          writer.headers.set "Content-Type" "text/html"
          writer.headers.set "Cache-Control" "no-store, no-cache"
          writer.write portal_html
        
        // Handle form submission - DIRECT CONFIGURATION APPROACH
        else if path.contains "?":
          log.info "Form submission detected - using direct configuration approach"
          
          // Parse the query parameters
          query := url.QueryString.parse path
          
          // Check if we have form parameters
          if not query.parameters.is_empty:
            // Extract SSID - first from network dropdown, then from ssid field
            ssid := ""
            wifi_network := query.parameters.get "network" --if_absent=: null
            if wifi_network and wifi_network != "custom":
              ssid = wifi_network.trim
            else:
              ssid_param := query.parameters.get "ssid" --if_absent=: null
              if ssid_param: ssid = ssid_param.trim
            
            // Extract password
            password := query.parameters.get "password" --if_absent=: ""
            if password: password = password.trim
            
            // If we have a valid SSID, prepare to return credentials
            if ssid and ssid != "":
              log.info "Form submitted - valid credentials found: SSID=$ssid, password length=$(password.size)"
              
              // Send the success page to the browser first
              log.info "Sending success page to browser"
              writer.headers.set "Content-Type" "text/html"
              writer.headers.set "Connection" "close"
              writer.write """
<html><head><title>Connected</title><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>body{font-family:sans-serif;text-align:center;margin:0 auto;max-width:100%;padding:20px}
.s{color:#4CAF50;font-size:24px;margin:20px 0}.m{background:#f8f9fa;padding:15px;margin:15px 0;border-radius:6px}
.l{width:30px;height:30px;border:4px solid #eee;border-top:4px solid #4CAF50;border-radius:50%;animation:s 1s infinite linear;margin:20px auto}
@keyframes s{0%{transform:rotate(0deg)}100%{transform:rotate(360deg)}}</style>
</head><body>
<div class="s">WiFi Connected!</div>
<div class="m">Connected to <b>$ssid</b><br>The device will restart...</div>
<div class="l"></div>
<p>You'll be disconnected when the device restarts.</p>
</body></html>
"""
              // First, send the response to the client so they see the success page
              log.info "Sending success page to browser and waiting for it to complete..."
              
              // Sleep a bit to ensure the response is sent
              sleep --ms=500
              
              log.info "MEGA DIRECT APPROACH: Now attempting WiFi connection directly from HTTP handler"
              
              // Use a task to just close the socket and continue normal flow
              task::
                log.info ">>> SOCKET CLOSE TASK STARTED"
                sleep --ms=500  // Wait for response to be sent
                exception := catch:
                  socket.close
                  log.info ">>> SOCKET CLOSED BY TASK"
              
              // Continue with normal HTTP handler flow - the task will handle everything
              log.info ">>> HTTP HANDLER CONTINUING - WIFI CONFIGURATION RUNNING IN BACKGROUND"
              
              // Store credentials in result for the normal flow too (backup approach)
              result = {:}  // Create empty map
              result["ssid"] = ssid
              result["password"] = password
          else:
            // Show the portal again for invalid submissions
            writer.headers.set "Content-Type" "text/html"
            writer.headers.set "Cache-Control" "no-store, no-cache"
            writer.write portal_html
        
        // Default case - show the portal
        else:
          log.info "Showing portal page (default)"
          writer.headers.set "Content-Type" "text/html"
          writer.headers.set "Cache-Control" "no-store, no-cache"
          writer.write portal_html
  finally:
    // If we have credentials, return them immediately
    if result:
      log.info "*** FORM SUBMISSION COMPLETE: RETURNING CREDENTIALS ***"
      log.info "Credentials: SSID=$(result["ssid"]), password length=$(result["password"].size)"
      log.info ">>> HTTP SERVER EXITING - RETURNING CREDENTIALS TO run_captive_portal"
      
      // This is the most important part - return credentials to run_captive_portal
      return result
    
    // Otherwise, just close the socket and return
    socket.close
    log.info "HTTP server closed without receiving credentials"
  
  // This line should not be reached
  log.warn "HTTP server exited without results - this should not happen"
  unreachable