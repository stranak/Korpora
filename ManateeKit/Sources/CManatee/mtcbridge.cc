#include "mtcbridge.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <numeric>
#include <sstream>
#include <string>
#include <vector>

#include "bgrstat.hh"
#include "corpus.hh"
#include "concord.hh"
#include "concget.hh"
#include "concstat.hh"
#include "cqpeval.hh"
#include "subcorp.hh"

struct MTCCorpus {
    Corpus *corp;
};
struct MTCConcordance {
    Concordance *conc;
};
struct MTCKwic {
    KWICLines *kl;
    // Needed by mtc_kwic_get_{left,kwic,right}_attr to look up an arbitrary
    // secondary attribute by name on demand - kl itself only knows about
    // the single kwic_attr it was opened with.
    Corpus *corp;
};
struct MTCCollocItems {
    CollocItems *items;
    // CollocItems starts already positioned at its first (best-scoring)
    // item, unlike KWICLines (which starts before its first line) - this
    // tracks whether mtc_colloc_next has been called yet, so it can offer
    // the same "call advances, then tells you if a row is available"
    // convention as mtc_kwic_next despite the different underlying protocol.
    bool started;
};
struct MTCFreqDist {
    std::vector<std::string> words;
    std::vector<NumOfPos> freqs;
    std::vector<NumOfPos> norms;
    // freq_dist itself returns words/freqs/norms in unspecified (unordered_map)
    // order - this holds a permutation of indices sorted by freqs descending,
    // so mtc_freq_dist_get_* can index through it directly.
    std::vector<size_t> order;
};

namespace {

void set_error(char **error, const char *msg) {
    if (error)
        *error = strdup(msg);
}

void set_error(char **error, const std::exception &e) {
    set_error(error, e.what());
}

/* Joins `attr`'s values across [from, to), one '\x1F' (unit separator -
 * matches get_corp_text's own attrdelim convention in concord/concget.cc,
 * chosen because it can't appear in real corpus text) immediately before
 * *every* token, including the first. This "leading delimiter" shape
 * (rather than a plain separator strictly *between* tokens) makes the
 * result unambiguous to split back into exactly one entry per token even
 * when a token's own attribute value happens to be an empty string - the
 * caller drops the first character then splits on '\x1F' keeping empty
 * pieces (see mtcbridge.h's doc comment on mtc_kwic_get_left_attr).
 * `from >= to` (an undefined/empty line's segment, or zero tokens) yields
 * "" (not NULL) - the only string with no leading delimiter at all, so it
 * unambiguously decodes to zero tokens rather than one empty one. */
char *join_attr_range(PosAttr *attr, Position from, Position to) {
    std::ostringstream out;
    if (from < to) {
        TextIterator *it = attr->textat(from);
        for (Position p = from; p < to; p++)
            out << '\x1F' << it->next();
        delete it;
    }
    return strdup(out.str().c_str());
}

char *kwic_get_attr_range(MTCKwic *kwic, const char *attr_name, Position from, Position to, char **error) {
    try {
        PosAttr *attr = kwic->corp->get_attr(attr_name);
        return join_attr_range(attr, from, to);
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error reading attribute");
        return nullptr;
    }
}

/* conf->structs entries are themselves CorpInfo nodes (their own .attrs
 * holds that structure's structural attributes) - see corp/corpconf.hh. */
CorpInfo *find_struct_info(MTCCorpus *corp, const char *struct_name) {
    if (!corp || !struct_name)
        return nullptr;
    for (auto &entry : corp->corp->conf->structs) {
        if (entry.first == struct_name)
            return entry.second;
    }
    return nullptr;
}

} // namespace

