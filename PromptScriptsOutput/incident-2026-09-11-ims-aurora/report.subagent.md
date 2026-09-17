# Aurora PostgreSQL Incident Investigation

## Executive summary
Incident-window evidence was collected read-only for the Aurora global cluster. CPU, connection, and DB load peaks are summarized below; causality remains evidence-based and requires correlating PI SQL/log data with application ownership.

## Timeline
| UTC              | MDT   | Event                                   | Evidence                   |
|------------------|-------|-----------------------------------------|----------------------------|
| 2026-09-11 22:38 | 16:38 | CPU and connections spike detected      | CloudWatch metrics         |
| 2026-09-11 23:00 | 17:00 | First page                              | Provided incident timeline |
| 2026-09-11 23:30 | 17:30 | Second page                             | Provided incident timeline |
| 2026-09-12 00:10 | 18:10 | Content Services severed DB connections | Provided incident timeline |
| 2026-09-12 00:20 | 18:20 | Services normal                         | Provided incident timeline |

## Metric summary
### ims-account-aurora-us-west-2-cluster-2
| Metric                    | Peak            | Average         | Points |
|---------------------------|-----------------|-----------------|--------|
| ActiveTransactions        | N/A             | N/A             | 0      |
| BlockedTransactions       | N/A             | N/A             | 0      |
| BufferCacheHitRatio       | 100.000         | 99.174          | 121    |
| CPUUtilization            | 15.318          | 2.476           | 121    |
| CommitLatency             | 0.088           | 0.016           | 121    |
| CommitThroughput          | 1737.128        | 178.076         | 121    |
| DBLoad                    | N/A             | N/A             | 0      |
| DBLoadCPU                 | N/A             | N/A             | 0      |
| DBLoadNonCPU              | N/A             | N/A             | 0      |
| DatabaseConnections       | 1819.000        | 249.298         | 121    |
| DeadlocksActive           | N/A             | N/A             | 0      |
| DeadlocksAvgDuration      | N/A             | N/A             | 0      |
| DiskQueueDepth            | 0.000           | 0.000           | 120    |
| EBSByteBalance%           | N/A             | N/A             | 0      |
| EBSIOBalance%             | N/A             | N/A             | 0      |
| FreeableMemory            | 74827390976.000 | 74155245229.488 | 121    |
| MaximumUsedTransactionIDs | 185324600.000   | 185090533.446   | 121    |
| NetworkReceiveThroughput  | 774145.250      | 84890.544       | 121    |
| NetworkTransmitThroughput | 1054176.892     | 114934.507      | 121    |
| ReadIOPS                  | 28.240          | 0.932           | 120    |
| ReadLatency               | 0.001           | 0.000           | 120    |
| ReadThroughput            | 231343.720      | 7633.834        | 120    |
| ReplicationSlotDiskUsage  | -1.000          | -1.000          | 121    |
| SwapUsage                 | 0.000           | 0.000           | 121    |
| WriteIOPS                 | 872.644         | 56.602          | 120    |
| WriteLatency              | 0.001           | 0.000           | 120    |
| WriteThroughput           | 221637.665      | 13893.896       | 120    |

### ims-account-aurora-us-west-2-cluster-1
| Metric                    | Peak            | Average         | Points |
|---------------------------|-----------------|-----------------|--------|
| ActiveTransactions        | N/A             | N/A             | 0      |
| BlockedTransactions       | N/A             | N/A             | 0      |
| BufferCacheHitRatio       | 100.000         | 100.000         | 121    |
| CPUUtilization            | 0.882           | 0.588           | 121    |
| CommitLatency             | 0.011           | 0.010           | 121    |
| CommitThroughput          | 218385.964      | 1805.855        | 121    |
| DBLoad                    | N/A             | N/A             | 0      |
| DBLoadCPU                 | N/A             | N/A             | 0      |
| DBLoadNonCPU              | N/A             | N/A             | 0      |
| DatabaseConnections       | 17.000          | 17.000          | 121    |
| DeadlocksActive           | N/A             | N/A             | 0      |
| DeadlocksAvgDuration      | N/A             | N/A             | 0      |
| DiskQueueDepth            | 0.000           | 0.000           | 121    |
| EBSByteBalance%           | N/A             | N/A             | 0      |
| EBSIOBalance%             | N/A             | N/A             | 0      |
| FreeableMemory            | 74792701952.000 | 74768906967.802 | 121    |
| MaximumUsedTransactionIDs | 185325557.000   | 185092376.190   | 121    |
| NetworkReceiveThroughput  | 8434.716        | 8407.574        | 121    |
| NetworkTransmitThroughput | 5867.265        | 5848.405        | 121    |
| ReadIOPS                  | 100.410         | 0.830           | 121    |
| ReadLatency               | 0.001           | 0.000           | 121    |
| ReadThroughput            | 822559.056      | 6798.009        | 121    |
| ReplicationSlotDiskUsage  | -1.000          | -1.000          | 121    |
| SwapUsage                 | 0.000           | 0.000           | 121    |
| WriteIOPS                 | 0.000           | 0.000           | 121    |
| WriteLatency              | 0.000           | 0.000           | 121    |
| WriteThroughput           | 0.000           | 0.000           | 121    |

