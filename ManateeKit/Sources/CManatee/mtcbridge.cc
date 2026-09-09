#include "mtcbridge.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
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

/* No C++ exception may cross this file's extern "C" boundary: unwinding
 * into a C/Swift caller is undefined behavior, and in practice libc++
 * calls std::terminate() -> abort(), taking the whole app down with no
 * catchable Swift error. This bit the project once already (2026-09-08):
 * an unguarded mtc_corpus_size, called via Corpus.info() from the New
 * Concordance picker, hit a registry file whose baked-in absolute PATH no
 * longer resolved after a directory rename, and Manatee's throw while
 * opening the lexicon killed the app - and the test host with it, so the
 * whole suite reported "not run" rather than failing.
 *
 * Every entry point below therefore either takes a `char **error`
 * out-param and reports through set_error, or - when its signature has no
 * way to say anything - wraps its body in one of these guards and returns
 * the same sentinel it already uses for a null handle. A sentinel means
 * "failed", not a real value; callers must treat it as such (see
 * Corpus.size in ManateeKit.swift, which throws on -1). */
template <typename T, typename F>
T guard(T sentinel, F &&body) noexcept {
    try {
        return body();
    } catch (...) {
        return sentinel;
    }
}

/* Same, for the void entry points - the closes/frees, whose `delete` runs
 * Manatee destructors that unmap files. Nothing to report and nothing a
 * caller could do about it, so a throw here is simply swallowed. */
template <typename F>
void guard_void(F &&body) noexcept {
    try {
        body();
    } catch (...) {
    }
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

/* Drains an IdStrGenerator into the same leading-'\x1F'-delimiter encoding
 * join_attr_range produces (see its comment for why the delimiter leads
 * rather than separates - an attribute value can legitimately be the empty
 * string, and this keeps that unambiguous). `max_values` > 0 stops early;
 * 0 means "all of them".
 *
 * Note the iteration protocol: IdStrGenerator's constructor calls next()
 * itself, so it arrives already positioned at its first item - the same
 * "already started" convention CollocItems has, and the opposite of
 * KWICLines. Hence check end() *before* the first read, and advance at the
 * bottom of the loop. */
std::string join_id_str_values(IdStrGenerator *values, int max_values) {
    std::string result;
    int taken = 0;
    for (; !values->end(); values->next()) {
        if (max_values > 0 && taken >= max_values)
            break;
        result += '\x1F';
        result += values->getStr();
        ++taken;
    }
    return result;
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
    guard_void([&] {
        delete corp->corp;
        delete corp;
    });
}

long long mtc_corpus_size(MTCCorpus *corp, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return -1;
    }
    try {
        // search_size(), not size(): for a plain Corpus these are the same
        // (Corpus::search_size()'s default body is just `return size();`), but
        // SubCorpus overrides search_size() to the actual restricted token
        // count - size() alone would always report the *parent* corpus's full
        // size, even for a subcorpus (see corp/subcorp.hh).
        //
        // Despite reading like a cheap accessor, this is the call that first
        // touches the corpus's compiled data: search_size() -> size() ->
        // get_default_attr() lazily opens the default attribute's lexicon
        // off disk. A corpus that opened fine (mtc_corpus_open only parses
        // the registry *file*) can still throw here, because a registry's
        // PATH is an absolute path that may no longer resolve.
        return static_cast<long long>(corp->corp->search_size());
    } catch (std::exception &e) {
        set_error(error, e);
        return -1;
    } catch (...) {
        set_error(error, "unknown error reading corpus size");
        return -1;
    }
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
    guard_void([&] {
        delete conc->conc;
        delete conc;
    });
}

long long mtc_concordance_size(MTCConcordance *conc) {
    if (!conc)
        return -1;
    return guard<long long>(-1, [&] { return static_cast<long long>(conc->conc->size()); });
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
        // maxctx clamps structure-aligned context specs (e.g. "-1:s"/"1:s",
        // used by Sentence view - see ConcordanceDocument.ConcordanceViewMode)
        // to at most this many tokens each side. 100 was fine for KonText's
        // usual numeric KWIC widths, but too tight for a real sentence -
        // 2000 comfortably covers any realistic <s>, while still bounding
        // a pathological/mistagged structure from pulling in the whole
        // corpus.
        mk->kl = new KWICLines(corp->corp, view, left_ctx, right_ctx,
                               kwic_attr, kwic_attr, "", "", 2000);
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
    guard_void([&] {
        delete kwic->kl;
        delete kwic;
    });
}

int mtc_kwic_next(MTCKwic *kwic) {
    if (!kwic)
        return 0;
    // Real engine work, not an accessor: nextline() reads the next hit's
    // data off disk, so this can throw on a corpus whose files went away.
    return guard<int>(0, [&] { return kwic->kl->nextline() ? 1 : 0; });
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

long long mtc_kwic_get_pos(MTCKwic *kwic) {
    if (!kwic)
        return -1;
    return guard<long long>(-1, [&] { return static_cast<long long>(kwic->kl->get_pos()); });
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
    return guard<long long>(0, [&] { return conc->conc->get_linegroup(static_cast<ConcIndex>(line_idx)); });
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
    guard_void([&] {
        delete items->items;
        delete items;
    });
}

int mtc_colloc_next(MTCCollocItems *items) {
    if (!items)
        return 0;
    return guard<int>(0, [&] {
        if (items->started) {
            if (items->items->eos())
                return 0;
            items->items->next();
        }
        items->started = true;
        return items->items->eos() ? 0 : 1;
    });
}

char *mtc_colloc_get_item(MTCCollocItems *items) {
    if (!items)
        return nullptr;
    return guard<char *>(nullptr, [&] { return strdup(items->items->get_item()); });
}

long long mtc_colloc_get_freq(MTCCollocItems *items) {
    if (!items)
        return 0;
    return guard<long long>(0, [&] { return static_cast<long long>(items->items->get_freq()); });
}

long long mtc_colloc_get_cnt(MTCCollocItems *items) {
    if (!items)
        return 0;
    return guard<long long>(0, [&] { return static_cast<long long>(items->items->get_cnt()); });
}

double mtc_colloc_get_bgr(MTCCollocItems *items, char bgr_code) {
    if (!items)
        return 0.0;
    return guard<double>(0.0, [&] { return items->items->get_bgr(bgr_code); });
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
    guard_void([&] { delete dist; });
}

int mtc_freq_dist_count(MTCFreqDist *dist) {
    if (!dist)
        return 0;
    return static_cast<int>(dist->order.size());
}

char *mtc_freq_dist_get_word(MTCFreqDist *dist, int index) {
    if (!dist || index < 0 || static_cast<size_t>(index) >= dist->order.size())
        return nullptr;
    return guard<char *>(nullptr, [&] { return strdup(dist->words[dist->order[index]].c_str()); });
}

long long mtc_freq_dist_get_freq(MTCFreqDist *dist, int index) {
    if (!dist || index < 0 || static_cast<size_t>(index) >= dist->order.size())
        return 0;
    return guard<long long>(0, [&] { return static_cast<long long>(dist->freqs[dist->order[index]]); });
}

long long mtc_freq_dist_get_norm(MTCFreqDist *dist, int index) {
    if (!dist || index < 0 || static_cast<size_t>(index) >= dist->order.size())
        return 0;
    return guard<long long>(0, [&] { return static_cast<long long>(dist->norms[dist->order[index]]); });
}

int mtc_corpus_attr_count(MTCCorpus *corp) {
    if (!corp)
        return 0;
    return guard<int>(0, [&] { return static_cast<int>(corp->corp->conf->attrs.size()); });
}

char *mtc_corpus_attr_name(MTCCorpus *corp, int index) {
    if (!corp || index < 0 || static_cast<size_t>(index) >= corp->corp->conf->attrs.size())
        return nullptr;
    return guard<char *>(nullptr, [&] { return strdup(corp->corp->conf->attrs[index].first.c_str()); });
}

int mtc_corpus_struct_count(MTCCorpus *corp) {
    if (!corp)
        return 0;
    return guard<int>(0, [&] { return static_cast<int>(corp->corp->conf->structs.size()); });
}

char *mtc_corpus_struct_name(MTCCorpus *corp, int index) {
    if (!corp || index < 0 || static_cast<size_t>(index) >= corp->corp->conf->structs.size())
        return nullptr;
    return guard<char *>(nullptr, [&] { return strdup(corp->corp->conf->structs[index].first.c_str()); });
}

int mtc_corpus_struct_attr_count(MTCCorpus *corp, const char *struct_name) {
    CorpInfo *s = find_struct_info(corp, struct_name);
    return guard<int>(0, [&] { return s ? static_cast<int>(s->attrs.size()) : 0; });
}

char *mtc_corpus_struct_attr_name(MTCCorpus *corp, const char *struct_name, int index) {
    CorpInfo *s = find_struct_info(corp, struct_name);
    if (!s || index < 0 || static_cast<size_t>(index) >= s->attrs.size())
        return nullptr;
    return guard<char *>(nullptr, [&] { return strdup(s->attrs[index].first.c_str()); });
}

char *mtc_corpus_get_struct_attr(MTCCorpus *corp, long long position, const char *struct_attr_name, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return nullptr;
    }
    try {
        // get_attr's default struct_attr=false is what returns the
        // position-indexed StructPosAttr wrapper (via get_struct_pos_attr)
        // rather than the structure's own instance-indexed raw attribute -
        // pos2str below needs the former, since `position` is a corpus-wide
        // token position, not a structure instance number.
        PosAttr *attr = corp->corp->get_attr(struct_attr_name);
        return strdup(attr->pos2str(static_cast<Position>(position)));
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error reading structural attribute");
        return nullptr;
    }
}

char *mtc_corpus_positional_attr_range(MTCCorpus *corp, long long from_position, long long to_position,
                                        const char *attr_name, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return nullptr;
    }
    try {
        // Same "call PosAttr::pos2str directly off a position, no live
        // concordance needed" approach as mtc_corpus_get_struct_attr above
        // (Phase 5.4) - just over a range of positions instead of one, and
        // for a plain positional attribute (e.g. "word") rather than a
        // structural one. Clamped to [0, search_size()) rather than trusting
        // the caller's range - Extended Context requests position ± N
        // tokens, which easily runs off either end of the corpus for a hit
        // near its start/end.
        long long size = static_cast<long long>(corp->corp->search_size());
        long long from = std::max<long long>(0, from_position);
        long long to = std::min<long long>(size, to_position);
        PosAttr *attr = corp->corp->get_attr(attr_name);
        std::string result;
        for (long long pos = from; pos < to; ++pos) {
            if (pos > from)
                result += " ";
            result += attr->pos2str(static_cast<Position>(pos));
        }
        return strdup(result.c_str());
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error reading positional attribute range");
        return nullptr;
    }
}

int mtc_corpus_attr_value_count(MTCCorpus *corp, const char *attr_name, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return -1;
    }
    try {
        // get_attr, not get_struct_attr, even for a "doc.author"-style name:
        // the StructPosAttr wrapper it returns forwards WordList straight
        // through, so the lexicon reached here is the same one either way -
        // and already deduplicated (see mtcbridge.h's section comment).
        return corp->corp->get_attr(attr_name)->id_range();
    } catch (std::exception &e) {
        set_error(error, e);
        return -1;
    } catch (...) {
        set_error(error, "unknown error counting attribute values");
        return -1;
    }
}

char *mtc_corpus_attr_values(MTCCorpus *corp, const char *attr_name, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return nullptr;
    }
    try {
        std::unique_ptr<IdStrGenerator> values(corp->corp->get_attr(attr_name)->dump_str());
        return strdup(join_id_str_values(values.get(), 0).c_str());
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error reading attribute values");
        return nullptr;
    }
}

char *mtc_corpus_attr_values_matching(MTCCorpus *corp, const char *attr_name, const char *pattern,
                                       int ignore_case, int max_values, char **error) {
    if (!corp) {
        set_error(error, "null corpus handle");
        return nullptr;
    }
    try {
        // regexp2strids is lazy, so with max_values set this stops reading
        // the lexicon once it has enough - the whole reason to prefer it
        // over filtering a full dump_str for a high-cardinality attribute.
        std::unique_ptr<IdStrGenerator> values(
            corp->corp->get_attr(attr_name)->regexp2strids(pattern, ignore_case != 0));
        return strdup(join_id_str_values(values.get(), max_values).c_str());
    } catch (std::exception &e) {
        set_error(error, e);
        return nullptr;
    } catch (...) {
        set_error(error, "unknown error matching attribute values");
        return nullptr;
    }
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
