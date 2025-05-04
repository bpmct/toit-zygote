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

// Used for iOS captive portal detection paths
IOS_DETECTION_PATHS ::= [
  "/hotspot-detect.html",
  "/library/test/success.html",
  "/generate_204",
  "/gen_204", 
  "/mobile/status.php"
]

// Temporary redirects for Android
TEMPORARY_REDIRECTS ::= {
  "generate_204": "/",    // Used by Android captive portal detection.
  "gen_204": "/",         // Used by Android captive portal detection.
}

// Very small response for iOS captive portal detection - with redirect to the proper page
IOS_CAPTIVE_RESPONSE ::= """
<html><head><title>Success</title><meta http-equiv="refresh" content="0; url=/portal.html"></head><body>Success</body></html>
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
<form id="wf">
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
document.getElementById("wf").addEventListener("submit",function(e){
var d=document.getElementById("nw"),s=document.getElementById("ss"),
t=document.getElementById("st").value,p=document.getElementById("pw").value;
if(d.value!=="custom"){s.disabled=false;s.value=d.value}
if(!s.value||s.value.trim()===""){e.preventDefault();alert("Please enter a network name");return false}
if(t==="password"&&(!p||p.trim()==="")){e.preventDefault();alert("Please enter a password");return false}
});
}
</script>
</body>
</html>
"""

// Simple and direct debug log without timestamp processing
direct_log message/string:
  log.debug message

main:
  // We should only run when the device is in setup mode (RUNNING is false)
  // if mode.RUNNING: return
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
      
      while retry_count < MAX_CONNECTION_RETRIES and not connected:
        exception := catch:
          log.info "connecting to wifi in STA mode (attempt $(retry_count + 1))" --tags=credentials
          network_sta := wifi.open
              --save
              --ssid=credentials["ssid"]
              --password=credentials["password"]
          network_sta.close
          log.info "connecting to wifi in STA mode => success" --tags=credentials
          connected = true
          return
        
        if exception:
          log.warn "connecting to wifi in STA mode => failed (attempt $(retry_count + 1))" --tags=credentials
          retry_count++
          // Create a status message with the SSID from credentials
          ssid := credentials["ssid"]
          status_message = "Failed to connect to $ssid. Please check your credentials and try again."
          // Short sleep before retrying
          sleep --ms=1000

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

run_http network/net.Interface access_points/List status_message/string="" -> Map:
  socket := network.tcp_listen 80
  server := http.Server
  
  log.info "HTTP server starting"
  
  // Precompute the network options once
  network_options := ""
  exception := catch:
    options := access_points.map: | ap |
      str := "Good"
      if ap.rssi > -60: str = "Strong"
      else if ap.rssi < -75: str = "Weak"
      "<option value=\"$(ap.ssid)\">$(ap.ssid) ($str)</option>"
    network_options = options.join "\n"
  
  if exception:
    log.info "Error preparing network options: $exception"
    network_options = "<option value=\"example\">Custom Network</option>"
  
  // Precompute the full form HTML
  portal_html := ""
  exception = catch:
    // Substitute the network options into the portal HTML
    substitutions := {
      "network-options": network_options,
      "status-message": status_message != "" ? "<div class=\"msg\">$status_message</div>" : ""
    }
    portal_html = INDEX.substitute: substitutions[it]
  
  if exception:
    log.info "Error preparing portal HTML: $exception"
    portal_html = "<html><body><h1>WiFi Setup</h1><p>Error loading form. Please try again.</p></body></html>"
  
  log.info "Portal page precomputed and ready"
  
  result/Map? := null
  try:
    server.listen socket:: | request writer |
      log.info "Connection received"
      
      // Detect path and check if it's an iOS detection request
      path := request.path
      is_ios_detection := false
      user_agent := ""
      
      catch:
        values := request.headers.get "User-Agent"
        if values and values.size > 0:
          user_agent = values[0]
          if user_agent.contains "CaptiveNetworkSupport":
            is_ios_detection = true
      
      log.info "Request path: $path (iOS detection: $is_ios_detection)"
      
      // Set flags for response type
      should_send_ios_response := false
      should_send_form := false
      should_send_success := false
      
      // Process form submission if present
      query := url.QueryString.parse path
      ssid := ""
      password := ""
      
      if is_ios_detection or IOS_DETECTION_PATHS.contains path:
        // This is an iOS captive portal detection request
        should_send_ios_response = true
      else if path == "/portal.html":
        // This is a request for the full portal after iOS detection
        should_send_form = true
      else if not query.parameters.is_empty:
        // This is a form submission
        log.info "Form submission detected"
        
        // Get SSID from network parameter or ssid parameter
        wifi_network := query.parameters.get "network" --if_absent=: null
        if wifi_network and wifi_network != "custom":
          ssid = wifi_network.trim
        else:
          ssid_param := query.parameters.get "ssid" --if_absent=: null
          if ssid_param: ssid = ssid_param.trim
        
        log.info "SSID from form: '$ssid'"
        
        if ssid != "":
          // Set password based on security type
          security := query.parameters.get "security_type" --if_absent=: "password"
          
          // Only get password if the network is not open
          if security != "open":
            pwd := query.parameters.get "password" --if_absent=: null
            if pwd: password = pwd.trim
          
          // Set the response flag and credentials
          should_send_success = true
          result = { "ssid": ssid, "password": password }
        else:
          // No valid SSID, show form again
          should_send_form = true
      else:
        // Regular request, show the form
        should_send_form = true
      
      // Now send the appropriate response based on the flags
      if should_send_ios_response:
        log.info "Sending minimal iOS response"
        writer.headers.set "Content-Type" "text/html"
        writer.headers.set "Connection" "close"
        writer.write IOS_CAPTIVE_RESPONSE
      else if should_send_success:
        log.info "Sending success page for network: $ssid"
        writer.headers.set "Content-Type" "text/html"
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
        // Close the socket if we have credentials
        if result: socket.close
      else if should_send_form:
        log.info "Sending full portal page"
        writer.headers.set "Content-Type" "text/html"
        writer.headers.set "Cache-Control" "no-store, no-cache, must-revalidate, max-age=0"
        writer.headers.set "Pragma" "no-cache"
        writer.write portal_html
  finally:
    if result: return result
    socket.close
  unreachable

handle_http_request request/http.Request writer/http.ResponseWriter access_points/List status_message/string="" precomputed_portal/string="?" -> Map?:
  query := url.QueryString.parse request.path
  resource := query.resource
  
  // Add detailed logging for request debugging
  direct_log "Processing request: $resource (query size: $(query.parameters.size))"
  
  // Safely check for iOS user agents
  is_ios := false
  ua := ""
  catch:
    values := request.headers.get "User-Agent"
    if values and values.size > 0:
      ua = values[0]
      is_ios = ua.contains "iPhone" or ua.contains "iPad" or ua.contains "CaptiveNetworkSupport"
      direct_log "User-Agent: $ua"
  
  if resource == "/": resource = "index.html"
  if resource == "/hotspot-detect.html" or
     resource == "/generate_204" or 
     resource == "/gen_204" or
     resource == "/mobile/status.php" or  // Added for better iOS detection
     resource == "/library/test/success.html":  // Added for better iOS detection
    resource = "index.html"
  
  if resource.starts_with "/": resource = resource[1..]

  // Using a simpler approach now - no special loading page
  // Just go straight to the portal for all requests

  TEMPORARY_REDIRECTS.get resource --if_present=:
    direct_log "Redirecting to: $it"
    writer.headers.set "Location" it
    writer.write_headers 302
    return null

  if resource != "index.html":
    direct_log "Resource not found: $resource"
    writer.headers.set "Content-Type" "text/plain"
    writer.write_headers 404
    writer.write "Not found: $resource"
    return null

  // Check if this is a form submission with credentials
  wifi_credentials := null
  if not query.parameters.is_empty:
    direct_log "Form submission detected"
    // Get SSID from network parameter or ssid parameter
    ssid := ""
    network := query.parameters.get "network" --if_absent=: null
    if network and network != "custom":
      ssid = network.trim
    else:
      ssid_param := query.parameters.get "ssid" --if_absent=: null
      if ssid_param: ssid = ssid_param.trim
    
    direct_log "SSID from form: '$ssid'"
    
    if ssid != "":
      // Set password based on security type
      password := ""
      security := query.parameters.get "security_type" --if_absent=: "password"
      
      // Only get password if the network is not open
      if security != "open":
        pwd := query.parameters.get "password" --if_absent=: null
        if pwd: password = pwd.trim
      
      wifi_credentials = { "ssid": ssid, "password": password }
      
      // Write minimal success page
      direct_log "Sending success page for network: $ssid"
      writer.headers.set "Content-Type" "text/html"
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
      direct_log "Success page sent, returning credentials"
      return wifi_credentials

  // Use the precomputed portal page if available, otherwise build it
  if precomputed_portal != "?":
    direct_log "Using precomputed portal page"
    writer.headers.set "Content-Type" "text/html"
    // Set cache-control headers to prevent caching
    writer.headers.set "Cache-Control" "no-store, no-cache, must-revalidate, max-age=0"
    writer.headers.set "Pragma" "no-cache"
    writer.write precomputed_portal
    direct_log "Portal page sent"
    return null
  
  // Create simplified network options for faster loading
  direct_log "Building portal page with $(access_points.size) networks"
  network_options := access_points.map: | ap |
    str := "Good"
    if ap.rssi > -60: str = "Strong"
    else if ap.rssi < -75: str = "Weak"
    "<option value=\"$(ap.ssid)\">$(ap.ssid) ($str)</option>"
  network_options_string := network_options.join "\n"
  
  // Create status message HTML if there is a message, but keep it minimal
  status_html := ""
  if status_message != "":
    status_html = "<div class=\"msg\">$status_message</div>"

  direct_log "Rendering portal form"
  substitutions := {
    "network-options": network_options_string,
    "status-message": status_html
  }
  writer.headers.set "Content-Type" "text/html"
  // Set cache-control headers to prevent caching
  writer.headers.set "Cache-Control" "no-store, no-cache, must-revalidate, max-age=0"
  writer.headers.set "Pragma" "no-cache"
  writer.write (INDEX.substitute: substitutions[it])
  direct_log "Portal page sent"

  return null
