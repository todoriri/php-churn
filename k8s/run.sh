#!/bin/bash

set -x

NUM_BATCHES=10
NS_PER_BATCH=200
TOTAL_NS=$((NUM_BATCHES * NS_PER_BATCH))

WAIT_AFTER_CREATE_SEC=300 # Time to let pods stabilize and write before deletion
WAIT_AFTER_DELETE_SEC=30 # Time to allow CSI cleanup before next batch creation


CUSTOM_WORKER_IMAGE="quay.io/todor_nutanix/churn:churn-test"
echo "--- Using Public Image: ${CUSTOM_WORKER_IMAGE} ---"

TEMP_IMAGE_PUSH_PROJECT="image-push-temp-$RANDOM" # Using $RANDOM for uniqueness

trap 'find /tmp -maxdepth 1 -type d -name "kustomize-*" -print0 | xargs -0 rm -rf' EXIT

echo "--- Starting High-Churn NFS Volume Lifecycle Test (Image-based Workload) ---"
echo "Total namespaces to process: 100 (in $NUM_BATCHES batches of $NS_PER_BATCH)"

# Pre-flight checks for necessary commands
if ! command -v oc &> /dev/null
then
echo "Error: 'oc' command not found. Please ensure OpenShift CLI (oc) is installed and configured."
exit 1
fi

if ! command -v podman &> /dev/null
then
echo "Error: 'podman' command not found. Please ensure Podman is installed."
exit 1
fi

if ! command -v envsubst &> /dev/null
then
echo "Error: envsubst command not found. Please install gettext (e.g., 'sudo apt install gettext')."
exit 1
fi

# wait for a project to become available
wait_for_project() {
local project_name=$1
local max_retries=10
local sleep_sec=5
echo "Waiting for project '$project_name' to become ready..."
for (( i=1; i<=$max_retries; i++ )); do
if oc get project "$project_name" >/dev/null 2>&1; then
echo "Project '$project_name' is ready."
return 0 # Success
else
echo "Project '$project_name' not found (attempt $i/$max_retries). Sleeping $sleep_sec seconds..."
sleep "$sleep_sec"
fi
done
echo "Error: Project '$project_name' did not become ready after $max_retries attempts."
return 1 # Failure
}



# Apply Workload Manifests using Kustomize 
# =========================================================
echo "--- Phase 2: Applying Workload Manifests using Kustomize ---"

# This function will now handle building and applying the Kustomize overlay
apply_kustomize_workload() {
local ns_name=$1
local pod_suffix=$2
local worker_image=$3 # This is CUSTOM_WORKER_IMAGE from Phase 1

# Create a temporary directory for overlay
local TEMP_OVERLAY_DIR=$(mktemp -d -t kustomize-XXXXXXXXXX)

# Copy kustomize_base files into temp
cp kustomize_base/pvc.yaml "$TEMP_OVERLAY_DIR/"
cp kustomize_base/worker.pod.yaml "$TEMP_OVERLAY_DIR/"
cp kustomize_base/kustomization.yaml "$TEMP_OVERLAY_DIR/"
cp kustomize_base/php-config.yaml "$TEMP_OVERLAY_DIR/"


# replace the ${WORKER_IMAGE} placeholder.
export WORKER_IMAGE="$worker_image" # Make it available for envsubst
cat "${TEMP_OVERLAY_DIR}/worker.pod.yaml" | envsubst '${WORKER_IMAGE}' > "${TEMP_OVERLAY_DIR}/worker.pod.yaml.tmp" && \
mv "${TEMP_OVERLAY_DIR}/worker.pod.yaml.tmp" "${TEMP_OVERLAY_DIR}/worker.pod.yaml"
unset WORKER_IMAGE # Unset to avoid interfering with next iterations
# --- MODIFICATION END ---


export NAMESPACE_NAME="$ns_name"
export POD_SUFFIX="$pod_suffix"
cat "${TEMP_OVERLAY_DIR}/kustomization.yaml" | envsubst '${NAMESPACE_NAME} ${POD_SUFFIX}' > "${TEMP_OVERLAY_DIR}/kustomization.yaml.tmp" && \
mv "${TEMP_OVERLAY_DIR}/kustomization.yaml.tmp" "${TEMP_OVERLAY_DIR}/kustomization.yaml"
unset NAMESPACE_NAME POD_SUFFIX # Unset after use in this function

echo " - Building and applying Kustomize manifests for namespace: $ns_name (Pod suffix: $pod_suffix)"

# build Kustomize manifest for specific instance 
echo "--- Generated Kustomize YAML for $ns_name ---"
GENERATED_KUSTOMIZE_YAML=$(oc kustomize "$TEMP_OVERLAY_DIR")
echo "$GENERATED_KUSTOMIZE_YAML" # This will print the full generated YAML to stdout
echo "-------------------------------------------"

# apply it
# This line will show the error if oc apply fails
if ! echo "$GENERATED_KUSTOMIZE_YAML" | oc apply -f -; then
echo "Error: Failed to apply Kustomize manifests for namespace '$ns_name'."
return 1 # Indicate failure
fi

return 0 # Indicate success
}


