# #############################################################################
# FILE:        main.tf
# PURPOSE:     Provisions the DRE sandbox database environment in GCP.
# AUTHOR:      Michael D'Spain (CPIE-DRE)
# PROJECT:     dre-sandbox-471618
# REGION:      us-west1 (Oregon) — chosen for low latency from PST and lower cost
#              than us-central1 for sustained-use SQL workloads.
#
# RESOURCES MANAGED BY THIS FILE:
#   1. google_sql_database_instance.sql_server
#        Managed Cloud SQL for SQL Server 2022 Enterprise instance.
#        Used as a managed alternative to a self-hosted VM — no patching, no
#        OS access, automated backups, regional HA optional.
#   2. google_compute_instance.sql_server_vm
#        Self-managed Windows Server 2022 + SQL Server 2022 Standard VM.
#        Used when full OS access is needed (e.g., Agent jobs, linked servers,
#        SQLCLR, custom file system layout, third-party agents).
#   3. google_compute_disk.sql_data_disk
#        Dedicated PD-SSD attached to the SQL Server VM for user databases.
#   4. google_compute_instance.mysql_vm
#        Debian 12 + MySQL 8 VM with the Sakila sample DB pre-loaded for
#        training, demos, and migration testing.
#   5. google_compute_disk.mysql_data_disk
#        Dedicated PD-SSD for the MySQL data directory (/var/lib/mysql).
#   6. google_compute_firewall.* (RDP, SQL, MySQL, SSH)
#        VPC firewall rules — currently open to 0.0.0.0/0 for sandbox use.
#        TIGHTEN BEFORE PRODUCTION USE.
#
# USAGE:
#   # First-time initialization (downloads providers, creates .terraform/):
#   terraform init
#
#   # Preview changes — always run before apply:
#   terraform plan \
#     -var="sql_root_password=<strongpw>" \
#     -var="sql_sa_password=<strongpw>" \
#     -var="mysql_root_password=<strongpw>"
#
#   # Apply changes (will prompt for confirmation):
#   terraform apply -var=...
#
#   # Tear down everything (subject to deletion_protection on Cloud SQL):
#   terraform destroy -var=...
#
# COST NOTES:
#   - Cloud SQL Enterprise db-custom-24-159744 is the largest cost driver
#     (~$2,500+/month at on-demand rates). Stop the instance when idle.
#   - The Windows SQL VM incurs Windows + SQL Server license cost on top of
#     the underlying compute (n2-standard-8). Stop when not in use.
#   - PD-SSD disks bill while allocated even when the VM is stopped.
#
# SECURITY TODOS BEFORE PRODUCTION:
#   - Replace 0.0.0.0/0 firewall ranges with corporate VPN / office CIDRs.
#   - Disable public IPs and use Private Service Connect / private IP only.
#   - Move secrets to Secret Manager and read them via google_secret_manager_*.
#   - Enable Cloud SQL IAM authentication and audit logging.
#   - Enable VPC Service Controls / Org Policy guardrails on the project.
# #############################################################################

# =============================================================================
# TERRAFORM CONFIGURATION
# =============================================================================
# The `terraform` block declares settings for Terraform itself (as opposed to
# the resources it manages). The two most common things that go here are:
#   - required_providers: which plugins to download and what versions are OK.
#   - backend:            where to store the state file (local vs. GCS, S3, etc.).
#
# We currently use the default LOCAL backend (terraform.tfstate is written next
# to this file). For team use, switch to a remote backend such as GCS:
#
#   backend "gcs" {
#     bucket = "dre-sandbox-tfstate"
#     prefix = "gcp/dbms"
#   }
#
# Providers are how Terraform talks to cloud APIs — in this case, Google Cloud.
# "~> 6.0" is a pessimistic version constraint meaning >= 6.0.0 and < 7.0.0,
# which lets us pick up bug fixes and new resources without an unexpected
# breaking change from a major-version bump.
# =============================================================================
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google" # Official Google provider on the HashiCorp registry
      version = "~> 6.0"           # Allow 6.x bug-fix and minor updates; block 7.x
    }
  }
}

# =============================================================================
# GOOGLE CLOUD PROVIDER
# =============================================================================
# Configures how Terraform authenticates and interacts with GCP.
# - project: The GCP project ID where resources will be created.
# - region:  Default region for regional resources (can be overridden per-resource).
# - Authentication uses whatever method is available (gcloud auth application-default
#   login, GOOGLE_CREDENTIALS env var, or service account key file).
# =============================================================================
provider "google" {
  project = "dre-sandbox-471618"
  region  = "us-west1"
}

# =============================================================================
# VARIABLES
# =============================================================================
# Variables let you parameterize the config so values aren't hard-coded.
# Defaults are provided for most variables, but they can be overridden at
# runtime via:
#   - CLI flags:        terraform plan -var="sql_instance_name=my-sql"
#   - .tfvars file:     terraform plan -var-file="prod.tfvars"
#   - Environment vars: TF_VAR_sql_instance_name="my-sql"
# =============================================================================

# The name for the Cloud SQL instance. Must be unique within the project.
# Cloud SQL instance names cannot be reused for up to 7 days after deletion.
variable "sql_instance_name" {
  description = "Name for the Cloud SQL for SQL Server instance."
  default     = "cs-sql-01"
}

