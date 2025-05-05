# ESP32 WiFi Setup with Captive Portal in Toit

This document explains how to implement a reliable WiFi setup flow with a captive portal for ESP32 devices using the Toit programming language.

## Overview

This implementation provides a complete solution for configuring WiFi on ESP32 devices:

1. When a device can't connect to WiFi, it starts in setup mode
2. Setup mode creates a WiFi access point (AP) named "mywifi"
3. A captive portal is presented to users who connect to this AP
4. When users submit WiFi credentials, they're saved and the device restarts
5. The device then connects to the configured WiFi network

## Key Components

The implementation consists of two main containers:

1. **Setup Container** (src/setup.toit):
   - Creates WiFi AP
   - Runs DNS server to redirect all domains
   - Runs HTTP server with captive portal detection
   - Displays a setup form to collect WiFi credentials
   - Saves credentials and triggers restart

2. **Application Container** (src/main.toit):
   - Checks for saved credentials on boot
   - Configures WiFi with saved credentials (when available)
   - Runs the main application logic when connected
   - Falls back to setup mode if connection fails

## Technical Challenges & Solutions

### Challenge 1: Cross-Platform Captive Portal Detection

Different operating systems detect captive portals differently:

| Platform | Detection Method |
|----------|-----------------|
| iOS | Requests `/hotspot-detect.html` or `/library/test/success.html` |
| Android | Requests various URLs from domain `connectivitycheck.gstatic.com` |
| Windows | Issues HTTP requests to `www.msftconnecttest.com` |

**Solution:**
- DNS server redirects all domain queries to the ESP32's IP address
- HTTP server detects special captive portal detection URLs
- Returns specific responses for iOS and other platforms
- Uses a meta-refresh tag to redirect to the portal page

```toit
// Ultra-minimal response for iOS captive portal detection
// With meta refresh to automatically redirect to the portal
IOS_RESPONSE ::= """
<html><head><meta http-equiv="refresh" content="0;url=/portal.html" /><title>Success</title></head><body>Success</body></html>
"""
```

### Challenge 2: Socket Operations Hanging

A critical issue was the HTTP server hanging when trying to close sockets after form submission.

**Solutions Explored:**
1. Directly connecting to WiFi from the HTTP handler (failed due to "WiFi already established in AP mode")
2. Using a background task to close sockets (worked partially but had timing issues)
3. Using a global variable to communicate between tasks (complicated and unreliable)

**Final Solution:**
- Store credentials directly in persistent flash storage (Bucket)
- Call `mode.run_application()` to exit setup mode
- Let the application container read credentials on next boot

```toit
// Save WiFi credentials to flash storage
bucket := storage.Bucket.open --flash "github.com/kasperl/toit-zygote-wifi"
bucket["ssid"] = ssid
bucket["password"] = password

// Exit directly to application mode
mode.run_application
```

### Challenge 3: Container Coordination

Ensuring the right container runs at the right time.

**Solution:**
- Use `mode.RUNNING` to determine which container should run
- `mode.run_application()` and `mode.run_setup()` for transitions
- Check in both containers if they should be running

```toit
// In main.toit
if not mode.RUNNING:
  log.info "*** NOT IN RUNNING MODE - EXITING APP CONTAINER ***"
  return

// In setup.toit
if mode.RUNNING:
  log.info "*** NOT IN SETUP MODE - EXITING SETUP CONTAINER ***"
  return
```

### Challenge 4: Ensuring Success Page Display

The success page wasn't consistently showing before the device restarted.

**Solution:**
- Add sufficient delays to ensure the page is fully sent
- Use JavaScript to update the page even after device disconnects
- Improved styling and better status messages

```toit
// Give time for the success page to be fully sent
log.info ">>> WAITING TO ENSURE SUCCESS PAGE IS DISPLAYED"
sleep --ms=1500  // Longer wait for success page

// Additional delay after saving
log.info ">>> SAVING COMPLETE - WAITING 2 SECONDS BEFORE EXITING SETUP"
sleep --ms=2000  // Additional delay to ensure page rendering
```

## Implementation Details

### 1. DNS Server

A simple DNS server that responds to all queries with the ESP32's IP address:

```toit
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
```

### 2. HTTP Server

Handles captive portal detection and serves the setup form:

