#include "mtcbridge.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <sstream>
#include <string>

#include "corpus.hh"
#include "concord.hh"
#include "concget.hh"
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
};

namespace {

void set_error(char **error, const char *msg) {
    if (error)
        *error = strdup(msg);
}

void set_error(char **error, const std::exception &e) {
    set_error(error, e.what());
}

/* Manatee's Tokens vectors alternate [text-run, tag, text-run, tag, ...]
 * (see concord/concget.cc:tcl_output_tokens) - even indices are the actual
 * token text, odd indices are collocation/annotation markup. We only want
 * the text for this API. */
char *join_text_tokens(const Tokens &toks) {
    std::ostringstream out;
    bool first = true;
    for (size_t i = 0; i < toks.size(); i += 2) {
        if (!first)
            out << ' ';
        out << toks[i];
        first = false;
    }
    return strdup(out.str().c_str());
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

char *mtc_kwic_get_left(MTCKwic *kwic) {
    return join_text_tokens(kwic->kl->get_left());
}

char *mtc_kwic_get_kwic(MTCKwic *kwic) {
    return join_text_tokens(kwic->kl->get_kwic());
}

char *mtc_kwic_get_right(MTCKwic *kwic) {
    return join_text_tokens(kwic->kl->get_right());
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