# The root password for the SQL Server instance. Marked "sensitive" so
# Terraform won't display it in plan output or logs. Since there's no default,
# you MUST supply it at runtime (e.g., -var="sql_root_password=YourP@ssw0rd!").
variable "sql_root_password" {
  description = "Root password for the SQL Server instance."
  sensitive   = true
}

# =============================================================================
# LOCAL VALUES (Computed/Reusable Values)
# =============================================================================
# `locals` let you define values once and reuse them across multiple resources,
# similar to constants in a normal programming language. They are evaluated at
# plan time and cannot be overridden from the CLI (unlike variables).
#
# GCP uses "labels" instead of Azure "tags" — same concept, different name.
# Label rules (enforced by GCP):
#   - Keys: 1-63 chars, lowercase letters/numbers/underscores/hyphens, must start
#           with a lowercase letter.
#   - Values: 0-63 chars, lowercase letters/numbers/underscores/hyphens.
#   - Up to 64 labels per resource.
# These labels feed cost reports, Resource Manager filters, and Cloud Asset
# Inventory queries — keep them consistent across every resource in the file.
# =============================================================================
locals {
  labels = {
    application = "content-services" # App/product these resources belong to
    cost-center = "2650"             # Finance cost-center for chargeback reporting
    created-by  = "michael-dspain"   # Human owner / point of contact
    environment = "dev"              # dev | test | stage | prod
    owner       = "cpie-dre"         # Owning team
    service     = "content-services" # Logical service grouping
  }
}

# =============================================================================
# CLOUD SQL FOR SQL SERVER — ENTERPRISE PLUS (MEMORY-OPTIMIZED)
# =============================================================================
# Creates a Cloud SQL instance running SQL Server 2022 Enterprise.
#
# Edition: ENTERPRISE_PLUS
#   Enterprise Plus unlocks higher memory-per-vCPU limits (up to 32 GB/vCPU)
#   compared to standard Enterprise (6.5 GB/vCPU). This is required for
#   memory-heavy configurations like 24 vCPUs + 500 GB RAM (~20.8 GB/vCPU).
#   Enterprise Plus also provides:
#     - Data cache (local SSD for hot data)
#     - Advanced HA with near-zero downtime maintenance
#     - 99.99% SLA (regional)
#
# Machine tier: db-perf-optimized-N-24
#   - 24 vCPUs
#   - 500 GB RAM (512,000 MB)
#   Enterprise Plus uses "db-perf-optimized-N-<cpu>" tiers for
#   performance/memory-optimized configurations.
#
# Storage:
#   - 1 TB (1,000 GB) SSD persistent disk
#   - Auto-resize enabled (grows automatically if you approach the limit)
#   - Auto-resize limit set to 2 TB to prevent runaway growth
#
# Availability:
#   - ZONAL (single zone) — no automatic failover
#   - Change to REGIONAL for HA with automatic failover to a standby
#
# Backups:
#   - Automated daily backups enabled
#   - Point-in-time recovery (PITR) enabled via transaction log backups
#   - Retained for 7 days
#   - Backup window: 04:00-08:00 UTC (off-peak)
#
# Maintenance:
#   - Sunday, 05:00-06:00 UTC (off-peak window)
#
# Networking:
#   - Public IP enabled by default (restrict with authorized_networks)
#   - For private-only access, enable private_network and disable public IP
#
# Deletion protection is enabled to prevent accidental destruction.
# Set to false when you intentionally want to tear down the instance.
# =============================================================================
resource "google_sql_database_instance" "sql_server" {
  name                = var.sql_instance_name
  database_version    = "SQLSERVER_2022_ENTERPRISE"
  region              = "us-west1"
  root_password       = var.sql_root_password
  deletion_protection = true

  settings {
    # ---------------------------------------------------------------------
    # Machine sizing
    # ---------------------------------------------------------------------
    # `tier` for SQL Server Enterprise uses the `db-custom-<vCPU>-<MB RAM>`
    # format. SQL Server caps memory at 6.5 GB per vCPU, so 24 vCPUs * 6.5 GB
    # = 156 GB (159,744 MB). Going higher requires more vCPUs.
    tier              = "db-custom-24-159744" # 24 vCPUs, 156 GB RAM (max at 6.5 GB/vCPU)
    edition           = "ENTERPRISE"          # Enterprise Plus is NOT available for SQL Server (Postgres/MySQL only)
    availability_type = "ZONAL"               # Single-zone; switch to "REGIONAL" for HA standby + auto failover

    # ---------------------------------------------------------------------
    # Storage
    # ---------------------------------------------------------------------
    # PD_SSD = Persistent Disk SSD (high IOPS, low latency, required at this tier).
    # Auto-resize grows the disk in 5 GB increments as it nears capacity, which
    # prevents "out of space" outages but can quietly inflate costs — the
    # autoresize_limit acts as a safety cap.
    disk_type             = "PD_SSD" # PD_SSD is the correct disk for this tier
    disk_size             = 1000     # Initial size in GB
    disk_autoresize       = true     # Auto-grow when space is low
    disk_autoresize_limit = 2000     # Hard ceiling in GB to prevent runaway growth

    # Apply the standard label set defined in `locals` for cost reporting.
    user_labels = local.labels

    # Automated backup configuration
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true    # PITR via transaction logs
      start_time                     = "04:00" # Daily backup window (UTC)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7 # Keep 7 daily backups
      }
    }

    # Maintenance window — Sunday 5 AM UTC
    maintenance_window {
      day          = 7 # Sunday (1=Mon, 7=Sun)
      hour         = 5 # 5 AM UTC
      update_track = "stable"
    }

    # ---------------------------------------------------------------------
    # IP configuration
    # ---------------------------------------------------------------------
    # Public IP is enabled with NO authorized networks, which means the
    # instance has a public IP but rejects all inbound TCP — you must add
    # authorized_networks blocks (allow-list of CIDRs) before clients can
    # connect over the public IP, OR connect via the Cloud SQL Auth Proxy
    # which uses IAM and tunnels over an encrypted channel.
    #
    # For production: prefer private IP only (set ipv4_enabled = false and
    # configure private_network with a VPC peering range).
    ip_configuration {
      ipv4_enabled = true
      # Example allow-list (uncomment and edit to use):
      # authorized_networks {
      #   name  = "office-vpn"
      #   value = "203.0.113.0/24"
      # }
    }

    # ---------------------------------------------------------------------
    # SQL Server-specific flags
    # ---------------------------------------------------------------------
    # `database_flags` is how Cloud SQL exposes SQL Server `sp_configure`
    # options. Flags here are persisted across restarts. Only a curated
    # subset of sp_configure options is supported by Cloud SQL — see:
    # https://cloud.google.com/sql/docs/sqlserver/flags
    database_flags {
      name  = "remote access" # Allows remote stored procedure execution between linked servers
      value = "on"
    }
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================
# Outputs are printed after "terraform apply" completes and can be queried
# later with "terraform output". They're useful for:
#   - Displaying important info (IPs, connection strings) after deployment.
#   - Passing values to other Terraform modules or scripts.
# =============================================================================
output "sql_server_public_ip" {
  description = "Public IP address of the Cloud SQL instance"
  value       = google_sql_database_instance.sql_server.public_ip_address
}

