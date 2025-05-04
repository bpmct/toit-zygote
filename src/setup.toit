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
MAX_SETUP_TIMEOUT       ::= Duration --m=30  // 30 minutes timeout instead of 15
MAX_CONNECTION_RETRIES  ::= 5   // Number of connection attempts before giving up

// Ultra-minimal response for iOS captive portal detection
// Include a meta refresh to automatically redirect to the full portal
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
  // We allow the setup container to start and eagerly terminate
  // if we don't need it yet. This makes it possible to have
  // the setup container installed always, but have it run with
  // the -D jag.disabled flag in development.
  if mode.RUNNING:
    log.info "WiFi already configured, skipping setup"
    return

  // When running in development we run for less time before we
  // back to trying out the app.
  timeout := mode.DEVELOPMENT ? (Duration --m=2) : MAX_SETUP_TIMEOUT
  log.info "Starting setup with timeout: $timeout"
  
  exception := catch --trace:
    run timeout
  
  if exception:
    log.error "Setup failed with error: $exception"
  
  // We're done trying to complete the setup. Go back to running
  // the application and let it choose when to re-initiate the
  // setup process.
  log.info "Setup completed or timed out, returning to application mode"
  
  // Make sure to wait just a moment before triggering the mode switch
  // This ensures all logs are processed and connections are properly closed
  sleep --ms=500
  
  // Use the mode.run_application function to properly handle the mode switch
  mode.run_application

run timeout/Duration:
  log.info "Setup container started, scanning for WiFi access points"
  channels := ByteArray 12: it + 1
  access_points := wifi.scan channels
  access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi

  log.info "Establishing WiFi in AP mode ($CAPTIVE_PORTAL_SSID)"
  status_message := ""
  
  while true:
    network_ap := wifi.establish
        --ssid=CAPTIVE_PORTAL_SSID
        --password=CAPTIVE_PORTAL_PASSWORD
    credentials/Map? := null

    portal_exception := catch --trace:
      with_timeout (Duration --m=5):  // Limit each portal attempt to 5 minutes
        credentials = run_captive_portal network_ap access_points status_message

    if portal_exception: 
      log.info "Captive portal exception: $portal_exception"
      status_message = "Connection attempt timed out. Please try again."

    // Always close the AP network interface
    ap_close_exception := catch --trace:
      network_ap.close
    
    if ap_close_exception:
      log.warn "Error closing AP network: $ap_close_exception"
    
    if not credentials:
      log.info "No credentials received, continuing AP mode"
      continue

    if credentials:
      // Try multiple times to connect
      for retry := 0; retry < MAX_CONNECTION_RETRIES; retry++:
        exception := catch --trace:
          log.info "Connecting to WiFi in STA mode (attempt $(retry + 1))" --tags=credentials
          
          // Try to connect to WiFi
          log.info "Attempting to connect to WiFi SSID: '$(credentials["ssid"])'"
          network_sta := wifi.open
              --save
              --ssid=credentials["ssid"]
              --password=credentials["password"]
          
          // Wait for valid IP address for a short time
          ip_address := null
          wait_attempts := 0
          while wait_attempts < 20 and not ip_address:
            ip_address = network_sta.address
            if ip_address:
              log.info "Successfully connected with IP address: $ip_address" --tags=credentials
              break
            sleep --ms=500
            wait_attempts++
          
          if not ip_address:
            throw "Failed to obtain IP address"
          
          // Keep connection open to ensure configuration is saved
          log.info "Successfully connected to WiFi, keeping connection open to save configuration"
          sleep --ms=15000
          
          // Close the connection and return to indicate success
          network_sta.close
          log.info "WiFi configuration saved, returning to application mode"
          
          // Make sure we wait a bit before returning to ensure all operations complete
          sleep --ms=1000
          
          return
          
        if exception:
          log.warn "WiFi connection failed (attempt $(retry + 1)): $exception" --tags=credentials
          
          // Create status message if we need to retry the captive portal
          if retry == MAX_CONNECTION_RETRIES - 1:  // Last attempt failed
            ssid := credentials["ssid"]
            status_message = "Failed to connect to $ssid. Please check your credentials and try again."

run_captive_portal network/net.Interface access_points/List status_message/string="" -> Map:
  // Make sure to log what we're doing 
  log.info "Starting captive portal with DNS and HTTP servers"
  
  results := Task.group --required=1 [
    :: run_dns network,
    :: run_http network access_points status_message,
  ]
  
  log.info "Captive portal ended, got form submission"
  return results[1]  // Return the result from the HTTP server at index 1.