```toit
run_http network_interface/net.Interface access_points/List status_message/string="" -> Map:
  // ... HTTP server setup ...

  // Handle iOS captive portal detection
  if path == "/hotspot-detect.html" or path == "/library/test/success.html":
    writer.headers.set "Content-Type" "text/html"
    writer.headers.set "Connection" "close"
    writer.write IOS_RESPONSE
  
  // Handle the portal page request
  else if path == "/portal.html":
    writer.headers.set "Content-Type" "text/html"
    writer.headers.set "Cache-Control" "no-store, no-cache"
    writer.write portal_html
```

### 3. Form Submission Handling

Processes form submissions and saves credentials:

```toit
// Handle form submission
else if path.contains "?":
  // Parse query parameters
  query := url.QueryString.parse path
  
  // Extract SSID and password
  ssid := ""
  wifi_network := query.parameters.get "network" --if_absent=: null
  if wifi_network and wifi_network != "custom":
    ssid = wifi_network.trim
  else:
    ssid_param := query.parameters.get "ssid" --if_absent=: null
    if ssid_param: ssid = ssid_param.trim
  
  password := query.parameters.get "password" --if_absent=: ""
  
  // Save credentials to storage
  bucket := storage.Bucket.open --flash "github.com/kasperl/toit-zygote-wifi"
  bucket["ssid"] = ssid
  bucket["password"] = password
  
  // Exit setup mode
  mode.run_application
```

### 4. Application Container Flow

On boot, the application container checks for saved credentials:

```toit
// Check if we have saved credentials
bucket := storage.Bucket.open --flash "github.com/kasperl/toit-zygote-wifi"
ssid := bucket.get "ssid" --if_absent=: null
password := bucket.get "password" --if_absent=: null

if ssid and password:
  // Configure WiFi with saved credentials
  network_sta := wifi.open
      --save
      --ssid=ssid
      --password=password
      
  // Clean up storage after successful configuration
  bucket.remove "ssid"
  bucket.remove "password"
```

## Best Practices

1. **Error Handling**:
   - Use `catch` blocks for all network operations
   - Log errors with detailed messages
   - Provide fallback mechanisms when operations fail

2. **Logging**:
   - Include clear, distinctive log messages
   - Tag critical points in execution
   - Use visual separators (like `***`) for important logs

3. **User Experience**:
   - Provide clear feedback in the UI
   - Show loading indicators for long operations
   - Make success/failure states obvious

4. **Resource Management**:
   - Always close sockets and network interfaces
   - Use `try`/`finally` blocks to ensure cleanup
   - Avoid resource leaks in error cases

5. **Container Coordination**:
   - Clear separation between setup and application modes
   - Explicit transitions between modes
   - Check mode before executing container-specific code

## Common Issues

1. **"WiFi already established"** errors:
   - Can't have AP and STA modes active simultaneously
   - Must close AP before opening STA
   - Use mode switching to reset WiFi state

2. **Socket hanging**:
   - Socket operations can block indefinitely
   - Use timeouts for all operations
   - Consider alternative communication methods

3. **Captive portal not detected**:
   - Different platforms have different detection mechanisms
   - iOS is particularly strict about response formats
   - Test on multiple devices and platforms

4. **Form submission issues**:
   - HTTP response must complete before closing connection
   - Use proper content length headers
   - Add delays to ensure response completes

## Debugging Techniques

1. **Verbose Logging**:
   - Add detailed log messages at key points
   - Use unique prefixes for easier filtering
   - Log all errors with context

2. **State Tracking**:
   - Log state transitions explicitly
   - Track network interface states
   - Monitor credentials through the system

3. **Incremental Testing**:
   - Test individual components in isolation
   - Build up from simple cases to complex flows
   - Verify each step before proceeding

## Conclusion

Building a reliable WiFi setup flow for ESP32 devices requires careful attention to cross-platform compatibility, proper resource management, and robust error handling. The implementation provided in this project demonstrates a working solution that handles these challenges effectively.

The key to success is understanding the flow of execution across containers and ensuring proper coordination between setup and application modes. By following the patterns shown here, you can create a user-friendly and reliable WiFi configuration experience for your ESP32 devices.

## References

- [Toit Documentation](https://docs.toit.io/)
- [ESP32 WiFi Documentation](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/network/esp_wifi.html)
- [Captive Portal Detection](https://datatracker.ietf.org/doc/html/rfc7710)
- [GitHub Repository](https://github.com/kasperl/toit-zygote)