extern "C" {

MTCCorpus *mtc_corpus_open(const char *name, char **error) {
    try {
        MTCCorpus *c = new MTCCorpus;
        c->corp = new Corpus(std::string(name));
        return c;
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error opening corpus");
        return nullptr;
    }
}

void mtc_corpus_close(MTCCorpus *corp) {
    if (!corp)
        return;
    delete corp->corp;
    delete corp;
}

long long mtc_corpus_size(MTCCorpus *corp) {
    if (!corp)
        return -1;
    // search_size(), not size(): for a plain Corpus these are the same
    // (Corpus::search_size()'s default body is just `return size();`), but
    // SubCorpus overrides search_size() to the actual restricted token
    // count - size() alone would always report the *parent* corpus's full
    // size, even for a subcorpus (see corp/subcorp.hh).
    return static_cast<long long>(corp->corp->search_size());
}

MTCConcordance *mtc_query(MTCCorpus *corp, const char *cql, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return nullptr;
    }
    try {
        std::string query = std::string(cql) + ";";
        RangeStream *rs = corp->corp->filter_query(
            eval_cqpquery(query.c_str(), corp->corp));
        MTCConcordance *mc = new MTCConcordance;
        mc->conc = new Concordance(corp->corp, rs);
        mc->conc->sync();
        return mc;
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error evaluating query");
        return nullptr;
    }
}

void mtc_concordance_close(MTCConcordance *conc) {
    if (!conc)
        return;
    delete conc->conc;
    delete conc;
}

long long mtc_concordance_size(MTCConcordance *conc) {
    if (!conc)
        return -1;
    return static_cast<long long>(conc->conc->size());
}

MTCKwic *mtc_kwic_open(MTCCorpus *corp, MTCConcordance *conc,
                       const char *left_ctx, const char *right_ctx,
                       const char *kwic_attr, char **error) {
    if (!corp || !conc) {
        set_error(error, "null corpus/concordance handle");
        return nullptr;
    }
    try {
        // useview=true reflects sort/shuffle; ConcStream itself falls back
        // to raw order safely when no view exists yet (concord/concstrm.cc),
        // so this is safe whether or not any operation has run yet.
        RangeStream *view = conc->conc->RS(true);
        MTCKwic *mk = new MTCKwic;
        mk->kl = new KWICLines(corp->corp, view, left_ctx, right_ctx,
                               kwic_attr, kwic_attr, "", "", 100);
        mk->corp = corp->corp;
        return mk;
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error opening KWIC view");
        return nullptr;
    }
}

void mtc_kwic_close(MTCKwic *kwic) {
    if (!kwic)
        return;
    delete kwic->kl;
    delete kwic;
}

int mtc_kwic_next(MTCKwic *kwic) {
    if (!kwic)
        return 0;
    return kwic->kl->nextline() ? 1 : 0;
}

char *mtc_kwic_get_left_attr(MTCKwic *kwic, const char *attr_name, char **error) {
    if (!kwic) {
        set_error(error, "null kwic handle");
        return nullptr;
    }
    return kwic_get_attr_range(kwic, attr_name, kwic->kl->get_ctxbeg(), kwic->kl->get_pos(), error);
}

char *mtc_kwic_get_kwic_attr(MTCKwic *kwic, const char *attr_name, char **error) {
    if (!kwic) {
        set_error(error, "null kwic handle");
        return nullptr;
    }
    Position beg = kwic->kl->get_pos();
    return kwic_get_attr_range(kwic, attr_name, beg, beg + kwic->kl->get_kwiclen(), error);
}

char *mtc_kwic_get_right_attr(MTCKwic *kwic, const char *attr_name, char **error) {
    if (!kwic) {
        set_error(error, "null kwic handle");
        return nullptr;
    }
    Position beg = kwic->kl->get_pos() + kwic->kl->get_kwiclen();
    return kwic_get_attr_range(kwic, attr_name, beg, kwic->kl->get_ctxend(), error);
}

int mtc_concordance_sort(MTCConcordance *conc, const char *criteria, int uniq, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        conc->conc->sort(criteria, uniq != 0);
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error sorting concordance");
        return 0;
    }
}

int mtc_concordance_shuffle(MTCConcordance *conc, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        conc->conc->shuffle();
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error shuffling concordance");
        return 0;
    }
}

