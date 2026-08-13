<#
.SYNOPSIS
  Grant CRUD (or read-only) + default privileges to a Cloud SQL Postgres role across
  one or more databases on a Cloud SQL instance.

.DESCRIPTION
  Implements a three-tier group-role model on the Cloud SQL instance:
    - app_ro   : SELECT on tables + SELECT on sequences (currval only)
    - app_rw   : SELECT/INSERT/UPDATE/DELETE on tables + USAGE/SELECT/UPDATE on sequences
    - app_ddl  : ALL on tables + ALL on sequences + CREATE on schemas + object ownership

  Every run bootstraps all three group roles cluster-wide (idempotent, NOLOGIN) and
  wires their standard permission tier on every non-system schema in every target
  database, including DEFAULT PRIVILEGES for future objects created by either the
  admin session or by app_ddl. Finally, the mode flag selects which group role the
  IAM principal (-Role) is granted membership in.

  Mode → group role mapping (default is READ-ONLY — safest for prod):
    - default    → GRANT app_ro  TO -Role
    - -ReadOnly  → GRANT app_ro  TO -Role  (explicit; same as default)
    - -ReadWrite → GRANT app_rw  TO -Role
    - -GrantDdl  → GRANT app_ddl TO -Role  (plus reassigns existing object ownership to app_ddl)

  Idempotent — safe to re-run.

  Pre-flight: verifies -Role is already registered on the instance as an IAM user,
  group, or service account (via `gcloud sql users list`). IAM principals are
  provisioned via Terraform — this script does not create them. The three group
  roles (app_ro/app_rw/app_ddl) ARE managed by this script; do not manage them via
  Terraform.

  Connectivity: all Cloud SQL Postgres instances in this fleet are PSC-enabled and
  are reached via `cloud-sql-proxy --psc` on a loopback port. The script launches
  the proxy in-process, adds an /etc/hosts entry for the PSC dnsName when needed
  (one sudo prompt), waits for the loopback listener, runs grants, then kills the
  proxy in a finally block. TLS terminates at the proxy → PGSSLMODE=disable on
  loopback.

  Script fails fast if the target instance is not PSC-enabled (the fleet
  convention is PSC-only; a public/private-IP-only instance is a policy drift).

  Credentials: the admin password lives in $env:PGPASSWORD only for the child psql
  process, then is cleared in the finally block. Omit -PasswordFile to be prompted
  (recommended on macOS/pwsh 7 — no DPAPI).

.PARAMETER Role
  Postgres role to grant to. For IAM service accounts on Cloud SQL, use the SA email
  WITHOUT the ".gserviceaccount.com" suffix, e.g. portal-sa@vz-inscape-portfolio-dev.iam
  For IAM user accounts, use the full email, e.g. user@vizio.com

.PARAMETER Instance
  Cloud SQL instance name (short name, e.g. admin-portal-db).

.PARAMETER Project
  GCP project ID that owns the instance.

.PARAMETER AllDatabases
  Switch. Auto-discover all connectable databases via pg_database, minus
  -ExcludeDatabases. Mutually exclusive with -Databases.

.PARAMETER Databases
  Explicit array of database names. Mutually exclusive with -AllDatabases.

.PARAMETER ExcludeDatabases
  Databases to skip when -AllDatabases is used. Ignored otherwise.
  Default: template0, template1, cloudsqladmin, postgres, pmm.

.PARAMETER AdminUser
  Postgres admin login (member of cloudsqlsuperuser). Default 'postgres'.

.PARAMETER PasswordFile
  Optional path to a secure-string file for the admin password. Create with:
    Read-Host -AsSecureString | ConvertFrom-SecureString | Set-Content <path>
  On macOS/pwsh 7 the file is AES-encrypted with a session-scoped key — usable only
  on the same host/user session that created it. Omit to be prompted interactively.

.PARAMETER ReadOnly
  Switch. Grants app_ro membership to -Role. This is the DEFAULT when no mode
  switch is passed — the flag is retained as an explicit.  Effective perms the
  IAM principal inherits via app_ro:
    - Tables:    SELECT
    - Sequences: SELECT (allows currval; blocks nextval)
    - Default privileges: SELECT on future tables and sequences
  All three group roles (app_ro/app_rw/app_ddl) are always provisioned regardless of
  this flag — the flag only selects which one the IAM principal joins.
  Mutually exclusive with -ReadWrite and -GrantDdl.

.PARAMETER ReadWrite
  Switch. Grants app_rw membership to -Role. Required to opt into write access —
  the default (no switch) is READ-ONLY. Effective perms via app_rw:
    - Tables:    SELECT, INSERT, UPDATE, DELETE
    - Sequences: USAGE, SELECT, UPDATE
    - Default privileges: same on future objects
  Mutually exclusive with -ReadOnly and -GrantDdl.

.PARAMETER GrantDdl
  Switch. Grants app_ddl membership to -Role instead of app_rw, and reassigns
  ownership of every existing user object in every target database to app_ddl
  (skipping extension-owned). Postgres has no grantable ALTER privilege, so full
  DDL (ALTER, DROP, ADD COLUMN, CREATE INDEX, CREATE TABLE) requires ownership —
  granted here via app_ddl, not to the IAM principal directly. Also seeds
  ALL default privileges on future functions in every schema for app_ddl.
  Mutually exclusive with -ReadOnly and -ReadWrite. Blast radius: reassigns
  ownership of every user object in every target DB to app_ddl — verify no
  tooling depends on the previous owner before running against stage/prod.

.PARAMETER TakeOwnership
  Switch. Transfer ownership of every existing user object (tables, partitioned
  tables, views, matviews, sequences, foreign tables, functions) to app_ddl,
  skipping extension-owned. Additive to the mode-selected group grant — does NOT
  itself grant app_ddl membership to -Role, and does NOT broaden default
  privileges to ALL on functions. Use this when you want the ownership tier
  reassigned to app_ddl but do NOT want the IAM principal to inherit DDL (e.g.
  the principal only needs app_rw). Requires -ReadWrite or -GrantDdl —
  reassigning ownership under a read-only grant makes no sense. Redundant when
  combined with -GrantDdl (which already implies ownership transfer).

.PARAMETER PostDmsPromote
  Switch. Post-promotion cleanup for a Cloud SQL Postgres instance that was the
  destination of a GCP Database Migration Service (DMS) job. Before the normal
  bootstrap/grant flow, drops any leftover `pglogical` extension + schema and
  resets every table-owned sequence to GREATEST(last_value, MAX(col)) — DMS uses
  pglogical logical replication, which does NOT sync sequence current values, so
  first inserts on the destination collide on the PK without this. After grants,
  runs ANALYZE across user schemas because logical replication leaves pg_stat
  empty. Requires -GrantDdl.  every migrated object is owned by `postgres` on the destination and must be
  reassigned to app_ddl. Run ONLY after the DMS job has been promoted (the
  DROP EXTENSION pglogical will fail while replication is still active).

