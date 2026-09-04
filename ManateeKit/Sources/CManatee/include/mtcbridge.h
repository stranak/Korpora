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

/* Runs a CQL query against the corpus. Returns NULL and sets *error on failure
 * (bad CQL syntax, unknown attribute, etc). */
MTCConcordance *mtc_query(MTCCorpus *corp, const char *cql, char **error);
void mtc_concordance_close(MTCConcordance *conc);
long long mtc_concordance_size(MTCConcordance *conc);

/* KWIC iteration over a concordance. left_ctx/right_ctx are Manatee context
 * specs (e.g. "-10" for 10 tokens of left context); kwic_attr is the
 * positional attribute to render (e.g. "word"). */
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

void mtc_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif
