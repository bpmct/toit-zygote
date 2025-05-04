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

TEMPORARY_REDIRECTS ::= {
  "generate_204": "/",    // Used by Android captive portal detection.
  "gen_204": "/",         // Used by Android captive portal detection.
}

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
  result/Map? := null
  try:
    server.listen socket:: | request writer |
      result = handle_http_request request writer access_points status_message
      if result: socket.close
  finally:
    if result: return result
    socket.close
  unreachable

handle_http_request request/http.Request writer/http.ResponseWriter access_points/List status_message/string="" -> Map?:
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

  // Create network options for the dropdown
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

  substitutions := {
    "network-options": network_options_string,
    "status-message": status_html
  }
  writer.headers.set "Content-Type" "text/html"
  writer.write (INDEX.substitute: substitutions[it])

  if query.parameters.is_empty: return null
  
  // Get SSID from network parameter or ssid parameter
  ssid := ""
  network := query.parameters.get "network" --if_absent=: null
  if network and network != "custom":
    ssid = network.trim
  else:
    ssid_param := query.parameters.get "ssid" --if_absent=: null
    if ssid_param: ssid = ssid_param.trim
  
  if ssid == "": return null
  
  // Set password based on security type
  password := ""
  security := query.parameters.get "security_type" --if_absent=: "password"
  
  // Only get password if the network is not open
  if security != "open":
    pwd := query.parameters.get "password" --if_absent=: null
    if pwd: password = pwd.trim
  
  return { "ssid": ssid, "password": password }
