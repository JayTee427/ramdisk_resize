"""Tiny x64 disassembler for RAMDiskVE.sys (capstone + pefile).

usage:
  rdis.py <file.sys> strings            every instruction that references a string, with the string
  rdis.py <file.sys> imports            every instruction that references an import
  rdis.py <file.sys> find <text>        instructions whose annotation contains <text>
  rdis.py <file.sys> refs <hexoff>      instructions using [reg + <hexoff>] (e.g. refs b20 -> device-extension field 0xb20)
  rdis.py <file.sys> <lo> <hi>          disassemble RVA range [lo, hi) (hex)

Python adds the script's own folder to sys.path, so keep this file in a folder without a dis.py.
"""
import sys, re, pefile, capstone
from capstone import x86

pe = pefile.PE(sys.argv[1]); base = pe.OPTIONAL_HEADER.ImageBase
data = pe.get_memory_mapped_image()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64); md.detail = True
text = [s for s in pe.sections if s.Name.startswith(b'.text') or s.Characteristics & 0x20000000]
# map strings
strs = {}
for m in re.finditer(rb'(?:[\x20-\x7e]\x00){4,}', data):
    strs[m.start()] = m.group().decode('utf-16le')
for m in re.finditer(rb'[\x20-\x7e]{5,}\x00', data):
    strs.setdefault(m.start(), m.group()[:-1].decode())
# imports
imps = {}
for e in pe.DIRECTORY_ENTRY_IMPORT:
    for i in e.imports: imps[i.address - base] = (i.name or b'?').decode()
insns = []
for s in text:
    a = s.VirtualAddress; code = data[a:a + s.Misc_VirtualSize]
    off = 0
    while off < len(code):
        got = False
        for ins in md.disasm(code[off:], a + off):
            insns.append(ins); off = ins.address - a + ins.size; got = True
        if not got or off < len(code): off += 1
def ann(ins):
    out = ''
    for op in ins.operands:
        if op.type == x86.X86_OP_MEM and op.mem.base == x86.X86_REG_RIP:
            t = ins.address + ins.size + op.mem.disp
            if t in strs: out += '  ; "%s"' % strs[t][:90]
            elif t in imps: out += '  ; [' + imps[t] + ']'
            else: out += '  ; ->%x' % t
    return out
def show(ins): print('%x  %-7s %s%s' % (ins.address, ins.mnemonic, ins.op_str, ann(ins)))

cmd = sys.argv[2]
if cmd in ('strings', 'imports', 'find'):
    pat = {'strings': '; "', 'imports': '; ['}.get(cmd) or sys.argv[3]
    for ins in insns:
        if pat in ann(ins): show(ins)
elif cmd == 'refs':
    disp = int(sys.argv[3], 16)
    for ins in insns:
        if any(op.type == x86.X86_OP_MEM and op.mem.base != x86.X86_REG_RIP and op.mem.disp == disp for op in ins.operands): show(ins)
else:
    lo = int(sys.argv[2], 16); hi = int(sys.argv[3], 16)
    for ins in insns:
        if lo <= ins.address < hi: show(ins)