for batch_num in $(seq 1 $NUM_BATCHES); do
echo "--- Processing Batch $batch_num of $NUM_BATCHES ---"
declare -a current_namespaces

echo "Initiating namespace creations and workload applications..."
for i in $(seq 1 $NS_PER_BATCH); do
NS_INDEX=$(( (batch_num - 1) * NS_PER_BATCH + i ))
NS_NAME="churn-test-${NS_INDEX}"
POD_SUFFIX="${NS_INDEX}"
current_namespaces+=("$NS_NAME")

echo " - Creating namespace $NS_NAME (with retries)..."
NAMESPACE_CREATED=false
if oc new-project "$NS_NAME" >/dev/null 2>&1; then
echo " - Initiated creation of namespace '$NS_NAME'."
else
if oc get project "$NS_NAME" >/dev/null 2>&1; then
echo " - Namespace '$NS_NAME' already exists. Proceeding with wait."
else
echo " - Error: Failed to initiate creation of namespace '$NS_NAME'. Check permissions or quota. Skipping to next namespace."
continue
fi
fi

if wait_for_project "$NS_NAME"; then
NAMESPACE_CREATED=true
else
echo "Fatal Error: Namespace '$NS_NAME' did not become ready after creation attempt and retries. Skipping workload for this namespace."
continue # Skip to next namespace creation if wait fails
fi

# Now, call the Kustomize application function
if $NAMESPACE_CREATED; then # Only apply if namespace created/found
if ! apply_kustomize_workload "$NS_NAME" "$POD_SUFFIX" "$CUSTOM_WORKER_IMAGE"; then
echo "Warning: Workload application failed for $NS_NAME. This namespace might not have an active pod."
fi
fi
done

echo "Waiting $WAIT_AFTER_CREATE_SEC seconds for pods to become Running and generate writes..."
sleep $WAIT_AFTER_CREATE_SEC


