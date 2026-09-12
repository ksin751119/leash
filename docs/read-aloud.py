#!/usr/bin/env python3
"""Prints the-story.md as a reading script: what you SAY, with what you DO marked.

The file is written for editing; this is written for holding while a timer runs.
Also prints the word count both ways, because the length has been wrong by estimate
three times and the only number that settles it is your own stopwatch.
"""
import re, sys
src = "/home/ubuntu/DEV/leash/docs/the-story.md"
t = open(src).read().split("## Not spoken")[0]
# Everything before the first section heading is front matter written for an editor, not
# a reader — and it is full of bold, so it would otherwise be mistaken for lines to type.
t = t[t.index("\n## "):]

spoken, out = 0, []
for line in t.splitlines():
    s = line.strip()
    if s.startswith("> ["):
        out.append(("do", s[1:].strip()))
    elif s.startswith("> **") or (s.startswith(">") and "**" in s):
        out.append(("type", s[1:].strip()))
    elif s.startswith(">") or s.startswith("---") or s.startswith("# "):
        continue
    elif s.startswith("## "):
        out.append(("head", s[3:]))
    elif s:
        out.append(("say", s))
    else:
        out.append(("gap", ""))

# A ⟨cut⟩ paragraph is several lines; only the first carries the marker, so the flag has
# to persist to the blank line. Counting only the marked line reported 49 cuttable words
# where the truth is 95, which is the difference between fitting and not.
in_cut = False
for i, (kind, text) in enumerate(out):
    if kind == "gap":
        in_cut = False
    elif kind == "say" and text.startswith("⟨cut⟩"):
        in_cut = True
    out[i] = (kind, text, in_cut and kind == "say")

for kind, text, is_cut in out:
    plain = re.sub(r"[*`\[\]⟨⟩]", "", text)
    if kind == "head":
        print("\n" + "=" * 72 + f"\n{plain.upper()}\n" + "=" * 72)
    elif kind == "do":
        print(f"   \033[2m\u2192 {text.strip('[]')}\033[0m")
    elif kind == "type":
        print(f"   \033[1;33mTYPE: {plain}\033[0m")
    elif kind == "say":
        spoken += len(plain.split())
        print(("   \033[2m" + ("[CUT] " if text.startswith("⟨cut⟩") else "      ") + plain + "\033[0m")
              if is_cut else "   " + plain)
    else:
        print()

cut_words = sum(len(re.sub(r"[*`\[\]⟨⟩]", "", x).split()) for k, x, c in out if c)
print("\n" + "-" * 72)
print(f"as written  {spoken} words   ~{spoken/165:.1f} min at 165 wpm")
print(f"with cuts   {spoken-cut_words} words   ~{(spoken-cut_words)/165:.1f} min")
print("-" * 72)
print("Read it aloud with a timer. The cap is 4:00 and your pace is the only number\nthat settles it.")
