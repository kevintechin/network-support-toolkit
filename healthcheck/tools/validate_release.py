#!/usr/bin/env python3
from pathlib import Path
import sys, json, hashlib, re

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
TOOL_VERSION = '1.2.1'
FUNCTION_COUNT = 77
failures=[]; passes=[]

def ok(name, cond, detail=''):
    (passes if cond else failures).append((name, detail))

def read_text(p): return p.read_text(encoding='utf-8-sig')

def strip_ps(text):
    text=text.lstrip('\ufeff').replace('\r\n','\n').replace('\r','\n')
    out=[]; i=0; n=len(text)
    while i<n:
        c=text[i]
        if c=='#':
            e=text.find('\n',i); i=n if e<0 else e; continue
        if c=='@' and i+1<n and text[i+1] in "\"'":
            e=text.find('\n',i+2); e=n if e<0 else e
            if text[i+2:e].strip()=='':
                q=text[i+1]; end=q+'@'; i=e+1
                while i<n:
                    z=text.find('\n',i); z=n if z<0 else z
                    if text[i:z].strip()==end: i=z+1; break
                    i=z+1
                out.append('<STR>'); continue
        if c=="'":
            i+=1
            while i<n:
                if text[i]=="'":
                    if i+1<n and text[i+1]=="'": i+=2; continue
                    i+=1; break
                i+=1
            out.append('<STR>'); continue
        if c=='"':
            i+=1
            while i<n:
                if text[i]=='`': i+=2; continue
                if text[i]=='"': i+=1; break
                i+=1
            out.append('<STR>'); continue
        out.append(c); i+=1
    return re.sub(r'\s+','', ''.join(out))

required=[
 'zh-TW/NetworkHealthCheck.ps1','zh-TW/NetworkHealthCheck.config.json','zh-TW/Start-NetworkCheck.cmd','zh-TW/Start-NetworkCheck-IT.cmd',
 'en-US/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.config.json','en-US/Start-NetworkCheck.cmd','en-US/Start-NetworkCheck-IT.cmd',
 'docs/NetworkHealthCheck_Technical_Guide_zh-TW.md','docs/NetworkHealthCheck_Technical_Guide_en-US.md'
]
for rel in required: ok('required file '+rel,(ROOT/rel).is_file())
for rel in ['zh-TW/NetworkHealthCheck.config.json','en-US/NetworkHealthCheck.config.json']:
    try: json.loads(read_text(ROOT/rel)); ok('JSON parse '+rel,True)
    except Exception as e: ok('JSON parse '+rel,False,str(e))
for rel in ['zh-TW/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.ps1','zh-TW/NetworkHealthCheck.config.json','en-US/NetworkHealthCheck.config.json']:
    b=(ROOT/rel).read_bytes(); ok('UTF-8 BOM '+rel,b.startswith(b'\xef\xbb\xbf')); ok('CRLF '+rel,b'\r\n' in b and b'\n' not in b.replace(b'\r\n',b''))
for rel in ['zh-TW/Start-NetworkCheck.cmd','en-US/Start-NetworkCheck.cmd','zh-TW/Start-NetworkCheck-Console.cmd','en-US/Start-NetworkCheck-Console.cmd','zh-TW/Start-NetworkCheck-IT.cmd','en-US/Start-NetworkCheck-IT.cmd']:
    b=(ROOT/rel).read_bytes(); ok('CMD CRLF '+rel,b'\r\n' in b and b'\n' not in b.replace(b'\r\n',b'')); ok('CMD script reference '+rel,b'NetworkHealthCheck.ps1' in b)
zh=read_text(ROOT/'zh-TW/NetworkHealthCheck.ps1'); en=read_text(ROOT/'en-US/NetworkHealthCheck.ps1')
ok('PowerShell executable skeleton equality',strip_ps(zh)==strip_ps(en))
zh_funcs=re.findall(r'^function\s+([A-Za-z0-9_-]+)',zh,re.M); en_funcs=re.findall(r'^function\s+([A-Za-z0-9_-]+)',en,re.M)
ok('function set equality',zh_funcs==en_funcs,f'zh={len(zh_funcs)}, en={len(en_funcs)}'); ok(f'function count {FUNCTION_COUNT}',len(zh_funcs)==FUNCTION_COUNT,str(len(zh_funcs)))
cjk=lambda s:any('\u4e00'<=c<='\u9fff' for c in s)
for rel in ['en-US/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.config.json','en-US/README_en-US.txt']:
    ok('English file has no CJK '+rel,not cjk(read_text(ROOT/rel)))
for rel in ['zh-TW/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.ps1']:
    ok('version '+TOOL_VERSION+' '+rel,'$script:ToolVersion = "'+TOOL_VERSION+'"' in read_text(ROOT/rel))
# New-Object argument lists are parsed in expression mode, where the comma binds tighter than + (v1.2.0 shipped
# `Point(22, 84 + $offset)` = three arguments, and the GUI fell back to console mode): arithmetic must be parenthesized.
def unparenthesized_arithmetic(text):
    hits=[]
    for n,line in enumerate(text.splitlines(),1):
        m=re.search(r'New-Object [A-Za-z.]+\((.*)\)\s*$',line)
        if not m: continue
        depth=0; prev=''
        for c in m.group(1):
            if c in '([': depth+=1
            elif c in ')]': depth-=1
            elif depth==0 and (c in '+*/' or (c=='-' and prev not in '(, ')): hits.append(n); break
            if c!=' ': prev=c
    return hits
for rel in ['zh-TW/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.ps1']:
    hits=unparenthesized_arithmetic(read_text(ROOT/rel)); ok('New-Object arguments parenthesized '+rel,not hits,'lines '+', '.join(map(str,hits)) if hits else '')
# A script's top-level scope and its $script: scope are the same variable table, so a top-level
# `$script:<Parameter> = <literal>` overwrites the bound parameter (v1.2.0 wrote `$script:Interactive = $false` and
# the IT launcher opened the user layout): such a line must derive its value from the parameter itself.
def overwritten_parameters(text):
    head=text.split('\n)',1)[0]; params=re.findall(r'\[[\w\[\].]+\]\$(\w+)',head); hits=[]
    for n,line in enumerate(text.splitlines(),1):
        m=re.match(r'^\$script:(\w+)\s*=\s*(.*)$',line)
        if m and m.group(1) in params and ('$'+m.group(1)) not in m.group(2): hits.append(f'{n} (${m.group(1)})')
    return hits
for rel in ['zh-TW/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.ps1']:
    hits=overwritten_parameters(read_text(ROOT/rel)); ok('parameters not overwritten at script scope '+rel,not hits,'lines '+', '.join(hits) if hits else '')
# Hash manifest is checked if already present.
manifest=ROOT/'SHA256SUMS.txt'
if manifest.exists():
    for raw in read_text(manifest).splitlines():
        if not raw.strip(): continue
        expected, rel=raw.split('  ',1); p=ROOT/rel
        actual=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else ''
        ok('SHA256 '+rel,actual==expected,actual)
print(f'Root: {ROOT}')
for name,detail in passes: print('[PASS]',name,detail)
for name,detail in failures: print('[FAIL]',name,detail)
print(f'Summary: {len(passes)} passed, {len(failures)} failed')
sys.exit(1 if failures else 0)
