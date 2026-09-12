#!/usr/bin/env python3
"""Prints the-story.md as a reading script: what you SAY, with what you DO marked.

The file is written for editing; this is written for holding while a timer runs.
Also prints the word count both ways, because the length has been wrong by estimate
three times and the only number that settles it is your own stopwatch.

    python3 docs/read-aloud.py            # for a terminal
    python3 docs/read-aloud.py --md       # writes docs/narration.md

`docs/narration.md` is deliberately git-ignored. It is a rendering of a tracked file, so
committing it would mean two copies of the script that can disagree — and the one anybody
edits by hand would be the one that is regenerated over.
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

MD = "--md" in sys.argv

def emit(line=""):
    buf.append(line)

buf = []
for kind, text, is_cut in out:
    plain = re.sub(r"⟨cut⟩\s*", "", text)
    plain = re.sub(r"[*`\[\]⟨⟩]", "", plain)
    if kind == "head":
        if MD:
            emit(f"## {plain}")
        else:
            emit("\n" + "=" * 72 + f"\n{plain.upper()}\n" + "=" * 72)
    elif kind == "do":
        stage = text.strip("[]")
        emit(f"> **▶** {stage}" if MD else f"   \033[2m\u2192 {stage}\033[0m")
    elif kind == "type":
        emit(f"**TYPE →** {plain}" if MD else f"   \033[1;33mTYPE: {plain}\033[0m")
    elif kind == "say":
        spoken += len(plain.split())
        if MD:
            # Only the first line of a cut block is labelled; the rest are blockquoted so
            # the block reads as one thing to drop rather than five separate ones.
            emit((f"> *(cut)* {plain}" if text.startswith("⟨cut⟩") else f"> {plain}")
                 if is_cut else plain)
        else:
            emit(("   \033[2m" + ("[CUT] " if text.startswith("⟨cut⟩") else "      ") + plain + "\033[0m")
                 if is_cut else "   " + plain)
    else:
        emit()

cut_words = sum(len(re.sub(r"[*`\[\]⟨⟩]", "", re.sub(r"⟨cut⟩\s*", "", x)).split())
                for k, x, c in out if c)
kept = spoken - cut_words

if MD:
    header = [
        "# Leash — narration",
        "",
        "> Generated from `docs/the-story.md` by `python3 docs/read-aloud.py --md`.",
        "> Edit the story, not this file — this one is regenerated and is not tracked in git.",
        "",
        f"**{spoken} words as written · {kept} with every *(cut)* line dropped.**",
        "",
        "| | words | 165 wpm | 175 wpm | 185 wpm |",
        "|---|---|---|---|---|",
        f"| as written | {spoken} | {spoken/165:.1f} | {spoken/175:.1f} | {spoken/185:.1f} |",
        f"| with cuts | **{kept}** | {kept/165:.1f} | **{kept/175:.1f}** | {kept/185:.1f} |",
        "",
        "The cap is **4:00**. Short declarative lines read faster than a words-per-minute",
        "model predicts, so treat the table as a floor and time yourself.",
        "",
        "`→` is what you do · **TYPE →** is what you type · *(cut)* comes out in that order",
        "if it runs long.",
        "",
        "---",
    ]
    out_path = "/home/ubuntu/DEV/leash/docs/narration.md"
    open(out_path, "w").write("\n".join(header + buf).rstrip() + "\n")
    print(f"wrote {out_path}  ({spoken} words, {kept} with cuts)")
else:
    print("\n".join(buf))
    print("\n" + "-" * 72)
    print(f"as written  {spoken} words   ~{spoken/165:.1f} min at 165 wpm")
    print(f"with cuts   {kept} words   ~{kept/165:.1f} min")
    print("-" * 72)
    print("Read it aloud with a timer. The cap is 4:00 and your pace is the only number\nthat settles it.")