output "sql_server_connection_name" {
  description = "Connection name for Cloud SQL Proxy (project:region:instance)"
  value       = google_sql_database_instance.sql_server.connection_name
}

# =============================================================================
# VARIABLES — COMPUTE ENGINE SQL SERVER VM
# =============================================================================

variable "vm_name" {
  description = "Name for the Compute Engine SQL Server VM."
  default     = "gcdbms-sqlvm-01"
}

variable "vm_zone" {
  description = "Zone for the VM (must be in the same region as other resources)."
  default     = "us-west1-b"
}

variable "vm_machine_type" {
  description = "Machine type for the VM. n2-standard-8 = 8 vCPUs, 32 GB RAM."
  default     = "n2-standard-8"
}

variable "sql_sa_password" {
  description = "SA password for the SQL Server instance on the VM. Must meet SQL Server complexity requirements."
  sensitive   = true
}

# =============================================================================
# COMPUTE ENGINE — SQL SERVER 2022 STANDARD ON WINDOWS SERVER 2022
# =============================================================================
# Creates a GCE VM using a Google-provided SQL Server image.
#
# Image family: sql-std-2022-win-2022
#   - SQL Server 2022 Standard pre-installed on Windows Server 2022
#   - Licensed through GCP (included in per-minute VM pricing)
#   - Other options:
#       sql-ent-2022-win-2022    (Enterprise)
#       sql-web-2022-win-2022    (Web)
#       sql-exp-2022-win-2022    (Express — free SQL license)
#
# Boot disk:
#   - 200 GB SSD (pd-ssd) for OS + SQL Server binaries + system DBs
#
# Data disk:
#   - Separate 500 GB SSD attached for user databases / logs
#   - Keeps data isolated from OS for performance and manageability
#
# Networking:
#   - Ephemeral external IP for initial access (remove for production)
#   - RDP (3389) and SQL Server (1433) allowed via firewall rules below
#
# NOTE: After provisioning, connect via RDP to:
#   1. Initialize and format the data disk (Disk Management)
#   2. Move tempdb / user DBs to the data disk
#   3. Configure Windows Firewall, SQL Server auth, etc.
# =============================================================================
resource "google_compute_instance" "sql_server_vm" {
  name         = var.vm_name
  machine_type = var.vm_machine_type
  zone         = var.vm_zone
  labels       = local.labels

  # Boot disk — SQL Server 2022 Standard on Windows Server 2022
  boot_disk {
    initialize_params {
      image = "windows-sql-cloud/sql-std-2022-win-2022"
      size  = 200 # GB
      type  = "pd-ssd"
    }
  }

  # Data disk — separate SSD for SQL Server databases
  attached_disk {
    source      = google_compute_disk.sql_data_disk.id
    device_name = "sql-data"
  }

  network_interface {
    network = "default"

    # Ephemeral external IP — remove this block for private-only access
    access_config {}
  }

  # Allow the VM to call GCP APIs (e.g., Cloud Storage for backups)
  service_account {
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Enable OS Login for SSH (not RDP, but useful for gcloud compute reset-windows-password)
    enable-oslogin = "true"

    # Startup script: Enable mixed-mode auth, set SA password, restart SQL Server
    # Runs once on first boot. Uses a sentinel file to prevent re-execution.
    windows-startup-script-cmd = <<-EOT
      if exist C:\sql_sa_configured.flag exit /b 0
      net stop MSSQLSERVER
      net start MSSQLSERVER /m"SQLCMD"
      sqlcmd -S localhost -E -Q "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"
      sqlcmd -S localhost -E -Q "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2"
      net stop MSSQLSERVER
      net start MSSQLSERVER
      sqlcmd -S localhost -E -Q "ALTER LOGIN [sa] WITH PASSWORD = N'${var.sql_sa_password}'; ALTER LOGIN [sa] ENABLE;"
      echo done > C:\sql_sa_configured.flag
    EOT
  }
}

