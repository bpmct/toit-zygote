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
// This is the response iOS expects for captive portal detection
// Multiple format options provided - we'll use the simpler one that works
// Important: The word "Success" must be present for iOS to recognize it
IOS_SUCCESS_RESPONSE ::= """HTTP/1.1 200 OK
Content-Type: text/html
Cache-Control: no-store
Connection: close
Content-Length: 66

<html><head><title>Success</title></head><body>Success</body></html>
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
  
  try:
    // Standard UDP DNS server
    hosts := dns.SimpleDnsServer device_ip_address  // Answer the device IP to all queries
    
    // Main DNS request processing loop
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      
      // Fetch the sender info
      sender_address := datagram.address
      sender_ip := sender_address.ip.stringify
      sender_port := sender_address.port
      
      log.info "DNS query from $sender_ip:$sender_port - answering with: $device_ip_address"
      
      // Extract query name for debugging
      query_name := "<unknown>"
      query_name_exception := catch:
        if datagram.data.size > 12:  // DNS header is 12 bytes
          // Skip header, count bytes for the name
          pos := 12
          while pos < datagram.data.size and datagram.data[pos] != 0:
            pos++
          if pos > 12:
            query_name = extract_dns_name datagram.data 12
      
      log.info "DNS query for domain: $query_name"
      
      // Look up the response
      response := hosts.lookup datagram.data
      if not response: continue
      
      // Send the response
      socket.send (udp.Datagram response datagram.address)
  finally:
    log.info "DNS server closing"
    socket.close

// Helper to extract domain name from DNS query
extract_dns_name data/ByteArray offset/int -> string:
  result := ""
  pos := offset
  while pos < data.size:
    length := data[pos]
    if length == 0: break  // End of domain name
    if length >= 192: break  // Compressed pointer, not handling here
    
    pos++
    if pos + length > data.size: break
    
    if result != "": result += "."
    length.repeat:
      if pos < data.size:
        // Add the character by its ASCII value
        result += (data[pos]).stringify
        pos++
  
  return result

// Unified HTTP handler for cross-platform compatibility
direct_http_respond socket/tcp.ServerSocket access_points/List -> Map?:
  log.info "Starting unified captive portal handler"
  
  // This is the exact iOS success response content that's known to work
  IOS_SUCCESS_BYTES := IOS_SUCCESS_RESPONSE.to_byte_array
   
  while true:
    log.debug "Waiting for connection..."
    client := socket.accept
    
    if client:
      log.info "Client connection established"
      
      // Get client info for better debugging
      client_ip := "<unknown>"
      client_port := 0
      
      client_info_exception := catch:
        client_ip = client.peer_address.ip.stringify
        client_port = client.peer_address.port
        log.info "Connection from $client_ip:$client_port"
      
      if client_info_exception:
        log.warn "Could not get client info: $client_info_exception"
      
      // We need to make sure to *either* send iOS success OR main page, not both
      // Read the request to determine what kind of request it is
      
      // Read a bit of the request to check if it's an iOS detection
      request_bytes := ByteArray 1024  // Larger buffer to capture more of the request
      bytes_read := 0
      read_exception := null
      
      read_exception = catch:
        in := client.in
        if in:
          bytes := in.read --max-size=1024
          if bytes:
            bytes_read = bytes.size
            bytes.size.repeat: | i |
              request_bytes[i] = bytes[i]
      
      if read_exception:
        log.warn "Error reading request: $read_exception"
      
      // Convert to string if we read something
      request_str := ""
      if bytes_read > 0:
        str_exception := catch:
          request_str = request_bytes[..bytes_read].to_string
          
        if str_exception:
          log.warn "Error converting request to string: $str_exception"
      
      // Log the request for debugging
      if request_str and request_str.size > 0:
        log_length := request_str.size > 100 ? 100 : request_str.size
        log.info "Request from $client_ip: $(request_str[..log_length])"
        
        // Look for Host header to identify the domain being requested
        host_idx := request_str.index_of "Host: "
        if host_idx >= 0:
          host_end := request_str.index_of "\r\n" host_idx
          if host_end > host_idx:
            host := request_str[host_idx + 6..host_end]
            log.info "Host header: $host"
      
      // Enhanced request classification - add the User-Agent for better debugging
      is_ios_detection := request_str.contains "hotspot-detect" or 
                          request_str.contains "success.html" or
                          request_str.contains "captive.apple.com" or
                          request_str.contains "CaptiveNetworkSupport"
      
      // Check for iOS user agent
      is_ios_device := request_str.contains "iPhone" or
                       request_str.contains "iPad" or
                       request_str.contains "Darwin" or
                       request_str.contains "CFNetwork"
                       
      is_form_submit := request_str.contains "POST" and request_str.contains "ssid="
      
      is_direct_page := request_str.contains "GET / " or
                        request_str.contains "GET /index.html"
      
      // Also check for Android connection test URLs
      is_android_detection := request_str.contains "generate_204" or
                              request_str.contains "connectivitycheck" or
                              request_str.contains "redirect"
      
      // Log the detection for detailed debugging
      log.info "Request analysis: iOS detection=$is_ios_detection, iOS device=$is_ios_device, Android=$is_android_detection, Form=$is_form_submit, Direct=$is_direct_page"
      
      if is_ios_detection or (is_ios_device and not is_direct_page and not is_form_submit):
        // For iOS detection requests, send the iOS success response
        log.info "iOS detection request - sending iOS success response"
        ios_exception := catch:
          client.out.write IOS_SUCCESS_BYTES
          log.info "iOS success response sent successfully"
        
        if ios_exception:
          log.warn "Error sending iOS response: $ios_exception"
      
      else if is_form_submit:
        // Handle form submission
        log.info "Form submission - processing credentials"
        credentials := parse_form_submission request_str
        if credentials and credentials.get "ssid" --if_absent=(: null):
          log.info "Valid credentials received"
          close_exception := catch:
            client.close
          
          if close_exception:
            log.warn "Error closing socket after credentials: $close_exception"
          
          return credentials
        else:
          // Invalid form submission - show setup page
          log.info "Invalid form submission - showing setup page"
          form_page_exception := catch:
            serve_main_page client access_points
          
          if form_page_exception:
            log.warn "Error serving page after invalid form: $form_page_exception"
      
      else:
        // For all other requests (including Android and direct page), serve the main setup page
        log.info "Regular/Android request - serving main page"
        main_page_exception := catch:
          serve_main_page client access_points
        
        if main_page_exception:
          log.warn "Error serving main page: $main_page_exception"
      
      // Long delay to ensure connection stability - especially important for iOS
      sleep --ms=1500
      
      close_exception := catch:
        client.close
        log.info "Connection closed successfully after response"
      
      if close_exception:
        log.warn "Error closing socket: $close_exception"
      
      // Additional sleep after closing to prevent immediate reconnection issues
      sleep --ms=300
    
    else:
      sleep --ms=10

// Helper to serve the main page
serve_main_page client/tcp.Socket access_points/List -> none:
  // Create network options HTML
  network_options := []
  
  options_exception := catch:
    network_options = access_points.map: | ap |
      signal_str := ap.rssi > -60 ? "Strong" : (ap.rssi < -75 ? "Weak" : "Good")
      "<option value=\"$(ap.ssid)\">$(ap.ssid) ($signal_str)</option>"
  
  if options_exception:
    log.warn "Error creating network options: $options_exception"
    network_options = ["<option value=\"custom\">Custom network...</option>"]
  
  // Substitute network options into the template
  content := ""
  template_exception := catch:
    content = INDEX.substitute: { "network-options": network_options.join "\n" }
  
  if template_exception:
    log.warn "Error substituting template: $template_exception"
    content = "<html><body><h1>WiFi Setup</h1><p>Please enter your WiFi details:</p><form method='POST'><input name='ssid'><input name='password' type='password'><input type='submit'></form></body></html>"
  
  // Create HTTP response with the content
  headers := """HTTP/1.1 200 OK
