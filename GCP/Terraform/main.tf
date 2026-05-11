# =============================================================================
# TERRAFORM CONFIGURATION
# =============================================================================
# This block tells Terraform which providers (plugins) are needed.
# Providers are how Terraform talks to cloud APIs — in this case, Google Cloud.
# "~> 6.0" means any version >= 6.0 and < 7.0 (pessimistic constraint).
# =============================================================================
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"    # Download from HashiCorp's registry
      version = "~> 6.0"              # Pin to major version 6.x
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
# Locals let you define values once and reuse them across multiple resources.
# GCP uses "labels" instead of Azure "tags" — same concept, different name.
# Label keys/values must be lowercase, max 63 chars, letters/numbers/hyphens only.
# =============================================================================
locals {
  labels = {
    application = "content-services"
    cost-center = "2650"
    created-by  = "michael-dspain"
    environment = "dev"
    owner       = "cpie-dre"
    service     = "content-services"
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
    tier              = "db-custom-24-159744"   # 24 vCPUs, 156 GB RAM (max at 6.5 GB/vCPU)
    edition           = "ENTERPRISE"             # Enterprise Plus is not available for SQL Server
    availability_type = "ZONAL"                  
    disk_type         = "PD_SSD"                 # PD_SSD is the correct disk for this tier
    disk_size         = 1000                     
    disk_autoresize   = true                     
    disk_autoresize_limit = 2000             # Auto-grow when space is low
  
    user_labels = local.labels

    # Automated backup configuration
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true       # PITR via transaction logs
      start_time                     = "04:00"    # Daily backup window (UTC)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7                      # Keep 7 daily backups
      }
    }

    # Maintenance window — Sunday 5 AM UTC
    maintenance_window {
      day          = 7    # Sunday (1=Mon, 7=Sun)
      hour         = 5    # 5 AM UTC
      update_track = "stable"
    }

    # IP configuration — public IP with no authorized networks by default.
    # Add authorized_networks blocks to restrict access by IP/CIDR,
    # or switch to private IP via private_network.
    ip_configuration {
      ipv4_enabled = true
    }

    # SQL Server-specific flags
    database_flags {
      name  = "remote access"
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
      size  = 200    # GB
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
resource "google_compute_disk" "sql_data_disk" {
  name  = "${var.vm_name}-data"
  type  = "pd-ssd"
  zone  = var.vm_zone
  size  = 500    # GB
  labels = local.labels
}

# =============================================================================
# FIREWALL RULES — RDP and SQL Server access
# =============================================================================
# These rules allow inbound traffic to the VM. Restrict source_ranges to your
# office/VPN CIDR blocks for production use. 0.0.0.0/0 is open to the internet.
# =============================================================================
resource "google_compute_firewall" "allow_rdp" {
  name    = "${var.vm_name}-allow-rdp"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]    # TODO: Restrict to your IP/CIDR
  target_tags   = ["sql-server"]
}

resource "google_compute_firewall" "allow_sql" {
  name    = "${var.vm_name}-allow-sql"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["1433"]
  }

  source_ranges = ["0.0.0.0/0"]    # TODO: Restrict to your IP/CIDR
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

# =============================================================================
# DATA DISK — Separate SSD for MySQL data
# =============================================================================
resource "google_compute_disk" "mysql_data_disk" {
  name   = "${var.mysql_vm_name}-data"
  type   = "pd-ssd"
  zone   = var.mysql_vm_zone
  size   = 200    # GB
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
      size  = 50     # GB
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

  source_ranges = ["0.0.0.0/0"]    # TODO: Restrict to your IP/CIDR
  target_tags   = ["mysql-server"]
}

resource "google_compute_firewall" "allow_mysql_ssh" {
  name    = "${var.mysql_vm_name}-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]    # TODO: Restrict to your IP/CIDR
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