# =============================================================================
# DATA DISK — Separate SSD for SQL Server databases and logs
# =============================================================================
# Best practice: keep the OS, SQL binaries, system DBs, user DBs, and tempdb
# on different disks. This file currently provisions ONE additional data disk
# beyond the OS disk; for production you typically want three or more:
#   - data:   user database files (.mdf / .ndf)
#   - log:    transaction logs (.ldf) on its own disk for sequential write perf
#   - tempdb: highly volatile, benefits from a Local SSD when available
#
# pd-ssd performance scales with size — 500 GB ≈ 15,000 read IOPS, 15,000 write
# IOPS, and ~240 MB/s throughput. Increase `size` to scale performance even if
# you don't need the capacity.
# =============================================================================
resource "google_compute_disk" "sql_data_disk" {
  name   = "${var.vm_name}-data" # Conventional naming: <vm-name>-data
  type   = "pd-ssd"              # pd-ssd | pd-balanced | pd-standard | pd-extreme
  zone   = var.vm_zone           # Disk + VM must be in the same zone for attachment
  size   = 500                   # GB — also drives IOPS/throughput limits
  labels = local.labels
}

# =============================================================================
# FIREWALL RULES — RDP and SQL Server access
# =============================================================================
# GCP firewall rules are VPC-level (not per-VM). They match traffic by:
#   - direction (INGRESS by default)
#   - protocol + port
#   - source_ranges  (for INGRESS) or destination_ranges (for EGRESS)
#   - target_tags    — only applies to VMs that carry the matching network tag
#
# IMPORTANT: target_tags below reference "sql-server", but the
# google_compute_instance.sql_server_vm resource does NOT currently set a
# `tags = ["sql-server"]` argument, so these rules will not match it. Either
# add `tags = ["sql-server"]` to that VM or change target_tags here. The
# MySQL VM correctly sets tags = ["mysql-server"].
#
# Restrict source_ranges to your office/VPN CIDR blocks for production use.
# 0.0.0.0/0 means "the entire public Internet" — sandbox only.
# =============================================================================
resource "google_compute_firewall" "allow_rdp" {
  name    = "${var.vm_name}-allow-rdp"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # TODO: Restrict to your IP/CIDR
  target_tags   = ["sql-server"]
}

resource "google_compute_firewall" "allow_sql" {
  name    = "${var.vm_name}-allow-sql"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["1433"]
  }

  source_ranges = ["0.0.0.0/0"] # TODO: Restrict to your IP/CIDR
  target_tags   = ["sql-server"]
}

# =============================================================================
# OUTPUTS — COMPUTE ENGINE SQL SERVER VM
# =============================================================================
output "sql_vm_name" {
  description = "Name of the SQL Server VM"
  value       = google_compute_instance.sql_server_vm.name
}

output "sql_vm_external_ip" {
  description = "External IP of the SQL Server VM (use for RDP and SSMS connections)"
  value       = google_compute_instance.sql_server_vm.network_interface[0].access_config[0].nat_ip
}

output "sql_vm_internal_ip" {
  description = "Internal IP of the SQL Server VM"
  value       = google_compute_instance.sql_server_vm.network_interface[0].network_ip
}

output "sql_vm_reset_password_command" {
  description = "Run this command to set the Windows admin password"
  value       = "gcloud compute reset-windows-password ${google_compute_instance.sql_server_vm.name} --zone=${var.vm_zone}"
}

# =============================================================================
# VARIABLES — COMPUTE ENGINE MYSQL VM
# =============================================================================

variable "mysql_vm_name" {
  description = "Name for the Compute Engine MySQL VM."
  default     = "gcdbms-mysqlvm-01"
}

variable "mysql_vm_zone" {
  description = "Zone for the MySQL VM (must be in the same region as other resources)."
  default     = "us-west1-b"
}

variable "mysql_vm_machine_type" {
  description = "Machine type for the MySQL VM. e2-standard-4 = 4 vCPUs, 16 GB RAM."
  default     = "e2-standard-4"
}

variable "mysql_root_password" {
  description = "Root password for the MySQL instance. Must be a strong password."
  sensitive   = true
}