Content-Type: text/html
Cache-Control: no-cache, no-store, must-revalidate
Pragma: no-cache
Expires: 0
Connection: close
Content-Length: $(content.size)

"""
  
  // Send headers and content
  serve_exception := catch:
    client.out.write headers.to_byte_array
    client.out.write content.to_byte_array
    log.info "Main page served successfully"
  
  if serve_exception:
    log.warn "Error sending main page: $serve_exception"

// Helper to parse form submissions with improved error handling
parse_form_submission request_str/string -> Map?:
  result := null
  
  parse_exception := catch:
    // Check if we have form data - look for the standard delimiter first
    form_data_start := request_str.index_of "\r\n\r\n"
    if form_data_start < 0: 
      // If we can't find the header delimiter, try looking directly for form data
      form_data_start = request_str.index_of "ssid="
      if form_data_start < 0:
        form_data_start = request_str.index_of "network="
        if form_data_start < 0:
          log.warn "No form data found in request"
          return null
    else:
      form_data_start += 4  // Skip the \r\n\r\n
    
    // Extract the form data
    form_data := request_str[form_data_start..]
    
    // Log what we found for debugging
    log.info "Form data (first 30 chars): $(form_data.size > 30 ? form_data[..30] + "..." : form_data)"
    
    // Extract parameters
    params := {:}
    
    // First try to split by & for normal form encoding
    pairs := form_data.split "&"
    pairs.do: | pair |
      key_value := pair.split "="
      if key_value.size == 2:
        key := key_value[0]
        value := key_value[1]
        // Simple URL decoding
        value = decode_url_component value
        params[key] = value
    
    // Log the parameters
    log.info "Found $(params.size) parameters in form submission"
    
    // Extract SSID (either from network dropdown or direct input)
    ssid := ""
    
    // Get SSID from network dropdown if present
    network := params.get "network" --if_absent=(: null)
    if network and network != "custom":
      ssid = network
      log.info "Using network selection: $ssid"
    else:
      // Otherwise get from ssid field
      ssid_param := params.get "ssid" --if_absent=(: null)
      if ssid_param: 
        ssid = ssid_param
        log.info "Using SSID from form: $ssid"
    
    // Get password
    password := params.get "password" --if_absent=(: "")
    
    // Truncate password for logging (show first 3 chars if any)
    log_password := password.size > 0 ? password[..min 3 password.size] + "..." : "<empty>"
    log.info "Password: $log_password"
    
    // Set credentials if valid
    if ssid and ssid != "": 
      log.info "Valid credentials found: SSID=$ssid"
      result = { "ssid": ssid, "password": password }
    else:
      log.warn "Missing or invalid SSID"
  
  if parse_exception:
    log.warn "Error parsing form submission: $parse_exception"
  
  return result

// Custom URL decoder function for form parameters
decode_url_component str/string -> string:
  // Simple URL decoding - just handle + for now
  return str.replace "+" " "

run_http network/net.Interface access_points/List -> Map:
  log.info "Starting captive portal web server"
  socket := network.tcp_listen 80
  result := direct_http_respond socket access_points
  socket.close
  if result: return result
  unreachable