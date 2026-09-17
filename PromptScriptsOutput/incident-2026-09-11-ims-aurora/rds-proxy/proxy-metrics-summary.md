# RDS Proxy metric summary — account-db-prod-proxy-us-west-2

Window: 2026-09-11 22:00 UTC → 2026-09-12 01:00 UTC (1-min)

| Metric | Unit | Points | Peak | Avg | Sum |
|---|---|---|---|---|---|
| ClientConnections |  | 180 | 908.00 | 157.94 | 523980 |
| ClientConnectionsReceived |  | 151 | 3417.00 | 155.86 | 794323 |
| ClientConnectionsClosed |  | 162 | 3438.00 | 144.44 | 788280 |
| ClientConnectionsSetupSucceeded |  | 151 | 3370.00 | 154.62 | 788096 |
| ClientConnectionsSetupFailedAuth | (no data) |  |  |  |  |
| DatabaseConnections |  | 180 | 261.00 | 51.74 | 474996 |
| DatabaseConnectionsCurrentlyBorrowed |  | 172 | 261.00 | 21.68 | 61959 |
| DatabaseConnectionsCurrentlySessionPinned | (no data) |  |  |  |  |
| DatabaseConnectionsBorrowLatency |  | 180 | 7131550.00 | 367585.66 | 11199058399 |
| DatabaseConnectionRequests |  | 42 | 1479.00 | 284.79 | 405720 |
| MaxDatabaseConnectionsAllowed |  | 180 | 261.00 | 261.00 | 2395980 |
| QueryDatabaseResponseLatency |  | 3 | 16379784.00 | 3255794.32 | 480236437 |
| QueryRequests |  | 3 | 215.00 | 54.36 | 5545 |

## Coverage

- **ClientConnections**: 180 points, 2026-09-11 22:00 → 2026-09-12 00:59 UTC
- **ClientConnectionsReceived**: 151 points, 2026-09-11 22:00 → 2026-09-12 00:56 UTC
- **ClientConnectionsClosed**: 162 points, 2026-09-11 22:00 → 2026-09-12 00:59 UTC
- **ClientConnectionsSetupSucceeded**: 151 points, 2026-09-11 22:00 → 2026-09-12 00:56 UTC
- **ClientConnectionsSetupFailedAuth**: NO DATAPOINTS in window
- **DatabaseConnections**: 180 points, 2026-09-11 22:00 → 2026-09-12 00:59 UTC
- **DatabaseConnectionsCurrentlyBorrowed**: 172 points, 2026-09-11 22:00 → 2026-09-12 00:59 UTC
- **DatabaseConnectionsCurrentlySessionPinned**: NO DATAPOINTS in window
- **DatabaseConnectionsBorrowLatency**: 180 points, 2026-09-11 22:00 → 2026-09-12 00:59 UTC
- **DatabaseConnectionRequests**: 42 points, 2026-09-11 22:00 → 2026-09-12 00:15 UTC
- **MaxDatabaseConnectionsAllowed**: 180 points, 2026-09-11 22:00 → 2026-09-12 00:59 UTC
- **QueryDatabaseResponseLatency**: 3 points, 2026-09-11 22:00 → 2026-09-12 00:00 UTC
- **QueryRequests**: 3 points, 2026-09-11 22:00 → 2026-09-12 00:00 UTC

## Snapshot at incident anchors