.PARAMETER ProxyBinary
  Path/name of the Auth Proxy binary. Auto-detects `cloud-sql-proxy` (v2) then
  `cloud_sql_proxy` (v1). Override only when both are missing from PATH.

.PARAMETER ProxyPort
  Loopback port the proxy listens on. Default 5433. Change if 5433 is already in use.

.PARAMETER SkipHostsEntry
  Switch. Skip the automatic `/etc/hosts` entry for PSC dnsNames. Use when your VPN
  already provides private DNS resolution for `.sql.goog` so the script doesn't need
  sudo. Ignored on non-PSC instances.

.EXAMPLE
  # Recommended: interactive password prompt. Auth Proxy is always used.
  # Default mode is READ-ONLY — pass -ReadWrite for CRUD.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases `
    -ReadWrite

.EXAMPLE
  # Grant DDL (ownership transfer + CREATE on schemas) so the role can run migrations
  # — ALTER TABLE, ADD COLUMN, CREATE INDEX, DROP TABLE, CREATE TABLE.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') `
    -GrantDdl

.EXAMPLE
  # Hand a DB off to a service account: RW group grant + transfer ownership of
  # every existing table/view/sequence/function to app_ddl. -TakeOwnership requires
  # -ReadWrite (or -GrantDdl); the SA gets CRUD via app_rw, and app_ddl now owns
  # existing objects.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') `
    -ReadWrite -TakeOwnership

.EXAMPLE
  # PSC-fronted instance (fleet default). Script adds an /etc/hosts entry for the
  # PSC dnsName (one sudo prompt) and passes --psc to the proxy.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') `
    -ReadWrite

.EXAMPLE
  # Same PSC instance but DNS is already served by your VPN's private zone —
  # skip the /etc/hosts management (no sudo needed).
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases `
    -SkipHostsEntry -ReadWrite

.EXAMPLE
  # Targeted grant on a subset of databases via the Auth Proxy on a custom port.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'tvevents-sa@vz-inscape-portfolio-stage.iam' `
    -Instance tvcdb-stage -Project 'vz-inscape-portfolio-stage' `
    -Databases @('tvevents','tvlocation','dai_demapping','app_whitelist','optout') `
    -ProxyPort 5440 -ReadWrite

.EXAMPLE
  # Read-only grant for an auditor / reporting SA.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'reporting-sa@vz-inscape-portfolio-stage.iam' `
    -Instance tvcdb-stage -Project 'vz-inscape-portfolio-stage' `
    -Databases @('tvevents','tvlocation') `
    -ReadOnly

.EXAMPLE
  # Non-interactive: use a saved secure-string password file.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases -ReadWrite `
    -PasswordFile "$HOME/.secure/admin-portal-db-postgres.txt"

.EXAMPLE
  # Post-DMS promotion: run once after the Database Migration Service job is
  # promoted. Drops pglogical leftovers, realigns sequences to MAX(col),
  # reassigns ownership of every migrated object off 'postgres' onto app_ddl,
  # grants app_ddl membership to the app SA, then ANALYZEs. -GrantDdl is required.
  ./Grant-CloudSQLPgRole.ps1 `
    -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
    -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
    -AllDatabases -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') `
    -GrantDdl -PostDmsPromote

.NOTES
  Proxy logs: /tmp/cloudsql-proxy-<PID>.log (stdout) and .err (stderr).
  Cleanup: PGPASSWORD is always cleared and the proxy is always killed via finally,
  even on Ctrl-C or SQL error.
#>

[CmdletBinding(DefaultParameterSetName = 'AllDatabases')]
param(
    # Postgres role receiving the grants. For IAM service accounts, use the SA email
    # WITHOUT '.gserviceaccount.com', e.g. 'portal-sa@vz-inscape-portfolio-dev.iam'.
    # For IAM user accounts, use the full email, e.g. 'user@vizio.com'. The role must
    # already exist as a Cloud SQL IAM principal — provisioned via Terraform, not here.
    [Parameter(Mandatory)]
    [string]$Role,

    # Cloud SQL instance short name (e.g. 'admin-portal-db'). Used for the IAM
    # pre-flight check and for `gcloud sql instances describe` to verify PSC and
    # read the PSC dnsName + endpoint IP for the /etc/hosts entry.
    [Parameter(Mandatory)]
    [string]$Instance,

    # GCP project ID that owns -Instance. Passed to every gcloud call.
    [Parameter(Mandatory)]
    [string]$Project,

    # PARAMETER SET ANCHOR: 'AllDatabases'. Auto-discover every connectable database
    # via `SELECT datname FROM pg_database WHERE datallowconn`, minus -ExcludeDatabases.
    # Mutually exclusive with -Databases (parameter binder enforces one-or-the-other
    # at parse time).
    [Parameter(ParameterSetName = 'AllDatabases', Mandatory)]
    [switch]$AllDatabases,

    # PARAMETER SET ANCHOR: 'SpecificDatabases'. Explicit list of database names,
    # e.g. -Databases @('tvevents','tvlocation'). Skips the pg_database discovery
    # query entirely. Mutually exclusive with -AllDatabases.
    [Parameter(ParameterSetName = 'SpecificDatabases', Mandatory)]
    [string[]]$Databases,

    # DBs to skip when -AllDatabases is used. Ignored in the 'SpecificDatabases' set.
    # Defaults exclude Cloud SQL management DBs, template DBs, and the pmm monitoring DB.
    [Parameter(ParameterSetName = 'AllDatabases')]
    [string[]]$ExcludeDatabases = @('template0','template1','cloudsqladmin','postgres','pmm'),

    # Postgres admin login used to run the grants and ownership DDL. Must be a member
    # of `cloudsqlsuperuser` on Cloud SQL — 'postgres' is the built-in default.
    [string]$AdminUser = 'postgres',

    # Optional secure-string file for the admin password. Create with:
    #   Read-Host -AsSecureString | ConvertFrom-SecureString | Set-Content <path>
    # Omit to be prompted interactively. On macOS/pwsh 7 the file is AES-encrypted
    # with a session-scoped key — usable only on the same host/user session.
    [string]$PasswordFile,

    # MODE: read-only. NOW THE DEFAULT — passing this switch is equivalent to passing
    # nothing. Retained as an explicit self-documenting opt-in and for back-compat.
    # Grants app_ro membership to -Role (SELECT on tables, SELECT on sequences).
    # Mutually exclusive with -ReadWrite, -GrantDdl, and -TakeOwnership.
    [switch]$ReadOnly,

    # MODE: read-write. Grants app_rw membership to -Role
    # (SELECT/INSERT/UPDATE/DELETE on tables, USAGE/SELECT/UPDATE on sequences).
    # Required to opt into write access — default is now READ-ONLY.
    # Mutually exclusive with -ReadOnly and -GrantDdl.
    [switch]$ReadWrite,

    # MODE: full DDL. Runs ownership transfer of every existing table/view/matview/
    # sequence/foreign table/function (excluding extension-owned) to app_ddl, plus
    # grants app_ddl membership to -Role. Mutually exclusive with -ReadOnly and
    # -ReadWrite. Blast radius: reassigns owner on every user object in every
    # target DB — verify no tooling depends on the previous owner before running
    # against stage/prod.
    [switch]$GrantDdl,

    # MODE modifier: transfer ownership of existing user objects to app_ddl WITHOUT
    # granting app_ddl membership to -Role. Additive to -ReadWrite. Requires
    # -ReadWrite or -GrantDdl. Redundant with -GrantDdl (already implies transfer).
    [switch]$TakeOwnership,

    # Post-DMS promotion cleanup. Run this against a Cloud SQL Postgres instance
    # that was the destination of a GCP Database Migration Service job and has just
    # been promoted. Drops pglogical leftovers, resets every table-owned sequence
    # to MAX(col) (DMS/pglogical does not sync sequence current values), then runs
    # the normal bootstrap/ownership/grant flow, then ANALYZEs user schemas.
    # Requires -GrantDdl: freshly promoted destinations always need ownership
    # reassigned off 'postgres' onto app_ddl.
    [switch]$PostDmsPromote,

    # Override the Auth Proxy binary. Auto-detects `cloud-sql-proxy` (v2) then
    # `cloud_sql_proxy` (v1) on PATH. Set only if neither is on PATH.
    [string]$ProxyBinary,

    # Loopback port the Auth Proxy listens on. Default 5433 (avoids collision with a
    # local Postgres on 5432). Change if 5433 is already in use.
    [int]   $ProxyPort = 5433,

    # Skip the automatic /etc/hosts entry that the script adds for PSC dnsNames.
    # PSC endpoints resolve only via a customer-managed private DNS zone; if your
    # VPN already forwards `.sql.goog` to Cloud DNS you don't need the hosts entry
    # (and don't want the sudo prompt). Ignored on non-PSC instances.
    [switch]$SkipHostsEntry
)

