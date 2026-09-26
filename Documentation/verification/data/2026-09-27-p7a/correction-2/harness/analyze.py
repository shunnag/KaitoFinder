from pathlib import Path
from collections import defaultdict
import json, statistics, sys
root=Path(sys.argv[1])
rows=[]
for path in sorted(root.glob('*/*.json')):
    if path.name=='phases.json': continue
    data=json.loads(path.read_text()); events=data.get('events',[])
    totals=[]; opened=None
    for e in events:
        if e['name']=='total':
            if e['event']=='begin':opened=e['ms']
            elif e['event']=='end' and opened is not None:totals.append((opened,e['ms']));opened=None
    for ordinal,(begin,end) in enumerate(totals):
        inside=[e for e in events if begin<=e['ms']<=end and e['name']!='total']
        starts=defaultdict(list); stages=defaultdict(float); spans=[]
        for e in inside:
            if e['event']=='begin': starts[e['name']].append(e['ms'])
            elif e['event']=='end' and starts[e['name']]:
                left=starts[e['name']].pop();stages[e['name']]+=e['ms']-left
                spans.append((left,e['ms'],e['name']))
        cursor=begin; previous='total_begin'; gaps=[]
        for left,right,name in sorted(spans):
            if left>cursor:gaps.append({'ms':left-cursor,'after':previous,'before':name})
            if right>cursor:cursor=right;previous=name
        if end>cursor:gaps.append({'ms':end-cursor,'after':previous,'before':'total_end'})
        finish=[e['ms'] for e in inside if e['event']=='credit' and e['name'].startswith('finish_additions:')]
        rows.append({'phase':path.parent.name,'label':data['label'],'ordinal':ordinal,'load':data['load'],
          'total':end-begin,'stages':dict(stages),'unattributed':sum(g['ms'] for g in gaps),
          'leading_gap':gaps[0]['ms'] if gaps and gaps[0]['after']=='total_begin' else 0,
          'finish_additions':finish[-1]-finish[0] if finish else 0,'gaps':sorted(gaps,key=lambda g:g['ms'],reverse=True)})
(root/'analysis.json').write_text(json.dumps(rows,indent=2)+'\n')
for phase in sorted(set(r['phase'] for r in rows)):
    selected=[r for r in rows if r['phase']==phase and not r['label'].endswith('/r0')]
    if not selected:continue
    print(phase,'n',len(selected))
    for key in ['total','unattributed','leading_gap','finish_additions']:
        vs=[r[key] for r in selected];print(' ',key,'median',round(statistics.median(vs),3),'range',round(min(vs),3),round(max(vs),3))
    for key in ['mutate','commit','updater_open']:
        print(' ',key,round(statistics.median(r['stages'].get(key,0) for r in selected),3))
    print(' largest gaps',[(r['label'],{**r['gaps'][0],'ms':round(r['gaps'][0]['ms'],3)}) for r in selected][:8])
