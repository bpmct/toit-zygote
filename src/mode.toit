// Copyright (C) 2023 Kasper Lund.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import esp32
import log
import system.storage
import system.containers

DEVELOPMENT/bool ::= containers.images.any: it.name == "jaguar"
RUNNING/bool ::= (ZYGOTE_STORE_.get ZYGOTE_STATE_KEY_) != ZYGOTE_STATE_SETUP_

run_application -> none:
  log.info "Removing setup flag from storage"
  ZYGOTE_STORE_.remove ZYGOTE_STATE_KEY_
  log.info "Triggering reboot via deep sleep"
  // Adding a longer sleep to ensure it can complete operations
  esp32.deep_sleep (Duration --ms=100)

run_setup -> none:
  log.info "Setting setup flag in storage"
  ZYGOTE_STORE_[ZYGOTE_STATE_KEY_] = ZYGOTE_STATE_SETUP_
  log.info "Triggering reboot via deep sleep"
  // Adding a longer sleep to ensure it can complete operations
  esp32.deep_sleep (Duration --ms=100)

ZYGOTE_STORE_       ::= storage.Bucket.open --flash "github.com/kasperl/toit-zygote"
ZYGOTE_STATE_KEY_   ::= "state"
ZYGOTE_STATE_SETUP_ ::= "setup"
