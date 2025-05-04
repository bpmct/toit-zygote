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

// No longer importing mode
// import .mode as mode

import io  // Import IO for system diagnostics

CAPTIVE_PORTAL_SSID     ::= "mywifi"
CAPTIVE_PORTAL_PASSWORD ::= "12345678"
MAX_SETUP_TIMEOUT       ::= Duration --m=120  // Extended to 2 hours for reliable operation
MAX_CONNECTION_RETRIES  ::= 10   // Increased even more for reliability
RUNNING                 ::= true // Force running mode

// Ultra-minimal response for iOS captive portal detection
// Include a meta refresh to automatically redirect to the full portal
IOS_RESPONSE ::= """
<html><head><meta http-equiv="refresh" content="0;url=/portal.html" /><title>Success</title></head><body>Success</body></html>
"""

// Simple response for direct detection success
DIRECT_SUCCESS_RESPONSE ::= """
HTTP/1.1 200 OK
Content-Type: text/html
Cache-Control: no-store
Connection: close
Content-Length: 165

<html><head><meta http-equiv="refresh" content="0;url=/portal.html" /><title>Success</title></head><body>Success - redirecting to portal...</body></html>
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
  // Make sure we run for at least 2 minutes after starting
  timeout := Duration --m=2
  if MAX_SETUP_TIMEOUT > timeout:
    timeout = MAX_SETUP_TIMEOUT
    
  log.info "Starting setup with timeout: $timeout"
  log.info "WARNING: This container will NOT stop automatically - you need to restart the device"
  
  // Start a watchdog process that will keep this container alive
  // This will ensure that if the main process crashes, the container stays running
  watchdog_task := task::
    watchdog_start_time := Time.monotonic_us
    while true:
      log.info "Watchdog: Container uptime $(Duration --us=(Time.monotonic_us - watchdog_start_time))"
      sleep --ms=300000  // Check every 5 minutes (300000ms)
  
  // Force RUNNING to true to stay in setup mode, avoiding mode switching
  // This will keep the container running until we're done
  exception := catch --trace:
    run timeout
  
  if exception:
    log.error "Setup failed with error: $exception" 
    log.error "Error details: $exception"
    // Ensure we don't exit even on error
    log.info "Error detected, but container will CONTINUE RUNNING"
    sleep --ms=300000  // Sleep for 5 minutes (300000ms)
    
    // Try again with a while loop to keep trying
    log.info "Attempting to restart setup process after error"
    while true:
      retry_exception := catch --trace:
        run timeout
      
      if retry_exception:
        log.error "Retry also failed: $retry_exception"
      
      log.info "Setup process completed or failed, waiting before possible retry"
      sleep --ms=300000  // Sleep for 5 minutes (300000ms)

// Print system information to help with debugging
print_system_info:
  // Just log basic information instead of trying to access io.free, env, etc.
  log.info "System info - Starting diagnostic logging"
  log.info "System time: $Time.now"
  log.info "Monotonic time: $(Time.monotonic_us)"

run timeout/Duration:
  start_time := Time.monotonic_us

  // Print system diagnostics at startup
  print_system_info
  
  log.info "Setup container started, will run for at least $timeout"
  log.info "scanning for wifi access points"
  channels := ByteArray 12: it + 1
  
  // Robustly handle WiFi scanning with retries
  scan_attempts := 0
  max_scan_attempts := 5
  access_points := []
  
  while scan_attempts < max_scan_attempts and access_points.is_empty:
    log.info "WiFi scan attempt $(scan_attempts + 1)/$max_scan_attempts"
    scan_exception := catch:
      access_points = wifi.scan channels
    
    if scan_exception:
      log.warn "WiFi scan failed: $scan_exception"
      scan_attempts++
      sleep --ms=1000
    else:
      if access_points.is_empty:
        log.warn "WiFi scan returned no access points, retrying..."
        scan_attempts++
        sleep --ms=2000
      else:
        log.info "WiFi scan successful, found $(access_points.size) networks"
        break
  
  // Sort access points by signal strength
  if not access_points.is_empty:
    access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi

  log.info "establishing wifi in AP mode ($CAPTIVE_PORTAL_SSID)"
  status_message := ""
  wifi_config_successful := false
  
  while (Duration --us=(Time.monotonic_us - start_time)) < timeout or not wifi_config_successful:
    elapsed_us := Time.monotonic_us - start_time
    elapsed := Duration --us=elapsed_us
    remaining := timeout - elapsed
    log.info "Starting AP mode cycle. Time elapsed: $elapsed, Time remaining: $remaining"
    
    network_ap := wifi.establish
        --ssid=CAPTIVE_PORTAL_SSID
        --password=CAPTIVE_PORTAL_PASSWORD
    credentials/Map? := null

    portal_exception := catch:
      with_timeout (Duration --m=5):  // Limit each portal attempt to 5 minutes
        credentials = run_captive_portal network_ap access_points status_message

    if portal_exception: 
      log.info "Captive portal exception: $portal_exception"
      status_message = "Connection attempt timed out. Please try again."

    // Always close the AP network interface
    try:
      network_ap.close
    finally:
      if not credentials: 
        log.info "No credentials received, continuing AP mode"
        continue

    if credentials:
      retry_count := 0
      connected := false
      
      while retry_count < MAX_CONNECTION_RETRIES and not connected:
        exception := catch:
          log.info "connecting to wifi in STA mode (attempt $(retry_count + 1))" --tags=credentials
          
          // MODIFIED APPROACH: Don't close the network until much later
          // This will keep the WiFi connection alive longer
          network_sta := wifi.open
              --save
              --ssid=credentials["ssid"]
              --password=credentials["password"]
          
          // Wait for the connection to actually complete
          log.info "WiFi connection initiated, waiting for it to complete..."
          
          // Make sure we have a valid IP address before continuing
          ip_address := null
          max_wait_attempts := 60  // Maximum 30 seconds (60 * 500ms)
          wait_attempts := 0
          
          while wait_attempts < max_wait_attempts:
            // Check if we have an IP address
            ip_address = network_sta.address
            if ip_address:
              log.info "Successfully connected with IP address: $ip_address" --tags=credentials
              break
            else:
              log.info "Waiting for IP address assignment (attempt $(wait_attempts + 1)/60)..."
              sleep --ms=500  // Check every 500ms
              wait_attempts++
          
          if not ip_address:
            throw "Failed to obtain IP address after successful connection"
          
          // Keep the network connection open for a long time to ensure it's saved
          log.info "Successfully connected to WiFi with IP: $ip_address, keeping connection open for 60+ seconds..."
          log.info "connecting to wifi in STA mode => success" --tags=credentials
          
          // Test the connection to make sure it's working
          log.info "Testing connection..."
          
          // Verify connectivity by trying to make a DNS query or TCP connection
          connect_success := false
          network_test_exception := catch --trace:
            log.info "Testing network connectivity to 8.8.8.8:53..."
            test_socket := network_sta.tcp_connect "8.8.8.8" 53
            if test_socket:
              log.info "Network connectivity test successful!"
              test_socket.close
              connect_success = true
            else:
              log.info "Network connectivity test failed - will still continue"
          
          if network_test_exception:
            log.info "Error during network test: $network_test_exception - will still continue"
          
          // Set flags to indicate success - even if the connection test failed
          // this is because the WiFi might just be isolated from the internet
          connected = true
          wifi_config_successful = true
          
          // Long delay while keeping network open - increased to 60 seconds
          log.info "Delaying for 60 seconds with network connection open"
          delay_start := Time.monotonic_us
          target_delay := Duration --s=60
          
          while (Duration --us=(Time.monotonic_us - delay_start)) < target_delay:
            // Periodically log to show we're still alive
            if (Time.monotonic_us - delay_start) % 5000000 < 100000:  // Log every ~5 seconds
              curr_elapsed := Duration --us=(Time.monotonic_us - delay_start)
              curr_remaining := target_delay - curr_elapsed
              log.info "Connection active for $curr_elapsed, waiting $curr_remaining more with active connection"
            sleep --ms=100
          
          // Make sure the connection is still good after the delay
          ip_address = network_sta.address
          log.info "After delay, IP address is: $ip_address"
          
          // Now save again and explicitly close the connection
          log.info "WiFi connection maintained for 30+ seconds. Now saving configuration and closing..."
          
          // Try to explicitly save the configuration again by reopening with save flag
          log.info "Re-saving WiFi configuration for: $(credentials["ssid"])"
          
          // IMPORTANT: Use multiple save attempts to ensure the configuration persists
          // This is critical to prevent the container stopping issue          
          for i := 0; i < 3; i++:
            log.info "Save attempt $(i+1)/3 for WiFi configuration"
            
            close_exception := catch --trace:
              // First make sure the previous connection is fully closed
              network_sta.close
              log.info "Previous WiFi connection closed successfully"
              sleep --ms=2000  // Wait longer between close/open
            
            if close_exception:
              log.warn "Error closing network connection: $close_exception"
              // Continue anyway
            
            reopen_exception := catch --trace:
              // Open with save flag
              log.info "Opening WiFi connection with --save flag (attempt $(i+1)/3)"
              temporary_net := wifi.open
                  --save
                  --ssid=credentials["ssid"]
                  --password=credentials["password"]
              
              // Check for IP address to confirm connection success
              temp_ip := null
              wait_count := 0
              while wait_count < 20 and not temp_ip:
                temp_ip = temporary_net.address
                if temp_ip:
                  log.info "Reconnection successful with IP: $temp_ip"
                  break
                sleep --ms=200
                wait_count++
              
              log.info "Keeping save connection open for 10 seconds..."
              sleep --ms=10000  // Keep open longer on each attempt
              
              log.info "Save attempt $(i+1) complete, closing connection"
              temporary_net.close
            
            if reopen_exception:
              log.warn "Error during configuration re-save attempt $(i+1): $reopen_exception"
          
          log.info "WiFi configuration explicitly re-saved for: $(credentials["ssid"])"
          
          // Set both connected and wifi_config_successful flags
          connected = true
          wifi_config_successful = true
          
          // Log success info
          log.info "WiFi connection closed, configuration should be saved successfully"
          log.info "Container will continue running to ensure settings are applied"
        
        if exception:
          log.warn "connecting to wifi in STA mode => failed (attempt $(retry_count + 1)): $exception" --tags=credentials
          retry_count++
          // Create a status message with the SSID from credentials
          ssid := credentials["ssid"]
          status_message = "Failed to connect to $ssid. Please check your credentials and try again."
          // Short sleep before retrying
          sleep --ms=1000

  // After the main loop completes, check if we need to stay alive longer
  elapsed_us := Time.monotonic_us - start_time
  elapsed := Duration --us=elapsed_us
  
  // Always stay alive for the full timeout, plus extra time to ensure changes persist
  remaining := timeout - elapsed
  if remaining > Duration.ZERO:
    log.info "WiFi setup completed, but staying alive for $remaining more to ensure settings apply"
    sleep remaining
  
  // Add additional delay to ensure ESP32 has time to save configuration
  extra_delay := Duration --m=1
  log.info "Adding extra $extra_delay delay to ensure configuration persists"
  sleep extra_delay
    
  final_elapsed := Duration --us=(Time.monotonic_us - start_time)
  log.info "Setup container completed successfully after running for $final_elapsed"
  
  // Force this container to stay running indefinitely
  // This prevents the container from stopping until system restart
  log.info "Setup complete - now keeping container alive indefinitely"
  forever_counter := 0
  while true:
    // Use a counter to only log occasionally to reduce log spam
    if forever_counter % 60 == 0:
      log.info "Setup container still running... (wifi configured as: $(wifi_config_successful ? "SUCCESS" : "PENDING")) (uptime: $(Duration --us=(Time.monotonic_us - start_time)))"
    
    // Every 5 minutes, try to verify the WiFi configuration is still working
    // but only attempt to open a new connection periodically
    if wifi_config_successful and forever_counter % 300 == 0 and forever_counter > 0:
      log.info "Performing periodic WiFi health check"
      // Just check if WiFi is working in general, not with specific credentials
      check_exception := catch --trace:
        // Try to open a default connection without specifying credentials
        check_net := net.open
        if check_net:
          check_ip := check_net.address
          log.info "WiFi health check successful - current IP: $check_ip"
          check_net.close
        else:
          log.warn "WiFi health check failed - no connection obtained"
      
      if check_exception:
        log.warn "WiFi health check failed: $check_exception"
    
    forever_counter++
    sleep --ms=1000  // Sleep for 1 second (1000ms)

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

  log.info "DNS server started on $device_ip_address"

  try:
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      response := hosts.lookup datagram.data
      if not response: continue
      socket.send (udp.Datagram response datagram.address)
  finally:
    log.info "Closing DNS server"
    exception := catch: socket.close
    if exception: log.warn "DNS server exception: $exception"

// Create a separate simple HTTP handler that just responds to captive portal detection
// without going through the full server processing
direct_http_respond socket/tcp.ServerSocket -> none:
  log.info "Starting direct HTTP responder for faster iOS detection"
  
  try:
    while not Task.current.is_canceled:
      // Accept a client connection
      client := null
      exception := catch:
        client = socket.accept
      
      if not client: continue
      
      // Get peer info for logging
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
          log.info "Sending direct iOS response with auto-redirect"
          
          // Send a minimal HTTP response with redirect
          exception = catch:
            client.write DIRECT_SUCCESS_RESPONSE.to_byte_array
          
          log.info "Sent iOS response directly with redirect"
        else:
          log.info "Not an iOS detection request, closing"
      
      // Always close the client socket
      if client:
        exception = catch:
          client.close
  finally:
    log.info "Direct HTTP responder shutting down"
    exception := catch: 
      // Nothing to close here, socket is closed elsewhere
      null

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
        
        // Handle iOS captive portal detection (backup for the direct handler)
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
            
            // Cancel the direct HTTP task
            exception := catch: direct_task_var.cancel
            
            // Force close socket after success page is sent
            log.info "Success page sent, closing server"
            exception = catch: socket.close
            
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
    exception := catch: direct_task_var.cancel
    
    // Always close the socket when done
    log.info "Closing HTTP server socket"
    exception = catch: socket.close
    
    if result: return result
    else: return {:}  // Return empty map if no result so we don't get unreachable