# Restricted ingress for the MySQL VM. Includes:
#   - Admin workstation (75.71.182.151/32) for ad-hoc mysql/SSH access.
#   - Service Networking VPC peering range (10.113.32.0/20) used by Google
#     Cloud Database Migration Service to reach the VM at its private IP.
#   - Internal VPC range (10.128.0.0/9) for in-VPC clients (other VMs, etc.).
# Used by both google_compute_firewall.allow_mysql (3306) and the SSH rule
# (which gets only the admin entry — see allow_mysql_ssh below).
variable "mysql_allowed_cidrs" {
  description = "CIDRs allowed to reach MySQL on tcp/3306 (admin + DMS peering + in-VPC)."
  type        = list(string)
  default     = ["75.71.182.151/32", "10.113.32.0/20", "10.128.0.0/9"]
}

variable "mysql_admin_cidrs" {
  description = "CIDRs allowed to SSH (tcp/22) into the MySQL VM. Admin workstations only."
  type        = list(string)
  default     = ["75.71.182.151/32"]
}

# =============================================================================
# DATA DISK — Separate SSD for MySQL data
# =============================================================================
resource "google_compute_disk" "mysql_data_disk" {
  name   = "${var.mysql_vm_name}-data"
  type   = "pd-ssd"
  zone   = var.mysql_vm_zone
  size   = 200 # GB
  labels = local.labels
}

# =============================================================================
# COMPUTE ENGINE — MYSQL 8 ON DEBIAN 12 WITH SAKILA DATABASE
# =============================================================================
# Creates a GCE VM running Debian 12, installs MySQL 8, configures root
# access, and imports the Sakila sample database.
#
# Boot disk:
#   - 50 GB SSD for OS + MySQL binaries
#
# Data disk:
#   - Separate 200 GB SSD for MySQL data directory (/var/lib/mysql)
#
# Startup script:
#   1. Formats and mounts the data disk to /mnt/mysql-data
#   2. Installs MySQL 8 from the official MySQL APT repository
#   3. Moves the data directory to the data disk
#   4. Sets the root password and enables remote root login
#   5. Downloads and imports the Sakila sample database
#   6. Creates a sentinel file to prevent re-execution on reboot
#
# NOTE: The startup script runs as root on first boot. Check the serial
# console output for progress: gcloud compute instances get-serial-port-output
# =============================================================================
resource "google_compute_instance" "mysql_vm" {
  name         = var.mysql_vm_name
  machine_type = var.mysql_vm_machine_type
  zone         = var.mysql_vm_zone
  labels       = local.labels
  tags         = ["mysql-server"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 50 # GB
      type  = "pd-ssd"
    }
  }

  attached_disk {
    source      = google_compute_disk.mysql_data_disk.id
    device_name = "mysql-data"
  }

  network_interface {
    network = "default"

    # Ephemeral external IP — remove this block for private-only access
    access_config {}
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "true"

    startup-script = <<-EOFSCRIPT
      #!/bin/bash
      set -ex

      LOGFILE="/var/log/mysql-setup.log"
      exec > >(tee -a "$LOGFILE") 2>&1

      SENTINEL="/opt/mysql_setup_complete.flag"
      if [ -f "$SENTINEL" ]; then
        echo "MySQL setup already completed. Skipping."
        exit 0
      fi

      MYSQL_ROOT_PASS="${var.mysql_root_password}"

      echo "=== Starting MySQL setup ==="

      # -----------------------------------------------------------------------
      # 1. Format and mount the data disk
      # -----------------------------------------------------------------------
      DATA_DISK="/dev/disk/by-id/google-mysql-data"
      MOUNT_POINT="/mnt/mysql-data"

      if ! blkid "$DATA_DISK"; then
        echo "Formatting data disk..."
        mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0 "$DATA_DISK"
      fi

      mkdir -p "$MOUNT_POINT"
      mount -o discard,defaults "$DATA_DISK" "$MOUNT_POINT"

      # Add to fstab for persistence across reboots
      if ! grep -q "$MOUNT_POINT" /etc/fstab; then
        DISK_UUID=$(blkid -s UUID -o value "$DATA_DISK")
        echo "UUID=$DISK_UUID $MOUNT_POINT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
      fi

      # -----------------------------------------------------------------------
      # 2. Install MySQL 8 from official MySQL APT repository
      # -----------------------------------------------------------------------
      echo "Installing MySQL 8..."
      export DEBIAN_FRONTEND=noninteractive

      apt-get update -y
      apt-get install -y wget lsb-release gnupg rsync

      # Download MySQL APT config package
      wget -q https://dev.mysql.com/get/mysql-apt-config_0.8.32-1_all.deb -O /tmp/mysql-apt-config.deb

      # Pre-seed mysql-apt-config to avoid interactive prompts
      echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.0" | debconf-set-selections
      echo "mysql-apt-config mysql-apt-config/select-tools select Enabled" | debconf-set-selections
      echo "mysql-apt-config mysql-apt-config/select-preview select Disabled" | debconf-set-selections
      DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb

      # MySQL's GPG key B7B3B788A8D3785C is expired (known issue).
      # Replace signed-by with trusted=yes to bypass the expired key check.
      sed -i 's|\[signed-by=/usr/share/keyrings/mysql-apt-config.gpg\]|[trusted=yes]|g' /etc/apt/sources.list.d/mysql.list

      apt-get update -y

      # Pre-seed root password to avoid interactive prompts
      echo "mysql-community-server mysql-community-server/root-pass password $MYSQL_ROOT_PASS" | debconf-set-selections
      echo "mysql-community-server mysql-community-server/re-root-pass password $MYSQL_ROOT_PASS" | debconf-set-selections

      DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-community-server

      echo "MySQL installed successfully."
      mysql --version

      # -----------------------------------------------------------------------
      # 3. Stop MySQL and move data directory to data disk
      # -----------------------------------------------------------------------
      echo "Moving MySQL data directory to data disk..."
      systemctl stop mysql

      rsync -av /var/lib/mysql/ "$MOUNT_POINT/mysql/"
      chown -R mysql:mysql "$MOUNT_POINT/mysql"

      # Update MySQL config to use new data directory
      printf '[mysqld]\ndatadir = %s/mysql\n' "$MOUNT_POINT" > /etc/mysql/mysql.conf.d/custom-datadir.cnf

      # Update AppArmor if present
      if [ -f /etc/apparmor.d/usr.sbin.mysqld ]; then
        sed -i "s|/var/lib/mysql/|$MOUNT_POINT/mysql/|g" /etc/apparmor.d/usr.sbin.mysqld
        apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || true
      fi

      systemctl start mysql

      # -----------------------------------------------------------------------
      # 4. Configure root access for remote connections
      # -----------------------------------------------------------------------
      echo "Configuring MySQL root access..."
      mysql -u root -p"$MYSQL_ROOT_PASS" -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASS';"
      mysql -u root -p"$MYSQL_ROOT_PASS" -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASS';"
      mysql -u root -p"$MYSQL_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
      mysql -u root -p"$MYSQL_ROOT_PASS" -e "FLUSH PRIVILEGES;"

      # Enable remote connections
      sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true

      systemctl restart mysql

      # -----------------------------------------------------------------------
      # 5. Download and import the Sakila sample database
      # -----------------------------------------------------------------------
      echo "Downloading Sakila database..."
      cd /tmp
      wget -q https://downloads.mysql.com/docs/sakila-db.tar.gz -O sakila-db.tar.gz
      tar -xzf sakila-db.tar.gz

      echo "Importing Sakila schema..."
      mysql -u root -p"$MYSQL_ROOT_PASS" < /tmp/sakila-db/sakila-schema.sql

      echo "Importing Sakila data..."
      mysql -u root -p"$MYSQL_ROOT_PASS" < /tmp/sakila-db/sakila-data.sql

      # Verify
      echo "Verifying Sakila installation..."
      mysql -u root -p"$MYSQL_ROOT_PASS" -e "USE sakila; SHOW TABLES; SELECT COUNT(*) AS total_actors FROM actor;"

      # Cleanup
      rm -rf /tmp/sakila-db /tmp/sakila-db.tar.gz /tmp/mysql-apt-config.deb

      # -----------------------------------------------------------------------
      # 6. Mark setup complete
      # -----------------------------------------------------------------------
      touch "$SENTINEL"
      echo "=== MySQL setup complete. Sakila database imported. ==="
    EOFSCRIPT
  }
}

