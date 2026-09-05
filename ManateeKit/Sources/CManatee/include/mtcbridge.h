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

/* Space-joined token strings for the current line. Caller must free with
 * mtc_free_string. Valid only after mtc_kwic_next() returns nonzero. */
char *mtc_kwic_get_left(MTCKwic *kwic);
char *mtc_kwic_get_kwic(MTCKwic *kwic);
char *mtc_kwic_get_right(MTCKwic *kwic);

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
