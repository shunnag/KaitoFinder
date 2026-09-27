from pathlib import Path
from collections import OrderedDict
import json,hashlib,re,os
base=Path(os.environ['SP'])
root=Path(__file__).resolve().parent
allrows={}; sources={}
for label,folder,run in [('B1','bp39',1),('S1','bp41',1),('S2','bp41',2),('B2','bp39',2)]:
 p=base/folder/f'probe-p7p0b-r{run}.log';raw=p.read_bytes();lines=raw.decode().splitlines(); groups=OrderedDict()
 for n,line in enumerate(lines,1):
  if not line.startswith('PROBE-TSV\t'):continue
  cols=line.split('\t');key='/'.join(cols[2:6]);stage=cols[6]
  groups.setdefault(key,{})[stage]={'calls':int(cols[7]),'ms':float(cols[8]),'read':cols[9],'written':cols[10],'output':cols[11],'line':n}
 allrows[label]=groups
 sources[label]={'path':str(p),'sha256':hashlib.sha256(raw).hexdigest(),'start':lines[0],'end':lines[-1],
 'test_lines':[x for x in lines if x.startswith('Test Case')],
 'lha_deferred_timing':[x for x in lines[6756:6905] if x.startswith('PROBE deferred')],
 'stage_order':[x for x in lines if x.startswith('PROBE-STAGE-BEGIN lha/payload/immediate/replace_file/')],
 'progress':[x for x in lines if x.startswith('PROBE-PROGRESS\tlha\tpayload\treplace_file')]}
 print(label,sources[label]['lha_deferred_timing'][:6])
key='lha/payload/immediate/replace_file'
keys=list(allrows['B1']);i=keys.index(key)
print('Nearby totals ms: B1 S1 S2 B2')
for k in keys[i-7:i+8]:
 print(k,' '.join(f"{allrows[l][k].get('total',{}).get('ms',0):.3f}" for l in allrows))
print('Replacement stages: B1 S1 S2 B2')
for stage in allrows['B1'][key]:
 print(stage,' '.join(f"{allrows[l][key].get(stage,{}).get('ms',0):.3f}" for l in allrows))
for l in allrows:
 d=allrows[l][key];s=sum(v['ms'] for k,v in d.items() if k!='total');print(l,'named sum',round(s,3),'total minus sum',round(d['total']['ms']-s,3),sources[l]['progress'])
(root/'orchestrator-comparison.json').write_text(json.dumps({'sources':sources,'rows':allrows},indent=2)+'\n')
