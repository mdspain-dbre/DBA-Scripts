# Redis — DRE/DBA Roles & Responsibilities

**Status:** Draft — pending follow-up with Garry (eviction policy) and Elliot (Grafana/Prometheus connectivity)
**Owner:** Database Reliability Engineering (DRE)

## Scope

Redis is now a supported datastore under DRE. This document defines what we monitor, alert on, and operationally own.

## 1. Monitoring — RED Framework (Requests, Errors, Duration)

| Signal       | What we track                                                                                                 |
| ------------ | ------------------------------------------------------------------------------------------------------------- |
| **Rate**     | Ops/sec, command mix (read vs. write vs. search)                                                              |
| **Errors**   | Failed commands, rejected connections, client timeouts                                                        |
| **Duration** | p50 (expected latency), p95 (early warning — rising faster than median), p99 (worst-case sustainable latency) |

## 2. Memory Management

Core metrics to monitor and alert on:

- used_memory
- Evictions / OOM kills
- instantaneous_ops_per_sec
- total_commands_processed
- keyspace_hits / keyspace_misses (cache hit ratio)

## 3. Key Operational Metrics (alerting candidates)

- Ops/sec
- Command mix (read / write / search)
- Cache hit ratio (hits vs. misses)
- Failed commands
- Rejected connections
- Client timeouts
- Evictions

## 4. Native Tooling

- DB Profiler
- Prometheus
- redis-benchmark

## 5. Configuration Management

- **maxmemory** — set via console or CONFIG SET; DRE reviews/owns sizing
- **Eviction count** — reviewed periodically to validate sizing against maxmemory

## 6. Persistence / Backup Tuning

- RDB and/or AOF durability settings, managed via the provider dashboard
- DRE responsible for validating persistence config matches data-durability requirements per instance

## 7. Eviction Policy (pending decision — Garry)

| Policy               | Evicts                               | Best for                                              |
| -------------------- | ------------------------------------ | ----------------------------------------------------- |
| allkeys-lru          | Least-recently-used, any key         | General-purpose cache (most common default)           |
| volatile-lru         | Least-recently-used, TTL keys only   | Mixed cache + persistent data in one instance         |
| allkeys-lfu          | Least-frequently-used, any key       | Hot-key access patterns where frequency > recency     |
| volatile-lfu         | Least-frequently-used, TTL keys only | Same as above, mixed dataset                          |
| allkeys-random       | Random, any key                      | Uniform/unpredictable access, no bookkeeping overhead |
| volatile-random      | Random, TTL keys only                | Same, mixed dataset                                   |
| volatile-ttl         | Nearest expiration, TTL keys only    | Aggressively reclaim soon-to-expire data              |
| noeviction (default) | Nothing — writes error on OOM        | Redis as durable store, not a cache                   |

**Common pitfall:** volatile-* policies only consider keys with a TTL set. If no keys have a TTL, behavior silently falls back to noeviction — memory fills and writes fail. Confirm TTL usage before selecting a volatile-* policy.

**Action item:** confirm target eviction policy per instance/use case with Garry.

## 8. Observability Setup — Open Items

- Grafana/Prometheus scraping requires VPC peering to reach Redis metrics endpoints; not currently possible in our GCP setup as configured.
- **Action item:** work with Elliot to determine a viable path (e.g., exporter sidecar, private endpoint, alternate scrape topology).

## Next Steps

1. Finalize eviction policy standard(s) with Garry.
2. Resolve Prometheus/Grafana connectivity with Elliot.
3. Define alert thresholds for p95/p99 duration, cache hit ratio, and eviction rate per instance tier.
4. Document maxmemory sizing standard per environment (dev/qa/prod).
