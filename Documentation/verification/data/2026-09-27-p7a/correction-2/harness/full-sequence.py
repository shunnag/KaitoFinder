from pathlib import Path
import os,json,subprocess,time,re,sys
repo=Path.cwd();main=repo/'build/s41-p7a-correction-2';control=repo/'build/s41-p7a-correction-2-items'
root=main/'full-sequence';root.mkdir(exist_ok=True)
methods=['testArchiveEditsWhenEnabled','testArchiveEditorsDirectlyWhenEnabled','testArchiveOpeningWhenEnabled']
phases=json.loads((root/'phases.json').read_text()) if (root/'phases.json').exists() else []
lookup={'batch-1':main,'items-1':control,'batch-2':main,'items-2':control}
for label in sys.argv[1:]:
 build=lookup[label]
 env=dict(os.environ,KAITOFINDER_PERFORMANCE_PROBES='1',KAITOFINDER_PROBE_ENTRIES='100000',KAITOFINDER_PROBE_PAYLOAD_MIB='256',
 KAITOFINDER_PROBE_FORMATS='zip,tar,tar.gz,tar.bz2,tar.xz,7z,lha',KAITOFINDER_CORRECTION2_FULL_TIMELINE='1',
 KAITOFINDER_REPLACEMENT_OUTPUT=str(root/label),DYLD_LIBRARY_PATH=str(build),
 DYLD_FRAMEWORK_PATH=str(build)+':'+str(repo/'build/Review0924Opt/Build/Products/Debug'),TZ='Asia/Tokyo')
 cmd=['/Applications/Xcode.app/Contents/Developer/usr/bin/xctest','-XCTest',','.join('KaitoFinderTests.PerformanceProbeTests/'+m for m in methods),str(build/'P1dAS33Tests.xctest')]
 start=time.time();load=os.getloadavg();path=root/(label+'.log')
 print('Starting',label,time.strftime('%Y-%m-%d %H:%M:%S'),load,flush=True)
 with path.open('w') as log:
  log.write('START '+str(start)+' LOAD '+str(load)+'\n');log.flush()
  try:code=subprocess.run(cmd,env=env,cwd=repo,stdout=log,stderr=subprocess.STDOUT,timeout=1200).returncode
  except subprocess.TimeoutExpired:code='timeout'
  log.write('END '+str(time.time())+' LOAD '+str(os.getloadavg())+'\n')
 text=path.read_text(errors='replace');cases=re.findall(r"Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|failed|skipped)",text)
 result={'label':label,'build':str(build),'command':cmd,'log':str(path),'start':start,'end':time.time(),'load_start':load,'load_end':os.getloadavg(),'exit':code,'cases':cases,'environment':{k:v for k,v in env.items() if k.startswith(('KAITOFINDER_','DYLD_')) or k=='TZ'}}
 phases.append(result);(root/'phases.json').write_text(json.dumps(phases,indent=2)+'\n')
 print('Completed',label,'exit',code,'cases',cases,'elapsed',round(time.time()-start,3),flush=True)
 if code or len(cases)!=3 or any(x[2]!='passed' for x in cases):raise SystemExit('Full sequence failed: '+label)
