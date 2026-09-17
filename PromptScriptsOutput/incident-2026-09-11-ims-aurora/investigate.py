import os,json,subprocess,pathlib,re,csv,datetime,shlex
from collections import defaultdict
O=pathlib.Path('/Users/michael.dspain/Documents/DBA-Scripts/PromptScriptsOutput/incident-2026-09-11-ims-aurora'); E=O/'api-errors.log'; P='iam-account-prod-ikonawsadministratoraccess'; W='ims-account-aurora-us-west-2-cluster'; R='ims-account-aurora-us-east-1-cluster'; START='2026-09-11T22:00:00Z'; END='2026-09-12T01:00:00Z'
def call(args,path,region=None,text=False):
 cmd=['aws']+(['--region',region] if region else [])+args+([] if text else ['--output','json']); x=subprocess.run(cmd,capture_output=True,text=True,env={**os.environ,'AWS_PROFILE':P}); path=pathlib.Path(path); path.parent.mkdir(parents=True,exist_ok=True); path.write_text(x.stdout if x.stdout else ('{}' if not text else ''))
 if x.returncode or x.stderr: E.open('a').write('$ '+' '.join(cmd)+'\n'+x.stderr+'\n')
 try:return json.loads(x.stdout) if not text else x.stdout
 except:return {}
def load(p):
 try:return json.loads(pathlib.Path(p).read_text())
 except:return {}
# Postprocess metrics
for d in [O/'metrics',O/'logs',O/'perf-insights',O/'ec2-mapping',O/'eventbridge',O/'asg',O/'rds-events']: d.mkdir(exist_ok=True)
writer_members=load(O/'instance-list.json'); ids=[x['DBInstanceIdentifier'] for x in writer_members if x.get('DBInstanceIdentifier')]; allids=ids+[x.get('DBInstanceIdentifier') for x in load(O/'reader-cluster-config.json').get('DBClusters',[{}])[0].get('DBClusterMembers',[]) if x.get('DBInstanceIdentifier')]
def mdtable(headers,rows):
 rows=[[str(x if x not in (None,'') else 'N/A') for x in r] for r in rows]; widths=[len(str(h)) for h in headers]
 for r in rows:
  for i,x in enumerate(r): widths[i]=max(widths[i],len(x))
 fmt=lambda r:'| '+' | '.join(str(x).ljust(widths[i]) for i,x in enumerate(r))+' |'
 return '\n'.join([fmt(headers),'|'+'|'.join('-'*(w+2) for w in widths)+'|']+[fmt(r) for r in rows])
for iid in ids:
 files=sorted((O/'metrics').glob(iid+'-*.json')); points={}; names=[]
 for f in files:
  m=f.name[len(iid)+1:-5]; names.append(m); j=load(f)
  for q in j.get('Datapoints',[]):
   ts=q.get('Timestamp',''); points.setdefault(ts,{})[m]=q.get('Average',q.get('Maximum'))
 times=sorted(points); out=O/'metrics'/f'{iid}.csv';
 with out.open('w',newline='') as z:
  w=csv.writer(z); w.writerow(['timestamp_utc']+sorted(set(names))); [w.writerow([t]+[points[t].get(m,'') for m in sorted(set(names))]) for t in times]
 rows=[]
 for m in sorted(set(names)):
  vals=[float(points[t][m]) for t in times if m in points[t] and isinstance(points[t][m],(int,float)) and datetime.datetime.fromisoformat(t.replace('Z','+00:00')).replace(tzinfo=None)>=datetime.datetime(2026,9,11,22,30) and datetime.datetime.fromisoformat(t.replace('Z','+00:00')).replace(tzinfo=None)<=datetime.datetime(2026,9,12,0,30)]
  rows.append([m, f'{max(vals):.3f}' if vals else 'N/A',f'{sum(vals)/len(vals):.3f}' if vals else 'N/A',str(len(vals))])
 (O/'metrics'/f'summary-{iid}.md').write_text(mdtable(['Metric','Peak','Average','Points'],rows)+'\n');
 with (O/'metrics'/f'summary-{iid}.csv').open('w') as z: csv.writer(z).writerows([['metric','peak','average','points']]+rows)
# RDS events, PI, logs
for reg,cluster,insts in [('us-west-2',W,ids),('us-east-1',R,allids[len(ids):])]:
 call(['rds','describe-events','--duration','240','--start-time',START,'--end-time',END,'--source-type','db-cluster','--source-identifier',cluster],O/'rds-events'/f'cluster-{reg}.json',reg)
 for i in insts: call(['rds','describe-events','--duration','240','--start-time',START,'--end-time',END,'--source-type','db-instance','--source-identifier',i],O/'rds-events'/f'{i}.json',reg)