# Any uncaught error (throw, non-zero cmdlet, ErrorRecord from a native call handled
# via 2>&1) terminates the script instead of continuing. Required for the try/finally
# cleanup below to actually fire on failure.
$ErrorActionPreference = 'Stop'

# Mode-switch guardrails: reject combinations that would either contradict themselves
# or silently upgrade a read-only grant into full write access. Enforced here rather
# than via ParameterSet so the error message is explicit about *why* it's rejected.
if ($ReadOnly -and $ReadWrite) {
    throw "-ReadOnly and -ReadWrite are mutually exclusive."
}
if ($ReadOnly -and $GrantDdl) {
    throw "-ReadOnly and -GrantDdl are mutually exclusive: ownership implies full access."
}
if ($ReadWrite -and $GrantDdl) {
    throw "-ReadWrite and -GrantDdl are mutually exclusive: DDL already includes write access."
}
if ($ReadOnly -and $TakeOwnership) {
    throw "-ReadOnly and -TakeOwnership are mutually exclusive: an owner can do anything, which defeats read-only."
}
if ($TakeOwnership -and -not ($ReadWrite -or $GrantDdl)) {
    throw "-TakeOwnership requires -ReadWrite or -GrantDdl. The default mode is read-only, and reassigning object ownership under a read-only grant makes no sense."
}
if ($PostDmsPromote -and -not $GrantDdl) {
    throw "-PostDmsPromote requires -GrantDdl. A freshly DMS-promoted instance has every migrated object owned by 'postgres' — a read-only or read-write grant without ownership reassignment leaves the destination in a broken state."
}

# Tool preflight: fail fast with an actionable message instead of a cryptic
# "command not found" mid-run. psql runs the grants; gcloud is used for the IAM
# user check and `sql instances describe` to read the PSC dnsName + endpoint IP
# for the /etc/hosts entry.
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "psql not found on PATH. Install postgresql-client or add it to PATH."
}
# gcloud is used for the IAM principal pre-flight (`sql users list`) and
# `sql instances describe` to verify PSC and read the PSC dnsName + endpoint IP
# for the /etc/hosts entry.
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    throw "gcloud not found on PATH. Install the Google Cloud SDK: brew install --cask google-cloud-sdk"
}

# Pre-flight: verify the role exists on the Cloud SQL instance as an IAM principal.
# IAM users/groups/SAs are provisioned via Terraform — this script does not create them.
Write-Host "Verifying '$Role' exists on $Instance ($Project) as a Cloud SQL IAM principal..." -ForegroundColor DarkCyan
$usersJson = & gcloud sql users list --instance=$Instance --project=$Project --format=json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "gcloud sql users list failed:`n$usersJson"
    exit 1
}
$users = $usersJson | ConvertFrom-Json
$match = $users | Where-Object { $_.name -eq $Role -and $_.type -like 'CLOUD_IAM_*' }
if (-not $match) {
    Write-Error "Role '$Role' is not registered on Cloud SQL instance '$Instance' as an IAM user, group, or service account. IAM principals are provisioned via Terraform — fix the IaC and re-apply, then re-run this script."
    exit 1
}
Write-Host "Confirmed on Cloud SQL: $($match.name) [$($match.type)]" -ForegroundColor Green

# Resolve admin password → plaintext into PGPASSWORD only for the child psql process.
if ($PasswordFile) {
    if (-not (Test-Path $PasswordFile)) { throw "PasswordFile not found: $PasswordFile" }
    $secure = Get-Content $PasswordFile | ConvertTo-SecureString
} else {
    $secure = Read-Host -AsSecureString -Prompt "Postgres password for $AdminUser@$Instance"
}
$plain = ConvertFrom-SecureString -SecureString $secure -AsPlainText