# verifying PVCs and Pods are ready
echo "Verifying PVCs and Pods are ready for Batch $batch_num..."
for i in $(seq 1 $NS_PER_BATCH); do # Iterate using the inner loop counter
    # Calculate the correct NS_INDEX for this pod in this batch
    CURRENT_NS_INDEX=$(( (batch_num - 1) * NS_PER_BATCH + i ))
    NS_NAME="churn-test-${CURRENT_NS_INDEX}"
    POD_SUFFIX="${CURRENT_NS_INDEX}" # This is now consistent with NS_INDEX

    PVC_NAME="php-shared-${POD_SUFFIX}"
    POD_NAME="worker-${POD_SUFFIX}"

    PVC_READY=false
    POD_READY=false

    # Wait for PVC to be Bound
    for ((retry=0; retry<15; retry++)); do # Max 15 retries (15*5s = 75s)
        PVC_STATUS=$(oc get pvc -n "$NS_NAME" "$PVC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "$PVC_STATUS" == "Bound" ]]; then
            echo " - PVC '$PVC_NAME' in '$NS_NAME' is Bound."
            PVC_READY=true
            break
        elif [[ "$PVC_STATUS" == "NotFound" ]]; then
            echo " - PVC '$PVC_NAME' in '$NS_NAME' not found yet. Retrying... (attempt $((retry+1)))"
        else
            echo " - Waiting for PVC '$PVC_NAME' in '$NS_NAME' to be Bound (Current: $PVC_STATUS)... (attempt $((retry+1)))"
        fi
        sleep 5
    done
    if ! $PVC_READY; then
        echo "WARNING: PVC '$PVC_NAME' in '$NS_NAME' did not become Bound within expected time! Inspect it manually."
        oc get pvc -n "$NS_NAME" "$PVC_NAME"
        oc describe pvc -n "$NS_NAME" "$PVC_NAME"
        continue # Skip pod check if PVC is not ready
    fi

    # wait for pod to be Running if pvc is ready
    if $PVC_READY; then
        for ((retry=0; retry<15; retry++)); do # Max 15 retries
            POD_STATUS=$(oc get pod -n "$NS_NAME" "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
            if [[ "$POD_STATUS" == "Running" ]]; then
                echo " - Pod '$POD_NAME' in '$NS_NAME' is Running."
                POD_READY=true
                break
            elif [[ "$POD_STATUS" == "NotFound" ]]; then
                echo " - Pod '$POD_NAME' in '$NS_NAME' not found yet. Retrying... (attempt $((retry+1)))"
            else
                echo " - Waiting for Pod '$POD_NAME' in '$NS_NAME' to be Running (Current: $POD_STATUS)... (attempt $((retry+1)))"
            fi
            sleep 5
        done
        if ! $POD_READY; then
            echo "WARNING: Pod '$POD_NAME' in '$NS_NAME' not Running within expected time (Current: $POD_STATUS)! Inspect it manually."
            oc get pod -n "$NS_NAME" "$POD_NAME"
            oc describe pod -n "$NS_NAME" "$POD_NAME"
        fi
    fi
done

echo "--- Phase 3: Initiating Concurrent Deletion of Batch $batch_num ---"
# deletion commands in parallel
for ns in "${current_namespaces[@]}"; do
echo " - Deleting project $ns"
oc delete project "$ns" --grace-period=0 --force --wait=false &
done
wait # Wait for all `oc delete project` commands to be submitted

echo "Deletion commands initiated. Waiting $WAIT_AFTER_DELETE_SEC seconds for CSI driver cleanup and Ganesha activity..."
sleep $WAIT_AFTER_DELETE_SEC

# check for stuck resources after deletion
echo "Checking for stuck PVCs/PVs (status: Terminating)..."
oc get pvc -A --field-selector=status.phase=Terminating
oc get pv -A --field-selector=status.phase=Terminating

done

# Clean up the temporary image push project after all batches are done
echo "--- Cleaning up temporary image push project '$TEMP_IMAGE_PUSH_PROJECT' ---"
oc delete project "$TEMP_IMAGE_PUSH_PROJECT" --wait=false || true

echo "--- High-Churn Test Completed ---"
echo "Review logs from OpenShift CSI driver, Ganesha"
=============================== kustomize_base/kustomization.yaml ===============================
# kustomize_base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- pvc.yaml
- worker.pod.yaml
- php-config.yaml

namespace: ${NAMESPACE_NAME}
nameSuffix: "-${POD_SUFFIX}"

patches:
- target:
kind: Pod
name: worker
patch: |-
# This patch replaces the dummy command/args in worker.pod.yaml
# to run your entrypoint.sh script (where your main workload logic now resides).
- op: replace
path: /spec/containers/0/command
value:
- /bin/bash
- op: replace
path: /spec/containers/0/args
value:
- -c
- /usr/local/bin/entrypoint.sh
=============================== kustomize_base/worker.pod.yaml ===============================
# kustomize_base/worker.pod.yaml
apiVersion: v1
kind: Pod
metadata:
name: worker
namespace: some-placeholder-namespace # Kustomize will set this
spec:
affinity:
nodeAffinity:
requiredDuringSchedulingIgnoredDuringExecution:
nodeSelectorTerms:
- matchExpressions:
- key: nine-node-type
operator: In
values:
- customer
containers:
- name: php
command: ["/bin/bash", "-c"] # Dummy command, to be replaced by Kustomize patch
args: ["echo", "Initial args, will be replaced by Kustomize"] # Dummy args, to be replaced by Kustomize patch
env: null
image: ${WORKER_IMAGE}
imagePullPolicy: Always
livenessProbe:
exec:
command:
- /bin/bash
- -c
- ls /app/client_files && rm -f "/app/client_files/liveness_prob" && touch "/app/client_files/liveness_prob"
failureThreshold: 1
initialDelaySeconds: 20
periodSeconds: 30
successThreshold: 1
timeoutSeconds: 5
resources:
limits:
cpu: 600m
memory: 612Mi
requests:
cpu: 10m
memory: 612Mi
terminationMessagePath: /dev/termination-log
terminationMessagePolicy: File
volumeMounts:
- mountPath: /app/client_files
name: php-shared
- mountPath: /usr/local/etc/php/conf.d/default.ini
name: php-config
subPath: php_command.ini
- mountPath: /usr/local/etc/php-fpm.d/zz-docker.conf
name: php-config
subPath: php.fpf
- mountPath: /var/run/secrets/kubernetes.io/serviceaccount
name: kube-api-access-5k7wm
readOnly: true
dnsPolicy: ClusterFirst
enableServiceLinks: true
preemptionPolicy: PreemptLowerPriority
priority: 0
restartPolicy: Always
schedulerName: default-scheduler
securityContext: {}
serviceAccount: default
serviceAccountName: default
terminationGracePeriodSeconds: 30
tolerations:
- effect: NoExecute
key: node.kubernetes.io/not-ready
operator: Exists
tolerationSeconds: 300
- effect: NoExecute
key: node.kubernetes.io/unreachable
operator: Exists
tolerationSeconds: 300
- key: nine-node-type
value: customer
volumes:
- name: php-shared
persistentVolumeClaim:
claimName: php-shared
- configMap:
defaultMode: 420
name: php-config
name: php-config
- name: kube-api-access-5k7wm
projected:
defaultMode: 420
sources:
- serviceAccountToken:
expirationSeconds: 3607
path: token
- configMap:
items:
- key: ca.crt
path: ca.crt
name: kube-root-ca.crt
- downwardAPI:
items:
- fieldRef:
apiVersion: v1
fieldPath: metadata.namespace
path: namespace
=============================== kustomize_base/pvc.yaml ===============================
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
name: php-shared
namespace: ${NAMESPACE_NAME}
spec:
accessModes:
- ReadWriteMany
resources:
requests:
storage: 8Gi
storageClassName: nutanix-dynfiles
volumeMode: Filesystem
=============================== /home/todoriri/oc_manifests/php_docker/entrypoint.sh ===============================
#!/bin/bash

echo "Starting simple continuous writer."

# path for log files within the mounted volume
VOLUME_PATH="/app/client_files"


# defaults for local testing.
POD_NAME_VAR="${POD_NAME:-unknown-pod}"
NAMESPACE_NAME_VAR="${NAMESPACE_NAME:-unknown-namespace}"

LOG_FILE="${VOLUME_PATH}/${POD_NAME_VAR}_${NAMESPACE_NAME_VAR}_data.log"
ERROR_FILE="${VOLUME_PATH}/${POD_NAME_VAR}_${NAMESPACE_NAME_VAR}_errors.log"

echo "Writer: Log file will be: $LOG_FILE"
echo "Writer: Error log will be: $ERROR_FILE"

COUNTER=0
while true; do
# write data to the log file on the mounted volume
if echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Pod ${POD_NAME_VAR} in ${NAMESPACE_NAME_VAR} writing data. Loop count: $COUNTER" >> "$LOG_FILE"; then
# Keep log file size manageable (last 1000 lines)
tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
else
echo "$(date +%Y-%m-%dT%H:%M:%S%Z) - Error writing to $LOG_FILE. Volume likely unmounted or inaccessible." >> "$ERROR_FILE"
fi
sleep 0.1 # Write every 100 milliseconds for high activity
COUNTER=$((COUNTER + 1))
done
=============================== kustomize_base/php-config.yaml ===============================
# kustomize_base/php-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
name: php-config
data:
php_command.ini: |
display_errors = On
log_errors = On
error_reporting = E_ALL
max_execution_time = 300
memory_limit = 512M
upload_max_filesize = 100M
post_max_size = 100M
php.fpf: |
[global]
error_log = /proc/self/fd/2 ; Redirect FPM errors to stderr (container logs)
daemonize = no ; Do not daemonize, let Kubernetes manage process

[www]
listen = 9000 ; Or the port your FPM process listens on
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_servers = 1
pm.max_spare_servers = 3
access.log = /proc/self/fd/2 ; Redirect FPM access logs to stderr
; Clear environment variables in FPM workers (common for security)
clear_env = no
