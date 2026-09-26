from pathlib import Path
from collections import defaultdict
import json
root=Path(__file__).resolve().parent/'full-sequence'
rows=[]
for p in sorted(root.glob('*/full-*.json')):
 d=json.loads(p.read_text());es=d['events'];begin=next((e['ms'] for e in es if e['event']=='begin' and e['name']=='total'),None);end=next((e['ms'] for e in es if e['event']=='end' and e['name']=='total'),None)
 if begin is None or end is None:continue
 inside=[e for e in es if begin<=e['ms']<=end and e['name']!='total'];starts=defaultdict(list);spans=[];stages=defaultdict(float);observer={};observer_ms=[]
 for e in inside:
  name=e['name'];t=e['ms']
  if e['event']=='begin':starts[name].append(t)
  elif e['event']=='end' and starts[name]:
   left=starts[name].pop();spans.append((left,t,name));stages[name]+=t-left
  elif e['event']=='observer_begin':observer[name]=t
  elif e['event']=='observer_end' and name in observer:observer_ms.append((t-observer.pop(name),name))
 cursor=begin;previous='total_begin';gaps=[]
 for left,right,name in sorted(spans):
  if left>cursor:gaps.append({'ms':left-cursor,'after':previous,'before':name})
  if right>cursor:cursor=right;previous=name
 if end>cursor:gaps.append({'ms':end-cursor,'after':previous,'before':'total_end'})
 finish=[e['ms'] for e in inside if e['event']=='credit' and e['name'].startswith('finish_additions:')]
 row={'phase':p.parent.name,'label':d['label'],'total':end-begin,'stages':dict(stages),'observer_ms':sum(x[0] for x in observer_ms),
 'max_observer':max(observer_ms,default=(0,None)),'unattributed':sum(g['ms'] for g in gaps),'gaps':sorted(gaps,key=lambda g:g['ms'],reverse=True),
 'finish_additions_credit_interval':finish[-1]-finish[0] if finish else None,'load':d['load']}
 rows.append(row)
(root/'analysis.json').write_text(json.dumps(rows,indent=2)+'\n')
for r in rows:
 if r['label']=='full/lha/payload/immediate/replace_file':
  print(r['phase'],'total',round(r['total'],3),'unattributed',round(r['unattributed'],3),'observer',round(r['observer_ms'],3),'drain',round(r['finish_additions_credit_interval'] or 0,3),'mutate',round(r['stages'].get('mutate',0),3),'load',r['load'])
  print(' Largest gaps:',[(round(g['ms'],3),g['after'],g['before']) for g in r['gaps'][:4]])
