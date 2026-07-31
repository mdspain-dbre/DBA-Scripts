# Finding: Cloud SQL Auth Proxy fails for PSC instance `tvc-qa` (DNS resolution)

**Date:** 2026-07-28
**Instance:** `tvc-qa` — PostgreSQL 18, project `vz-inscape-portfolio-qa`, region `us-east4`
**Connection name:** `vz-inscape-portfolio-qa:us-east4:tvc-qa`
**Access:** PSC (Private Service Connect) only — no public IP, no VPC-native private IP
**Impact:** `cloud-sql-proxy --psc` fails from a laptop/off-VPC-DNS host with `dial tcp: lookup <hash>.<...>.us-east4.sql.goog: no such host`, even though the PSC endpoint IP is reachable.

## TL;DR
The proxy failure is **DNS name resolution**, not IAM and not networking. In `--psc` mode the Cloud SQL Auth Proxy dials the instance's API‑provided `dnsName` (a `*.sql.goog` name) that only resolves inside the VPC's **private** Cloud DNS zone. A client whose resolver is public (e.g. home ISP over split‑tunnel VPN) gets `NXDOMAIN` and the proxy can't connect — while a plain TCP connection to the PSC IP still succeeds.

## Key facts
| Item                                                  | Value                                                                                                                  |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| PSC endpoint IP (consumer VPC `vz-inscape-qa-vpc-01`) | `10.235.255.244`                                                                                                       |
| Instance API `dnsName` (what the proxy dials)         | `0dc2f1e00504.196oni6tu0t0i.us-east4.sql.goog`                                                                         |
| Private DNS zone holding that A record                | `inscape-qa-sql-goog-portfolio-qa-use4` (`196oni6tu0t0i.us-east4.sql.goog.`, **private**) in `vz-inscape-portfolio-qa` |
| Public custom name → same IP                          | `tvc-db.qa.gcp.cognet.tv` → A → `10.235.255.244` (zone `qa.gcp.cognet.tv`, **public**)                                 |
| SSL mode                                              | `ENCRYPTED_ONLY` (TLS required)                                                                                        |
| IAM DB auth                                           | enabled (`cloudsql.iam_authentication=on`)                                                                             |
| Proxy version tested                                  | cloud-sql-proxy 2.21.3                                                                                                 |

## Root cause
1. `cloud-sql-proxy --psc <conn-name>` looks up the instance's `dnsName` from the Admin API and **dials that exact name**. It does not accept a substitute hostname for PSC.
2. That `*.sql.goog` A record lives in a **private** Cloud DNS zone bound to the VPC. It resolves only for clients that query the VPC's Cloud DNS (169.254.169.254 / inbound forwarder).
3. The test client resolved via a public ISP resolver (`2001:558:feed::1`) → `NXDOMAIN` for the goog name → proxy `no such host`.
4. Split‑tunnel VPN routed the RFC1918 range, so **TCP to `10.235.255.244:5432` succeeded** even though **DNS for the goog name did not** — which is why direct connections worked but the proxy did not.

## Evidence
```text
# proxy in --private-ip mode
failed to connect: instance does not have IP of type "PRIVATE"   # it's PSC, not private-IP

# proxy in --psc mode
dial error ... lookup 0dc2f1e00504.196oni6tu0t0i.us-east4.sql.goog: no such host

# but the PSC IP is reachable
nc -z 10.235.255.244 5432  -> succeeded

# public custom name resolves to the same IP
dig +short tvc-db.qa.gcp.cognet.tv  -> 10.235.255.244

# the goog A record (in the private zone)
0dc2f1e00504.196oni6tu0t0i.us-east4.sql.goog.  A  10.235.255.244
```

## Workaround used (temporary, laptop-local)
Because the public custom name and the goog name resolve to the **same** PSC IP, alias the goog name to that IP in `/etc/hosts` for the session, then run the proxy normally, then remove it:
```bash
GOOG=0dc2f1e00504.196oni6tu0t0i.us-east4.sql.goog
IP=$(dig +short tvc-db.qa.gcp.cognet.tv | head -1)   # 10.235.255.244
echo "$IP  $GOOG  # csql-proxy-temp tvc-qa" | sudo tee -a /etc/hosts

cloud-sql-proxy --psc --auto-iam-authn --port 5433 \
  vz-inscape-portfolio-qa:us-east4:tvc-qa
# connect with NO password — proxy injects the IAM access token:
psql "host=127.0.0.1 port=5433 dbname=postgres user=<you>@vizio.com sslmode=disable" -c "select current_user;"

# cleanup
sudo sed -i '' "/# csql-proxy-temp tvc-qa/d" /etc/hosts
```
Result: connected as `<you>@vizio.com` via the Auth Proxy with no static password.

## Recommended durable fixes (pick one)
1. **DNS forwarding (best):** make the client resolve the private `*.sql.goog` zone — VPN pushes the VPC Cloud DNS / inbound forwarder for `sql.goog`. Then `--psc` works fleet‑wide, no hosts edits.
2. **Proxy DNS-names feature (cloud-sql-proxy ≥2.15):** add a **TXT** record on a resolvable domain whose value is the connection name, then run `cloud-sql-proxy --auto-iam-authn <that-domain>`. (The current `tvc-db.qa.gcp.cognet.tv` is an A record, so add a TXT to use this.)
3. **Skip the proxy:** connect directly to the reachable name/IP with an IAM token as the password:
   ```bash
   PGPASSWORD=$(gcloud auth print-access-token) \
     psql "host=tvc-db.qa.gcp.cognet.tv port=5432 dbname=postgres user=<you>@vizio.com sslmode=require"
   ```

## Notes
- IAM DB auth never failed here. Two independent gates: the OAuth token proves *who you are*; the IAM `cloudsql.instanceUser` binding + provisioned IAM DB user prove *you may log in*.
- `--auto-iam-authn` = proxy mints/injects the token (no password). Direct psql = you pass `PGPASSWORD=$(gcloud auth print-access-token)` yourself.
- `sslmode=require` (not `verify-full`) satisfies `ENCRYPTED_ONLY` without server‑cert verification.
