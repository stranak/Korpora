#ifndef MTCBRIDGE_H
#define MTCBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MTCCorpus MTCCorpus;
typedef struct MTCConcordance MTCConcordance;
typedef struct MTCKwic MTCKwic;

/* Opens a corpus by name (resolved via the MANATEE_REGISTRY env var / compiled-in
 * registry path, same lookup corpinfo/encodevert use). Returns NULL and sets
 * *error (caller must free with mtc_free_string) on failure. */
MTCCorpus *mtc_corpus_open(const char *name, char **error);
void mtc_corpus_close(MTCCorpus *corp);
long long mtc_corpus_size(MTCCorpus *corp);

/* Runs a CQL query against the corpus. The concordance handle stays open and
 * mutable - the mutators below (sort/shuffle/reduce/pnfilter/linegroup) all
 * operate in place on it, so it must be kept alive across multiple
 * operations rather than closed after one render, unlike the old one-shot
 * query-then-discard usage. Returns NULL and sets *error on failure (bad CQL
 * syntax, unknown attribute, etc). */
MTCConcordance *mtc_query(MTCCorpus *corp, const char *cql, char **error);
void mtc_concordance_close(MTCConcordance *conc);
long long mtc_concordance_size(MTCConcordance *conc);

/* KWIC iteration over a concordance. left_ctx/right_ctx are Manatee context
 * specs (e.g. "-10" for 10 tokens of left context); kwic_attr is the
 * positional attribute to render (e.g. "word"). Reflects the concordance's
 * current view (post sort/shuffle), not just its original order. */
MTCKwic *mtc_kwic_open(MTCCorpus *corp, MTCConcordance *conc,
                       const char *left_ctx, const char *right_ctx,
                       const char *kwic_attr, char **error);
void mtc_kwic_close(MTCKwic *kwic);

/* Advances to the next KWIC line. Returns 0 when the concordance is exhausted. */
int mtc_kwic_next(MTCKwic *kwic);

/* Positional-attribute text (e.g. "word", "lemma", "tag") for the current
 * KWIC line's left/kwic/right segment, independent of whichever attribute
 * mtc_kwic_open's kwic_attr rendered - lets a caller read more than one
 * attribute per token (word + lemma + tag, KonText-style) without
 * reopening the KWIC view per attribute; also the only way to read the
 * primary token text itself now (there's no separate mtc_kwic_get_left/
 * kwic/right - call this with attr_name == whatever kwic_attr was).
 *
 * Encoding: one token per '\x1F' (unit separator - can't appear in real
 * corpus text)-delimited piece, with the delimiter placed *before* every
 * token including the first, e.g. "\x1Fthe\x1Ffox\x1Fjumps" for 3 tokens.
 * A caller drops the first character then splits on '\x1F' keeping empty
 * pieces, to correctly recover a token whose own attribute value happens
 * to be an empty string. An entirely empty ("") result means zero tokens
 * (an undefined/empty line's segment), not one empty-valued token - the
 * leading delimiter makes that case unambiguous. NULL and *error set only
 * for an attr_name that doesn't exist in this corpus. Valid only after
 * mtc_kwic_next() returns nonzero. */
char *mtc_kwic_get_left_attr(MTCKwic *kwic, const char *attr_name, char **error);
char *mtc_kwic_get_kwic_attr(MTCKwic *kwic, const char *attr_name, char **error);
char *mtc_kwic_get_right_attr(MTCKwic *kwic, const char *attr_name, char **error);

/* The current KWIC line's match start position - a corpus-wide token
 * index, stable and meaningful independent of this iterator's lifetime
 * (unlike everything else on MTCKwic). Callers keep this alongside a
 * fetched line so they can look up that line's enclosing structural
 * attributes later, on demand, via mtc_corpus_get_struct_attr - without
 * needing to keep a KWIC iterator (or even the concordance) open. Valid
 * only after mtc_kwic_next() returns nonzero. */
long long mtc_kwic_get_pos(MTCKwic *kwic);

/* -------------------- concordance operations --------------------
 * All mutate *conc in place and report failure the same way as mtc_query
 * (return 0 and set *error). `criteria` strings use Manatee's own sort-key
 * grammar directly (e.g. "word/i 0<0~0>0" - see conccrit.cc), since that's
 * already a well-defined, documented format not worth reinventing. */

