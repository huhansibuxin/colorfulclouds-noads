# -*- coding: utf-8 -*-
"""Tweak.xm 结构自检：括号平衡 / Logos 指令配对 / 新增符号定义引用配对。
本机没有 theos 环境（铁律：不在本机构建），所以推 CI 前先用它做一轮廉价体检。"""
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "Tweak.xm"
src = open(PATH, encoding="utf-8").read()

BS = chr(92)   # backslash
SQ = chr(39)   # single quote
DQ = chr(34)   # double quote


def strip_comments_and_strings(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif c == "/" and i + 1 < n and s[i + 1] == "*":
            j = s.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c == DQ or c == SQ:
            quote = c
            i += 1
            while i < n and s[i] != quote:
                i += 2 if s[i] == BS else 1
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


body = strip_comments_and_strings(src)
ok = True
for op, cl in (("{", "}"), ("(", ")"), ("[", "]")):
    a, b = body.count(op), body.count(cl)
    good = a == b
    ok = ok and good
    print("%-4s %-4s  %4d / %4d   %s" % (op, cl, a, b, "OK" if good else "*** MISMATCH ***"))

hooks = re.findall(r"^%hook\s+(\S+)", src, re.M)
ends = re.findall(r"^%end", src, re.M)
ctors = re.findall(r"^%ctor", src, re.M)
groups = re.findall(r"^%group\s+(\S+)", src, re.M)
print()
print("%%hook=%d  %%end=%d  %s" % (len(hooks), len(ends),
                                   "OK" if len(ends) >= len(hooks) else "*** 缺 %end ***"))
print("%%ctor=%d (必须 1)" % len(ctors))
print("%%group=%d" % len(groups))
print("hooks:", ", ".join(hooks))

print()
names = ("CYClassOverridesSelector", "CYFetchOpMain", "CYAnimatedViewDidMoveToWindow",
         "CYFreezeAnimatedView", "CYRestoreAnimatedView", "CYDecodeGateEnterBackground",
         "CYDecodeGateEnterForeground", "CYInstallDecodeGate", "origFetchOpMain",
         "origYYViewDidMoveToWindow", "gCYAnimatedViews", "gCYForeground",
         "gCYFetchSkipped", "kCYFrozenKey")
for name in names:
    uses = len(re.findall(r"\b%s\b" % re.escape(name), src))
    if uses == 0:
        ok = False
    print("  %-32s %2d 次  %s" % (name, uses, "OK" if uses else "*** 未定义/未使用 ***"))

print()
print("CYInstallDecodeGate 调用点：")
for m in re.finditer(r"^[ \t]*CYInstallDecodeGate\(\);[^\n]*", src, re.M):
    print("   ", m.group(0).strip()[:100])

print()
print("verdict:", "PASS" if ok else "FAIL")