# =============================================================================
# FIREWALL RULES — MySQL access
# =============================================================================
resource "google_compute_firewall" "allow_mysql" {
  name    = "${var.mysql_vm_name}-allow-mysql"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }

  # Restricted ingress — see var.mysql_allowed_cidrs for composition.
  source_ranges = var.mysql_allowed_cidrs
  target_tags   = ["mysql-server"]
}

resource "google_compute_firewall" "allow_mysql_ssh" {
  name    = "${var.mysql_vm_name}-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Admin workstations only — DMS does not need SSH.
  source_ranges = var.mysql_admin_cidrs
  target_tags   = ["mysql-server"]
}

# =============================================================================
# OUTPUTS — COMPUTE ENGINE MYSQL VM
# =============================================================================
output "mysql_vm_name" {
  description = "Name of the MySQL VM"
  value       = google_compute_instance.mysql_vm.name
}

output "mysql_vm_external_ip" {
  description = "External IP of the MySQL VM (use for MySQL client connections)"
  value       = google_compute_instance.mysql_vm.network_interface[0].access_config[0].nat_ip
}

output "mysql_vm_internal_ip" {
  description = "Internal IP of the MySQL VM"
  value       = google_compute_instance.mysql_vm.network_interface[0].network_ip
}

output "mysql_vm_ssh_command" {
  description = "SSH into the MySQL VM"
  value       = "gcloud compute ssh ${google_compute_instance.mysql_vm.name} --zone=${var.mysql_vm_zone}"
}

output "mysql_connection_command" {
  description = "Connect to MySQL from a remote client"
  value       = "mysql -h <EXTERNAL_IP> -u root -p"
}

