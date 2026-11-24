import subprocess, sys, re, os, json
R='/Users/andrewlee/Documents/WebDev/pixel3-ios-dev/work/ref/metal2vulkan'
B=R+'/target/release/metal2vulkan'; P=R+'/crates/metal2vulkan-validation/profiles/'+os.environ.get('M2V_PROFILE','lavapipe')+'.json'
S=sys.argv[1]; lib=sys.argv[2]; tag=sys.argv[3]
out=f'{S}/spv/{tag}'; os.makedirs(out,exist_ok=True)
def run(args,name):
    for f in os.listdir(out):
        if f.startswith(name+'.'): os.remove(os.path.join(out,f))
    try:
        vd=[] if '--fragment' not in args else ['--vertex-descriptor',f'{S}/spv/vd.json']
        r=subprocess.run([B,lib,f'{out}/{name}.spv','--profile',P]+vd+args,capture_output=True,text=True,timeout=120)
        msg=(r.stdout+r.stderr).strip().splitlines()[-1:] 
    except subprocess.TimeoutExpired: msg=['TIMEOUT']
    ok=any(f.startswith(name+'.') and f.endswith('.spv') for f in os.listdir(out))
    return ok,(msg[0] if msg else '')
r=subprocess.run([B,lib,'/dev/null','--profile',P],capture_output=True,text=True)
fns=re.findall(r'([A-Za-z0-9_]+) \((Vertex|Fragment|Kernel)\)',r.stdout+r.stderr)
verts=[f for f,k in fns if k=='Vertex']
res={'ok':0,'bad':[]}
def pick_vert(frag):
    base=re.sub(r'_(frag)','',frag); suf=frag.rsplit('_',1)[-1]
    cands=[v for v in verts if v.endswith(suf) and v.split('_vert')[0] and frag.startswith(v.split('_vert')[0])]
    return cands[0] if cands else (verts[0] if verts else None)
for f,k in fns:
    if k=='Kernel':
        ok,m=run(['--function',f],f)
        if not ok and 'TileAttachments' in m: ok,m=run(['--function',f,'--color-format','0:BGRA8Unorm','--color-format','1:RGBA16Float'],f)
    elif k=='Fragment':
        first=pick_vert(f)
        if not first: continue
        cf=[]
        for i in range(4): cf+=['--color-format',f'{i}:RGBA16Float' if i else '0:BGRA8Unorm']
        ok=False; m=''
        for v in [first]+[x for x in verts if x!=first]:
            ok,m=run(['--function',v,'--fragment',f]+cf,f)
            tries=0
            while not ok and 'ColorAttachment { index: ' in m and tries<40:
                i=int(m.split('ColorAttachment { index: ')[1].split(',')[0]); tries+=1
                fmts=['RG16Float','R32Uint','R16Float','R8Unorm','RGBA8Unorm','R32Float','RG32Float','RGBA32Float','R16Uint','RGBA16Uint','R32Sint','RGBA32Uint','RG16Uint','RGBA8Uint','RG8Unorm','R16Unorm','RGBA16Float']
                cur=[cf[j+1] for j in range(0,len(cf),2)]
                key=f'{i}:'; old=[c for c in cur if c.startswith(key)]
                oldf=old[0].split(':')[1] if old else None
                nxt=fmts[(fmts.index(oldf)+1)%len(fmts)] if oldf in fmts else fmts[0]
                if old: cf[cf.index(old[0])]=f'{i}:{nxt}'
                else: cf+=['--color-format',f'{i}:{nxt}']
                if nxt==fmts[-1] and oldf==fmts[-2]: break
                ok,m=run(['--function',v,'--fragment',f]+cf,f)
            if ok or 'UnmatchedVarying' not in m: break
    else:
        ok,m=run(['--function',f],f) if not any(k2=='Fragment' for _,k2 in fns) else (True,'(paired)')
        if m=='(paired)': continue
    if ok: res['ok']+=1
    else: res['bad'].append((f,m[:250]))
print(f"{tag}: {len(fns)} functions, ok {res['ok']}, failed {len(res['bad'])}")
for b in res['bad'][:15]: print('  ',b)