run_dns network/net.Interface -> none:
  device_ip_address := network.address
  socket := network.udp_open --port=53
  hosts := dns.SimpleDnsServer device_ip_address  // Answer the device IP to all queries.

  log.info "DNS server started on $device_ip_address"

  try:
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      response := hosts.lookup datagram.data
      if not response: continue
      socket.send (udp.Datagram response datagram.address)
  finally:
    log.info "Closing DNS server"
    dns_exception := catch --trace: socket.close
    if dns_exception: log.warn "DNS server exception: $dns_exception"

// Simple response for direct detection success
DIRECT_SUCCESS_RESPONSE ::= """
HTTP/1.1 200 OK
Content-Type: text/html
Cache-Control: no-store
Connection: close
Content-Length: 165

<html><head><meta http-equiv="refresh" content="0;url=/portal.html" /><title>Success</title></head><body>Success - redirecting to portal...</body></html>
"""

// Create a separate simple HTTP handler that just responds to captive portal detection
// without going through the full server processing
direct_http_respond socket/tcp.ServerSocket -> none:
  log.info "Starting direct HTTP responder for faster iOS detection"
  
  try:
    while not Task.current.is_canceled:
      client := null
      accept_exception := catch --trace:
        client = socket.accept
      
      if not client: continue
      
      // Read request data - minimal parsing to identify iOS detection
      data := ByteArray 1024
      bytes_read := 0
      read_exception := catch --trace:
        bytes_read = client.read data
      
      if bytes_read > 0:
        // Convert data to string and check for iOS detection paths
        request_str := ""
        string_exception := catch --trace:
          request_str = data.to_string
        
        log.info "Direct HTTP request: $(bytes_read) bytes"
        
        is_ios_detection := false
        if request_str.contains "GET /hotspot-detect.html" or 
           request_str.contains "GET /library/test/success.html" or
           request_str.contains "CaptiveNetworkSupport":
          is_ios_detection = true
        
        if is_ios_detection:
          log.info "Sending direct iOS response with auto-redirect"
          
          // Send a minimal HTTP response with redirect
          write_exception := catch --trace:
            client.write DIRECT_SUCCESS_RESPONSE.to_byte_array
          
          log.info "Sent iOS response directly with redirect"
        
      // Always close the client socket
      if client:
        client_exception := catch --trace:
          client.close
  finally:
    log.info "Direct HTTP responder shutting down"

run_http network_interface/net.Interface access_points/List status_message/string="" -> Map:
  socket := network_interface.tcp_listen 80
  
  // Start a task that directly handles captive portal detection
  // This bypasses HTTP server overhead for faster response times
  direct_task_var := task::
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
  should_exit := false
  
  try:
    server.listen socket:: | request writer |
      // Skip processing connect requests
      if request.method == "CONNECT":
        log.debug "Skipping CONNECT request"
      else:
        path := request.path
        log.info "Request: $path"
        
        // Handle iOS captive portal detection
        if path == "/hotspot-detect.html" or path == "/library/test/success.html":
          log.info "Sending iOS detection response with redirect"
          writer.headers.set "Content-Type" "text/html"
          writer.headers.set "Connection" "close"
          writer.write IOS_RESPONSE
        
        // This is the page we redirect to - always show the full portal
        else if path == "/portal.html" or path == "/" or path == "/index.html":
          log.info "Showing full portal page"
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
            log.info "Form submitted - ssid: $ssid"
            result = {:}
            result["ssid"] = ssid
            result["password"] = password
            
            // Show success page and ensure it's sent completely
            log.info "Sending success page for $ssid"
            success_page := """
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
            writer.headers.set "Content-Type" "text/html"
            writer.headers.set "Connection" "close"
            writer.headers.set "Content-Length" "$(success_page.size)"
            writer.write success_page
            writer.close
            
            // Force close socket after success page is sent
            log.info "Success page sent, closing server"
            socket_exception := catch --trace: socket.close
            
            // Cancel the direct HTTP task as well
            direct_task_exception := catch --trace: direct_task_var.cancel
            
            // Set flag to exit after this request
            should_exit = true
          else:
            // Show the portal again for invalid submissions
            log.info "Invalid submission - showing portal page again"
            writer.headers.set "Content-Type" "text/html"
            writer.headers.set "Cache-Control" "no-store, no-cache"
            writer.write portal_html
        
        // Default case - show the portal
        else:
          log.info "Showing portal page (default)"
          writer.headers.set "Content-Type" "text/html"
          writer.headers.set "Cache-Control" "no-store, no-cache"
          writer.write portal_html
      
      // Break out of listener if needed
      if should_exit: 
        Task.current.cancel
  finally:
    // Cancel the direct HTTP task explicitly when exiting
    final_cancel_exception := catch --trace: direct_task_var.cancel
    
    // Always close the socket when done
    log.info "Closing HTTP server socket"
    final_socket_exception := catch --trace: socket.close
    
    if result: return result
    else: return {:}  // Return empty map if no result so we don't get unreachable