# Organization CRAIG deployment — existing infrastructure only

Target: account 533331890675, us-east-1, shines-dev-eks-cluster, namespace
craig-dev, release craig, ECR prefix craig/. Authentication uses the server's
normal AWS credential chain (the existing EC2 instance role); no profile is forced.

This package contains no Terraform and performs no AWS infrastructure provisioning.
It builds main and pushes to existing ECR repositories. Missing repositories fail
before building. It does not create namespaces, ALBs, target groups or controllers.

Existing routing is preserved: nginx-craig-dev handles application ingresses;
nginx-alb-craig-dev, alb-nginx-ingress and existing TargetGroupBindings are not
managed by this package. URLs are https://sandportal.dhs.ga.gov (app and auth)
and https://sandshines.dhs.ga.gov (intake). TLS terminates on the existing routing
infrastructure. No new certificate or Kubernetes TLS Secret is created. The old
cases.internal.example.gov host is retained as-is; it is not a newly configured DNS name.

## Prerequisites

Run on the organization build server with Docker/Buildx running, AWS CLI, Helm,
kubectl, Git and Git LFS, Python 3 with PyYAML, OpenSSL and Bash. GitLab main must
be readable. The existing kubeconfig must contain context:
arn:aws:eks:us-east-1:533331890675:cluster/shines-dev-eks-cluster

The role needs existing ECR repository read/push access, and Kubernetes access to
read the ingress class, namespace and release and manage CRAIG application resources.
No AWS keys or kubeconfig are shipped in the archive.

## Run

```bash
bash craig deploy --discard-test-data
```

This single command checks tools, Docker, AWS identity, repositories and cluster
access, fetches main, builds/pushes images, resets/deploys and prints final status.
It stops on the first failure and holds one lock for the entire operation.
Prerequisites and credentials must already be installed/configured; it does not
install software or change the server's permissions automatically.

Individual `preflight`, `fetch`, `build`, `reset-deploy --discard-test-data`, and
`status` commands remain available for troubleshooting.

Build completes before reset so a build failure leaves the existing deployment alone.
Fetch selects current main, without creating a GitLab branch or running CI. Build
pins all images to that commit plus a timestamp. It also updates the existing ECR
latest tags. Build metadata and secrets are kept privately in ignored .work/.
Do not share that directory. The deploy command checks the source revision and
build-values checksum before using the images.

Reset explicitly erases the CRAIG release and its ephemeral database, broker and
Keycloak data. This was selected for the disposable organization dev stack. It
installs infrastructure workloads first, then applications/migrations and seed data.
These are Kubernetes application workloads, not provisioning of AWS infrastructure.
The existing unused pending PVC is not deleted by the script.

Before uninstalling, the script inspects the previous Helm manifest. It refuses
unexpected resource ownership, PVCs, ALB ingresses, TargetGroupBindings or NGINX
resources. If it refuses, stop and inspect the named resource; do not bypass the
check or uninstall the ingress-controller release. Uninstall hooks are disabled.

A partial install may remain if deployment fails; use ./craig status and pod logs
before retrying. Re-running reset-deploy repeats the destructive reset using the
same verified build. Keep the previous-manifest.yaml file private: it can contain
Secrets. Rollback cannot restore erased ephemeral data.

For a newer main, repeat fetch, build and reset-deploy. Do not use the personal
Terraform repository's scripts/craig wrapper on this server.

## Validation performed locally

Shell syntax, Helm lint/render, and manifest ownership guards. No organization AWS
or Kubernetes operations were run while preparing this package. Server permissions,
NGINX annotation policy and actual organization login must be verified on deployment.

The chart uses synthetic devstack credentials and ephemeral per-pod object storage;
it is for the approved test reset, not retained real-world data. Current main can
change its runtime requirements, so future builds still require rollout verification.
