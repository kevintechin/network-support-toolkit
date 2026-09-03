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
# Both guards below work on the comment-free logical lines of the whole file (block and line comments removed, backtick
# continuations joined); code inside here-strings or built dynamically (Invoke-Expression, splatted argument lists) is
# outside their scope by design.
def strip_block_comments(text):
    # <# ... #> may span lines and is removed only outside single / double quotes (a quoted "<#" is string data) and outside
    # line comments; the newlines it contained are kept so that reported line numbers stay valid. Line comments are copied
    # verbatim here and removed per line by strip_line_comment. PowerShell block comments do not nest (language
    # specification 2.2.3, 'Comments do not nest'; verified on Windows PowerShell 5.1: the first #> ends the comment).
    out=[]; q=None; i=0; n=len(text)
    while i<n:
        c=text[i]
        if q:
            if q=='"' and c=='`': out.append(text[i:i+2]); i+=2; continue
            if c==q and text[i+1:i+2]==q: out.append(q+q); i+=2; continue
            if c==q: q=None
            out.append(c); i+=1; continue
        if c=='"' or c=="'": q=c; out.append(c); i+=1; continue
        if c=='<' and text[i+1:i+2]=='#':
            e=text.find('#>',i+2); e=n if e<0 else e+2
            out.append('\n'*text.count('\n',i,e)); i=e; continue
        if c=='#':
            e=text.find('\n',i); e=n if e<0 else e
            out.append(text[i:e]); i=e; continue
        out.append(c); i+=1
    return ''.join(out)
def strip_line_comment(line, blank_single=False):
    # Drop <# ... #> and a trailing # comment that is outside single / double quotes, so comments never hide or fake a
    # pattern; with blank_single the contents of single-quoted strings are dropped too (nothing expands inside them).
    line=re.sub(r'<#.*?#>','',line); out=[]; q=None; i=0
    while i<len(line):
        c=line[i]
        if q:
            if q=='"' and c=='`': out.append(line[i:i+2]); i+=2; continue
            if c==q and line[i+1:i+2]==q:   # doubled quote inside a string ('' or "")
                if not (q=="'" and blank_single): out.append(q+q)
                i+=2; continue
            if c==q: q=None; out.append(c); i+=1; continue
            if not (q=="'" and blank_single): out.append(c)
            i+=1; continue
        if c=='"' or c=="'": q=c
        elif c=='#': break
        out.append(c); i+=1
    return ''.join(out)
def logical_lines(text, blank_single=False):
    # (first physical line number, text) per logical line: block comments removed (newlines kept), line comments removed,
    # and a physical line that ends with a backtick joined with the next one (PowerShell's explicit line continuation).
    out=[]; pending=None
    for i,raw in enumerate(strip_block_comments(text).splitlines(),1):
        line=strip_line_comment(raw,blank_single)
        if pending is None: pending=[i,line]
        else: pending[1]+=' '+line.lstrip()
        if pending[1].rstrip().endswith('`'): pending[1]=pending[1].rstrip()[:-1]; continue
        out.append((pending[0],pending[1])); pending=None
    if pending is not None: out.append((pending[0],pending[1]))
    return out
def unparenthesized_arithmetic(text):
    # Command names are case-insensitive. The argument list is `Type(...)` right after the type name, `-ArgumentList (...)`
    # (the balanced group, across lines), or an unparenthesized `-ArgumentList a, b ...` read up to the next parameter or end
    # of statement; string contents are skipped. A `+` at top level of any of these is the v1.2.0 mistake.
    lines=logical_lines(text); code='\n'.join(t for _,t in lines); hits=[]
    def scan(i,bare):
        depth=0; prev=''; q=None
        while i<len(code):
            c=code[i]
            if q:
                if q=='"' and c=='`': i+=2; continue
                if q=="'" and c=="'" and code[i+1:i+2]=="'": i+=2; continue
                if c==q: q=None
                i+=1; continue
            if c=='"' or c=="'": q=c
            elif c in '([': depth+=1
            elif c in ')]':
                if depth==0: return False
                depth-=1
            elif depth==0 and bare and (c in ';|}\n' or (c=='-' and code[i-1:i].isspace() and code[i+1:i+2].isalpha())): return False
            elif depth==0 and (c in '+*/%' or (c=='-' and prev not in '(, ')): return True
            if not c.isspace(): prev=c
            i+=1
        return False
    for m in re.finditer(r'\bnew-object\s+(?:-typename\s+)?[\w.\[\]]+\s*\(|\bnew-object\b[^()\n]*-argumentlist\s*(\()?',code,re.I):
        bare=m.group(0).rstrip().lower().endswith('-argumentlist')
        if scan(m.end(),bare): hits.append(lines[code.count('\n',0,m.start())][0])
    return hits
