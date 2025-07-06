#!/bin/bash

echo "Starting simple continuous writer."

# Define paths for log files within the mounted volume
VOLUME_PATH="/app/client_files" # This should match your volumeMount in worker.pod.yaml

# POD_NAME and NAMESPACE_NAME will be injected via Downward API in the Pod spec.
# Provide defaults for local testing if running without Kubernetes.
POD_NAME_VAR="${POD_NAME:-unknown-pod}"
NAMESPACE_NAME_VAR="${NAMESPACE_NAME:-unknown-namespace}"

LOG_FILE="${VOLUME_PATH}/${POD_NAME_VAR}_${NAMESPACE_NAME_VAR}_data.log"
ERROR_FILE="${VOLUME_PATH}/${POD_NAME_VAR}_${NAMESPACE_NAME_VAR}_errors.log"

echo "Writer: Log file will be: $LOG_FILE"
echo "Writer: Error log will be: $ERROR_FILE"

COUNTER=0
while true; do
  # Attempt to write data to the log file on the mounted volume
  if echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Pod ${POD_NAME_VAR} in ${NAMESPACE_NAME_VAR} writing data. Loop count: $COUNTER" >> "$LOG_FILE"; then
    # Keep log file size manageable (last 1000 lines)
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true # Suppress errors if mv fails due to unmount
  else
    echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Error writing to $LOG_FILE. Volume likely unmounted or inaccessible." >> "$ERROR_FILE"
  fi
  sleep 0.01 # Write every 10 milliseconds for high activity
  COUNTER=$((COUNTER + 1))
done
