# UD English EWT, the query-assistant benchmark corpus

`ud-en-ewt.vert.xz` is the manatee vertical file that
`scripts/nl-spike/build-ud-corpus.sh` compiles into `data/ud-en-ewt/`
(gitignored), with a registry for the machine it runs on. Every gold
query in `../bench/` and every result in `../results/` was produced
against exactly this file, so **don't swap in another UD release**
without re-checking the gold queries (hit counts change).

- Source: [UniversalDependencies/UD_English-EWT](https://github.com/UniversalDependencies/UD_English-EWT)
  at commit `4a4d77f599ea53cc405f85d0cec4b2f14f81d42b` (2026-05-06,
  master at the time; r2.18 era). Files `en_ewt-ud-{train,dev,test}.conllu`.
- Converted with `scripts/conllu2vert.py OUT.vert train dev test` (that
  order). The conversion is deterministic; `build-ud-corpus.sh
  --from-source` redoes it from the pinned commit and checks the result
  against this file (SHA-256 below).
- 254,820 tokens; positional attributes `word lemma upos xpos feats
  deprel` (feats MULTIVALUE, sep `|`); structures `doc` (id, genre,
  split) and `s` (id).
- SHA-256 of the uncompressed vertical:
  `385cd3a445ad5d65bb126dd52a6393b14687fe60837fb47d820f4878cf8e5545`

License: the UD English EWT treebank is CC BY-SA 4.0
(`LICENSE-UD_English-EWT.txt`, copied from the treebank). This derived
file is distributed under the same license, with attribution to the UD
English EWT contributors (Silveira et al. 2014, "A Gold Standard
Dependency Corpus for English"; the Universal Dependencies project).
