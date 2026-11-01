#!/usr/bin/env python3
# Patch 8821au tasklet/callback signatures for Linux 5.10 + CFI.
# tasklet_init() calls its callback as void(unsigned long). The driver declares callbacks as
# void(void *) and casts them, which does not change the target type; CFI then traps.
# Fix: callbacks take unsigned long and convert back to void * inside.
import re
import sys
import pathlib

if len(sys.argv) != 2:
    print("usage: patch_tasklets.py <driver_dir>")
    sys.exit(2)

root = pathlib.Path(sys.argv[1])
names = ["usb_recv_tasklet", "rtl8812au_xmit_tasklet", "mpath_tx_tasklet_hdl"]
defs = {n: 0 for n in names}
changed = 0

for p in root.rglob("*"):
    if not p.is_file() or p.suffix not in (".c", ".h"):
        continue
    try:
        s = p.read_text(errors="ignore")
    except OSError:
        continue
    o = s
    for n in names:
        # definition: void NAME(void *priv) followed by { on the next line
        def_pat = r"void\s+" + n + r"\s*\(\s*void\s*\*\s*priv\s*\)\s*\n(\s*)\{"
        defs[n] += len(re.findall(def_pat, s))
        s = re.sub(
            def_pat,
            lambda m, n=n: "void " + n + "(unsigned long _priv)\n" + m.group(1)
            + "{\n" + m.group(1) + "\tvoid *priv = (void *)_priv;",
            s,
        )
        # prototype: void NAME(void *priv);
        s = re.sub(r"void\s+" + n + r"\s*\(\s*void\s*\*\s*priv\s*\)\s*;",
                   "void " + n + "(unsigned long _priv);", s)
        # casts at tasklet_init call sites: (void(*))NAME, (void(*)(unsigned long))NAME, (void *)NAME
        s = re.sub(r"\(\s*void\s*\(\s*\*\s*\)\s*(\(\s*unsigned long\s*\)\s*)?\)\s*" + n + r"\b", n, s)
        s = re.sub(r"\(\s*void\s*\*\s*\)\s*" + n + r"\b", n, s)
    if s != o:
        p.write_text(s)
        changed += 1
        print("patched:", p)

print("files changed:", changed)
for n in names:
    print("definitions patched for %s: %d" % (n, defs[n]))

missing = [n for n in names if defs[n] == 0]
if missing:
    print("ERROR: no matching definition for:", ", ".join(missing))
    sys.exit(1)

# verify: no old-style definitions left
left = []
for p in root.rglob("*"):
    if not p.is_file() or p.suffix not in (".c", ".h"):
        continue
    s = p.read_text(errors="ignore")
    for n in names:
        if re.search(r"void\s+" + n + r"\s*\(\s*void\s*\*\s*priv\s*\)", s):
            left.append((str(p), n))
if left:
    print("ERROR: old-style definitions still present:")
    for f, n in left:
        print("  ", f, n)
    sys.exit(1)

print("PASS: tasklet callbacks use unsigned long")