# #############################################################################
# DATABASE MIGRATION SERVICE (DMS) — REVERSE-ENGINEERED FROM LIVE PROJECT
# #############################################################################
# Reverse-engineered on 2026-05-11 from the live DMS configuration in
# project `dre-sandbox-471618`, region `us-central1`, using:
#   gcloud database-migration migration-jobs list/describe
#   gcloud database-migration connection-profiles list/describe
#
# DISCOVERED RESOURCES
# --------------------
# Connection profiles (2):
#   1. mdmysql        SOURCE      MySQL     @ 10.138.0.9:3306 (the GCE MySQL VM)
#   2. sakilamysql    DESTINATION Cloud SQL MySQL 8.4 Enterprise Plus (REGIONAL HA)
#
# Migration jobs (1):
#   1. mdmysql      MySQL    -> Cloud SQL    CONTINUOUS  (state: RUNNING, phase: CDC)
#                   Uses VPC peering connectivity over the "default" network.
#                   Logical dump, OPTIMAL parallelism, all objects.
#
# (The live SQL Server profile `stackoverflow` and job `gcdbmsmove` exist in
# the project but are intentionally omitted from this file: the
# hashicorp/google 6.x provider has no schema for SQL Server source profiles
# or the SQL Server homogeneous job config. Manage those via gcloud/console.)
#
# IMPORTANT — IMPORT BEFORE APPLY
# -------------------------------
# These resources ALREADY EXIST in GCP. If you `terraform apply` without
# importing first, Terraform will try to CREATE duplicates and fail (name
# conflict). To bring the existing resources under management:
#
#   terraform import \
#     google_database_migration_service_connection_profile.mdmysql \
#     projects/dre-sandbox-471618/locations/us-central1/connectionProfiles/mdmysql
#
#   terraform import \
#     google_database_migration_service_connection_profile.sakilamysql \
#     projects/dre-sandbox-471618/locations/us-central1/connectionProfiles/sakilamysql
#
#   terraform import \
#     google_database_migration_service_migration_job.mdmysql \
#     projects/dre-sandbox-471618/locations/us-central1/migrationJobs/mdmysql
#
# The `stackoverflow` connection profile and `gcdbmsmove` migration job
# CANNOT be imported — the hashicorp/google v6.x provider does not yet
# support SQL Server source profiles or the SQL Server homogeneous job
# config block. Manage those two resources via gcloud or the console.
#
# After import, run `terraform plan` and reconcile any drift between this file
# and the actual config. Passwords are NEVER returned by the API (only
# passwordSet=true is shown), so you MUST supply them via -var or a tfvars file.
# #############################################################################

# =============================================================================
# DMS VARIABLES — passwords for source/destination connection profiles
# =============================================================================
# DMS connection profiles store credentials but the API never reads them back.
# Terraform will therefore always show a "password" diff after import unless
# you set `lifecycle { ignore_changes = [...] }` (see below). Supply real
# passwords at apply time:
#   terraform apply \
#     -var="dms_source_mysql_password=..." \
#     -var="dms_destination_cloudsql_root_password=..."
# =============================================================================

variable "dms_region" {
  description = "GCP region where the DMS connection profiles and jobs live."
  default     = "us-central1"
}

variable "dms_source_mysql_password" {
  description = "Password for the SOURCE MySQL connection profile (mdmysql @ 10.138.0.9). Not returned by API after creation."
  sensitive   = true
  default     = ""
}

variable "dms_destination_cloudsql_root_password" {
  description = "Root password for the DESTINATION Cloud SQL MySQL instance (sakilamysql). Not returned by API after creation."
  sensitive   = true
  default     = ""
}

# =============================================================================
# DMS CONNECTION PROFILE — SOURCE MySQL (mdmysql)
# =============================================================================
# Points DMS at the self-managed MySQL 8 VM created earlier in this file.
# Host 10.138.0.9 is the internal IP of `gcdbms-mysqlvm-01` on the default VPC
# at the time of capture. If that VM is recreated, the IP may change — consider
# reserving a static internal IP and referencing it via
# `google_compute_instance.mysql_vm.network_interface[0].network_ip`.
#
# `ssl {}` is present in the live config but empty, meaning SSL is allowed but
# not enforced. For production add `ssl { type = "SERVER_ONLY" }` or stronger.
# =============================================================================
resource "google_database_migration_service_connection_profile" "mdmysql" {
  location              = var.dms_region
  connection_profile_id = "mdmysql"
  display_name          = "mdmysql"
  labels                = local.labels

  mysql {
    host     = "10.138.0.9"
    port     = 3306
    username = "root"
    password = var.dms_source_mysql_password

    # Empty SSL block matches live config (SSL allowed but not enforced).
    ssl {
      type = "NONE"
    }
  }

  # The GCP Database Migration API silently rewrites credential fields on every
  # update and never returns them on read. Combined with the fact that label
  # changes alone trigger a full update, leaving these attributes managed by
  # Terraform will repeatedly clobber the live password and break the running
  # CDC job. Manage labels and credentials out-of-band (gcloud / console) and
  # ignore them here. The `mysql` block is ignored wholesale because any
  # nested change forces the whole block to be re-sent.
  lifecycle {
    ignore_changes = [
      mysql,
      labels,
      terraform_labels,
      effective_labels,
    ]
  }
}