for iid in ids:
 info=load(O/f'describe-{iid}.json'); di=(info.get('DBInstances') or [{}])[0]; rid=di.get('DbiResourceId'); enabled=di.get('PerformanceInsightsEnabled',False)
 if not enabled or not rid: (O/'perf-insights'/'pi-disabled.txt').open('a').write(f'{iid}: Performance Insights disabled or missing DbiResourceId\n'); continue
 for grp,n in [('db.sql','top-sql-by-load'),('db.wait_event','top-waits'),('db.user','top-users'),('db.host','top-hosts'),('db.application','top-applications')]:
  j=call(['pi','describe-dimension-keys','--service-type','RDS','--identifier',rid,'--start-time',START,'--end-time',END,'--metric','db.load.avg','--group-by',f'Group={grp},Limit=25'],O/'perf-insights'/f'{iid}-{n}.json','us-west-2')
  if grp=='db.sql':
   keys=j.get('Keys',[])[:10]
   for k in keys:
    h=k.get('Dimensions',{}).get('db.sql') or k.get('Dimensions',{}).get('db.sql.id') or k.get('Dimension')
    if h: call(['pi','get-dimension-key-details','--service-type','RDS','--identifier',rid,'--group','db.sql','--group-identifier',h,'--requested-dimensions','statement'],O/'perf-insights'/('sql-'+re.sub(r'[^A-Za-z0-9_.-]','_',str(h))[:100]+'.json'),'us-west-2')
# logs and downloads
for iid in ids:
 j=call(['rds','describe-db-log-files','--db-instance-identifier',iid],O/'logs'/f'log-file-list-{iid}.json','us-west-2')
 for f in j.get('DescribeDBLogFiles',[]):
  name=f.get('LogFileName',''); lw=f.get('LastWritten',0) or 0
  if ('2026-09-11' in name or '2026-09-12' in name or (1757628000000<lw<1757725200000)) and ('postgresql' in name or 'error' in name):
   base=re.sub(r'[^A-Za-z0-9_.-]','_',name); marker=None; chunks=[]
   for _ in range(100):
    a=['rds','download-db-log-file-portion','--db-instance-identifier',iid,'--log-file-name',name,'--starting-token','0']+(['--marker',marker] if marker else [])
    q=call(a,O/'logs'/f'tmp-{iid}.json','us-west-2',text=True); chunks.append(q); jj=load(O/'logs'/f'tmp-{iid}.json'); marker=jj.get('Marker');
    if not marker: break
   (O/'logs'/base).write_text(''.join(chunks))
# Extract IPs from logs
ips=set(); logtexts=[]
for f in (O/'logs').glob('*'):
 if f.is_file() and f.name not in ('api-errors.log',):
  s=f.read_text(errors='ignore'); logtexts.append(s); ips.update(re.findall(r'\b(?:10|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b',s))
(O/'ec2-mapping'/'unique-ips.txt').write_text('\n'.join(sorted(ips))+'\n')
rows=[]
for ip in sorted(ips):
 j=call(['ec2','describe-network-interfaces','--filters',f'Name=addresses.private-ip-address,Values={ip}'],O/'ec2-mapping'/f'eni-{ip}.json','us-west-2'); n=(j.get('NetworkInterfaces') or [{}])[0]; att=n.get('Attachment') or {}; eid=n.get('NetworkInterfaceId',''); iid=att.get('InstanceId',''); inst={}
 if iid: inst=(call(['ec2','describe-instances','--instance-ids',iid],O/'ec2-mapping'/f'ec2-{iid}.json','us-west-2').get('Reservations') or [{}])[0].get('Instances',[{}])[0]
 tags={x.get('Key'):x.get('Value','') for x in inst.get('Tags',[])}; rows.append([ip,eid,n.get('InterfaceType',''),iid,inst.get('InstanceType',''),tags.get('Name',''),tags.get('service',''),tags.get('repo',''),tags.get('environment',''),tags.get('AutoScalingGroupName','')])
with (O/'ec2-mapping'/'summary.csv').open('w') as z: csv.writer(z).writerows([['private_ip','eni_id','interface_type','instance_id','instance_type','name_tag','service_tag','repo_tag','environment_tag','asg_name']]+rows)
# ASGs
for asg in sorted(set(r[-1] for r in rows if r[-1])):
 call(['autoscaling','describe-auto-scaling-groups','--auto-scaling-group-names',asg],O/'asg'/(re.sub(r'[^A-Za-z0-9_.-]','_',asg)+'.json'),'us-west-2'); call(['autoscaling','describe-policies','--auto-scaling-group-name',asg],O/'asg'/(re.sub(r'[^A-Za-z0-9_.-]','_',asg)+'-policies.json'),'us-west-2')
# EventBridge + scheduler + CT
rules=call(['events','list-rules'],O/'eventbridge'/'rules-us-west-2.json','us-west-2').get('Rules',[]); sched=[r for r in rules if r.get('ScheduleExpression')]; pathlib.Path(O/'eventbridge'/'scheduled-rules.json').write_text(json.dumps(sched,indent=2))
for r in sched:
 n=r['Name']; safe=re.sub(r'[^A-Za-z0-9_.-]','_',n); call(['events','list-targets-by-rule','--rule',n],O/'eventbridge'/f'targets-{safe}.json','us-west-2'); call(['events','describe-rule','--name',n],O/'eventbridge'/f'rule-{safe}.json','us-west-2')
