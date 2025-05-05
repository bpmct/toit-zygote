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
  log.info "scanning for wifi access points"
  channels := ByteArray 12: it + 1
  access_points := wifi.scan channels
  access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi

  log.info "establishing wifi in AP mode ($CAPTIVE_PORTAL_SSID)"
  status_message := ""
  
  while true:
    network_ap := wifi.establish
        --ssid=CAPTIVE_PORTAL_SSID
        --password=CAPTIVE_PORTAL_PASSWORD
    credentials/Map? := null

    portal_exception := catch:
      credentials = (with_timeout timeout: run_captive_portal network_ap access_points status_message)

    if portal_exception: 
      log.info "Captive portal exception: $portal_exception"
      status_message = "Connection attempt timed out. Please try again."

    try:
      network_ap.close
    finally:
      // Ensure we always continue to the next iteration if no credentials
      if not credentials: continue

    if credentials:
      retry_count := 0
      connected := false
      
      log.info "*** STARTING WIFI CONNECTION PROCESS ***"
      while retry_count < MAX_CONNECTION_RETRIES and not connected:
        log.info "*** CONNECTION ATTEMPT $(retry_count + 1) ***"
        exception := catch:
          log.info "Opening WiFi in STA mode with credentials" --tags=credentials
          
          // Open WiFi connection with --save flag to ensure credentials are stored in flash
          network_sta := wifi.open
              --save    // CRITICAL: This ensures credentials persist after reboot
              --ssid=credentials["ssid"]
              --password=credentials["password"]
          
          // Log network details if connected
          log.info "WiFi connected, address: $(network_sta.address)"
          
          // Wait to make sure credentials are saved to flash
          log.info "Waiting 5 seconds to ensure credentials are saved..."
          sleep --ms=5000
          
          // Close the connection properly
          log.info "Closing WiFi connection"
          network_sta.close
          
          log.info "WiFi credentials saved successfully" --tags=credentials
          connected = true
          
          // Success - return to main function
          log.info "*** CONNECTION SUCCESSFUL - RETURNING TO MAIN ***"
          return
        
        if exception:
          log.warn "WiFi connection failed (attempt $(retry_count + 1)): $exception" --tags=credentials
          retry_count++
          
          // Create a status message with the SSID from credentials
          ssid := credentials["ssid"]
          status_message = "Failed to connect to $ssid. Please check your credentials and try again."
          
          // Short sleep before retrying
          log.info "Waiting 2 seconds before retry..."
          sleep --ms=2000

run_captive_portal network/net.Interface access_points/List status_message/string="" -> Map:
  results := Task.group --required=1 [
    :: run_dns network,
    :: run_http network access_points status_message,
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
  socket := network_interface.tcp_listen 80
  
  // Start a task that directly handles captive portal detection
  // This bypasses HTTP server overhead for faster response times
  task::
    direct_http_respond socket
  
  // Now start the regular server with slightly delayed execution
  // to allow the direct responder to handle initial iOS requests
  sleep --ms=100
  
  server := http.Server
  
  log.info "HTTP server starting"
  
  // Create network options HTML
  network_options := access_points.map: | ap |
    str := "Good"
    if ap.rssi > -60: str = "Strong"
    else if ap.rssi < -75: str = "Weak"
    "<option value=\"$(ap.ssid)\">$(ap.ssid) ($str)</option>"
  
  // Prepare the main portal page HTML
  substitutions := {
    "network-options": network_options.join "\n",
    "status-message": status_message != "" ? "<div class=\"msg\">$status_message</div>" : ""
  }
  portal_html := INDEX.substitute: substitutions[it]
  
  result := null
  
  try:
    server.listen socket:: | request writer |
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
        
        // Handle form submission
        else if path.contains "?":
          query := url.QueryString.parse path
          
          // Get SSID from network parameter or ssid parameter
          ssid := ""
          wifi_network := query.parameters.get "network" --if_absent=: null
          if wifi_network and wifi_network != "custom":
            ssid = wifi_network.trim
          else:
            ssid_param := query.parameters.get "ssid" --if_absent=: null
            if ssid_param: ssid = ssid_param.trim
          
          if ssid != "":
            // Get password if needed
            password := ""
            security := query.parameters.get "security_type" --if_absent=: "password"
            if security != "open":
              pwd := query.parameters.get "password" --if_absent=: null
              if pwd: password = pwd.trim
            
            // Return the credentials
            log.info "Form submitted - ssid: $ssid, closing socket and returning credentials"
            result = {:}
            result["ssid"] = ssid
            result["password"] = password
            
            // Show success page
            writer.headers.set "Content-Type" "text/html"
            writer.headers.set "Connection" "close"  // Ensure connection is closed
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
            log.info "Closing socket immediately after form submission"
            
            // Force server.listen to exit by closing the socket
            socket.close
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
    if result: return result
    socket.close
  unreachable