for rel in ['zh-TW/NetworkHealthCheck.ps1','en-US/NetworkHealthCheck.ps1']:
    hits=unparenthesized_arithmetic(read_text(ROOT/rel)); ok('New-Object arguments parenthesized '+rel,not hits,'lines '+', '.join(map(str,hits)) if hits else '')
# A script's top-level scope and its $script: scope are the same variable table, so a top-level
# `$script:<Parameter> = <literal>` overwrites the bound parameter (v1.2.0 wrote `$script:Interactive = $false` and
# the IT launcher opened the user layout): such a line, at any indentation, must use the parameter's own token on the right-hand
# side. Outside a function the same holds for unscoped assignments and for Set-Variable / New-Variable without -Scope.
def overwritten_parameters(text):
    head=text.split('\n)',1)[0]; params={x.lower() for x in re.findall(r'\[[\w\[\].]+\]\$(\w+)',head)}
    param_end=head.count('\n')+2   # the line holding the param block's closing ')'; defaults inside the block are not overwrites
    hits=[]; in_function=False
    # The only accepted initializer is the parameter itself: $Name or ${Name} (any case), optionally inside ( ) or @( ),
    # with at most one [type] cast outside or inside the parentheses and an optional .IsPresent. Anything else - a literal,
    # `$Name -and $false`, `"$Name"`, `$Name.Trim()`, `'a' + $Name` - is treated as an overwrite: a transformed value
    # belongs in a script variable with a different name.
    cast=r'(?:\[[\w.\[\]]+\]\s*)?'
    token=lambda name,expr: re.match(r'^'+cast+r'(?:@?\(\s*)?'+cast+r'\$\{?'+re.escape(name)+r'\}?(?:\.IsPresent)?\s*\)?$',expr.strip(),re.I) is not None
    for n,code in logical_lines(text,blank_single=True):   # comment-free, backtick continuations joined, single quotes blanked
        if n<=param_end: continue
        # Every function in these files opens with `function Name {` and closes with a column-0 `}`; everything else is
        # top level, where try / if / foreach blocks create no scope, so "local" means the script scope there.
        local=in_function
        if re.match(r'^function\s',code):
            # The declaration line is scanned as a body line: unscoped assignments on it are locals, explicit $script: /
            # $global: ones are not. A one-line `function F { ... }` is closed on its own line.
            local=True; in_function=('{' not in code) or (code.count('{')!=code.count('}'))
        elif code.rstrip()=='}': in_function=False
        # Assignment statements at every statement start of the line (line start, after `{`, after `;` - if / try / foreach
        # blocks create no scope): $Name, ${Name}, $script:Name, $Script:Name, ${script:Name}, $global:Name, $local:Name ...,
        # with or without type constraints / attributes in front ([bool]$script:Name = ..., [ValidateNotNull()][string[]]$Name = ...).
        # Names are case-insensitive like PowerShell's. The assigned expression (read up to the next `;` or `}`) must be the
        # parameter itself (see `token` above); comments and single-quoted strings were removed before matching.
        # Plain `=` must copy the parameter itself; a compound assignment (+= -= *= /= %=) or an increment / decrement
        # (prefix or postfix ++ / --) always changes the value and is an overwrite whatever follows.
        overwrite=lambda scope,name: name.lower() in params and (scope in ('script','global') or (scope in ('','local','private') and not local))
        for m in re.finditer(r'(?:^|[{;])\s*(?:\[[^=]*?\]\s*)*\$\{?(?:(\w+):)?(\w+)\}?\s*(?:(\+\+|--)|([-+*/%]?=)(?!=)\s*([^;}]*))',code,re.I):
            if overwrite((m.group(1) or '').lower(),m.group(2)) and (m.group(3) or m.group(4)!='=' or not token(m.group(2),m.group(5))): hits.append(f'{n} (${m.group(2)})')
        for m in re.finditer(r'(?:^|[{;])\s*(?:\+\+|--)\$\{?(?:(\w+):)?(\w+)\}?',code,re.I):   # prefix ++ / --
            if overwrite((m.group(1) or '').lower(),m.group(2)): hits.append(f'{n} (${m.group(2)})')
        # Set-Variable / New-Variable reach the same variable through the cmdlet interface: -Scope Script / Global (or a
        # numeric parent scope) anywhere, or no -Scope / -Scope Local at the top level. -Name may be positional.
        if re.search(r'\b(Set|New)-Variable\b',code,re.I):
            nm=re.search(r'-Name\s+["\']?(\w+)',code,re.I) or re.search(r'\b(?:Set|New)-Variable\s+(?!-)["\']?(\w+)',code,re.I)
            sc=re.search(r'-Scope\s+["\']?(\w+)',code,re.I); scope=(sc.group(1).lower() if sc else '')
            if nm and nm.group(1).lower() in params and (scope in ('script','global') or scope.isdigit() or (scope in ('','local') and not local)):
                hits.append(f'{n} (Set-Variable {nm.group(1)})')
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
