import os, json, subprocess, pathlib, re
from datetime import datetime
OUT=pathlib.Path('/Users/michael.dspain/Documents/DBA-Scripts/PromptScriptsOutput/incident-2026-09-11-ims-aurora'); ERR=OUT/'api-errors.log'; PROFILE='iam-account-prod-ikonawsadministratoraccess'
def run(args,out,region=None):
    cmd=['aws']+(['--region',region] if region else [])+args+['--output','json']
    e=subprocess.run(cmd,text=True,capture_output=True,env={**os.environ,'AWS_PROFILE':PROFILE})
    pathlib.Path(out).write_text(e.stdout if e.stdout else ('{}' if e.returncode==0 else ''))
    if e.returncode or e.stderr: ERR.open('a').write(f"{' '.join(cmd)}\n{e.stderr}\n")
    try:return json.loads(e.stdout or '{}')
    except:return {}
writer='ims-account-aurora-us-west-2-cluster'; reader='ims-account-aurora-us-east-1-cluster'
c=run(['rds','describe-db-clusters','--db-cluster-identifier',writer],OUT/'cluster-writer-config.json','us-west-2')
run(['rds','describe-db-clusters','--db-cluster-identifier',reader],OUT/'reader-cluster-config.json','us-east-1')
cl=(c.get('DBClusters') or [{}])[0]; members=cl.get('DBClusterMembers',[])
(OUT/'instance-list.json').write_text(json.dumps(members,indent=2))
ids=[x.get('DBInstanceIdentifier') for x in members if x.get('DBInstanceIdentifier')]
# include reader cluster members for event/PI context
rc=run(['rds','describe-db-clusters','--db-cluster-identifier',reader],OUT/'reader-cluster-config.json','us-east-1'); rids=[x.get('DBInstanceIdentifier') for x in ((rc.get('DBClusters') or [{}])[0].get('DBClusterMembers',[])) if x.get('DBInstanceIdentifier')]
for region, names in [('us-west-2',ids),('us-east-1',rids)]:
 for i in names: run(['rds','describe-db-instances','--db-instance-identifier',i],OUT/f'describe-{i}.json',region)
metrics=['CPUUtilization','DatabaseConnections','ReadIOPS','WriteIOPS','ReadLatency','WriteLatency','ReadThroughput','WriteThroughput','FreeableMemory','SwapUsage','NetworkReceiveThroughput','NetworkTransmitThroughput','DiskQueueDepth','BufferCacheHitRatio','CommitLatency','CommitThroughput','DBLoad','DBLoadCPU','DBLoadNonCPU','MaximumUsedTransactionIDs','DeadlocksActive','DeadlocksAvgDuration','ActiveTransactions','BlockedTransactions','ReplicationSlotDiskUsage','EBSByteBalance%','EBSIOBalance%']
start='2026-09-11T22:00:00Z'; end='2026-09-12T01:00:00Z'
for i in ids:
 for m in metrics: run(['cloudwatch','get-metric-statistics','--namespace','AWS/RDS','--metric-name',m,'--dimensions',f'Name=DBInstanceIdentifier,Value={i}','--statistics','Average','Maximum','Minimum','--period','60','--start-time',start,'--end-time',end],OUT/'metrics'/f'{i}-{m}.json','us-west-2')
for m in ['VolumeBytesUsed','VolumeReadIOPs','VolumeWriteIOPs','AuroraReplicaLag','AuroraReplicaLagMaximum','ServerlessDatabaseCapacity']:
 run(['cloudwatch','get-metric-statistics','--namespace','AWS/RDS','--metric-name',m,'--dimensions',f'Name=DBClusterIdentifier,Value={writer}','--statistics','Average','Maximum','--period','60','--start-time',start,'--end-time',end],OUT/'metrics'/f'cluster-{m}.json','us-west-2')
print(json.dumps({'writer_instances':ids,'reader_instances':rids}))