$results = New-Object System.Collections.Generic.List[object]
$proxyProc = $null
try {

if (-not $ProxyBinary) {
    if     (Get-Command cloud-sql-proxy -ErrorAction SilentlyContinue) { $ProxyBinary = 'cloud-sql-proxy' }
    elseif (Get-Command cloud_sql_proxy -ErrorAction SilentlyContinue) { $ProxyBinary = 'cloud_sql_proxy' }
    else { throw "Neither 'cloud-sql-proxy' nor 'cloud_sql_proxy' found on PATH. Install with: brew install cloud-sql-proxy" }
}

$descJson = & gcloud sql instances describe $Instance --project=$Project --format=json 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to describe ${Instance} in ${Project}:`n$descJson" }
$desc = $descJson | ConvertFrom-Json
$connName = $desc.connectionName
if (-not $connName) { throw "connectionName missing from describe output for $Instance." }

$pscCfg = $desc.settings.ipConfiguration.pscConfig
if (-not $pscCfg.pscEnabled) {
    throw "$Instance is not PSC-enabled. This script assumes every Cloud SQL Postgres instance in the fleet uses PSC — fix the instance in Terraform (settings.ipConfiguration.pscConfig.pscEnabled = true) and re-run."
}

$proxyArgs = @('--port', "$ProxyPort", '--psc', $connName)

<#
PSC + hostname resolution for the Auth Proxy.

Why this block exists: a PSC-fronted Cloud SQL Postgres instance is reachable
ONLY via its private Service Attachment (a per-instance forwarding rule with a
private IP in the customer VPC). Google publishes a per-instance dnsName like
`<uid>.<region>.sql.goog.` which resolves to that private IP, but ONLY via a
customer-managed private DNS zone in Cloud DNS + inbound forwarding — there is
no public authoritative record. From a laptop off-VPN (or on-VPN without the
private zone forwarded), the OS resolver returns NXDOMAIN, cloud-sql-proxy
never opens a TCP socket, and the run fails before any SQL is sent.

cloud-sql-proxy v2 with `--psc <connectionName>` performs a plain OS-level
DNS lookup on the dnsName from `sql instances describe` — it does NOT call the
Cloud SQL Admin API a second time to translate the connectionName into an IP,
and it does NOT honor GCP internal DNS via metadata. If the OS can't resolve
the name, the proxy can't connect. Full stop.

The fleet-wide fix is a private DNS zone forwarded over the VPN. Until that's
in place on every operator's box, this block does the moral equivalent at the
host level: pin the dnsName to the PSC endpoint IP in /etc/hosts for the
duration of the run. One sudo prompt, idempotent (skipped if already present),
and out-of-scope for -SkipHostsEntry when the VPN already provides resolution.

The IP we pin is pscAutoConnections[0].ipAddress — the internal address of
the auto-created PSC endpoint (forwarding rule) that Terraform provisioned in
the shared VPC. On instances where the PSC endpoint was created MANUALLY
(no auto-connection), that array is empty and the script bails with an
actionable error — the operator has to look up the endpoint IP themselves
and pass -SkipHostsEntry.
#>

if (-not $SkipHostsEntry) {
    <# emits the dnsName with a trailing dot (FQDN form); strip it so
     both /etc/hosts matching and the write-out compare on the exact hostname.
     #>
    $dnsName = ($desc.dnsName -replace '\.$','')
    $pscIp   = @($pscCfg.pscAutoConnections)[0].ipAddress
    if (-not $dnsName) { throw "PSC instance $Instance has no dnsName." }
    if (-not $pscIp)   { throw "PSC instance $Instance has no pscAutoConnections[].ipAddress (manual PSC endpoint?). Add /etc/hosts entry manually and re-run with -SkipHostsEntry." }

    # Word-boundary match so `foo.sql.goog` doesn't false-positive on `bar-foo.sql.goog`.
    $hostsMatch = Select-String -Path /etc/hosts -Pattern "\s$([regex]::Escape($dnsName))(\s|$)" -Quiet -ErrorAction SilentlyContinue
    if (-not $hostsMatch) {
        Write-Host "Adding /etc/hosts entry: $pscIp $dnsName (sudo required) ..." -ForegroundColor DarkCyan
        # Trailing comment tags the line with the Cloud SQL connectionName so the
        # source is greppable later when cleaning up stale PSC entries.
        $line = "$pscIp`t$dnsName  # cloud-sql-proxy PSC $connName"
        $line | & sudo tee -a /etc/hosts | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to append to /etc/hosts. Fix DNS out-of-band and re-run with -SkipHostsEntry." }
    } else {
        Write-Host "/etc/hosts already resolves $dnsName; leaving it alone." -ForegroundColor DarkGray
    }
}

<#
Launch the Cloud SQL Auth Proxy as an in-process child.

What the proxy actually does: opens a local TCP listener on 127.0.0.1:$ProxyPort
and, for every connection accepted there, opens an mTLS tunnel to the Cloud SQL
instance's private Service Attachment (with --psc) and shovels bytes both ways.
The tunnel handshakes with the Cloud SQL Admin API for a short-lived
per-instance client cert using the operator's ADC (gcloud auth
application-default login) — so IAM DB Auth "just works" without us managing
certs, passwords for the SSL leg, or trust stores.

Why in-process and not a long-lived sidecar: this script is one-shot. Owning
the proxy's lifecycle in the try/finally guarantees it dies when the script
exits — including on Ctrl-C or a mid-run SQL error — so we don't leave an
orphan holding a loopback port that the next run collides on.

Why Start-Process with -NoNewWindow -PassThru: we need the PID immediately so
the readiness poll below can check HasExited (fail fast if the proxy dies
during startup) and so the finally block has a handle to Kill().

Why redirect stdout/stderr to files: -NoNewWindow leaves the child sharing our
console; without redirection, the proxy's log lines would interleave with the
per-DB grant output and destroy readability. On failure we tail these files
into the exception message so the caller sees WHY the proxy died.

Log path includes $PID (this script's PID, not the proxy's): guarantees
uniqueness if the operator fires two runs in parallel from different shells.
#>

Write-Host "Starting $ProxyBinary $($proxyArgs -join ' ') ..." -ForegroundColor DarkCyan
$proxyLog = "/tmp/cloudsql-proxy-$PID.log"
$proxyProc = Start-Process -FilePath $ProxyBinary `
                           -ArgumentList $proxyArgs `
                           -PassThru -NoNewWindow `
                           -RedirectStandardOutput $proxyLog `
                           -RedirectStandardError  "${proxyLog}.err"

