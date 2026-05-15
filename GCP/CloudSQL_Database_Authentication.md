# Cloud SQL Database Authentication (PostgreSQL)

A breakdown of the database authentication options available in Cloud SQL for PostgreSQL, based on the official Google Cloud documentation.

Sources:
- [Cloud SQL built-in database authentication](https://docs.cloud.google.com/sql/docs/postgres/built-in-authentication)
- [Cloud SQL IAM authentication](https://docs.cloud.google.com/sql/docs/postgres/iam-authentication)
- [Cloud Identity Groups API overview](https://docs.cloud.google.com/identity/docs/groups)

---

## 1. Overview

Authentication in Cloud SQL is the process of verifying the identity of a user attempting to access a database instance. Cloud SQL for PostgreSQL supports two top-level authentication models that can be used independently or together (hybrid):

| Model                                                | Credential                         | Identity Source                         | User Management                                   |
|------------------------------------------------------|------------------------------------|-----------------------------------------|---------------------------------------------------|
| Built-in authentication                              | Username + password                | Local to the database                   | Manual                                            |
| IAM database authentication (user / service account) | Short-lived OAuth 2.0 access token | Google Cloud IAM                        | Centralized through IAM                           |
| IAM group authentication                             | Short-lived OAuth 2.0 access token | Google Cloud IAM + Cloud Identity group | Centralized through IAM and Cloud Identity groups |

Network traffic encryption requirements:
- **Built-in:** SSL not required.
- **IAM (user, SA, group):** SSL required.

---

## 2. Built-in Database Authentication

Built-in authentication uses a local PostgreSQL username and password to authenticate database users. These users own the objects they create in the database. Cloud SQL provides strong password enforcement via password policies.

> Note: Password policies do **not** apply to hashed passwords.

### 2.1 Instance Password Policies

Set at instance creation time (and editable later). Options include:

- **Minimum length** — minimum number of characters required.
- **Password complexity** — require a mix of lowercase, uppercase, numeric, and non-alphanumeric characters.
- **Restrict password reuse** — number of prior passwords that cannot be reused.
- **Disallow username** — prevent the username from appearing in the password.
- **Set password change interval** — minimum duration before a password can be changed again.

> Enabling a policy adds password verification overhead — typically <200 ms — when creating users or changing passwords.

### 2.2 User Password Policies

Set per user (at create time or later):

- **Set password to expire** — number of days until the password expires.
- **Lock after failed attempts** — number of incorrect login attempts before the account is locked.

User status (expired, locked) is visible from the Users page; admins can unlock and reset passwords there.

### 2.3 Read Replicas

Password policies are managed on the **primary** instance only — they cannot be modified separately on read replicas. When you promote a replica, you must re-enable the password policy and its options on the new primary.

---

## 3. IAM Database Authentication

IAM database authentication uses Google Cloud IAM to authenticate principals using short-lived **OAuth 2.0 access tokens** (valid for 1 hour) instead of passwords.

### 3.1 Core IAM Concepts

- **Principals** — user accounts, service accounts, or groups.
- **Roles** — collections of permissions granted to principals (e.g., `Cloud SQL Instance User`, which includes `cloudsql.instances.login`).
- **Resources** — Cloud SQL instances. Bindings are usually applied at the project level.

Cloud SQL supplies a set of [predefined IAM roles](https://docs.cloud.google.com/sql/docs/postgres/iam-roles) and supports custom roles. Legacy basic roles (Owner/Editor/Viewer) still work but lack least-privilege granularity.

> Note: When using **Workforce Identity Federation**, IAM database authentication for user logins is **not** supported on Cloud SQL for PostgreSQL.

### 3.2 Enabling IAM Authentication on an Instance

- Set the instance flag `cloudsql.iam_authentication` to enable IAM logins (this flag is also required for IAM group authentication).
- The flag is enabled by default for instances created in the Google Cloud console.
- Disabling the flag revokes access for any user that was added via IAM.
- Built-in users continue to work regardless of this flag.

#### Instance scenarios

| Scenario                                  | Behavior                                                                                |
|-------------------------------------------|-----------------------------------------------------------------------------------------|
| Read replicas                             | IAM database auth is **not** auto-enabled on replicas — must be configured explicitly. |
| Restored instance (same project)          | Existing user authorizations apply.                                                     |
| Restored instance (new project)           | Authorizations must be re-created.                                                      |
| Point-in-time restore (same project)      | Existing authorizations apply.                                                          |
| Point-in-time restore (different project) | Authorizations must be re-created.                                                      |

### 3.3 Automatic vs. Manual IAM Database Authentication

#### Automatic (recommended)
- A Cloud SQL connector — **Cloud SQL Auth Proxy**, or the Go / Java / Python language connectors — handles requesting and refreshing the OAuth 2.0 access token on the client's behalf.
- Client only needs to supply the IAM database username; the connector supplies the token as the password.
- Best for long-lived processes and connection-pooled apps because tokens are auto-refreshed.

#### Manual
- The principal explicitly requests an OAuth 2.0 token (e.g., via `gcloud`) with the Cloud SQL Admin API scope and uses their email as the username and the token as the password.
- Tokens expire after 1 hour — new connections after expiry fail.
- Requires SSL.
- Works with direct connections or with a Cloud SQL connector.

#### Context-aware access
If your IAM configuration uses **context-aware access**, you **cannot** use a Cloud SQL connector with IAM database authentication. Connect directly to the instance instead.

### 3.4 User & Service Account Administration

- Add IAM users / service accounts to an instance (or to a group with access).
- Console adds the `Cloud SQL User` role automatically; gcloud / API users must grant login privileges manually.
- Database object privileges are granted with PostgreSQL `GRANT`.

### 3.5 Restrictions

1. IAM database authentication usernames must be **all lowercase** (e.g., `example-user@example.com`).
2. Logins are only allowed over **SSL**; unencrypted connections are rejected.
3. Per-instance login quota of **12,000 logins/min** (success + failure). Exceeding it temporarily blocks logins. Use authorized networks and avoid frequent re-logins.

### 3.6 IAM Conditions

You can use [IAM Conditions](https://docs.cloud.google.com/iam/docs/conditions-overview) to grant Cloud SQL roles based on attributes such as time of day or specific resource names.

### 3.7 Audit Logging

Cloud Audit Logs (specifically **Data Access logs**) must be explicitly enabled to record login activity. Enabling this logging incurs additional cost.

---

## 4. IAM Group Authentication

IAM group authentication lets you manage Cloud SQL access at the **group** level — typically using a **Cloud Identity group**. Roles and database privileges are bound to the group, and members inherit them automatically.

### 4.1 Capabilities

- Add a user/SA to the group → automatically inherits IAM roles and database privileges.
- Remove a user/SA → loses the group's login access and database privileges.
- Grant or revoke privileges to many accounts at once via a single group operation.
- Each user/SA still authenticates with **their own** IAM identity — there is no shared group account. Cloud SQL creates a per-account database user on first login.
- Per-account activity remains visible in audit logs.

### 4.2 Effects of Group Membership Changes

When a user/SA is **added** to a group:
- They gain login if the group has `cloudsql.instances.login`.
- They inherit any database privileges granted to the group.
- If the account already had individual IAM access on the instance, **remove that individual binding first** before adding to the group.

When a user/SA is **removed** from a group:
- They lose privileges that came from the group.
- They may still be able to log in if other group memberships grant `cloudsql.instances.login`, but without the removed group's privileges.

> Membership changes can take ~15 minutes to propagate, plus normal IAM propagation time.

### 4.3 Best Practices

- When you revoke `cloudsql.instances.login` for a group, also delete the group from the Cloud SQL instance.
- When deleting a group from Cloud Identity, also delete it from the instance.
- Use groups for role-based access control (RBAC) and grant **least privilege**.
- Do **not** grant IAM group authentication roles to built-in users.

### 4.4 Restrictions

- Read replicas: with group auth enabled, the user must first log in to the **primary** so group user info replicates; subsequent logins can target the replica directly.
- Maximum **200 IAM groups per instance**.
- An instance cannot simultaneously hold an account as `CLOUD_IAM_USER` / `CLOUD_IAM_SERVICE_ACCOUNT` **and** as `CLOUD_IAM_GROUP_USER` / `CLOUD_IAM_GROUP_SERVICE_ACCOUNT`. Existing individual IAM accounts must be removed before they can inherit group privileges.
- Cloud Identity membership change propagation takes ~15 minutes.

---

## 5. Cloud Identity Groups (Reference)

Cloud Identity groups are the identity primitive used by IAM group authentication. The Cloud Identity Groups API only works with **Google Groups for Business**.

### 5.1 Group Types

| Type                            | Description                                                                                                                                                                |
|---------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Google Groups**               | Default type; has an email address; usable as a mailing list and for IAM bindings.                                                                                         |
| **Dynamic groups**              | Memberships are auto-managed by a query (e.g., job role). Limited to ~500/customer; available on Workspace Enterprise Standard/Plus, Enterprise for Education, and Cloud Identity premium. |
| **Security groups**             | A Google Group elevated specifically for access control. **Cannot be reverted** to a regular Google Group.                                                                 |
| **Locked groups**               | Google Groups locked to prevent drift from an external identity provider; only authorized admins can edit core attributes/memberships.                                     |
| **POSIX groups** *(deprecated)* | Used for LDAP / OS Login; new POSIX groups blocked since Sep 26, 2024.                                                                                                     |
| **Identity-mapped groups**      | Created via the Groups API only; map external identities (e.g., AD) into Cloud Search.                                                                                     |

### 5.2 Group Properties

- **Label** — identifies group type, e.g., `cloudidentity.googleapis.com/groups.discussion_forum`, `…/groups.dynamic`, `…/groups.security`, `…/groups.locked`, `…/groups.posix`, `system/groups/external`.
- **Entity key** — unique, human-readable ID (email address for most types; namespaced string for identity-mapped).
- **Parent** — the customer (for most types) or the identity source (identity-mapped).
- **Display name** — name shown in Google products.

### 5.3 Memberships

Members may be users, groups, or service accounts. Each membership has:

- **Preferred member key** — typically the email address.
- **Membership roles**:
  - `MEMBER` — required baseline role; no special permissions.
  - `MANAGER` — more than `MEMBER`, can manage other managers.
  - `OWNER` — broad permissions, including managing other owners and deleting the group.

> The Google Groups web UI supports additional roles (e.g., `BANNED`) that are not visible/manageable through the Cloud Identity Groups API.

---

## 6. Cloud SQL Authentication for MySQL

Cloud SQL for MySQL supports the same two authentication models as PostgreSQL — **built-in** (username/password) and **IAM** (individual or group) — but with several MySQL-specific differences. Sources:

- [Cloud SQL for MySQL — built-in authentication](https://docs.cloud.google.com/sql/docs/mysql/built-in-authentication)
- [Cloud SQL for MySQL — IAM authentication](https://docs.cloud.google.com/sql/docs/mysql/iam-authentication)

### 6.1 Built-in Authentication (MySQL)

Local MySQL users authenticate with username + password. Strong policies are available, but with MySQL-specific behavior:

#### Instance password policy options
- **Minimum length**
- **Password complexity** (mix of lowercase, uppercase, numeric, non-alphanumeric)
- **Restrict password reuse** — *MySQL 8.0+ only*
- **Disallow username**
- *(No `Set password change interval` option as in PostgreSQL.)*

> Enabling a policy adds typically <150 ms latency to user create / password change operations (vs. <200 ms on PostgreSQL).

#### User password policy options
- **Set password to expire** — supported on MySQL 5.7 and 8.0+
- **Lock after failed attempts** — MySQL 8.0+ only
- **Require current password when password is changed** — MySQL 8.0+ only

> User-level policy options (other than expiration) are **only supported on MySQL 8.0+**.

#### Read replicas
Same model as PostgreSQL: password policies are managed on the primary; on promotion you must re-enable them on the new primary.

### 6.2 IAM Database Authentication (MySQL)

Concepts and architecture mirror PostgreSQL:

- Same predefined Cloud SQL roles, custom roles, IAM Conditions, and `cloudsql.instances.login` permission.
- Uses short-lived OAuth 2.0 access tokens (1-hour TTL).
- **Workforce Identity Federation user logins are not supported** for Cloud SQL for MySQL.

#### Enabling IAM auth on the instance
- Use the database flag **`cloudsql_iam_authentication`** (note the **underscore** — different from PostgreSQL's `cloudsql.iam_authentication`).
- Enabled by default for instances created via the Google Cloud console.
- Required for both IAM database authentication and IAM group authentication.
- Disabling it revokes IAM-added users; built-in users are unaffected.

#### Granting database privileges
- Console add-user flow attaches the `Cloud SQL User` role automatically.
- After the IAM user/SA is added, **all** database privileges must be granted manually using the MySQL `GRANT` statement (PostgreSQL is similar but the console grants the role; MySQL requires explicit privilege grants every time).

#### Automatic vs. manual
Identical to PostgreSQL:
- **Automatic** (recommended) — via Cloud SQL Auth Proxy or Go / Java / Python connectors; the connector handles token request/refresh.
- **Manual** — principal acquires an OAuth 2.0 token (e.g., via `gcloud`) and supplies it as the password.
- **Context-aware access** — disables connector-based IAM auth; connect directly instead.

#### Instance scenarios
| Scenario                                  | Behavior                                                                                |
|-------------------------------------------|-----------------------------------------------------------------------------------------|
| Read replicas                             | IAM database auth is **not** auto-enabled on replicas — must be configured explicitly. |
| Restored instance (same project)          | Existing user authorizations apply.                                                     |
| Restored instance (new project)           | Authorizations must be re-created.                                                      |
| Point-in-time restore (same project)      | Existing authorizations apply.                                                          |
| Point-in-time restore (different project) | Authorizations must be re-created.                                                      |

### 6.3 IAM Group Authentication (MySQL)

Functionally equivalent to PostgreSQL: bind IAM roles and database privileges to a Cloud Identity group; members inherit them automatically and continue to log in with their own identities. Database accounts are created on first login and individual activity remains in audit logs.

**Restrictions specific to / shared with MySQL:**
- Maximum **200 IAM groups per instance**.
- An account cannot exist as both `CLOUD_IAM_USER` / `CLOUD_IAM_SERVICE_ACCOUNT` and `CLOUD_IAM_GROUP_USER` / `CLOUD_IAM_GROUP_SERVICE_ACCOUNT` on the same instance — remove the individual binding first.
- Cloud Identity membership changes take ~15 minutes to propagate (in addition to normal IAM propagation).
- Same best practices apply: also delete the group from the instance when revoking `cloudsql.instances.login`; grant least privilege; don't grant group-auth roles to built-in users.

> The MySQL IAM group docs do **not** call out the PostgreSQL-specific replica caveat (logging into the primary first to seed group user info before logging into a replica).

### 6.4 General IAM Restrictions (MySQL)

1. IAM usernames must be **all lowercase** (e.g., `example-user@example.com`).
2. IAM logins are only allowed over **SSL**.
3. Per-instance login quota of **12,000 logins/min** (success + failure).
4. **IAM database authentication is not supported on MySQL 5.6** — requires MySQL 5.7 or later.

### 6.5 MySQL vs. PostgreSQL — Key Differences at a Glance

| Aspect                             | Cloud SQL for MySQL                                  | Cloud SQL for PostgreSQL                  |
|------------------------------------|------------------------------------------------------|-------------------------------------------|
| IAM auth instance flag             | `cloudsql_iam_authentication` (underscore)           | `cloudsql.iam_authentication` (dot)       |
| `Set password change interval`     | Not available                                        | Available                                 |
| `Restrict password reuse`          | MySQL 8.0+ only                                      | Available                                 |
| `Lock after failed attempts`       | MySQL 8.0+ only                                      | Available                                 |
| `Require current password` policy  | MySQL 8.0+ only (MySQL-specific)                     | Not applicable                            |
| Password policy latency overhead   | < ~150 ms                                            | < ~200 ms                                 |
| Granting login role on add (UI)    | Adds `Cloud SQL User`; all privileges via `GRANT`    | Adds `Cloud SQL User`; privileges via `GRANT` |
| IAM auth version requirement       | **MySQL 5.7+** (5.6 not supported)                   | All supported PostgreSQL versions         |
| Replica login ordering for groups  | Not documented as required                           | Must log into primary first to seed       |
| Workforce Identity Federation      | Not supported for user logins                        | Not supported for user logins             |

### 6.6 Connecting with the SHA-2 Authentication Plugin (`caching_sha2_password`)

MySQL 8.0 in Cloud SQL defaults new built-in users to the **`caching_sha2_password`** plugin (the older `sha256_password` is also available). MySQL 5.7 still defaults to `mysql_native_password`.

> IAM database authentication users do **not** use SHA-2 — they authenticate via `mysql_clear_password` over the required SSL/TLS channel using the OAuth 2.0 access token as the password.

#### How clients negotiate SHA-2

A client authenticating a `caching_sha2_password` user must satisfy one of these paths:

1. **Connect over TLS/SSL (recommended)** — the password is sent over the encrypted channel; the server hashes it and (on success) caches the result for fast subsequent logins.
2. **RSA public-key exchange on a non-TLS connection** — the client retrieves the server's RSA public key (or is provided it locally) and uses it to encrypt the password. Requires explicit client opt-in (e.g., `--get-server-public-key` or `allowPublicKeyRetrieval=true`). Not recommended for production.
3. **Server-side cache hit** — after a successful authentication via path 1 or 2, the server can authenticate the same user with a fast SHA-2 challenge from any compatible client until the cache is cleared (e.g., on restart or `FLUSH PRIVILEGES`).

#### Client / driver requirements

| Client / Driver                     | Minimum version  | Notes                                                                                  |
|-------------------------------------|------------------|----------------------------------------------------------------------------------------|
| `mysql` CLI                         | 8.0+             | Older clients need `--default-auth=caching_sha2_password --get-server-public-key`.     |
| MySQL Connector/J (JDBC)            | 8.0.9+           | Use `sslMode=REQUIRED`; for non-SSL add `allowPublicKeyRetrieval=true`.                |
| MySQL Connector/Python              | 8.0.11+          | Works over SSL by default.                                                             |
| PyMySQL                             | 1.0+             | Install the `cryptography` package for non-SSL public-key auth.                        |
| MySQL Connector/NET                 | 8.0.10+          | —                                                                                      |
| PHP `mysqlnd`                       | PHP 7.2.8 / 7.3+ | Older builds may silently fall back / fail.                                            |
| Cloud SQL Auth Proxy                | Any current      | Provides TLS automatically — SHA-2 just works.                                         |
| Cloud SQL Go/Java/Python connectors | Any current      | Provides TLS automatically — SHA-2 just works.                                         |

#### Common errors and fixes

| Error                                                            | Fix                                                                                                              |
|------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `Authentication plugin 'caching_sha2_password' cannot be loaded` | Upgrade the client/driver. Avoid downgrading users to `mysql_native_password` (deprecated in 8.0).               |
| `Public Key Retrieval is not allowed` (JDBC)                     | Prefer enabling TLS (`sslMode=REQUIRED`); otherwise add `allowPublicKeyRetrieval=true`.                          |
| `SSL connection error` / unknown CA                              | Use the Cloud SQL Auth Proxy, or download the server CA from *Connections → Security* and pass `--ssl-ca`.       |
| Persistent failures after restart, then success on retry         | Cache was cleared by restart/`FLUSH PRIVILEGES`; first auth must use TLS or public-key path to repopulate it.    |

#### Quick examples

```bash
# CLI over TLS (recommended)
mysql -h <PUBLIC_IP> -u app_user -p \
  --ssl-mode=REQUIRED --ssl-ca=server-ca.pem
```

```text
# JDBC URL (TLS — recommended)
jdbc:mysql://<HOST>:3306/<DB>?sslMode=REQUIRED&serverTimezone=UTC
```

```bash
# Non-TLS fallback (testing only)
mysql -h <HOST> -u app_user -p --get-server-public-key
```

```sql
-- Inspect / set a user's plugin (run on the instance)
SELECT user, host, plugin FROM mysql.user WHERE user = 'app_user';

ALTER USER 'app_user'@'%' IDENTIFIED WITH caching_sha2_password BY '<password>';
```

#### Best practices

- Always connect over **TLS/SSL** — required for IAM auth, strongly recommended for built-in SHA-2 users.
- Prefer the **Cloud SQL Auth Proxy** or a Cloud SQL language connector — they provide TLS and avoid public-key retrieval issues.
- Keep client libraries up to date; SHA-2 problems are almost always caused by old drivers.
- Avoid switching users to `mysql_native_password` to "fix" SHA-2 errors — fix the client instead.

---

## 7. Choosing an Authentication Method

| Need                                                | Recommended Approach                                                        |
|-----------------------------------------------------|-----------------------------------------------------------------------------|
| Legacy apps using only username/password            | Built-in authentication with strong password policies                       |
| Centralized identity for individual humans/services | IAM database authentication (automatic)                                     |
| Centralized RBAC across many accounts               | IAM group authentication via Cloud Identity / security groups               |
| Long-lived apps with connection pooling             | Automatic IAM database authentication via a Cloud SQL connector             |
| Context-aware access in use                         | IAM authentication **without** a connector — connect directly              |
| Workforce Identity Federation users                 | Built-in authentication (IAM auth not supported for PostgreSQL user logins) |

---

## 8. Quick Reference

- **Login permission:** `cloudsql.instances.login` (in role `Cloud SQL Instance User`).
- **Instance flag for IAM auth:** `cloudsql.iam_authentication` (PostgreSQL) / `cloudsql_iam_authentication` (MySQL).
- **Token TTL:** 1 hour (OAuth 2.0).
- **Login quota:** 12,000/min per instance.
- **Group cap:** 200 IAM groups per instance.
- **Username casing:** must be all lowercase for IAM auth.
- **SSL:** required for any IAM-based login.
- **MySQL version:** IAM auth requires MySQL 5.7+ (not supported on 5.6).
