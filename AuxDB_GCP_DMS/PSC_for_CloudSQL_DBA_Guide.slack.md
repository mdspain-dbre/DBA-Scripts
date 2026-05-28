*Private Service Connect (PSC) for Cloud SQL — A DBA's Guide*

A practical primer on Google Cloud Private Service Connect, written for DBAs and DBREs who are not networking specialists.
Source doc: <https://docs.cloud.google.com/vpc/docs/private-service-connect>

─────────────────────────────

*1. The Core Problem PSC Solves*

When you create a Cloud SQL instance, Google hosts it in *their own VPC* (a "producer" project you don't own). Your apps live in *your VPC* (the "consumer"). How does your app talk to a database that isn't in your network?

Three connectivity options:
• *Public IP* — DB exposed to the internet. Like opening SQL Server to `0.0.0.0/0` with a firewall allowlist. Works, but feels gross.
• *Private Services Access (PSA)* — Google "peers" their VPC with yours. Like a site-to-site VPN. Broad, hard to lock down.
• *Private Service Connect (PSC)* — You create a single private IP endpoint inside your VPC that forwards to the Cloud SQL instance. Like a SQL Server alias or a load balancer VIP.

─────────────────────────────

*2. What PSC Actually Looks Like*

```
Your VPC (10.0.0.0/16)
 +-------------------------------+
 |  App VM: 10.0.1.5             |
 |       |                       |
 |       v                       |
 |  PSC Endpoint: 10.0.2.10  ----+---> Cloud SQL instance
 |  (forwarding rule)            |     (lives in Google's VPC,
 +-------------------------------+      you never see it directly)
```

Your app connects to `10.0.2.10:3306` (or 5432/1433). That IP exists *only in your VPC*. No VPC peering, no exposed routes, no internet.

─────────────────────────────

*3. Why DBAs Should Care*

• *No IP overlap headaches.* PSA reserves a `/16` or `/20` from your network for Google. PSC uses one IP per endpoint.
• *Per-instance access control.* Each Cloud SQL instance gets its own endpoint. You restrict which projects/VPCs may even attach.
• *Cross-region / cross-project clean.* The endpoint is local to wherever you put it.
• *Better DR/HA story.* Failover replicas can have their own PSC endpoints; point connection strings at the endpoint IP or DNS name.
• *No transitive networking surprises.* PSC is point-to-point, unlike PSA peering.

─────────────────────────────

*4. The Mental Model: Producer vs. Consumer*

PSC has two sides:
• *Producer* = Google (for Cloud SQL). Publishes a *service attachment* that exposes the database.
• *Consumer* = You. Creates an *endpoint* in your VPC pointing at that service attachment.

For Cloud SQL: *you are always the consumer.* Google handles the producer side automatically when you flag the instance as PSC-enabled.

─────────────────────────────

*5. The Three PSC "Types" — Which One Matters for Cloud SQL*

• *Endpoint* — Internal IP + forwarding rule in your VPC pointing at a service attachment. Layer 4 (TCP). → *Yes — this is the one.*
• *Backend* — Puts a Google Cloud load balancer in front of the service. Used for custom domains, cross-region failover, WAF. → Advanced — only if you need centralized routing.
• *Interface* — Lets the *producer* initiate connections *into* your VPC (reverse direction). → Not for Cloud SQL clients.

*Bottom line: for Cloud SQL, you create an Endpoint.* That's it.

─────────────────────────────

*6. Key Phrases Decoded*

• *Service attachment* → The "socket" Cloud SQL exposes. You don't create it; Cloud SQL gives you its URI when PSC is enabled. Reference it from your forwarding rule.
• *Forwarding rule* → The endpoint resource in your VPC. Holds the internal IP your app connects to. In Terraform: `google_compute_forwarding_rule` with `target = <service attachment URI>`.
• *Consumer accept list* → The instance decides which consumer projects may attach. Set via `ipConfiguration.pscConfig.allowedConsumerProjects`. Without your project on that list, your endpoint stays `PENDING` forever.
• *NAT subnet* → Google's internal plumbing. You don't manage it. Source IPs from the DB's perspective are NAT'd.
• *No shared dependencies* → Why PSC beats PSA: no `/16` carved out of your VPC, no overlapping CIDR risk.
• *Service-oriented / unidirectional* → Your VPC can reach the DB IP and _only_ the DB IP. Nothing else in Google's tenant project.

─────────────────────────────

*7. The Connection Flow*

1. App resolves `myinstance.abc123.us-central1.sql.goog` → `10.0.2.10` (your PSC endpoint).
2. TCP to `10.0.2.10:3306` hits the forwarding rule.
3. Google routes it privately to the Cloud SQL instance.
4. Cloud SQL auth (IAM DB auth, password, or Cloud SQL Auth Proxy) proceeds normally.

─────────────────────────────

*8. Minimum Terraform — Standalone Example*

```
# 1. Cloud SQL instance with PSC enabled, public IP OFF
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
        allowed_consumer_projects = [var.project_id]
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

# 2. Reserve a static internal IP in YOUR VPC for the endpoint
resource "google_compute_address" "psc_endpoint_ip" {
  name         = "auxdb-qa-psc-ip"
  project      = var.project_id
  region       = "us-west1"
  subnetwork   = var.consumer_subnet_self_link
  address_type = "INTERNAL"
}

# 3. The PSC endpoint — a forwarding rule targeting Cloud SQL's
#    auto-created service attachment.
resource "google_compute_forwarding_rule" "psc_endpoint" {
  name                  = "auxdb-qa-psc-fr"
  project               = var.project_id
  region                = "us-west1"
  network               = var.consumer_vpc_self_link
  ip_address            = google_compute_address.psc_endpoint_ip.id
  load_balancing_scheme = ""   # MUST be empty for PSC consumer
  target                = google_sql_database_instance.auxdb.psc_service_attachment_link
}

# 4. (Recommended) Private DNS so apps connect by name, not IP.
resource "google_dns_managed_zone" "sql_goog" {
  name       = "sql-goog-private"
  project    = var.project_id
  dns_name   = "sql.goog."
  visibility = "private"

  private_visibility_config {
    networks { network_url = var.consumer_vpc_self_link }
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
```

─────────────────────────────

*9. Applying This to the AuxDB QA main.tf*

Our current `main.tf` uses the Vizio fork of the `terraform-google-modules/sql-db` module with PSC explicitly *off*:

```
ip_configuration = {
  ipv4_enabled                  = true
  ...
  psc_enabled                   = false
  psc_allowed_consumer_projects = []
}
```

Minimum changes to switch to PSC:

```
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

Then *add* outside the module (the module won't create them):
• `google_compute_address` — the internal IP
• `google_compute_forwarding_rule` — the endpoint
• Optionally `google_dns_managed_zone` + `google_dns_record_set` — DNS

Two new variables: `consumer_vpc_self_link` and `consumer_subnet_self_link`.

─────────────────────────────

*10. How to Connect After PSC Is Up*

• *Cloud SQL Auth Proxy (recommended):* `cloud-sql-proxy --psc <project>:<region>:auxdb-qa`
   — handles TLS + IAM auth and uses the PSC endpoint automatically.
• *Direct connect:* point your client at the endpoint IP (or DNS name) on port 3306 (MySQL) / 5432 (Postgres) / 1433 (SQL Server).

─────────────────────────────

*11. Gotchas — Where Most People Trip Up*

1. *Forgetting `allowed_consumer_projects`* → endpoint creates but stays `PENDING` forever.
2. *Leaving `load_balancing_scheme` set* → for PSC consumer forwarding rules it MUST be empty (`""`).
3. *Skipping DNS* → connecting by raw IP breaks on failover and recreates. Use the auto-managed `*.sql.goog` zone.
4. *Mixing PSA and PSC* on the same instance — pick one.
5. *Firewall rules still matter* — egress from your client subnet to the endpoint IP/port has to be permitted.
6. *Public IP + PSC can coexist*, but disable public IP once PSC works.

─────────────────────────────

*12. Further Reading*

• <https://docs.cloud.google.com/vpc/docs/private-access-options|Choose a private access option> — PSC vs PSA tradeoff.
• <https://docs.cloud.google.com/vpc/docs/about-accessing-vpc-hosted-services-endpoints|About accessing published services through endpoints> — concrete how-to.
• <https://docs.cloud.google.com/vpc/docs/private-service-connect-deployments|Deployment patterns> — hub-and-spoke / centralized endpoint patterns for Shared VPC.

Skip Backends, Interfaces, and the Google APIs sections unless a network engineer specifically asks.

─────────────────────────────

_Authored by Michael D'Spain (CPIE-DRE) — internal DBA reference._