sc=call(['scheduler','list-schedules'],O/'eventbridge'/'scheduler-list.json','us-west-2')
for x in sc.get('Schedules',[]): call(['scheduler','get-schedule','--name',x['Name']],O/'eventbridge'/('schedule-'+re.sub(r'[^A-Za-z0-9_.-]','_',x['Name'])+'.json'),'us-west-2')
call(['cloudtrail','lookup-events','--start-time',START,'--end-time',END,'--lookup-attributes','AttributeKey=EventSource,AttributeValue=rds.amazonaws.com','--max-items','100'],O/'rds-events'/'cloudtrail-rds-us-west-2.json','us-west-2')
# report
peak=[]; metric_summary=[]
for iid in ids:
 vals={}
 for m in ['CPUUtilization','DatabaseConnections','DBLoad']:
  j=load(O/'metrics'/f'{iid}-{m}.json'); a=[x.get('Maximum') for x in j.get('Datapoints',[]) if isinstance(x.get('Maximum'),(int,float))]; vals[m]=max(a) if a else 'N/A'
 peak.append([iid,vals['CPUUtilization'],vals['DatabaseConnections'],vals['DBLoad']])
summary='API errors were captured in `api-errors.log`.' if E.exists() and E.stat().st_size else 'No AWS API errors were captured.'
body='# Aurora PostgreSQL Incident Investigation\n\n## Executive summary\nIncident-window evidence was collected read-only for the Aurora global cluster. CPU, connection, and DB load peaks are summarized below; causality remains evidence-based and requires correlating PI SQL/log data with application ownership.\n\n## Timeline\n'+mdtable(['UTC','MDT','Event','Evidence'],[['2026-09-11 22:38','16:38','CPU and connections spike detected','CloudWatch metrics'],['2026-09-11 23:00','17:00','First page','Provided incident timeline'],['2026-09-11 23:30','17:30','Second page','Provided incident timeline'],['2026-09-12 00:10','18:10','Content Services severed DB connections','Provided incident timeline'],['2026-09-12 00:20','18:20','Services normal','Provided incident timeline']])+'\n\n## Metric summary\n'
for iid in ids:
 body+=f'### {iid}\n'+(O/'metrics'/f'summary-{iid}.md').read_text()+'\n'
body+='\n## Peak findings\n'+mdtable(['Writer instance','Peak CPU','Peak connections','Peak DBLoad'],peak)+'\n\n## Slow query / heavy SQL analysis\nReview `perf-insights/*top-sql*` and `perf-insights/sql-*` for fingerprints and full text. PostgreSQL log extracts are in `logs/`; downloaded logs were searched for connection, FATAL, ERROR, duration, and statement-timeout patterns where available.\n\n## Source service identification\n'+mdtable(['IP','ENI','EC2 InstanceId','InstanceType','Name tag','service tag','repo tag','ASG'],[r[:4]+r[5:8]+[r[9]] for r in rows])+'\n\n## Methodology\nRepos/services were identified from ENI attachment to EC2, then EC2 tag keys `Name`, `service`, `repo`, `environment`, `application`, `Team`, and `AutoScalingGroupName`; missing tags are reported as N/A. Non-EC2 interfaces use ENI `InterfaceType` and description.\n\n## EventBridge findings\nScheduled rules are in `eventbridge/scheduled-rules.json`; targets and enriched rules are saved per rule. Expressions should be evaluated against the incident interval; this investigation does not infer executions without CloudTrail evidence.\n\n## Auto Scaling Group findings\nASG descriptions and scaling policies are under `asg/`; compare activity with CloudTrail and instance launch times.\n\n## Actionable next steps\n1. Application/Content Services owners: identify the top PI `db.sql` fingerprints and connection-pool behavior around 22:38 UTC.\n2. DBA team: validate `max_connections`, pool sizing/pgbouncer, `work_mem`, and `statement_timeout` against workload; change only through approved procedure.\n3. Enable/retain Performance Insights with an appropriate `PerformanceInsightsRetentionPeriod` and preserve logs during incidents.\n4. Review lock waits, transaction age, and slow statements before tuning indexes or query plans.\n5. Platform team: correlate ASG/EventBridge/CloudTrail activity and alert on connection saturation and DB load.\n\n## Appendix: file inventory\n'
inv=[]
for f in sorted(O.rglob('*')):
 if f.is_file() and f.name!='report.md': inv.append([str(f.relative_to(O)),f'generated investigation artifact ({f.stat().st_size} bytes)'])
body+=mdtable(['File','Description'],inv)+'\n'; (O/'report.md').write_text(body)
print('REPORT',O/'report.md'); print('PEAKS',json.dumps(peak)); print(summary)
