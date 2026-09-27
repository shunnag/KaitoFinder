from pathlib import Path
import json, os, subprocess, sys, time
repo=Path.cwd()
main=repo/'build/s41-p7a-correction-2'
control=repo/'build/s41-p7a-correction-2-items'
all_edits='--all-edits' in sys.argv
name='all-edits' if all_edits else 'replace-only'
root=main/name
root.mkdir(exist_ok=True)
phases=[]
for label, build in [('items-1',control),('batch-1',main),('batch-2',main),('items-2',control)]:
 env=dict(os.environ, KAITOFINDER_PERFORMANCE_PROBES='1',KAITOFINDER_REPLACEMENT_PROBE='1',
          KAITOFINDER_REPLACEMENT_RUNS='3' if all_edits else '7',KAITOFINDER_PROBE_FORMATS='lha',
          KAITOFINDER_PROBE_ENTRIES='100000',KAITOFINDER_PROBE_PAYLOAD_MIB='256',KAITO_TEST_TIMEOUT='900',
          KAITOFINDER_REPLACEMENT_OUTPUT=str(root/label), KAITOFINDER_REPLACEMENT_ALL_EDITS='1' if all_edits else '0')
 command=['python3',str(build/'run-tests.py'),'PerformanceProbeTests/testReplacementForCorrection2']
 print('Phase '+name+'/'+label+' load '+str(os.getloadavg()),flush=True)
 started=time.time()
 subprocess.run(command,env=env,check=True)
 result=json.loads((build/'test-results.json').read_text())[-1]
 phases.append({'label':label,'build':str(build),'command':command,'start':started,'end':time.time(),'load':os.getloadavg(),'result':result})
 (root/'phases.json').write_text(json.dumps(phases,indent=2)+'\n')
 if result['exit']!=0 or len(result['cases'])!=1 or result['cases'][0][2]!='passed':raise SystemExit('Probe failed')