### ims-account-aurora-us-west-2-cluster-0
| Metric                    | Peak            | Average         | Points |
|---------------------------|-----------------|-----------------|--------|
| ActiveTransactions        | N/A             | N/A             | 0      |
| BlockedTransactions       | N/A             | N/A             | 0      |
| BufferCacheHitRatio       | 100.000         | 99.149          | 118    |
| CPUUtilization            | 99.848          | 72.521          | 121    |
| CommitLatency             | 57.170          | 4.003           | 118    |
| CommitThroughput          | 7869.522        | 5491.999        | 118    |
| DBLoad                    | N/A             | N/A             | 0      |
| DBLoadCPU                 | N/A             | N/A             | 0      |
| DBLoadNonCPU              | N/A             | N/A             | 0      |
| DatabaseConnections       | 4504.000        | 2899.933        | 120    |
| DeadlocksActive           | N/A             | N/A             | 0      |
| DeadlocksAvgDuration      | N/A             | N/A             | 0      |
| DiskQueueDepth            | 9.000           | 0.655           | 116    |
| EBSByteBalance%           | N/A             | N/A             | 0      |
| EBSIOBalance%             | N/A             | N/A             | 0      |
| FreeableMemory            | 74657640448.000 | 62923390118.291 | 117    |
| MaximumUsedTransactionIDs | 185325881.000   | 185086825.162   | 117    |
| NetworkReceiveThroughput  | 3436858.131     | 2445486.301     | 120    |
| NetworkTransmitThroughput | 5389049.975     | 3732956.192     | 120    |
| ReadIOPS                  | 0.017           | 0.000           | 116    |
| ReadLatency               | 0.001           | 0.000           | 116    |
| ReadThroughput            | 136.538         | 1.177           | 116    |
| ReplicationSlotDiskUsage  | -1.000          | -1.000          | 120    |
| SwapUsage                 | 0.000           | 0.000           | 117    |
| WriteIOPS                 | 3093.250        | 703.904         | 116    |
| WriteLatency              | 0.002           | 0.001           | 116    |
| WriteThroughput           | 798877.273      | 158370.281      | 116    |


## Peak findings
| Writer instance                        | Peak CPU           | Peak connections | Peak DBLoad |
|----------------------------------------|--------------------|------------------|-------------|
| ims-account-aurora-us-west-2-cluster-2 | 15.318333333333333 | 1819.0           | N/A         |
| ims-account-aurora-us-west-2-cluster-1 | 0.8816813613560227 | 17.0             | N/A         |
| ims-account-aurora-us-west-2-cluster-0 | 99.84833333333333  | 4504.0           | N/A         |

## Slow query / heavy SQL analysis
Review `perf-insights/*top-sql*` and `perf-insights/sql-*` for fingerprints and full text. PostgreSQL log extracts are in `logs/`; downloaded logs were searched for connection, FATAL, ERROR, duration, and statement-timeout patterns where available.

## Source service identification
| IP        | ENI | EC2 InstanceId | InstanceType | Name tag | service tag | repo tag | ASG |
|-----------|-----|----------------|--------------|----------|-------------|----------|-----|
| 10.127.26 | N/A | N/A            | N/A          | N/A      | N/A         | N/A      | N/A |

## Methodology
Repos/services were identified from ENI attachment to EC2, then EC2 tag keys `Name`, `service`, `repo`, `environment`, `application`, `Team`, and `AutoScalingGroupName`; missing tags are reported as N/A. Non-EC2 interfaces use ENI `InterfaceType` and description.