### 22:35 UTC (pre-spike) (nearest sample: 2026-09-11 22:35:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 15.12 | 28.00 |
| ClientConnectionsReceived | 1.00 | 1.00 |
| ClientConnectionsClosed |  |  |
| ClientConnectionsSetupSucceeded | 1.00 | 1.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 32.10 | 117.00 |
| DatabaseConnectionsCurrentlyBorrowed | 3.12 | 7.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 99.45 | 1372.00 |
| DatabaseConnectionRequests |  |  |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 22:38 UTC (spike) (nearest sample: 2026-09-11 22:38:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 15.71 | 28.00 |
| ClientConnectionsReceived | 1.00 | 1.00 |
| ClientConnectionsClosed | 1.00 | 1.00 |
| ClientConnectionsSetupSucceeded | 1.00 | 1.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 32.10 | 117.00 |
| DatabaseConnectionsCurrentlyBorrowed | 1.38 | 3.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 96.01 | 943.00 |
| DatabaseConnectionRequests |  |  |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 22:45 UTC (nearest sample: 2026-09-11 22:45:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 15.35 | 28.00 |
| ClientConnectionsReceived |  |  |
| ClientConnectionsClosed | 1.00 | 1.00 |
| ClientConnectionsSetupSucceeded |  |  |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 32.08 | 117.00 |
| DatabaseConnectionsCurrentlyBorrowed | 2.20 | 5.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 104.80 | 1695.00 |
| DatabaseConnectionRequests | 1.00 | 1.00 |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 23:00 UTC (1st page) (nearest sample: 2026-09-11 23:00:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 136.12 | 142.00 |
| ClientConnectionsReceived | 207.94 | 335.00 |
| ClientConnectionsClosed | 79.82 | 185.00 |
| ClientConnectionsSetupSucceeded | 207.71 | 335.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 87.00 | 261.00 |
| DatabaseConnectionsCurrentlyBorrowed | 71.29 | 105.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 238676.75 | 1152135.00 |
| DatabaseConnectionRequests | 85.59 | 177.00 |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency | 890884.44 | 2052988.00 |
| QueryRequests | 34.26 | 82.00 |

### 23:30 UTC (2nd page) (nearest sample: 2026-09-11 23:30:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 95.62 | 103.00 |
| ClientConnectionsReceived | 151.09 | 177.00 |
| ClientConnectionsClosed | 26.09 | 70.00 |
| ClientConnectionsSetupSucceeded | 150.85 | 184.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 87.00 | 261.00 |
| DatabaseConnectionsCurrentlyBorrowed | 2.14 | 5.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 108546.62 | 746591.00 |
| DatabaseConnectionRequests | 40.03 | 96.00 |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 00:10 UTC (CS cut off) (nearest sample: 2026-09-12 00:10:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 273.57 | 465.00 |
| ClientConnectionsReceived | 1570.06 | 2248.00 |
| ClientConnectionsClosed | 1679.65 | 2453.00 |
| ClientConnectionsSetupSucceeded | 1570.15 | 2249.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 55.00 | 261.00 |
| DatabaseConnectionsCurrentlyBorrowed | 29.41 | 76.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 3035398.88 | 5374280.00 |
| DatabaseConnectionRequests | 860.21 | 1301.00 |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 00:14 UTC (pre-failover) (nearest sample: 2026-09-12 00:14:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 301.77 | 449.00 |
| ClientConnectionsReceived | 1268.76 | 2050.00 |
| ClientConnectionsClosed | 1353.91 | 1952.00 |
| ClientConnectionsSetupSucceeded | 1268.32 | 2048.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 37.14 | 261.00 |
| DatabaseConnectionsCurrentlyBorrowed | 22.65 | 87.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 3096510.35 | 5277512.00 |
| DatabaseConnectionRequests | 844.68 | 1160.00 |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 00:15 UTC (post-failover) (nearest sample: 2026-09-12 00:15:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 125.22 | 155.00 |
| ClientConnectionsReceived | 271.33 | 582.00 |
| ClientConnectionsClosed | 317.33 | 672.00 |
| ClientConnectionsSetupSucceeded | 262.71 | 581.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 34.88 | 149.00 |
| DatabaseConnectionsCurrentlyBorrowed | 4.00 | 24.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 640737.05 | 4916713.00 |
| DatabaseConnectionRequests | 208.22 | 710.00 |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |

### 00:20 UTC (recovered) (nearest sample: 2026-09-12 00:20:00+00:00)

| Metric | Avg | Max |
|---|---|---|
| ClientConnections | 92.06 | 114.00 |
| ClientConnectionsReceived | 1.00 | 1.00 |
| ClientConnectionsClosed | 19.41 | 42.00 |
| ClientConnectionsSetupSucceeded | 1.00 | 1.00 |
| ClientConnectionsSetupFailedAuth |  |  |
| DatabaseConnections | 34.88 | 149.00 |
| DatabaseConnectionsCurrentlyBorrowed | 1.00 | 1.00 |
| DatabaseConnectionsCurrentlySessionPinned |  |  |
| DatabaseConnectionsBorrowLatency | 78.46 | 1974.00 |
| DatabaseConnectionRequests |  |  |
| MaxDatabaseConnectionsAllowed | 261.00 | 261.00 |
| QueryDatabaseResponseLatency |  |  |
| QueryRequests |  |  |
