# Private Service Connect (PSC) for Cloud SQL — A DBA's Guide

A practical primer on Google Cloud Private Service Connect, written for database
administrators and DBREs who are not networking specialists.

> Source doc (canonical): <https://docs.cloud.google.com/vpc/docs/private-service-connect>

---

## 1. The Core Problem PSC Solves

When you create a Cloud SQL instance, Google hosts it in **their own VPC** (a
"producer" project you don't own). Your apps live in **your VPC** (the
"consumer"). So how does your app talk to a database that isn't in your network?

Google offers three connectivity options. Think of them like this:

| Option                            | DBA Analogy                                                                                                                                          |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Public IP**                     | DB exposed to the internet — like opening SQL Server to `0.0.0.0/0` with a firewall allowlist. Works, but feels gross.                               |
| **Private Services Access (PSA)** | Google "peers" their VPC with yours. Like a site-to-site VPN — your whole network can see their whole network. Broad, hard to lock down.             |
| **Private Service Connect (PSC)** | You create a **single private IP endpoint inside your VPC** that forwards to the Cloud SQL instance. Like a SQL Server alias or a load balancer VIP. |

---

## 2. What PSC Actually Looks Like

```
Your VPC (10.0.0.0/16)
 ┌─────────────────────────────────┐
 │  App VM: 10.0.1.5               │
 │       │                         │
 │       ▼                         │
 │  PSC Endpoint: 10.0.2.10  ──────┼──► Cloud SQL instance
 │  (forwarding rule)              │    (lives in Google's VPC,
 └─────────────────────────────────┘     you never see it directly)
```

Your app connects to `10.0.2.10:3306` (or 5432/1433). That IP exists **only in
your VPC**. No VPC peering, no exposed routes, no internet.

---

## 3. Why DBAs Should Care

1. **No IP overlap headaches.** PSA reserves a `/16` or `/20` from your network
   for Google. PSC uses one IP per endpoint. Huge for orgs with crowded RFC1918
   space.
2. **Per-instance access control.** Each Cloud SQL instance gets its own
   endpoint. You can restrict which projects/VPCs are even *allowed* to create
   an endpoint to a given instance.
3. **Works cross-region and cross-project cleanly** — the endpoint is local to
   wherever you put it.
4. **DR / HA story is cleaner.** Failover replicas can have their own PSC
   endpoints; you point connection strings at the endpoint IP (or better, a
   DNS name).
5. **No transitive networking surprises.** With PSA peering, anything peered to
   your VPC could potentially reach Cloud SQL. PSC is point-to-point.

---

## 4. The Mental Model: Producer vs. Consumer

PSC has two sides:

| Role         | Who you are            | What you do                                                             |
| ------------ | ---------------------- | ----------------------------------------------------------------------- |
| **Producer** | Google (for Cloud SQL) | Publishes a **service attachment** that exposes the database            |
| **Consumer** | You                    | Creates an **endpoint** in your VPC pointing at that service attachment |

For Cloud SQL: **you are always the consumer.** Google handles the producer
side automatically when you flag the instance as PSC-enabled.

---

## 5. The Three PSC "Types" — Which One Matters for Cloud SQL

The official doc lists three types. Here's the DBA cheat sheet:

| PSC Type      | What it is                                                                                                                     | Do I care for Cloud SQL?                                                      |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| **Endpoint**  | An internal IP + forwarding rule in your VPC that points at a service attachment. Layer 4 (TCP).                               | Yes — this is the one.                                                        |
| **Backend**   | Puts a Google Cloud load balancer in front of the service. Used when you want custom domains, cross-region failover, WAF, etc. | Advanced — only if you need centralized routing or multi-region failover.     |
| **Interface** | Lets the **producer** initiate connections **into** your VPC (reverse direction).                                              | No — not for Cloud SQL clients.                                               |

**Bottom line: for Cloud SQL, you create an Endpoint.** That's it.

---

## 6. Key Phrases From the Docs, Decoded

- **Service attachment** → The "socket" Google's Cloud SQL exposes. You don't
  create it; Cloud SQL gives you its URI when you enable PSC. You reference it
  from your forwarding rule.
- **Forwarding rule** → The actual endpoint resource in your VPC. This is what
  holds the internal IP your app connects to. In Terraform:
  `google_compute_forwarding_rule` with `target = <service attachment URI>`.
- **Consumer accept list** → The producer (Cloud SQL instance) decides which
  **consumer projects** are allowed to attach. For Cloud SQL you set this via
  `ipConfiguration.pscConfig.allowedConsumerProjects`. Without your project on
  that list, your endpoint stays in a `PENDING` state.
- **NAT subnet** → Google's internal plumbing. You don't manage it. Just know
  that traffic from the DB side appears NAT'd, so source IPs from the DB's
  perspective aren't your VM IPs.
- **No shared dependencies / no IP coordination** → The reason PSC > PSA: no
  `/16` carved out of your VPC, no overlapping CIDR risk.
- **Service-oriented / unidirectional** → Your VPC can reach the DB IP and
  *only* the DB IP. Nothing else in Google's tenant project is reachable.

---

## 7. The Connection Flow

1. App resolves `myinstance.abc123.us-central1.sql.goog` → `10.0.2.10` (your
   PSC endpoint).
2. TCP to `10.0.2.10:3306` hits the forwarding rule.
3. Google routes it privately to the actual Cloud SQL instance.
4. Cloud SQL auth (IAM DB auth, password, or Cloud SQL Auth Proxy) proceeds
   normally.

---

## 8. Minimum Terraform — Standalone Example

