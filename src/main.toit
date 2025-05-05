// Copyright (C) 2023 Kasper Lund.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import esp32
import log
import net
import net.wifi
import ntp
import system.storage

import .mode as mode

RETRIES ::= mode.DEVELOPMENT ? 2 : 3
PERIOD  ::= mode.DEVELOPMENT ? (Duration --s=5) : (Duration --s=10)

main:
  // First check if we're actually supposed to be running
  // (This prevents the app from running when the setup container should run)
  log.info "*** CHECKING IF THIS CONTAINER SHOULD RUN ***"
  if not mode.RUNNING:
    log.info "*** NOT IN RUNNING MODE - EXITING APP CONTAINER ***"
    return

  // First, check if we have saved credentials and need to configure WiFi
  log.info "*** APPLICATION CONTAINER STARTING ***"
  
  // Try to read credentials from storage
  log.info "*** CHECKING FOR SAVED WIFI CREDENTIALS ***"
  
  bucket := null
  ssid := null
  password := null
  
  // First check if we have credentials
  storage_error := catch:
    bucket = storage.Bucket.open --flash "github.com/kasperl/toit-zygote-wifi"
    ssid = bucket.get "ssid" --if_absent=: null
    password = bucket.get "password" --if_absent=: null
  
  if storage_error:
    log.error "*** ERROR ACCESSING STORAGE: $storage_error ***"
  
  // If we don't have credentials, continue normally
  if not ssid or not password:
    log.info "*** NO CREDENTIALS FOUND IN STORAGE ***"
  else:
    // We have credentials, try to configure WiFi
    log.info "*** CREDENTIALS FOUND IN STORAGE - SSID: $ssid ***"
    
    wifi_error := catch:
      // Open WiFi with credentials and --save flag to persist to flash memory
      log.info "*** OPENING WIFI WITH SAVED CREDENTIALS ***"
      network_sta := wifi.open
          --save
          --ssid=ssid
          --password=password
      
      // Wait to ensure credentials are saved to flash
      log.info "*** WAITING 5 SECONDS FOR WIFI CONNECTION ***"
      sleep --ms=5000
      
      // Close connection properly
      network_sta.close
      log.info "*** SAVED WIFI CREDENTIALS TO SYSTEM ***"
      
      // Try to clear our bucket to avoid reconfiguring next time
      log.info "*** CLEARING CUSTOM STORAGE BUCKET ***"
      bucket.remove "ssid"
      bucket.remove "password"
    
    if wifi_error:
      log.error "*** ERROR CONFIGURING WIFI: $wifi_error ***"
  
  // Now continue with normal WiFi connection attempts
  retries := 0
  while ++retries < RETRIES:
    network/net.Interface? := null
    exception := catch:
      log.info "*** ATTEMPTING NORMAL WIFI CONNECTION ***"
      network = net.open
      run network
      retries = 0
    if exception:
      log.warn "WiFi connection attempt failed" --tags={
        "attempt": retries,
        "error": exception.to_string
      }
    if network: network.close
    sleep PERIOD

  // We keep failing to connect or run the app. We assume
  // that this is because we've got the wrong WiFi credentials
  // so we enter the setup mode.
  log.info "All connection attempts failed, entering setup mode"
  mode.run_setup

run network/net.Interface:
  tags/Map? := null
  if mode.DEVELOPMENT: tags = {"mode": "development"}

  while true:
    log.info "running" --tags=tags
    result := ntp.synchronize --network=network
    if result:
      log.info "contacted ntp server" --tags={
        "adjustment" : result.adjustment,
        "accuracy"   : result.accuracy,
      }
    sleep PERIOD
