#!/usr/bin/env python3
"""Pre-push sanity check for the S2:U site. Exit 1 on problems."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
html = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
problems, warns = [], []

# media referenced by WORKS / LIST entries must exist
for m in sorted(set(re.findall(r"""v:\s*['"]([^'"]+\.(?:mp4|mov|webm))['"]""", html))):
    if not os.path.exists(os.path.join(ROOT, m)):
        problems.append(f"missing video file: {m}")
    poster = os.path.splitext(m)[0] + ".jpg"
    if not os.path.exists(os.path.join(ROOT, poster)):
        warns.append(f"no poster for {m} (expected {poster})")

# size limits
for name in os.listdir(ROOT):
    p = os.path.join(ROOT, name)
    if not os.path.isfile(p):
        continue
    mb = os.path.getsize(p) / 1e6
    if mb >= 95:
        problems.append(f"{name} is {mb:.0f} MB (GitHub limit 100 MB)")
    elif name.lower().endswith((".mp4", ".mov")) and mb > 8:
        warns.append(f"{name} is {mb:.1f} MB; compress for faster loading")
    elif name.lower().endswith((".jpg", ".jpeg", ".png")) and mb > 1:
        warns.append(f"{name} is {mb:.1f} MB; run scripts/prep-media.sh")

# domain binding must survive
cname = os.path.join(ROOT, "CNAME")
if not os.path.exists(cname) or open(cname).read().strip() != "sustaintoyou.com":
    problems.append("CNAME missing or wrong (must be sustaintoyou.com)")

# the data arrays the workflow relies on
for arr in ("sessions", "events", "photoSessions", "WORKS"):
    if not re.search(rf"\b(?:const|let)\s+{arr}\s*=\s*\[", html):
        problems.append(f"data array '{arr}' not found in index.html")

# crude bracket balance on the script block
script = "\n".join(re.findall(r"<script[^>]*>(.*?)</script>", html, re.S))
for a, b in ("()", "[]", "{}"):
    if script.count(a) != script.count(b):
        warns.append(f"unbalanced {a}{b} in <script> (could be inside strings; eyeball it)")

for w in warns:
    print("warn:", w)
for p in problems:
    print("FAIL:", p)
print("OK" if not problems else f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