# Wait up to ~20s for the local listener to accept connections, bailing early if the proxy exits.
$deadline = (Get-Date).AddSeconds(20)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if ($proxyProc.HasExited) { break }
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.Connect('127.0.0.1', $ProxyPort)
        $tcp.Close()
        $ready = $true
        break
    } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) {
    <#
    Readiness bail-out. The `-not $ready` condition fires in three distinct
    failure modes and this block exists to make them distinguishable:
      1. Deadline hit, proxy still alive but no listener — usually a PSC
         connection-name typo or DNS not resolving.
      2. $proxyProc.HasExited=true mid-loop — proxy crashed at startup: bad
         ADC, missing IAM role, PSC endpoint unreachable, 403 on the cert
         refresh call.
      3. Port already bound — Connect() throws ECONNREFUSED (or connects to
         something else) every 500ms; the loop's catch swallows it and we
         time out looking like case 1.
    Case 1 vs 2 is what the log tail is for. Case 3 you diagnose out-of-band
    (`lsof -i :$ProxyPort`) and re-run with -ProxyPort <different>.

    Why consume both files: -NoNewWindow + RedirectStandard* buries the proxy's
    real error message in /tmp/cloudsql-proxy-<PID>.log.err. Without this
    tail-and-attach the operator sees only "failed to become ready on
    127.0.0.1:5433" with zero signal about which of the three cases hit.

    -Raw reads the whole file as a single string (preserves whitespace, skips
    per-line pipeline). SilentlyContinue on Get-Content covers the tiny race
    where Test-Path saw the file but it was truncated a moment later — we
    don't want a secondary I/O error masking the real throw. `if ($content)`
    skips zero-byte redirect files so we don't append empty `--- path ---`
    headers to the exception message.
    #>

    $logTail = ''
    foreach ($f in @($proxyLog, "${proxyLog}.err")) {
        if (Test-Path $f) {
            $content = (Get-Content $f -Raw -ErrorAction SilentlyContinue)
            if ($content) { $logTail += "`n--- $f ---`n$content" }
        }
    }
    throw "Auth Proxy failed to become ready on 127.0.0.1:${ProxyPort}.$logTail"
}
Write-Host "Auth Proxy ready (PID $($proxyProc.Id))." -ForegroundColor Green

$env:PGHOST     = '127.0.0.1'
$env:PGPORT     = $ProxyPort
$env:PGUSER     = $AdminUser
$env:PGPASSWORD = $plain
# Proxy loopback is plaintext; TLS terminates at the proxy on the Cloud SQL leg.
$env:PGSSLMODE  = 'disable'
# Let NOTICE through so the DO block can log each grant it runs
$env:PGOPTIONS  = '-c client_min_messages=notice'

if ($AllDatabases) {
    <#
    -AllDatabases discovery. Query pg_database on the instance and use the
    result as the target list for the grant loop below.

    Why psql to the `postgres` DB specifically: it exists on every Cloud SQL
    Postgres instance, is always connectable by cloudsqlsuperuser (unlike
    template0/template1 which have datallowconn=false), and running the
    discovery query there means we don't need to know a target DB name to
    find target DB names — chicken-and-egg avoided.

    datallowconn filter: template0 and any DB explicitly marked no-connect
    would fail on the per-DB GRANT loop anyway; skipping them here avoids
    a guaranteed error later. -ExcludeDatabases pulls out the Cloud SQL
    management DBs (cloudsqladmin), the pmm monitoring DB, and the
    bootstrap DB (postgres) that we're currently connected to.

    -tAq: tuples-only, unaligned, quiet — makes psql emit a raw one-per-line
    list with no header, no separator formatting, no "(N rows)" tail. Feeds
    directly into a PowerShell array with @(...).
    #>

    $excludeList = ($ExcludeDatabases | ForEach-Object { "'$_'" }) -join ','
    $query = "SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ($excludeList) ORDER BY datname;"

    <#
    Redirect psql's stderr to a temp file (not 2>&1) so a stderr line like
    "server closed the connection unexpectedly" cannot land in $Databases and
    then get treated as a DB name by the grant loop. Keep stdout for the DB
    list, stderr for the actual error message on failure.
    #>
    $psqlErrFile = New-TemporaryFile
    $Databases = @(& psql -d postgres -tAq -c $query 2>$psqlErrFile)
    $psqlExit = $LASTEXITCODE
    $psqlErr  = (Get-Content $psqlErrFile.FullName -Raw -ErrorAction SilentlyContinue)
    Remove-Item $psqlErrFile.FullName -Force -ErrorAction SilentlyContinue
    if ($psqlExit -ne 0) {
        <#
        Same log-tail pattern as the proxy-readiness bail-out: if psql failed
        mid-run the proxy may have crashed under it, and its stderr file is
        the only place that says why. Attach both the psql stderr AND the
        proxy stdout/stderr to the throw so the operator gets the full
        picture in one message.
        #>
        $logTail = ''
        foreach ($f in @($proxyLog, "${proxyLog}.err")) {
            if (Test-Path $f) {
                $content = (Get-Content $f -Raw -ErrorAction SilentlyContinue)
                if ($content) { $logTail += "`n--- $f ---`n$content" }
            }
        }
        throw "psql discovery failed against 127.0.0.1:${ProxyPort} (exit ${psqlExit}):`n${psqlErr}${logTail}"
    }
    <#
    Empty result -> hard fail, not silent no-op. This almost always means the
    operator over-broadened -ExcludeDatabases (e.g. included every real DB
    by accident) or is pointed at a fresh instance with no user DBs yet.
    Silently succeeding with zero grants would be worse than failing loud.
    #>
    if ($Databases.Count -eq 0) {
        throw "No databases returned from pg_database. Check -ExcludeDatabases."
    }
    Write-Host "Discovered $($Databases.Count) database(s): $($Databases -join ', ')" -ForegroundColor DarkCyan
}

<#
Mode picks which of the three cluster-wide group roles the IAM principal joins.
All three group roles (app_ro / app_rw / app_ddl) are ALWAYS bootstrapped and
provisioned on every target schema regardless of mode — the mode flag only
controls the final `GRANT <group_role> TO <IAM principal>` at the end.
Default is READ-ONLY (safest for prod); opt into write access with -ReadWrite.
#>
if ($GrantDdl) {
    $targetGroupRole = 'app_ddl'
    $mode = "DDL/OWNER  (grant app_ddl membership to $Role; existing objects reassigned to app_ddl)"
} elseif ($ReadWrite) {
    $targetGroupRole = 'app_rw'
    $mode = "READ-WRITE (grant app_rw membership to $Role)"
} else {
    $targetGroupRole = 'app_ro'
    $mode = "READ-ONLY  (grant app_ro membership to $Role)"
}

if ($TakeOwnership -and -not $GrantDdl) {
    $mode += ' + OWNERSHIP TRANSFER (existing objects reassigned to app_ddl)'
}

if ($PostDmsPromote) {
    $mode = "POST-DMS PROMOTE + $mode"
}

Write-Host "Mode: $mode" -ForegroundColor Yellow
Write-Host "Group roles provisioned every run: app_ro, app_rw, app_ddl" -ForegroundColor DarkGray