# =============================================================================
# DMS CONNECTION PROFILE — DESTINATION Cloud SQL MySQL 8.4 (sakilamysql)
# =============================================================================
# REMOVED FROM TERRAFORM MANAGEMENT (2026-05-12).
#
# The GCP Database Migration API rejects updates to non-DRAFT CLOUDSQL
# connection profiles with:
#   Error 400: Updating a non-draft CLOUDSQL connection profile isn't supported yet
# This means ANY terraform apply that touches this resource (even just a
# label change) will fail. The block below is preserved for documentation
# only — do NOT uncomment without first removing the live profile or until
# Google adds update support.
#
# Live management of `sakilamysql`:
#   - Read:    gcloud database-migration connection-profiles describe sakilamysql \
#                --project=dre-sandbox-471618 --region=us-central1
#   - Modify:  via the GCP Console (and only on a DRAFT profile, in practice).
#
# The migration job's `destination` attribute below now references the
# resource by its full literal ID instead of via this resource block.
# =============================================================================
# resource "google_database_migration_service_connection_profile" "sakilamysql" {
#   location              = var.dms_region
#   connection_profile_id = "sakilamysql"
#   display_name          = "sakilamysql"
#   labels                = local.labels
#
#   cloudsql {
#     settings {
#       database_version      = "MYSQL_8_4"
#       edition               = "ENTERPRISE_PLUS"
#       tier                  = "db-perf-optimized-N-8"
#       zone                  = "us-central1-f"
#       data_disk_type        = "PD_SSD"
#       data_disk_size_gb     = "100"
#       auto_storage_increase = true
#       root_password         = var.dms_destination_cloudsql_root_password
#
#       source_id = "projects/dre-sandbox-471618/locations/${var.dms_region}/connectionProfiles/mdmysql"
#
#       ip_config {
#         enable_ipv4     = false
#         private_network = "projects/dre-sandbox-471618/global/networks/default"
#       }
#     }
#   }
#
#   lifecycle {
#     ignore_changes = [cloudsql[0].settings[0].root_password]
#   }
#
#   depends_on = [google_database_migration_service_connection_profile.mdmysql]
# }

# =============================================================================
# DMS MIGRATION JOB — mdmysql (MySQL VM -> Cloud SQL MySQL, CONTINUOUS)
# =============================================================================
# Heterogeneous-shaped but actually homogeneous MySQL -> MySQL continuous
# migration. Uses VPC peering connectivity over the `default` network so DMS
# can reach the private IP of the source MySQL VM (10.138.0.9).
#
# Live state at capture: state=RUNNING, phase=CDC (already past initial dump
# and streaming change data). Re-applying with `state` set explicitly can
# disrupt the running job — the resource intentionally omits `state`/`phase`
# so Terraform won't fight DMS over runtime status.
#
# Performance: dump_parallel_level = OPTIMAL lets DMS pick the parallelism
# based on source size and tier. Override to MAX or MIN if needed.
# =============================================================================
resource "google_database_migration_service_migration_job" "mdmysql" {
  location         = var.dms_region
  migration_job_id = "mdmysql"
  display_name     = "mdmysql"
  labels           = local.labels

  type      = "CONTINUOUS" # CONTINUOUS = initial dump + ongoing CDC; ONE_TIME = dump only
  dump_type = "LOGICAL"    # LOGICAL = mysqldump-style; PHYSICAL not supported for MySQL here

  source      = google_database_migration_service_connection_profile.mdmysql.id
  # sakilamysql is no longer managed by Terraform (see comment above its
  # removed resource block). Reference the live profile by its literal ID.
  destination = "projects/dre-sandbox-471618/locations/${var.dms_region}/connectionProfiles/sakilamysql"

  # NOTE — provider v6.x does NOT expose `source_database` or
  # `destination_database` blocks on this resource. Engine info (MYSQL/CLOUDSQL)
  # is inferred automatically from the linked connection profiles.

  performance_config {
    dump_parallel_level = "OPTIMAL"
  }

  vpc_peering_connectivity {
    vpc = "projects/dre-sandbox-471618/global/networks/default"
  }

  # NOTE: `state` and `phase` are read-only/computed in the provider schema, so
  # they don't need to be listed in `ignore_changes`. Terraform will never try
  # to write them. To start/stop/promote a running job, use gcloud:
  #   gcloud database-migration migration-jobs start  mdmysql --region=us-central1
  #   gcloud database-migration migration-jobs promote mdmysql --region=us-central1
}

# =============================================================================
# OUTPUTS — DMS
# =============================================================================
output "dms_source_mysql_profile" {
  description = "Resource name of the source MySQL connection profile."
  value       = google_database_migration_service_connection_profile.mdmysql.name
}

output "dms_destination_cloudsql_profile" {
  description = "Resource name of the destination Cloud SQL connection profile (managed out-of-band; not in Terraform state)."
  value       = "projects/dre-sandbox-471618/locations/${var.dms_region}/connectionProfiles/sakilamysql"
}

output "dms_mysql_migration_job" {
  description = "Resource name of the running MySQL -> Cloud SQL migration job."
  value       = google_database_migration_service_migration_job.mdmysql.name
}
