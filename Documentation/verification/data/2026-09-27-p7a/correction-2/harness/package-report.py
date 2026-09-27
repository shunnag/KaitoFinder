from pathlib import Path
import json,gzip,hashlib,shutil,difflib,subprocess,re
repo=Path.cwd();root=repo/'build/s41-p7a-correction-2';control=repo/'build/s41-p7a-correction-2-items'
out=repo/'Documentation/verification/data/2026-09-27-p7a/correction-2';(out/'logs').mkdir(parents=True,exist_ok=True);(out/'traces').mkdir(exist_ok=True);(out/'harness').mkdir(exist_ok=True)
def write(name,data): (out/name).write_text(json.dumps(data,indent=2)+'\n')
def packed(path,name):
 path=Path(path);raw=path.read_bytes();dest=out/'logs'/(name+'.gz');dest.write_bytes(gzip.compress(raw,mtime=0))
 return {'path':'logs/'+dest.name,'sha256_uncompressed':hashlib.sha256(raw).hexdigest()}
builds={};runs={};archive={};checks=json.loads((root/'source-checks.json').read_text())
for label,build in [('S41',root),('S39-caller',control)]:
 builds[label]=json.loads((build/'build-runs.json').read_text());archive[label]=json.loads((build/'archive-checks.json').read_text())
 values=json.loads((build/'test-results.json').read_text())
 for i,r in enumerate(values,1):r['retained_log']=packed(r['log'],label+'-'+Path(r['log']).name)
 runs[label]=values
full=json.loads((root/'full-sequence/phases.json').read_text())
for r in full:r['retained_log']=packed(r['log'],'full-'+r['label']+'.log')
runs['full-sequence']=full
native=json.loads((root/'native-sequence/run.json').read_text());native['retained_log']=packed(root/'native-sequence/xcodebuild.log','native-xcodebuild.log');runs['native-attempt']=native
write('build-runs.json',builds);write('runs.json',runs);write('checks.json',{'archives':archive,'sources_and_dependencies':checks})
case_rows=[c for label in ['S41','S39-caller'] for r in runs[label] for c in r['cases']]+[c for r in full for c in r['cases']]
write('summary.json',{'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'compiler_invocations':sum(len(v) for v in builds.values()),'compiler_failures':sum(r['exit']!=0 for v in builds.values() for r in v),'xctest_invocations':len(runs['S41'])+len(runs['S39-caller'])+len(full),'cases':{v:sum(c[2]==v for c in case_rows) for v in ['passed','failed','skipped']},'native_test_cases_started':0,'native_exit':native['exit']})
original=json.loads((root/'orchestrator-comparison.json').read_text())
original['rows']={label:{k:v for k,v in rows.items() if k.startswith('lha/payload/') or k.endswith('/payload/immediate/replace_file')} for label,rows in original['rows'].items()}
original['test_times']=json.loads((root/'orchestrator-test-times.json').read_text());write('orchestrator-comparison.json',original)
focused={kind:json.loads((root/kind/'analysis.json').read_text()) for kind in ['replace-only','all-edits']};write('focused-analysis.json',focused)
full_analysis=json.loads((root/'full-sequence/analysis.json').read_text());write('full-sequence-analysis.json',full_analysis)
for path in (root/'full-sequence').glob('*/full-lha-payload-immediate-replace_file.json'):shutil.copy2(path,out/'traces'/(path.parent.name+'.json'))
# Preserve exactly the isolated test changes used by the final probes, without changing canonical test sources.
patch=[]
for name in ['PerformanceProbeTests.swift','Support/ArchivePerformanceProbe.swift','ReplacementProbeTests.swift']:
 src=repo/'KaitoFinderTests'/name;temp=root/'KaitoFinder/KaitoFinderTests'/name
 before=src.read_text() if src.exists() else ''
 patch.extend(difflib.unified_diff(before.splitlines(True),temp.read_text().splitlines(True),fromfile='a/KaitoFinderTests/'+name if src.exists() else '/dev/null',tofile='b/KaitoFinderTests/'+name))
(out/'diagnostic-test-changes.diff').write_text(''.join(patch))
for name in ['build.py','run-tests.py','package-resources.py','paired.py','full-sequence.py','native-sequence.py','analyze.py','summarize-full.py','read-orchestrator.py','package-report.py']:
 shutil.copy2(root/name,out/'harness'/name)
shutil.copy2(control/'build.py',out/'harness/control-build.py')
print((out/'summary.json').read_text());print('Retained bytes:',sum(p.stat().st_size for p in out.rglob('*') if p.is_file()))
