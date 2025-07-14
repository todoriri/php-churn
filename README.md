This setup is designed to test the **performance and stability of a Kubernetes storage solution**, specifically a `ReadWriteMany` filesystem volume, under high-churn conditions. The core of the test is to simulate rapid creation and deletion of a large number of pods and their associated Persistent Volume Claims (PVCs) on a shared storage system like NFS (Nutanix Files, in this case).

Here is a short breakdown of the components:

### The Workload
* **`k8s/app/Dockerfile`**: This builds a minimal Alpine-based container image.
* **`k8s/app/entrypoint.sh`**: This is the script that runs inside each container. It's a "simple continuous writer and reader" that repeatedly writes and reads a log file (`data.log`) on a mounted volume, creating continuous I/O activity. It also includes error logging to detect when the volume becomes inaccessible, which is a key part of the test.

### The Orchestration
* **`k8s/kustomize_base/`**: This directory contains base Kubernetes manifest files (`pvc.yaml`, `worker.pod.yaml`, etc.) for a single pod and its shared volume claim.
    * The `pvc.yaml` defines a Persistent Volume Claim named `php-shared` with `ReadWriteMany` access, which is crucial for shared filesystems like NFS.
    * The `worker.pod.yaml` defines a pod that mounts this PVC and runs the entrypoint script.
* **`k8s/run.sh`**: This is the main orchestration script. It creates and deletes **batches** of namespaces, where each namespace contains a single pod and a PVC.
    * It uses `oc` (OpenShift CLI) and `kustomize` to dynamically generate and apply unique manifests for each namespace and pod.
    * It creates a large number of pods (e.g., 200 per batch, for a total of 2000 namespaces/pods), waits for them to become active and perform I/O, and then deletes the entire namespace and all its resources, simulating a high-churn environment.
    * The script explicitly waits after both creation and deletion phases to allow time for the underlying storage (CSI driver, Ganesha NFS server) to respond to the lifecycle events.

In essence, the entire setup is a **stress test** to see how the storage system handles the rapid creation and deletion of a high volume of `ReadWriteMany` persistent volumes. The `entrypoint.sh` workload is specifically designed to expose any instability or unreliability in the storage connection during this churn, as it would cause the writer and reader operations to fail and log errors.