## EventBridge findings
Scheduled rules are in `eventbridge/scheduled-rules.json`; targets and enriched rules are saved per rule. Expressions should be evaluated against the incident interval; this investigation does not infer executions without CloudTrail evidence.

## Auto Scaling Group findings
ASG descriptions and scaling policies are under `asg/`; compare activity with CloudTrail and instance launch times.

## Actionable next steps
1. Application/Content Services owners: identify the top PI `db.sql` fingerprints and connection-pool behavior around 22:38 UTC.
2. DBA team: validate `max_connections`, pool sizing/pgbouncer, `work_mem`, and `statement_timeout` against workload; change only through approved procedure.
3. Enable/retain Performance Insights with an appropriate `PerformanceInsightsRetentionPeriod` and preserve logs during incidents.
4. Review lock waits, transaction age, and slow statements before tuning indexes or query plans.
5. Platform team: correlate ASG/EventBridge/CloudTrail activity and alert on connection saturation and DB load.

## RDS event collection note
Corrected time-bounded `describe-events` requests were issued without `Duration`; the original AWS parameter-validation errors remain recorded in `api-errors.log`.

## Appendix: file inventory
| File                                                                          | Description                                     |
|-------------------------------------------------------------------------------|-------------------------------------------------|
| api-errors.log                                                                | generated investigation artifact (6196 bytes)   |
| cluster-writer-config.json                                                    | generated investigation artifact (3673 bytes)   |
| describe-ims-account-aurora-us-east-1-cluster-0.json                          | generated investigation artifact (5547 bytes)   |
| describe-ims-account-aurora-us-east-1-cluster-1.json                          | generated investigation artifact (5547 bytes)   |
| describe-ims-account-aurora-us-east-1-cluster-2.json                          | generated investigation artifact (5547 bytes)   |
| describe-ims-account-aurora-us-west-2-cluster-0.json                          | generated investigation artifact (5547 bytes)   |
| describe-ims-account-aurora-us-west-2-cluster-1.json                          | generated investigation artifact (5547 bytes)   |
| describe-ims-account-aurora-us-west-2-cluster-2.json                          | generated investigation artifact (5547 bytes)   |
| discovery_metrics.py                                                          | generated investigation artifact (3125 bytes)   |
| ec2-mapping/eni-10.127.26.json                                                | generated investigation artifact (32 bytes)     |
| ec2-mapping/summary.csv                                                       | generated investigation artifact (135 bytes)    |
| ec2-mapping/unique-ips.txt                                                    | generated investigation artifact (10 bytes)     |
| eventbridge/rules-us-west-2.json                                              | generated investigation artifact (2902 bytes)   |
| eventbridge/scheduled-rules.json                                              | generated investigation artifact (2 bytes)      |
| eventbridge/scheduler-list.json                                               | generated investigation artifact (24 bytes)     |
| instance-list.json                                                            | generated investigation artifact (541 bytes)    |
| investigate.py                                                                | generated investigation artifact (12158 bytes)  |
| logs/error_postgresql.log.2026-09-12-1800                                     | generated investigation artifact (26 bytes)     |
| logs/error_postgresql.log.2026-09-12-1900                                     | generated investigation artifact (26 bytes)     |
| logs/error_postgresql.log.2026-09-12-2000                                     | generated investigation artifact (26 bytes)     |
| logs/error_postgresql.log.2026-09-12-2100                                     | generated investigation artifact (26 bytes)     |
| logs/error_postgresql.log.2026-09-12-2200                                     | generated investigation artifact (26 bytes)     |
| logs/error_postgresql.log.2026-09-12-2300                                     | generated investigation artifact (26 bytes)     |
| logs/log-file-list-ims-account-aurora-us-west-2-cluster-0.json                | generated investigation artifact (11279 bytes)  |
| logs/log-file-list-ims-account-aurora-us-west-2-cluster-1.json                | generated investigation artifact (11277 bytes)  |
| logs/log-file-list-ims-account-aurora-us-west-2-cluster-2.json                | generated investigation artifact (11330 bytes)  |
| logs/tmp-ims-account-aurora-us-west-2-cluster-0.json                          | generated investigation artifact (26 bytes)     |
| logs/tmp-ims-account-aurora-us-west-2-cluster-1.json                          | generated investigation artifact (26 bytes)     |
| logs/tmp-ims-account-aurora-us-west-2-cluster-2.json                          | generated investigation artifact (995 bytes)    |
| metrics/cluster-AuroraReplicaLag.json                                         | generated investigation artifact (30187 bytes)  |
| metrics/cluster-AuroraReplicaLagMaximum.json                                  | generated investigation artifact (29439 bytes)  |
| metrics/cluster-ServerlessDatabaseCapacity.json                               | generated investigation artifact (68 bytes)     |
| metrics/cluster-VolumeBytesUsed.json                                          | generated investigation artifact (6505 bytes)   |
| metrics/cluster-VolumeReadIOPs.json                                           | generated investigation artifact (5878 bytes)   |
| metrics/cluster-VolumeWriteIOPs.json                                          | generated investigation artifact (6131 bytes)   |
| metrics/ims-account-aurora-us-west-2-cluster-0-ActiveTransactions.json        | generated investigation artifact (60 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-BlockedTransactions.json       | generated investigation artifact (61 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-BufferCacheHitRatio.json       | generated investigation artifact (34646 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-CPUUtilization.json            | generated investigation artifact (39771 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-CommitLatency.json             | generated investigation artifact (42649 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-CommitThroughput.json          | generated investigation artifact (41516 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-DBLoad.json                    | generated investigation artifact (48 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-DBLoadCPU.json                 | generated investigation artifact (51 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-DBLoadNonCPU.json              | generated investigation artifact (54 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-DatabaseConnections.json       | generated investigation artifact (34876 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-DeadlocksActive.json           | generated investigation artifact (57 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-DeadlocksAvgDuration.json      | generated investigation artifact (62 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-DiskQueueDepth.json            | generated investigation artifact (32785 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-EBSByteBalance%.json           | generated investigation artifact (57 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-EBSIOBalance%.json             | generated investigation artifact (55 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-0-FreeableMemory.json            | generated investigation artifact (38252 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-MaximumUsedTransactionIDs.json | generated investigation artifact (37207 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-NetworkReceiveThroughput.json  | generated investigation artifact (42481 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-NetworkTransmitThroughput.json | generated investigation artifact (42383 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-ReadIOPS.json                  | generated investigation artifact (34052 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-ReadLatency.json               | generated investigation artifact (33156 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-ReadThroughput.json            | generated investigation artifact (34055 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-ReplicationSlotDiskUsage.json  | generated investigation artifact (34080 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-SwapUsage.json                 | generated investigation artifact (32967 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-WriteIOPS.json                 | generated investigation artifact (39489 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-WriteLatency.json              | generated investigation artifact (40165 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0-WriteThroughput.json           | generated investigation artifact (39754 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-0.csv                            | generated investigation artifact (42118 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-ActiveTransactions.json        | generated investigation artifact (60 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-BlockedTransactions.json       | generated investigation artifact (61 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-BufferCacheHitRatio.json       | generated investigation artifact (35165 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-CPUUtilization.json            | generated investigation artifact (41502 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-CommitLatency.json             | generated investigation artifact (43028 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-CommitThroughput.json          | generated investigation artifact (41177 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-DBLoad.json                    | generated investigation artifact (48 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-DBLoadCPU.json                 | generated investigation artifact (51 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-DBLoadNonCPU.json              | generated investigation artifact (54 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-DatabaseConnections.json       | generated investigation artifact (34265 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-DeadlocksActive.json           | generated investigation artifact (57 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-DeadlocksAvgDuration.json      | generated investigation artifact (62 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-DiskQueueDepth.json            | generated investigation artifact (33720 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-EBSByteBalance%.json           | generated investigation artifact (57 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-EBSIOBalance%.json             | generated investigation artifact (55 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-1-FreeableMemory.json            | generated investigation artifact (39120 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-MaximumUsedTransactionIDs.json | generated investigation artifact (38051 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-NetworkReceiveThroughput.json  | generated investigation artifact (42325 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-NetworkTransmitThroughput.json | generated investigation artifact (42149 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-ReadIOPS.json                  | generated investigation artifact (35016 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-ReadLatency.json               | generated investigation artifact (34131 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-ReadThroughput.json            | generated investigation artifact (35022 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-ReplicationSlotDiskUsage.json  | generated investigation artifact (34270 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-SwapUsage.json                 | generated investigation artifact (33715 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-WriteIOPS.json                 | generated investigation artifact (34975 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-WriteLatency.json              | generated investigation artifact (34078 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1-WriteThroughput.json           | generated investigation artifact (34981 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-1.csv                            | generated investigation artifact (35953 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-ActiveTransactions.json        | generated investigation artifact (60 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-BlockedTransactions.json       | generated investigation artifact (61 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-BufferCacheHitRatio.json       | generated investigation artifact (36722 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-CPUUtilization.json            | generated investigation artifact (40263 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-CommitLatency.json             | generated investigation artifact (43214 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-CommitThroughput.json          | generated investigation artifact (40982 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-DBLoad.json                    | generated investigation artifact (48 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-DBLoadCPU.json                 | generated investigation artifact (51 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-DBLoadNonCPU.json              | generated investigation artifact (54 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-DatabaseConnections.json       | generated investigation artifact (34535 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-DeadlocksActive.json           | generated investigation artifact (57 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-DeadlocksAvgDuration.json      | generated investigation artifact (62 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-DiskQueueDepth.json            | generated investigation artifact (33533 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-EBSByteBalance%.json           | generated investigation artifact (57 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-EBSIOBalance%.json             | generated investigation artifact (55 bytes)     |
| metrics/ims-account-aurora-us-west-2-cluster-2-FreeableMemory.json            | generated investigation artifact (39120 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-MaximumUsedTransactionIDs.json | generated investigation artifact (38051 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-NetworkReceiveThroughput.json  | generated investigation artifact (42247 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-NetworkTransmitThroughput.json | generated investigation artifact (42215 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-ReadIOPS.json                  | generated investigation artifact (36667 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-ReadLatency.json               | generated investigation artifact (36186 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-ReadThroughput.json            | generated investigation artifact (36697 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-ReplicationSlotDiskUsage.json  | generated investigation artifact (34270 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-SwapUsage.json                 | generated investigation artifact (33715 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-WriteIOPS.json                 | generated investigation artifact (36665 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-WriteLatency.json              | generated investigation artifact (36256 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2-WriteThroughput.json           | generated investigation artifact (36572 bytes)  |
| metrics/ims-account-aurora-us-west-2-cluster-2.csv                            | generated investigation artifact (40119 bytes)  |
| metrics/summary-ims-account-aurora-us-west-2-cluster-0.csv                    | generated investigation artifact (969 bytes)    |
| metrics/summary-ims-account-aurora-us-west-2-cluster-0.md                     | generated investigation artifact (2175 bytes)   |
| metrics/summary-ims-account-aurora-us-west-2-cluster-1.csv                    | generated investigation artifact (946 bytes)    |
| metrics/summary-ims-account-aurora-us-west-2-cluster-1.md                     | generated investigation artifact (2175 bytes)   |
| metrics/summary-ims-account-aurora-us-west-2-cluster-2.csv                    | generated investigation artifact (965 bytes)    |
| metrics/summary-ims-account-aurora-us-west-2-cluster-2.md                     | generated investigation artifact (2175 bytes)   |
| perf-insights/pi-disabled.txt                                                 | generated investigation artifact (570 bytes)    |
| rds-events/cloudtrail-rds-us-west-2.json                                      | generated investigation artifact (214675 bytes) |
| rds-events/cluster-us-east-1.json                                             | generated investigation artifact (2 bytes)      |
| rds-events/cluster-us-west-2.json                                             | generated investigation artifact (2 bytes)      |
| rds-events/ims-account-aurora-us-east-1-cluster-0.json                        | generated investigation artifact (2 bytes)      |
| rds-events/ims-account-aurora-us-east-1-cluster-1.json                        | generated investigation artifact (2 bytes)      |
| rds-events/ims-account-aurora-us-east-1-cluster-2.json                        | generated investigation artifact (2 bytes)      |
| rds-events/ims-account-aurora-us-west-2-cluster-0.json                        | generated investigation artifact (2 bytes)      |
| rds-events/ims-account-aurora-us-west-2-cluster-1.json                        | generated investigation artifact (2 bytes)      |
| rds-events/ims-account-aurora-us-west-2-cluster-2.json                        | generated investigation artifact (2 bytes)      |
| reader-cluster-config.json                                                    | generated investigation artifact (3744 bytes)   |