/* Sorts by `criteria` (one or more "attr[/flags] ctx[~ctx]" pairs,
 * space-separated for multi-level sort); `uniq` discards duplicate keys. */
int mtc_concordance_sort(MTCConcordance *conc, const char *criteria, int uniq, char **error);

/* Randomizes line order. Manatee's shuffle() has no seed - not reproducible,
 * by design (KonText doesn't offer one either). */
int mtc_concordance_shuffle(MTCConcordance *conc, char **error);

/* Reduces to (approximately) `size` lines, sampled from the concordance's
 * current *raw* order - this resets any prior sort/shuffle view, matching
 * Manatee's own reduce_lines behavior (it discards the view, since sampling
 * runs over the underlying, not view-permuted, array). */
int mtc_concordance_reduce(MTCConcordance *conc, long long size, char **error);

/* Defines collocation slot `collnum` as a CQL sub-query over the window
 * [left_ctx, right_ctx] around each hit (context specs, e.g. "-5"/"5"),
 * keeping the `rank`-th match (1-based from the left, negative counts from
 * the right, 0 = exact-span match); `exclude_kwic` skips matches inside the
 * hit itself. Must be called before mtc_concordance_pnfilter for the same
 * collnum. */
int mtc_concordance_set_collocation(MTCConcordance *conc, int collnum, const char *query,
                                     const char *left_ctx, const char *right_ctx, int rank,
                                     int exclude_kwic, char **error);

/* Keeps (positive != 0) or drops (positive == 0) lines whose collocation
 * slot `collnum` matched (see mtc_concordance_set_collocation). */
int mtc_concordance_pnfilter(MTCConcordance *conc, int collnum, int positive, char **error);

/* Assigns `group` to lines [range_start, range_start + range_len) in the
 * concordance's current view. */
int mtc_concordance_set_linegroup(MTCConcordance *conc, long long range_start,
                                   long long range_len, int group, char **error);

/* Returns the line-group id of the given view-relative line index (0 if
 * ungrouped, or the index is out of range). */
long long mtc_concordance_get_linegroup(MTCConcordance *conc, long long line_idx);

/* Keeps only lines whose group is (or, if `invert` is 0, is not) listed in
 * `groups_spec` (whitespace-separated group ids, e.g. "1 2"). */
int mtc_concordance_delete_linegroups(MTCConcordance *conc, const char *groups_spec,
                                       int invert, char **error);

void mtc_free_string(char *s);

/* -------------------- collocations --------------------
 * Wraps concord/concstat.hh's CollocItems: the top `max_items` collocates of
 * `attr_name` found within [from_w, to_w] tokens of each hit (negative =
 * left of the hit, positive = right), ranked by association measure
 * `sort_fun_code`. Only candidate words with corpus-wide frequency >=
 * min_freq are even considered, and only those co-occurring with the node
 * in at least min_bgr lines are kept. `sort_fun_code`/the `bgr_code` passed
 * to mtc_colloc_get_bgr are single-char codes from corp/bgrstat.hh's
 * bgr_known_fun_codes ("tm3lsprfCDd1") - e.g. 'd' = logDice (Manatee/
 * KonText's own conventional default), 'm' = MI, 't' = T-score. */

typedef struct MTCCollocItems MTCCollocItems;

MTCCollocItems *mtc_colloc_open(MTCConcordance *conc, const char *attr_name,
                                 char sort_fun_code, long long min_freq, long long min_bgr,
                                 int from_w, int to_w, int max_items, char **error);
void mtc_colloc_close(MTCCollocItems *items);

/* Advances to the next collocate, best-scoring first (per sort_fun_code).
 * Returns 0 once exhausted - fields below are only valid after this
 * returns nonzero, same convention as mtc_kwic_next. */
int mtc_colloc_next(MTCCollocItems *items);

char *mtc_colloc_get_item(MTCCollocItems *items);      /* caller frees with mtc_free_string */
long long mtc_colloc_get_freq(MTCCollocItems *items);  /* corpus-wide frequency of the collocate */
long long mtc_colloc_get_cnt(MTCCollocItems *items);   /* co-occurrence count with the node */