$sql = @"
$(if ($PostDmsPromote) { @"
/*
  0. POST-DMS PROMOTION CLEANUP. Runs before bootstrap/ownership/grants.
  Drops pglogical leftovers so the ownership loop below does not trip on
  pglogical-owned relations, then resets every table-owned sequence to
  MAX(col) because DMS/pglogical does not sync sequence current values.
 */
DO `$`$
DECLARE
  r        record;
  new_val  bigint;
  n_seqs   int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
    RAISE NOTICE 'dropping pglogical extension (post-DMS cleanup)';
    EXECUTE 'DROP EXTENSION IF EXISTS pglogical CASCADE';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pglogical') THEN
    RAISE NOTICE 'dropping pglogical schema (post-DMS cleanup)';
    EXECUTE 'DROP SCHEMA IF EXISTS pglogical CASCADE';
  END IF;

  /*
    Find every sequence that is owned by a specific table column. Postgres
    creates this dependency automatically for identity columns (GENERATED
    ... AS IDENTITY) and SERIAL/BIGSERIAL, and it can also be created
    explicitly with ALTER SEQUENCE ... OWNED BY. That dependency lives in
    pg_depend with:
      deptype = 'a'  -> "auto" (identity / SERIAL)
      deptype = 'i'  -> "internal" (explicit OWNED BY)
    Both classid and refclassid must be pg_class because we want a
    sequence-to-relation edge specifically (pg_depend is polymorphic across
    catalog objects). refobjsubid is the pg_attribute.attnum of the owning
    column, which we join to pg_attribute to recover the column name for
    the MAX() lookup below.
   
    Standalone sequences (no OWNED BY) are intentionally skipped: without a
    known column we can't derive MAX() to realign to, and pglogical does
    sync current values for those in most configurations anyway.
   */
  FOR r IN
    SELECT n.nspname   AS seq_schema,
           s.relname   AS seq_name,
           tn.nspname  AS tbl_schema,
           t.relname   AS tbl_name,
           a.attname   AS col_name
    FROM   pg_class      s
    JOIN   pg_namespace  n  ON n.oid  = s.relnamespace
    JOIN   pg_depend     d  ON d.objid = s.oid
                           AND d.classid = 'pg_class'::regclass
                           AND d.refclassid = 'pg_class'::regclass
                           AND d.deptype IN ('a','i')
    JOIN   pg_class      t  ON t.oid  = d.refobjid
    JOIN   pg_namespace  tn ON tn.oid = t.relnamespace
    JOIN   pg_attribute  a  ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    WHERE  s.relkind = 'S'
      AND  n.nspname NOT IN ('pg_catalog','information_schema','pglogical')
      AND  n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
  LOOP
    /*
      setval to GREATEST(current, MAX(col)) is a safety belt: if a later run
      of this script fires after production writes have already advanced the
      sequence past MAX(col) (e.g. deleted rows), we won't accidentally
      REGRESS the sequence and cause collisions. COALESCE handles empty
      tables by seeding at 1. quote_ident() is used to build a qualified
      name safely; %I in format() handles the column and table refs.
     */
    EXECUTE format(
      'SELECT setval(%L, GREATEST( (SELECT last_value FROM %I.%I), COALESCE((SELECT MAX(%I) FROM %I.%I), 1) ))',
      quote_ident(r.seq_schema) || '.' || quote_ident(r.seq_name),
      r.seq_schema, r.seq_name,
      r.col_name,   r.tbl_schema, r.tbl_name
    ) INTO new_val;
    n_seqs := n_seqs + 1;
    RAISE NOTICE '  sequence %.% -> % (from %.%.%)',
      r.seq_schema, r.seq_name, new_val, r.tbl_schema, r.tbl_name, r.col_name;
  END LOOP;

  RAISE NOTICE 'post-DMS: % sequences realigned to MAX(col)', n_seqs;
END
`$`$;

"@ })
/*
  1. Bootstrap the three cluster-wide group roles (idempotent, NOLOGIN).
     Roles are cluster-scoped so this only actually creates on the first target DB;
     subsequent DBs no-op via IF NOT EXISTS.
 */
DO `$`$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')  THEN CREATE ROLE app_ro  NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')  THEN CREATE ROLE app_rw  NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ddl') THEN CREATE ROLE app_ddl NOLOGIN; END IF;
END
`$`$;

-- 2. Wire the standard three-tier permission model on this database.
DO `$`$
DECLARE
  s          text;
  n_tables   int;
  n_seqs     int;
  n_schemas  int := 0;
BEGIN
  -- Session needs membership in app_ddl to run `ALTER DEFAULT PRIVILEGES FOR ROLE app_ddl`
  -- and to reassign object ownership to app_ddl later.
  EXECUTE 'GRANT app_ddl TO CURRENT_USER';

  EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_ro, app_rw, app_ddl', current_database());
  RAISE NOTICE 'GRANT CONNECT ON DATABASE % TO app_ro, app_rw, app_ddl', current_database();

  /*
    Iterate every user schema. Filter out:
      * pg_catalog / information_schema  (system schemas, read-only)
      * pg_toast, pg_temp_*, pg_toast_temp_*  (all match pg\_% — internal)
    The `\` ESCAPE turns the `_` in `pg\_%` into a literal underscore so
    it doesn't match every one-character schema name.
   */
  FOR s IN
    SELECT nspname
    FROM   pg_namespace
    WHERE  nspname NOT IN ('pg_catalog','information_schema')
      AND  nspname NOT LIKE 'pg\_%' ESCAPE '\'
    ORDER  BY nspname
  LOOP
    n_schemas := n_schemas + 1;
    SELECT count(*) INTO n_tables FROM pg_tables    WHERE schemaname = s;
    SELECT count(*) INTO n_seqs   FROM pg_sequences WHERE schemaname = s;

    -- Schema-level
    EXECUTE format('GRANT USAGE         ON SCHEMA %I TO app_ro, app_rw', s);
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO app_ddl',        s);

    -- Existing objects
    EXECUTE format('GRANT SELECT                         ON ALL TABLES    IN SCHEMA %I TO app_ro',  s);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA %I TO app_rw',  s);
    EXECUTE format('GRANT ALL                            ON ALL TABLES    IN SCHEMA %I TO app_ddl', s);
    EXECUTE format('GRANT SELECT                         ON ALL SEQUENCES IN SCHEMA %I TO app_ro',  s);
    EXECUTE format('GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA %I TO app_rw',  s);
    EXECUTE format('GRANT ALL                            ON ALL SEQUENCES IN SCHEMA %I TO app_ddl', s);

    -- Default privileges for objects created by the CURRENT admin session
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT                         ON TABLES    TO app_ro',  s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO app_rw',  s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL                            ON TABLES    TO app_ddl', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT                         ON SEQUENCES TO app_ro',  s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT, UPDATE          ON SEQUENCES TO app_rw',  s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL                            ON SEQUENCES TO app_ddl', s);

    -- Default privileges for objects created by app_ddl (the intended DDL owner).
    -- Without these, tables new-migrated by an app_ddl member would only be visible to app_ddl.
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE app_ddl IN SCHEMA %I GRANT SELECT                         ON TABLES    TO app_ro', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE app_ddl IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO app_rw', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE app_ddl IN SCHEMA %I GRANT SELECT                         ON SEQUENCES TO app_ro', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE app_ddl IN SCHEMA %I GRANT USAGE, SELECT, UPDATE          ON SEQUENCES TO app_rw', s);

    RAISE NOTICE '  schema % : % tables, % sequences  (all three tiers, existing + future)', s, n_tables, n_seqs;
  END LOOP;

  RAISE NOTICE 'schemas processed: %', n_schemas;
