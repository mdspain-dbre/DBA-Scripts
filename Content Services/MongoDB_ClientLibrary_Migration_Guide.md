# MongoDB Driver Compatibility Matrix

## MongoDB Server 4.4 → MongoDB 5.0

**Date:** March 2026  
**Purpose:** Driver version reference for application teams upgrading to MongoDB 5.0.  
**Audience:** Application development teams  

> Upgrade your driver to a version that supports MongoDB 5.0 **before or at the same time** as the server upgrade.  
> Newer drivers are backward-compatible with older servers — you can upgrade your driver first and test against the current 4.4 server.

---

| Language                       | Minimum Driver Version for MongoDB 5.0 | Recommended Driver Version | Previous Version (4.4 Compatible) |
|--------------------------------|----------------------------------------|----------------------------|-----------------------------------|
| **Node.js** (mongodb)          | 4.0+                                   | 4.17+ (latest 4.x)         | 3.6.x – 3.7.x                     |
| **Node.js** (Mongoose)         | 6.0+                                   | 6.12+ (latest 6.x)         | 5.x                               |
| **Python** (PyMongo)           | 3.12+                                  | 3.13+ (latest 3.x)         | 3.11.x                            |
| **Java** (Sync/Async)          | 4.3+                                   | 4.11+ (latest 4.x)         | 4.0.x – 4.2.x                     |
| **Java** (Spring Data MongoDB) | 3.3+                                   | 3.4+ (latest 3.x)          | 3.2.x                             |
| **C# / .NET**                  | 2.13+                                  | 2.19+ (latest 2.x)         | 2.11.x – 2.12.x                   |
| **Go**                         | 1.7+                                   | 1.11+ (latest 1.x)         | 1.5.x – 1.6.x                     |
| **PHP** (ext-mongodb)          | 1.10+                                  | 1.12+ (latest)             | 1.9.x                             |
| **PHP** (MongoDB library)      | 1.9+                                   | 1.10+ (latest)             | 1.8.x                             |
| **Ruby** (mongo gem)           | 2.15+                                  | 2.17+ (latest 2.x)         | 2.13.x – 2.14.x                   |
| **Mongosh** (shell)            | 1.0+                                   | 1.10+ (latest 1.x)         | 0.x (legacy mongo shell)          |
| **MongoDB Compass**            | 1.30+                                  | 1.36+ (latest)             | 1.28+                             |

> **Note:** Always verify versions against the [MongoDB Driver Compatibility](https://www.mongodb.com/docs/drivers/) page, as new releases may occur after this document was written.
