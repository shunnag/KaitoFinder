from pathlib import Path
import json, subprocess, shutil
root=Path(__file__).resolve().parent
repo=root.parent.parent
framework=root/'KaitoFinder.framework'
if not framework.exists():
 shutil.copytree(repo/'build/P4AS21Verification/KaitoFinder.framework',framework,symlinks=True)
binary=framework/'Versions/A/KaitoFinder'
shutil.copy2(root/'libKaitoFinder.dylib',binary)
identity='@rpath/KaitoFinder.framework/Versions/A/KaitoFinder'
commands=[['/usr/bin/install_name_tool','-id',identity,str(binary)]]
test=root/'P1dAS33Tests.xctest/Contents/MacOS/KaitoFinderTests'
libs=subprocess.check_output(['/usr/bin/otool','-L',str(test)],text=True)
old=next((line.strip().split(' (')[0] for line in libs.splitlines() if 'libKaitoFinder.dylib' in line),None)
if old: commands.append(['/usr/bin/install_name_tool','-change',old,identity,str(test)])
resources=framework/'Versions/A/Resources'
for catalog in ['Localizable','GoMenu']:
 commands.append(['/usr/bin/xcrun','xcstringstool','compile','--output-directory',str(resources),str(root/'KaitoFinder/KaitoFinder/Resources'/(catalog+'.xcstrings'))])
for command in commands:
 subprocess.run(command,check=True,stdout=subprocess.DEVNULL)
(root/'resource-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
print('Packaged current app library and both catalogs')
