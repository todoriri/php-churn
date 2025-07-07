#!/bin/bash

echo "Starting simple continuous writer and reader."

VOLUME_PATH="/app/client_files"

POD_NAME_VAR="${POD_NAME:-unknown-pod}"
NAMESPACE_NAME_VAR="${NAMESPACE_NAME:-unknown-namespace}"

LOG_FILE="${VOLUME_PATH}/${POD_NAME_VAR}_${NAMESPACE_NAME_VAR}_data.log"
ERROR_FILE="${VOLUME_PATH}/${POD_NAME_VAR}_${NAMESPACE_NAME_VAR}_errors.log"

echo "Writer/Reader: Log file will be: $LOG_FILE"
echo "Writer/Reader: Error log will be: $ERROR_FILE"

touch "$LOG_FILE"

COUNTER=0
while true; do
  # --- WRITE OPERATION ---
  if echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Pod ${POD_NAME_VAR} in ${NAMESPACE_NAME_VAR} writing data. Loop count: $COUNTER" >> "$LOG_FILE"; then
    # Keep log file size manageable (last 1000 lines)
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
  else
    echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Error writing to $LOG_FILE. Volume likely unmounted or inaccessible." >> "$ERROR_FILE"
  fi


  if cat "$LOG_FILE" > /dev/null; then
    : # do nothing, read successful
  else
    echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Error reading from $LOG_FILE. Volume likely unmounted or inaccessible." >> "$ERROR_FILE"
  fi

  # sleep to control I/O rate
  sleep 0.01
  COUNTER=$((COUNTER + 1))
done