```hcl
# -----------------------------------------------------------------------------
# 1. Cloud SQL instance with PSC enabled, public IP OFF
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "auxdb" {
  name             = "auxdb-qa"
  project          = var.project_id
  region           = "us-west1"
  database_version = "MYSQL_8_0"

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "ZONAL"
    edition           = "ENTERPRISE"

    ip_configuration {
      ipv4_enabled = false   # no public IP

      psc_config {
        psc_enabled               = true
        allowed_consumer_projects = [var.project_id]   # who can attach
      }
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
      start_time         = "04:00"
    }
  }

  deletion_protection = true
}

# -----------------------------------------------------------------------------
# 2. Reserve a static internal IP in YOUR VPC for the endpoint
# -----------------------------------------------------------------------------
resource "google_compute_address" "psc_endpoint_ip" {
  name         = "auxdb-qa-psc-ip"
  project      = var.project_id
  region       = "us-west1"
  subnetwork   = var.consumer_subnet_self_link
  address_type = "INTERNAL"
}

# -----------------------------------------------------------------------------
# 3. The PSC endpoint — a forwarding rule that targets the service attachment
#    Cloud SQL auto-created when psc_enabled = true.
# -----------------------------------------------------------------------------
resource "google_compute_forwarding_rule" "psc_endpoint" {
  name                  = "auxdb-qa-psc-fr"
  project               = var.project_id
  region                = "us-west1"
  network               = var.consumer_vpc_self_link
  ip_address            = google_compute_address.psc_endpoint_ip.id
  load_balancing_scheme = ""   # MUST be empty string for PSC consumer
  target                = google_sql_database_instance.auxdb.psc_service_attachment_link
}

# -----------------------------------------------------------------------------
# 4. (Recommended) Private DNS so apps connect by name, not IP.
# -----------------------------------------------------------------------------
resource "google_dns_managed_zone" "sql_goog" {
  name       = "sql-goog-private"
  project    = var.project_id
  dns_name   = "sql.goog."
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = var.consumer_vpc_self_link
    }
  }
}

resource "google_dns_record_set" "auxdb" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.sql_goog.name
  name         = "${google_sql_database_instance.auxdb.dns_name}."
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.psc_endpoint_ip.address]
}

# -----------------------------------------------------------------------------
# Useful outputs
# -----------------------------------------------------------------------------
output "psc_endpoint_ip"          { value = google_compute_address.psc_endpoint_ip.address }
output "psc_dns_name"             { value = google_sql_database_instance.auxdb.dns_name }
output "instance_connection_name" { value = google_sql_database_instance.auxdb.connection_name }
```

---

## 9. Applying This to the AuxDB QA `main.tf`

Our current [main.tf](./main.tf) uses the Vizio fork of the
`terraform-google-modules/sql-db` module and has PSC explicitly **off**:

```hcl
ip_configuration = {
  ipv4_enabled                                  = true
  ...
  psc_enabled                                   = false
  psc_allowed_consumer_projects                 = []
}
```

To switch to PSC with that module, the **minimum changes** to the
`ip_configuration` block are:

```hcl
ip_configuration = {
  ipv4_enabled                                  = false   # turn off public IP
  ssl_mode                                      = "ENCRYPTED_ONLY"
  require_ssl                                   = null
  private_network                               = null
  allocated_ip_range                            = null
  enable_private_path_for_google_cloud_services = false
  authorized_networks                           = []
  psc_enabled                                   = true
  psc_allowed_consumer_projects                 = [var.project_id]
}
```

Then **add** the three resources outside the module (the module won't create
them for you — PSC consumer-side resources always live in your code):

- `google_compute_address` — the internal IP
- `google_compute_forwarding_rule` — the endpoint
- Optionally `google_dns_managed_zone` + `google_dns_record_set` — DNS

Two new variables required: `consumer_vpc_self_link` and
`consumer_subnet_self_link` pointing at the VPC/subnet where the app servers
live.

---

## 10. How to Connect After PSC Is Up

- **Cloud SQL Auth Proxy (recommended):**
  ```bash
  cloud-sql-proxy --psc <project>:<region>:auxdb-qa
  ```
  Proxy handles TLS + IAM auth and uses the PSC endpoint automatically.
- **Direct connect:** point your client at the endpoint IP (or DNS name) on
  port 3306 (MySQL) / 5432 (Postgres) / 1433 (SQL Server).

---

## 11. Gotchas — Where Most People Trip Up

1. **Forgetting `allowed_consumer_projects`** → endpoint creation succeeds but
   connection state is `PENDING` forever.
2. **Leaving `load_balancing_scheme` set** → for PSC consumer forwarding rules
   it must be **empty** (`""`).
3. **Skipping DNS** → connecting by raw IP works, but breaks on failover and
   during recreates. Use the auto-managed `*.sql.goog` zone.
4. **Mixing PSA and PSC** on the same instance — pick one connectivity model.
5. **Firewall rules still matter** — egress from your client subnet to the
   endpoint IP/port still has to be permitted.
6. **Public IP + PSC can coexist**, but for security most shops disable public
   IP once PSC works.

---

## 12. Further Reading (worth your time)

From the official PSC doc's sidebar:

- [Choose a private access option](https://docs.cloud.google.com/vpc/docs/private-access-options) — confirms PSC vs PSA tradeoff.
- [About accessing published services through endpoints](https://docs.cloud.google.com/vpc/docs/about-accessing-vpc-hosted-services-endpoints) — concrete how-to.
- [Deployment patterns](https://docs.cloud.google.com/vpc/docs/private-service-connect-deployments) — hub-and-spoke / centralized endpoint patterns for Shared VPC.

Skip Backends, Interfaces, and the Google APIs sections unless a network
engineer specifically asks.

---

*Authored by Michael D'Spain (CPIE-DRE) — internal DBA reference.*
