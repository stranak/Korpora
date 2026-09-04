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
    return static_cast<long long>(corp->corp->size());
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
        RangeStream *view = conc->conc->RS();
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

void mtc_free_string(char *s) { free(s); }

} // extern "C"
