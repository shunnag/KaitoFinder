from pathlib import Path
import os,json,subprocess,time,shutil,hashlib
repo=Path.cwd();root=repo/'build/s41-p7a-correction-2/native-sequence';root.mkdir(exist_ok=True)
source=Path('/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad/bp41/dd-opt/Build/Products')
products=root/'Products';products.mkdir(exist_ok=True)
if not (products/'Debug').exists():
 subprocess.run(['cp','-cR',str(source/'Debug'),str(products/'Debug')],check=True)
runfile='KaitoFinder_macosx27.0-arm64.xctestrun';shutil.copy2(source/runfile,products/runfile)
checks={}
for rel in ['Debug/KaitoFinder.app/Contents/MacOS/KaitoFinder','Debug/KaitoFinder.app/Contents/PlugIns/KaitoFinderTests.xctest/Contents/MacOS/KaitoFinderTests']:
 checks[rel]={'source':hashlib.sha256((source/rel).read_bytes()).hexdigest(),'copy':hashlib.sha256((products/rel).read_bytes()).hexdigest()}
 assert checks[rel]['source']==checks[rel]['copy']
env=dict(os.environ,TEST_RUNNER_KAITOFINDER_PERFORMANCE_PROBES='1',TEST_RUNNER_KAITOFINDER_PROBE_ENTRIES='100000',TEST_RUNNER_KAITOFINDER_PROBE_PAYLOAD_MIB='256',TEST_RUNNER_KAITOFINDER_PROBE_FORMATS='zip,tar,tar.gz,tar.bz2,tar.xz,7z,lha')
cmd=['xcodebuild','test-without-building','-xctestrun',str(products/runfile),'-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO','-resultBundlePath',str(root/'result.xcresult')]
for m in ['testArchiveEditsWhenEnabled','testArchiveEditorsDirectlyWhenEnabled','testArchiveOpeningWhenEnabled']:cmd+=['-only-testing:KaitoFinderTests/PerformanceProbeTests/'+m]
record={'command':cmd,'source_products':str(source),'artifact_checks':checks,'environment':{k:v for k,v in env.items() if k.startswith('TEST_RUNNER_KAITOFINDER_')},'start':time.time(),'load_start':os.getloadavg()}
(root/'run.json').write_text(json.dumps(record,indent=2)+'\n');print('Starting native Xcode host attempt',flush=True)
with (root/'xcodebuild.log').open('w') as log:
 try:record['exit']=subprocess.run(cmd,env=env,cwd=repo,stdout=log,stderr=subprocess.STDOUT,timeout=900).returncode
 except subprocess.TimeoutExpired:record['exit']='timeout'
record.update(end=time.time(),load_end=os.getloadavg());(root/'run.json').write_text(json.dumps(record,indent=2)+'\n')
print('Native Xcode host exit',record['exit'],flush=True)