END
`$`$;

$(if ($GrantDdl -or $TakeOwnership) { @"
/*
  3. Ownership transfer: reassign every existing user object to app_ddl (skipping
     extension-owned). Identity/SERIAL sequences are skipped -- Postgres forbids
     ALTER SEQUENCE OWNER TO on them; they follow the owning table's owner automatically.
 */
DO `$`$
DECLARE
  o record;
  n_objs  int := 0;
  n_funcs int := 0;
BEGIN
  /*
    Walk every user relation (tables, partitioned tables, views, matviews,
    sequences, foreign tables) and reassign ownership to app_ddl. Three
    filters combine to skip things we must NOT touch:
   
      1. LEFT JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'e'
         then AND d.objid IS NULL
         => excludes extension-owned relations. pg_depend.deptype='e' means
            the object was created by CREATE EXTENSION; changing its owner
            corrupts the extension's ability to be dropped/recreated cleanly.
   
      2. NOT EXISTS (... deptype IN ('a','i') ...) on pg_class
         => excludes sequences that are auto/internal-owned by a table
            column (identity/SERIAL/explicit OWNED BY). Postgres FORBIDS
            ALTER SEQUENCE OWNER TO on those — they must follow the
            owning table's owner automatically. Trying to reassign them
            raises: "cannot change owner of sequence ... it is linked to
            table column ...". The parent table's ALTER OWNER above will
            cascade to the sequence for free.
   
      3. schema filter same as bootstrap block (skip pg_catalog,
         information_schema, pg_*).
   
    The CASE maps pg_class.relkind codes to the ALTER-command noun the
    format() call needs. 'r' and 'p' both map to 'TABLE' because
    ALTER PARTITIONED TABLE is not a thing — you ALTER TABLE the root.
   */
  FOR o IN
    SELECT n.nspname, c.relname,
           CASE c.relkind
             WHEN 'r' THEN 'TABLE'
             WHEN 'p' THEN 'TABLE'
             WHEN 'v' THEN 'VIEW'
             WHEN 'm' THEN 'MATERIALIZED VIEW'
             WHEN 'S' THEN 'SEQUENCE'
             WHEN 'f' THEN 'FOREIGN TABLE'
           END AS obj_type
    FROM   pg_class c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    LEFT   JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'e'
    WHERE  c.relkind IN ('r','p','v','m','S','f')
      AND  n.nspname NOT IN ('pg_catalog','information_schema')
      AND  n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
      AND  d.objid IS NULL
      AND  NOT EXISTS (
             SELECT 1 FROM pg_depend dep
             WHERE dep.classid = 'pg_class'::regclass
               AND dep.objid   = c.oid
               AND dep.deptype IN ('a','i')
           )
  LOOP
    EXECUTE format('ALTER %s %I.%I OWNER TO app_ddl', o.obj_type, o.nspname, o.relname);
    n_objs := n_objs + 1;
  END LOOP;

  /*
    Functions live in pg_proc (not pg_class) so they need a separate loop.
    p.oid::regprocedure produces the fully-qualified callable signature
    like `myschema.myfunc(integer, text)` which is what ALTER FUNCTION
    requires to disambiguate overloads. The extension-owned filter mirrors
    the relation loop above (deptype='e' via LEFT JOIN + IS NULL).
   */
  FOR o IN
    SELECT p.oid::regprocedure::text AS sig
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    LEFT   JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
    WHERE  n.nspname NOT IN ('pg_catalog','information_schema')
      AND  n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
      AND  d.objid IS NULL
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO app_ddl', o.sig);
    n_funcs := n_funcs + 1;
  END LOOP;

$(if ($GrantDdl) { @"
  -- Default privileges for functions created by app_ddl going forward.
  FOR o IN
    SELECT nspname
    FROM   pg_namespace
    WHERE  nspname NOT IN ('pg_catalog','information_schema')
      AND  nspname NOT LIKE 'pg\_%' ESCAPE '\'
  LOOP
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE app_ddl IN SCHEMA %I GRANT ALL ON FUNCTIONS TO app_ddl', o.nspname);
  END LOOP;
"@ })

  RAISE NOTICE 'ownership transferred to app_ddl: % relations, % functions', n_objs, n_funcs;
END
`$`$;
"@ })

-- 4. Grant the mode-selected group role membership to the IAM principal.
GRANT $targetGroupRole TO "$Role";

-- verification: group memberships now held by the IAM principal
\echo ''
\echo 'group memberships for ${Role}:'
SELECT r.rolname AS group_role
FROM   pg_auth_members m
JOIN   pg_roles g ON g.oid = m.member
JOIN   pg_roles r ON r.oid = m.roleid
WHERE  g.rolname = '$Role'
ORDER  BY r.rolname;

\echo 'schemas with USAGE for ${targetGroupRole}:'
SELECT nspname
FROM   pg_namespace
WHERE  has_schema_privilege('$targetGroupRole', nspname, 'USAGE')
  AND  nspname NOT IN ('pg_catalog','information_schema')
  AND  nspname NOT LIKE 'pg\_%'
ORDER  BY nspname;

\echo 'table privilege counts for $targetGroupRole (perms the IAM principal inherits):'
SELECT table_schema,
       count(*) FILTER (WHERE privilege_type = 'SELECT') AS "SELECT",
       count(*) FILTER (WHERE privilege_type = 'INSERT') AS "INSERT",
       count(*) FILTER (WHERE privilege_type = 'UPDATE') AS "UPDATE",
       count(*) FILTER (WHERE privilege_type = 'DELETE') AS "DELETE"
FROM   information_schema.role_table_grants
WHERE  grantee = '$targetGroupRole'
GROUP  BY table_schema
ORDER  BY table_schema;

\echo 'default privileges seeded for future objects (all three tiers):'
SELECT n.nspname                                AS schema,
       pg_catalog.pg_get_userbyid(d.defaclrole) AS creator,
       d.defaclobjtype                          AS obj_type,
       d.defaclacl                              AS acl
FROM   pg_default_acl d
JOIN   pg_namespace   n ON n.oid = d.defaclnamespace
WHERE  d.defaclacl::text ~ '(app_ro|app_rw|app_ddl)'
ORDER  BY schema, creator, obj_type;

$(if ($GrantDdl -or $TakeOwnership) { @"
\echo 'objects now owned by app_ddl:'
SELECT n.nspname AS schema,
       CASE c.relkind
         WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table'
         WHEN 'v' THEN 'view'  WHEN 'm' THEN 'matview'
         WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table'
       END        AS kind,
       count(*)   AS n
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  c.relowner = (SELECT oid FROM pg_roles WHERE rolname = 'app_ddl')
  AND  c.relkind  IN ('r','p','v','m','S','f')
GROUP  BY n.nspname, c.relkind
ORDER  BY schema, kind;
"@ })
$(if ($PostDmsPromote) { @"

/*
 5. Post-DMS: refresh planner stats. Logical replication does not populate
    pg_stat, so first-query plans on a freshly promoted destination are
    pathological until ANALYZE runs.
*/
\echo 'post-DMS: running ANALYZE across user schemas'
ANALYZE;
"@ })
"@

foreach ($db in $Databases) {
    Write-Host "=== $db ===" -ForegroundColor Cyan
    try {
        # -v ON_ERROR_STOP=1 makes psql exit non-zero on the first SQL error
        $sql | & psql -d $db -v ON_ERROR_STOP=1 -q -f - 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "psql exited with code $LASTEXITCODE"
        }
        $results.Add([pscustomobject]@{ Database = $db; Status = 'OK'; Error = $null })
        Write-Host "  granted." -ForegroundColor Green
    }
    catch {
        $results.Add([pscustomobject]@{ Database = $db; Status = 'FAILED'; Error = $_.Exception.Message })
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    $plain = $null
    if ($proxyProc -and -not $proxyProc.HasExited) {
        Write-Host "Stopping Auth Proxy (PID $($proxyProc.Id))..." -ForegroundColor DarkCyan
        try { $proxyProc.Kill(); $proxyProc.WaitForExit() } catch {}
    }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

if ($results.Where({ $_.Status -eq 'FAILED' }).Count -gt 0) {
    exit 1
}



<#
# NOTE: default mode is now READ-ONLY (app_ro). Pass -ReadWrite for CRUD or -GrantDdl for DDL/owner.
# NOTE: Auth Proxy is always used — no -PgHost / -PgPort / -UseAuthProxy. Requires ADC:
#       gcloud auth application-default login

# Every DB on the instance except the excluded ones, read-only (default)
./Grant-CloudSQLPgRole.ps1 -Role 'tvevents-sa@vz-inscape-portfolio-stage.iam' `
  -Instance tvcdb-stage -Project 'vz-inscape-portfolio-stage' -AllDatabases


# Only these DBs, read-write
./Grant-CloudSQLPgRole.ps1 -Role 'tvevents-sa@vz-inscape-portfolio-stage.iam' `
  -Instance tvcdb-stage -Project 'vz-inscape-portfolio-stage' `
  -Databases @('tvevents','tvlocation') -ReadWrite

# All DBs, read-only, include postgres too
./Grant-CloudSQLPgRole.ps1 -Role 'tvmeta-sa@vz-inscape-portfolio-stage.iam' `
  -Instance tvcdb-stage -Project 'vz-inscape-portfolio-stage' `
  -AllDatabases -ReadOnly -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm')


# portal-sa needs write access — pass -ReadWrite explicitly (default is read-only)
./Grant-CloudSQLPgRole.ps1 -Role 'portal-sa@vz-inscape-portfolio-dev.iam' `
  -Instance admin-portal-db -Project 'vz-inscape-portfolio-dev' `
  -AllDatabases -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') -ReadWrite


./Grant-CloudSQLPgRole.ps1 `
  -Role 'portal-sa@vz-inscape-portfolio-qa.iam' `
  -Instance admin-portal-db -Project 'vz-inscape-portfolio-qa' `
  -AllDatabases -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') `
  -GrantDdl

# Post-DMS promotion cleanup: pglogical drop + sequence realignment + ownership
# reassignment off 'postgres' + app_ddl grant + ANALYZE. Run AFTER DMS promote.
./Grant-CloudSQLPgRole.ps1 `
  -Role 'portal-sa@vz-inscape-portfolio-stage.iam' `
  -Instance admin-portal-db -Project 'vz-inscape-portfolio-stage' `
  -Databases @('unicorn') -ExcludeDatabases @('postgres','cloudsqladmin','template1','pmm') `
  -GrantDdl -PostDmsPromote

  #>




<#
###################################################
PG Database tables dictionary
###################################################
One-line reference for the pg_catalog / information_schema relations touched by
the psql queries embedded in this script.

pg_catalog.pg_database          - Row per database in the cluster; used to enumerate connectable DBs (datallowconn) for -AllDatabases discovery.
pg_catalog.pg_namespace         - Row per schema (namespace); joined to resolve schema names and to filter out pg_catalog / information_schema / pglogical.
pg_catalog.pg_class             - Row per relation (tables, views, matviews, indexes, sequences, foreign tables); source for ownership reassignment and relkind -> ALTER-noun mapping.
pg_catalog.pg_attribute         - Row per column of every relation; joined to pg_depend on attnum to recover the owning column name of a sequence.
pg_catalog.pg_depend            - Dependency edges between catalog objects; used to find sequence->table->column links and to exclude extension-owned objects (deptype 'e','a','i').
pg_catalog.pg_proc              - Row per function / procedure; iterated separately from pg_class for ownership reassignment because functions do not live in pg_class.
pg_catalog.pg_roles             - Row per database role (users + groups); guards CREATE ROLE bootstrap and resolves owner OIDs (e.g. app_ddl).
pg_catalog.pg_auth_members      - Role membership edges (role -> member); used to audit which roles are granted to app_ro / app_rw / app_ddl and to the target principal.
pg_catalog.pg_default_acl       - Default privileges (ALTER DEFAULT PRIVILEGES) per schema/creator/object-type; audited to confirm future objects inherit the right grants.
pg_catalog.pg_extension         - Installed extensions in the current DB; probed to decide whether to run the pglogical drop path in -PostDmsPromote.
pg_catalog.pg_tables            - Convenience view over pg_class for ordinary tables; used for per-schema table counts in the bootstrap summary.
pg_catalog.pg_sequences         - Convenience view over pg_class for sequences; used for per-schema sequence counts and to drive setval() realignment.
pg_catalog.pg_stat_*            - Referenced in comments only; planner statistics that logical replication does NOT copy, which is why -PostDmsPromote runs ANALYZE.
information_schema.role_table_grants - SQL-standard view of table-level privileges; audited to confirm the target principal ended up with the expected SELECT/INSERT/UPDATE/DELETE grants.

#>