int mtc_concordance_reduce(MTCConcordance *conc, long long size, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        conc->conc->reduce_lines(std::to_string(size).c_str());
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error reducing concordance");
        return 0;
    }
}

int mtc_concordance_set_collocation(MTCConcordance *conc, int collnum, const char *query,
                                     const char *left_ctx, const char *right_ctx, int rank,
                                     int exclude_kwic, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        // eval_cqpquery (invoked internally for this sub-query, same as for
        // the main query in mtc_query) expects a `;`-terminated statement.
        conc->conc->set_collocation(collnum, std::string(query) + ";", left_ctx, right_ctx, rank,
                                     exclude_kwic != 0);
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error setting collocation");
        return 0;
    }
}

int mtc_concordance_pnfilter(MTCConcordance *conc, int collnum, int positive, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        conc->conc->delete_pnfilter(collnum, positive != 0);
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error applying filter");
        return 0;
    }
}

int mtc_concordance_set_linegroup(MTCConcordance *conc, long long range_start,
                                   long long range_len, int group, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        for (long long i = range_start; i < range_start + range_len; i++)
            conc->conc->set_linegroup(static_cast<ConcIndex>(i), group);
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error setting line group");
        return 0;
    }
}

long long mtc_concordance_get_linegroup(MTCConcordance *conc, long long line_idx) {
    if (!conc)
        return 0;
    return conc->conc->get_linegroup(static_cast<ConcIndex>(line_idx));
}

int mtc_concordance_delete_linegroups(MTCConcordance *conc, const char *groups_spec,
                                       int invert, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return 0;
    }
    try {
        conc->conc->delete_linegroups(groups_spec, invert != 0);
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error deleting line groups");
        return 0;
    }
}

void mtc_free_string(char *s) { free(s); }

MTCCollocItems *mtc_colloc_open(MTCConcordance *conc, const char *attr_name,
                                 char sort_fun_code, long long min_freq, long long min_bgr,
                                 int from_w, int to_w, int max_items, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return nullptr;
    }
    if (!strchr(bgr_known_fun_codes, sort_fun_code)) {
        set_error(error, "unrecognized association-measure code");
        return nullptr;
    }
    try {
        MTCCollocItems *mc = new MTCCollocItems;
        mc->items = new CollocItems(conc->conc, std::string(attr_name), sort_fun_code,
                                     static_cast<NumOfPos>(min_freq), static_cast<NumOfPos>(min_bgr),
                                     from_w, to_w, max_items);
        mc->started = false;
        return mc;
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error computing collocations");
        return nullptr;
    }
}

void mtc_colloc_close(MTCCollocItems *items) {
    if (!items)
        return;
    delete items->items;
    delete items;
}

int mtc_colloc_next(MTCCollocItems *items) {
    if (!items)
        return 0;
    if (items->started) {
        if (items->items->eos())
            return 0;
        items->items->next();
    }
    items->started = true;
    return items->items->eos() ? 0 : 1;
}

char *mtc_colloc_get_item(MTCCollocItems *items) {
    return strdup(items->items->get_item());
}

long long mtc_colloc_get_freq(MTCCollocItems *items) {
    return static_cast<long long>(items->items->get_freq());
}

long long mtc_colloc_get_cnt(MTCCollocItems *items) {
    return static_cast<long long>(items->items->get_cnt());
}

double mtc_colloc_get_bgr(MTCCollocItems *items, char bgr_code) {
    if (!items)
        return 0.0;
    return items->items->get_bgr(bgr_code);
}

