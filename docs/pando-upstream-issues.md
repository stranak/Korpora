# Draft: issues to report to ufal/pando (from the Korpora Phase A spike, 2026-09-30)

Not filed yet. Tested at `ufal/pando` `main` `8952b6d`, macOS 27 (arm64, Xcode 27) and macOS 15.7.7 (arm64 VM),
built with `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DPANDO_BUILD_SHARED=ON`. Index used below: UD English-EWT
(`en_ewt-ud-{train,dev,test}.conllu`) indexed with `pando-index`.
Context: Korpora (a native macOS corpus app) is evaluating pando as a second engine, embedding `libpando` through
its C API. Everything else in the spike went well; these are the things that got in the way.

## 1. `pando_run`/`pando_query`: `dcoll` ignores the relation list (blocks embedding)

Through the C API the relation in `dcoll REL by ATTR` is dropped: `"relations": []` in the result, and `obj`,
`nsubj` and no relation at all return the same list. The CLI honours it.

```c
// cc -I src/api repro_dcoll.c -Lbuild-shared -lpando -o repro_dcoll ; ./repro_dcoll IDX
pando_handle_t h = pando_open(argv[1], 0);
char *a = pando_run(h, "[upos=\"VERB\" & lemma=\"eat\"]; dcoll obj by lemma",   "{}");
char *b = pando_run(h, "[upos=\"VERB\" & lemma=\"eat\"]; dcoll nsubj by lemma", "{}");
// a and b: "relations": [] and the same collocates (food, here, can, not, time, he, ...)
```
CLI, same corpus: `pando IDX '[upos="VERB" & lemma="eat"]; dcoll obj by lemma' --min-freq 2` gives
`"relations": ["obj"]` and hay, grain, meat, cream, food, ... as expected.
Expected: the API returns what the CLI does. It looks like the CLI (`src/cli/query_main.cpp`) parses or applies
the relations itself and `program_api.cpp` does not; it may be worth checking that other commands (`coll` options,
`--measures`, `--min-freq`, `--window`) also reach the API, and documenting the option keys `pando_run` accepts.

## 2. `pando_open` fails when several handles are opened under the default fd limit

`MmapFile` keeps its file descriptor open for the lifetime of the mapping, so one handle uses one fd per index
file (79 for the EWT index; more for corpora with more attributes). The macOS default soft limit is 256, so the
fourth handle fails with NULL. The header promises that "multiple handles to the same corpus directory are fine".

```c
// ( ulimit -n 256; ./repro_fd IDX )   -> opened 3 of 8 handles
// ( ulimit -n 4096; ./repro_fd IDX )  -> opened 8 of 8 handles
for (int i = 0; i < 8; i++) { h[i] = pando_open(argv[1], 0); ok += h[i] != NULL; }
```
Seen for real on macOS 15 with 4 threads each opening its own handle (a thread's `pando_open` returned NULL in
most runs). Suggested fix: `close(fd_)` right after a successful `mmap` (a mapping stays valid without it). At
minimum, return an error string from `pando_open` so the caller can tell "too many open files" from "no such
corpus".

## 3. `<s> ... </s>` (CQP tag syntax) silently returns 0 hits

`pando IDX '<s> [lemma="cat"] </s>' --count-only` prints `0`. In this corpus `<s> [lemma="cat"]` returns 1 (and
`[lemma="cat"] within s` returns 93), so tag syntax appears to be half-supported rather than rejected. Similarly
`[lemma="cat"] within <s/>` is an error ("Expected identifier but got 's/'"). For users coming from CQP/Manatee
these forms are common; an explicit "not supported, use `within s`" error would avoid silently wrong counts.
Also errors for `([..] [..])+` and `{1,2}` on a parenthesised group ("Expected '[' or string or /regex/ at
position 0"), `containing [..]` with a token pattern, and `!( ... )` negation inside `[ ]` (CWB dialect).

## 4. `count M by a.form` returns 0 groups when a region has an attribute with the same name

On EWT, `M = a:[lemma="book"]; count M by a.form` gives `Total: 0 matches, 0 groups`, while `count M by a.lemma`
gives 70 and `M = [lemma="book"]; count M by form` gives book/booked/books. The corpus has a region `contr` with
an attribute `form` (`region_attrs=s_sent_id,contr_form,...`), so `a.form` seems to resolve to the region attribute.
Suggestion: prefer the positional attribute for `name.attr` on a named token, or report the ambiguity.

## 5. Test failures in the bundled test binaries

- `build/mv_stage1_executor_test`: `FAIL: m.parallel_matches.size() == 1u` at
  `src/index/mv_stage1_executor_test.cpp:136`.
- `build/cwb_dialect_test`: prints nothing and exits 0 (probably fine, but unclear whether it ran any checks).
- There is no `ctest`/`add_test` wiring, so a plain `ctest` finds nothing.

## 6. Build defaults

The default build sets the deployment target to the host OS (`minos 27.0` on macOS 27), so binaries built this
way don't run on older macOS. Building with `-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0` works cleanly, and the result
ran fine on macOS 15.7.7. A note in `wiki/Installation.md` (or a default) would help anyone shipping binaries.

## Questions for the author (not bugs)

1. **Format stability**: is the on-disk index layout expected to change? Re-indexing a billion-token corpus took 15
   min and 18 GB of RAM in our test, so a version stamp in `corpus.info` and a clear "reindex needed" error would
   matter to embedders.
2. **Cancellation**: is there (or could there be) a way to interrupt a running query on a handle? A UI needs it.
3. **Subcorpora**: is a persistent subcorpus object (a saved set of regions or positions to restrict later
   queries) planned, or is `within`/named queries the intended replacement?
4. **Relation-triple statistics for word profiles**: `dcoll`'s `freq` column is the collocate's corpus-wide
   frequency. For Sketch-Engine-style logDice we'd want the frequency of the (head, relation, dependent)
   triple. Is that available or planned? A single command producing all relations for a lemma in one pass would
   also help.
5. **Licensing** for embedding in a signed macOS app: we assume it will be settled directly with you.

## Measured, for context (synthetic corpora, warm cache)

1B tokens (7 attributes + dependencies): indexed in 14.7 min at ~1.1 M tokens/s, 41 GB, 18.4 GB peak RSS.
Selective queries under 2 s; `dcoll` for a lemma covering 1.3% of the corpus 7 s; a two-child tree restriction
over all nouns 20 s. Thank you for the engine: dependency-aware collocation this fast is exactly what we need.
