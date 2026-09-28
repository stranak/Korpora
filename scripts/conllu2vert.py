#!/usr/bin/env python3
"""Convert CoNLL-U files (Universal Dependencies) to a manatee vertical file.

Used to build a UD-annotated test corpus for the natural-language query
assistant (docs/nl-query-assistant.md, phase 0 spike and phase 3 benchmark).

Positional attributes, in this column order:
    word  lemma  upos  xpos  feats  deprel
Structures:
    <doc id="..." genre="..." split="...">   one per `# newdoc id`
    <s id="...">                              one per sentence

Multi-word token ranges (`1-2`) and empty nodes (`1.1`) are skipped, so
every vertical line is one syntactic word, which is what UD's annotation
describes. `genre` is the doc id's prefix up to the first "-" (UD English
EWT uses weblog/newsgroup/email/answers/reviews); `split` is the file's
train/dev/test part, taken from its name.

Usage:
    scripts/conllu2vert.py OUT.vert IN.conllu [IN.conllu ...]
"""
import re
import sys


def attr(value):
    """Escape a value for a vertical-file structure attribute."""
    return value.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")


def split_of(path):
    m = re.search(r"-(train|dev|test)\.conllu$", path)
    return m.group(1) if m else "all"


def convert(paths, out):
    doc_open = False
    tokens = 0
    for path in paths:
        split = split_of(path)
        sent_id = None
        in_sentence = False
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if line.startswith("# newdoc"):
                    if in_sentence:
                        out.write("</s>\n")
                        in_sentence = False
                    if doc_open:
                        out.write("</doc>\n")
                    doc_id = line.split("=", 1)[1].strip() if "=" in line else ""
                    genre = doc_id.split("-", 1)[0] if doc_id else "unknown"
                    out.write(f'<doc id="{attr(doc_id)}" genre="{attr(genre)}" split="{split}">\n')
                    doc_open = True
                elif line.startswith("# sent_id"):
                    sent_id = line.split("=", 1)[1].strip()
                elif line.startswith("#"):
                    continue
                elif not line.strip():
                    if in_sentence:
                        out.write("</s>\n")
                        in_sentence = False
                else:
                    cols = line.split("\t")
                    if len(cols) != 10 or "-" in cols[0] or "." in cols[0]:
                        continue
                    if not doc_open:
                        out.write(f'<doc id="" genre="unknown" split="{split}">\n')
                        doc_open = True
                    if not in_sentence:
                        out.write(f'<s id="{attr(sent_id or "")}">\n')
                        in_sentence = True
                    word, lemma, upos, xpos, feats, deprel = (
                        cols[1], cols[2], cols[3], cols[4], cols[5], cols[7])
                    out.write("\t".join((word, lemma, upos, xpos, feats, deprel)) + "\n")
                    tokens += 1
        if in_sentence:
            out.write("</s>\n")
    if doc_open:
        out.write("</doc>\n")
    return tokens


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "w", encoding="utf-8") as out:
        n = convert(sys.argv[2:], out)
    print(f"{n} tokens -> {sys.argv[1]}", file=sys.stderr)


if __name__ == "__main__":
    main()
