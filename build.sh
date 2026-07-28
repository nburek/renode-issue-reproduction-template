#!/usr/bin/env bash
set -x
set -e

# The pre-built ELF is already checked into artifacts/.
# In a real workflow this would cross-compile the firmware.
echo "Firmware ELF already present in artifacts/"
ls -la artifacts/basic_peripheral_test.elf
