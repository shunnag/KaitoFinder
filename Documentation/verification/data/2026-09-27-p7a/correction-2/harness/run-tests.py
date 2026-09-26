from pathlib import Path
import json, os, subprocess, sys, re
root=Path(__file__).resolve().parent
repo=root.parent.parent
env=dict(os.environ,DYLD_LIBRARY_PATH=str(root),DYLD_FRAMEWORK_PATH=str(root)+':'+str(repo/'build/Review0924Opt/Build/Products/Debug'),TZ='Asia/Tokyo')
results=json.loads((root/'test-results.json').read_text()) if (root/'test-results.json').exists() else []
for selection in sys.argv[1:]:
 print('Running '+selection,flush=True)
 cmd=['/Applications/Xcode.app/Contents/Developer/usr/bin/xctest','-XCTest','KaitoFinderTests.'+selection,str(root/'P1dAS33Tests.xctest')]
 path=root/(str(len(results)+1).zfill(3)+'-'+selection.replace('/','-')+'.log')
 with path.open('w') as log:
  try: code=subprocess.run(cmd,env=env,cwd=repo,stdout=log,stderr=subprocess.STDOUT,timeout=float(os.environ.get("KAITO_TEST_TIMEOUT", "240"))).returncode
  except subprocess.TimeoutExpired: code='timeout'
 text=path.read_text(errors='replace')
 cases=re.findall(r"Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|failed|skipped)",text)
 results.append({'selection':selection,'exit':code,'command':cmd,'log':str(path),'environment':{k:v for k,v in env.items() if k.startswith(('KAITOFINDER_', 'DYLD_')) or k=='TZ'},'cases':cases})
 (root/'test-results.json').write_text(json.dumps(results,indent=2))
 print(selection+': '+str(code)+'; '+str({k:sum(c[2]==k for c in cases) for k in ['passed','failed','skipped']}),flush=True)
 if code: print('\n'.join(line for line in text.splitlines() if 'error:' in line or 'failed' in line)[-4000:],flush=True)