/* Recomputes any association measure for the *current* item on demand,
 * independent of whichever code ranked/selected the top items at open time
 * (CollocItems itself supports this - the raw counts needed are cached per
 * item). Returns 0.0 for an unrecognized code (matches the engine's own
 * fallback, bgr_null). */
double mtc_colloc_get_bgr(MTCCollocItems *items, char bgr_code);

/* -------------------- frequency distributions --------------------
 * Wraps Corpus::freq_dist. `crit` uses the exact same criteria-string
 * grammar as mtc_concordance_sort's `criteria` (e.g. "lemma/i 0", or a
 * structural attribute like "doc.author 0"); only bins with count >=
 * min_freq are kept. Unlike the collocation iterator above, the whole
 * result set is computed up front, so it's exposed as count + index-based
 * getters rather than a step-iterator (see mtc_corpus_attr_name for the
 * same shape used elsewhere). Results are sorted by frequency, descending. */

typedef struct MTCFreqDist MTCFreqDist;

MTCFreqDist *mtc_freq_dist_open(MTCConcordance *conc, const char *crit,
                                 long long min_freq, char **error);
void mtc_freq_dist_close(MTCFreqDist *dist);

int mtc_freq_dist_count(MTCFreqDist *dist);

/* index in [0, mtc_freq_dist_count(dist)); out-of-range returns NULL/0. */
char *mtc_freq_dist_get_word(MTCFreqDist *dist, int index);  /* caller frees */
long long mtc_freq_dist_get_freq(MTCFreqDist *dist, int index);
/* A per-struct-value token count, only meaningful when crit's first
 * attribute is a structural attribute (e.g. "doc.author") - 0 otherwise.
 * Usable to compute a relative/normalized frequency client-side. */
long long mtc_freq_dist_get_norm(MTCFreqDist *dist, int index);

/* -------------------- corpus introspection --------------------
 * Reads the registry metadata already parsed when the corpus was opened
 * (Corpus::conf) - no engine work, just walking the parsed CorpInfo tree, so
 * these are cheap and side-effect-free. Index-based names are returned via
 * mtc_free_string-owned strings; index out of range returns NULL. */

int mtc_corpus_attr_count(MTCCorpus *corp);
char *mtc_corpus_attr_name(MTCCorpus *corp, int index);

int mtc_corpus_struct_count(MTCCorpus *corp);
char *mtc_corpus_struct_name(MTCCorpus *corp, int index);

int mtc_corpus_struct_attr_count(MTCCorpus *corp, const char *struct_name);
char *mtc_corpus_struct_attr_name(MTCCorpus *corp, const char *struct_name, int index);

/* The value of structural attribute "struct.attr" (e.g. "doc.author") for
 * whichever <struct> instance encloses corpus-wide token position `position`
 * (see mtc_kwic_get_pos) - a real per-match lookup, unlike the registry-only
 * introspection above. Wraps manatee-open's own StructPosAttr::pos2str,
 * which already resolves "which structure instance contains this position"
 * internally - no separate range lookup needed on our side. Empty string
 * (not NULL) if `position` isn't enclosed by any instance of that structure;
 * NULL and *error set only for a struct_attr_name that doesn't exist in
 * this corpus. */
char *mtc_corpus_get_struct_attr(MTCCorpus *corp, long long position, const char *struct_attr_name, char **error);

/* -------------------- subcorpora --------------------
 * A subcorpus is a Manatee-native concept: a saved range file restricting a
 * parent corpus to the hits of one CQL query scoped to a structure (e.g. one
 * <doc>). Manatee has no in-memory-only form of this - create_subcorpus
 * always writes subc_path to disk; SubCorpus always reads it back from
 * there. mtc_subcorpus_open's result is a normal MTCCorpus (SubCorpus
 * *is a* Corpus in C++, so mtc_query/mtc_corpus_size/etc. all work on it
 * unchanged) - close it with mtc_corpus_close like any other. */

int mtc_create_subcorpus(MTCCorpus *corp, const char *subc_path, const char *struct_name,
                          const char *query, char **error);
MTCCorpus *mtc_subcorpus_open(MTCCorpus *parent, const char *subc_path, char **error);

#ifdef __cplusplus
}
#endif

#endif
