# Cloud SQL Auth Proxy Setup (MySQL Migration)

## Context
- Source: AWS RDS MySQL 8.0.42 (`prod-rds-auxdb-80-20240903`)
- Target: Cloud SQL MySQL 8.0.44 (`auxdb-qa-dre-test2`)
- Project: `vz-inscape-portfolio-dev`
- Connection name: `vz-inscape-portfolio-dev:us-west1:auxdb-qa-dre-test2`

## Recommendation
- Day 1 migration: **Cloud SQL Auth Proxy + DB username/password**
- Phase 2 hardening: evaluate **IAM DB auth**
- Note: Proxy improves transport/security and access control, but does **not** fix old MySQL auth-plugin client incompatibilities.

## Prerequisites
1. Cloud SQL Admin API enabled.
2. Identity running proxy has `roles/cloudsql.client`.
3. If using IAM DB auth later, add `roles/cloudsql.instanceUser`.
4. Network path exists from proxy host to Cloud SQL endpoint.
5. For this instance (private/PSC), run proxy from an approved network location.

## Install Cloud SQL Auth Proxy
- Use official binary or official container image.
- Keep the binary on PATH (or pin image tag in Kubernetes/containers).

## Local Test Setup (fast validation)
1. Authenticate:
   - `gcloud auth application-default login`
2. Start proxy:
   - `cloud-sql-proxy --private-ip vz-inscape-portfolio-dev:us-west1:auxdb-qa-dre-test2 --port 3306`
3. Connect app/client to:
   - Host: `127.0.0.1`
   - Port: `3306`
   - DB user/password: existing MySQL credentials
4. Validate:
   - Run a simple query (`SELECT VERSION();`) using the same client/driver the app uses.

## VM/Server Setup (persistent)
1. Run proxy with attached service account (preferred over key files).
2. Grant service account `Cloud SQL Client`.
3. Run proxy as a system service (systemd), with restart policy.
4. Point app to `127.0.0.1:3306`.
5. Store DB credentials in Secret Manager (or approved secret store).

## GKE Sidecar Setup (recommended for k8s)
1. Use Workload Identity.
2. Map KSA -> GSA with `Cloud SQL Client`.
3. Add proxy sidecar in pod.
4. App container connects to `127.0.0.1:3306` inside pod.

## IAM Discussion (where it fits)
- **Control plane IAM**: who can run/manage proxy and Cloud SQL.
- **Data plane IAM DB auth**: optional replacement for static DB passwords over time.
- Migration does not require IAM DB auth on day 1.

## App Team Guidance
1. Standardize on Cloud SQL Auth Proxy for connectivity.
2. Keep DB user/password for cutover stability.
3. Identify old drivers that may fail with MySQL 8 auth plugin behavior.
4. Upgrade drivers in phases.
5. Later move compatible services to IAM DB auth.

## Suggested Rollout Plan
1. Pilot one non-critical app via proxy.
2. Validate connectivity, latency, and failover behavior.
3. Roll out by app tier.
4. Post-migration hardening:
   - enforce encrypted transport
   - increase connector/proxy enforcement
   - reduce legacy auth/plugin usage