MTCFreqDist *mtc_freq_dist_open(MTCConcordance *conc, const char *crit,
                                 long long min_freq, char **error) {
    if (!conc) {
        set_error(error, "null concordance handle");
        return nullptr;
    }
    try {
        MTCFreqDist *fd = new MTCFreqDist;
        // freq_dist takes ownership of the RangeStream and deletes it on
        // every exit path - RS() must only be handed to it once.
        RangeStream *rs = conc->conc->RS(true);
        conc->conc->corp->freq_dist(rs, crit, static_cast<NumOfPos>(min_freq),
                                     fd->words, fd->freqs, fd->norms);
        fd->order.resize(fd->words.size());
        std::iota(fd->order.begin(), fd->order.end(), 0);
        std::sort(fd->order.begin(), fd->order.end(), [fd](size_t a, size_t b) {
            return fd->freqs[a] > fd->freqs[b];
        });
        return fd;
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error computing frequency distribution");
        return nullptr;
    }
}

void mtc_freq_dist_close(MTCFreqDist *dist) {
    delete dist;
}

int mtc_freq_dist_count(MTCFreqDist *dist) {
    if (!dist)
        return 0;
    return static_cast<int>(dist->order.size());
}

char *mtc_freq_dist_get_word(MTCFreqDist *dist, int index) {
    if (!dist || index < 0 || static_cast<size_t>(index) >= dist->order.size())
        return nullptr;
    return strdup(dist->words[dist->order[index]].c_str());
}

long long mtc_freq_dist_get_freq(MTCFreqDist *dist, int index) {
    if (!dist || index < 0 || static_cast<size_t>(index) >= dist->order.size())
        return 0;
    return static_cast<long long>(dist->freqs[dist->order[index]]);
}

long long mtc_freq_dist_get_norm(MTCFreqDist *dist, int index) {
    if (!dist || index < 0 || static_cast<size_t>(index) >= dist->order.size())
        return 0;
    return static_cast<long long>(dist->norms[dist->order[index]]);
}

int mtc_corpus_attr_count(MTCCorpus *corp) {
    if (!corp)
        return 0;
    return static_cast<int>(corp->corp->conf->attrs.size());
}

char *mtc_corpus_attr_name(MTCCorpus *corp, int index) {
    if (!corp || index < 0 || static_cast<size_t>(index) >= corp->corp->conf->attrs.size())
        return nullptr;
    return strdup(corp->corp->conf->attrs[index].first.c_str());
}

int mtc_corpus_struct_count(MTCCorpus *corp) {
    if (!corp)
        return 0;
    return static_cast<int>(corp->corp->conf->structs.size());
}

char *mtc_corpus_struct_name(MTCCorpus *corp, int index) {
    if (!corp || index < 0 || static_cast<size_t>(index) >= corp->corp->conf->structs.size())
        return nullptr;
    return strdup(corp->corp->conf->structs[index].first.c_str());
}

int mtc_corpus_struct_attr_count(MTCCorpus *corp, const char *struct_name) {
    CorpInfo *s = find_struct_info(corp, struct_name);
    return s ? static_cast<int>(s->attrs.size()) : 0;
}

char *mtc_corpus_struct_attr_name(MTCCorpus *corp, const char *struct_name, int index) {
    CorpInfo *s = find_struct_info(corp, struct_name);
    if (!s || index < 0 || static_cast<size_t>(index) >= s->attrs.size())
        return nullptr;
    return strdup(s->attrs[index].first.c_str());
}

int mtc_create_subcorpus(MTCCorpus *corp, const char *subc_path, const char *struct_name,
                          const char *query, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return 0;
    }
    try {
        if (!create_subcorpus(subc_path, corp->corp, struct_name, query)) {
            set_error(error, "failed to create subcorpus (empty result?)");
            return 0;
        }
        return 1;
    } catch (std::exception &e) {
        set_error(error, e);
        return 0;
    } catch (...) {
        set_error(error, "unknown error creating subcorpus");
        return 0;
    }
}

MTCCorpus *mtc_subcorpus_open(MTCCorpus *parent, const char *subc_path, char **error) {
    if (!parent) {
        set_error(error, "null corpus handle");
        return nullptr;
    }
    try {
        MTCCorpus *c = new MTCCorpus;
        c->corp = new SubCorpus(parent->corp, std::string(subc_path));
        return c;
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error opening subcorpus");
        return nullptr;
    }
}

} // extern "C"
