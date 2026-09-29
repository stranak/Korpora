#!/usr/bin/env python3
"""Phase-0 spike (docs/nl-query-assistant.md): NL -> QueryPlan (a local MLX
model, JSON-Schema constrained with XGrammar) -> CQL, scored against a gold
query by hit-set comparison on UD English EWT.

Dev-only: the app does the same through mlx-swift-lm's MLXGuidedGeneration,
which vendors the same XGrammar. Setup, once (data/ is gitignored):

    uv venv --python 3.12 data/.venv-nl
    VIRTUAL_ENV=data/.venv-nl uv pip install mlx-lm xgrammar

Run (the model is fetched from Hugging Face into its cache on first use):

    data/.venv-nl/bin/python scripts/nl-spike/run.py mlx-community/Qwen3-4B-4bit
    ... run.py MODEL [requests.tsv|heldout.tsv] [--instructions FILE]
              [--retry] [--tag=-SUFFIX]
    ... run.py x heldout.tsv --rescore data/nl-spike/results-....tsv

requests.tsv is the dev set; heldout.tsv must not be used to tune prompts.
instructions-v2.txt has a {FACTS} placeholder filled from the corpus.
With the app's own prompt builder and schema (KorporaAssistant):

    B=KorporaAssistant/.build/debug/korpora-assistant
    MANATEE_REGISTRY=data/ud-en-ewt/registry $B schema ud_en_ewt > data/nl-spike/schema-app.json
    MANATEE_REGISTRY=data/ud-en-ewt/registry $B prompts ud_en_ewt scripts/nl-spike/heldout.tsv \
        > data/nl-spike/prompts-heldout.jsonl
    ... run.py MODEL scripts/nl-spike/heldout.tsv --schema data/nl-spike/schema-app.json \
        --prompts data/nl-spike/prompts-heldout.jsonl --tag=-app-heldout

Writes data/nl-spike/results-<model><tag>.tsv and prints a summary.
Results so far: docs/nl-query-assistant.md, "Phase 0 results".
"""
import argparse, json, os, re, subprocess, sys, time

import mlx.core as mx
import xgrammar as xgr
from mlx_lm import load
from mlx_lm.generate import generate
from mlx_lm.sample_utils import make_sampler
from xgrammar.kernels.apply_token_bitmask_mlx import apply_token_bitmask_mlx

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
UD = os.path.join(ROOT, "data", "ud-en-ewt")
OUT = os.path.join(ROOT, "data", "nl-spike")
TSTCQPGR = os.path.join(ROOT, "manatee-open", "src", "tstcqpgr")
ENV = dict(os.environ, MANATEE_REGISTRY=os.path.join(UD, "registry"))
REPEAT = {"once": "", "optional": "?", "zero-or-more": "*", "one-or-more": "+"}


def q(value):
    """Same quoting as CQLSerializer.quoted."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def to_cql(plan):
    """Same output as CQLSerializer.cql(for:)."""
    parts = []
    for p in plan["positions"]:
        conds = " & ".join(f'{c["attribute"]}{c["op"]}{q(c["value"])}' for c in p["conditions"])
        parts.append(f"[{conds}]" + REPEAT.get(p.get("repeat", "once"), ""))
    cql = "".join(parts)
    by_struct = {}
    for w in plan.get("within", []):
        struct, _, attr = w["attribute"].partition(".")
        by_struct.setdefault(struct, []).append(f"{attr}={q(w['value'])}")
    for struct, conds in by_struct.items():
        cql += f" within <{struct} {' & '.join(conds)}/>"
    return cql


def hits(cql):
    out = subprocess.run([TSTCQPGR, "ud_en_ewt", cql], capture_output=True, text=True, env=ENV).stdout
    if "exception" in out:
        return None, out.strip().splitlines()[-1]
    # tstcqpgr prints only the first 5 hits but counts all of them, so the
    # comparison key is (total count, first five positions) - a strong proxy
    # for hit-set equality, not a proof. The phase-3 benchmark compares full
    # sets through ManateeKit.
    total = re.search(r"rstream: finished (\d+)", out)
    first = tuple(re.findall(r"^(\d+\[\d+\])", out, re.M))
    return (int(total.group(1)) if total else 0, first), None


class GrammarProcessor:
    """mlx-lm logits processor: masks every token the grammar can't accept
    next. mlx-lm calls it with all tokens so far (prompt + generated), so
    the first call only records the prompt length."""

    def __init__(self, compiled, eos_id):
        self.matcher = xgr.GrammarMatcher(compiled)
        self.vocab_size = compiled.tokenizer_info.vocab_size
        self.bitmask = xgr.allocate_token_bitmask(1, self.vocab_size)
        self.eos_id = eos_id
        self.seen = None

    def __call__(self, tokens, logits):
        n = tokens.size
        if self.seen is None:
            self.seen = n
        else:
            for t in tokens[self.seen:n].tolist():
                if not self.matcher.is_terminated():
                    assert self.matcher.accept_token(t), f"grammar rejected token {t}"
            self.seen = n
        if self.matcher.is_terminated():
            mask = mx.full(logits.shape, -mx.inf)
            mask[..., self.eos_id] = 0
            return logits + mask
        self.matcher.fill_next_token_bitmask(self.bitmask)
        return apply_token_bitmask_mlx(mx.array(self.bitmask.numpy()), logits, self.vocab_size)


COLUMNS = ["word", "lemma", "upos", "xpos", "feats", "deprel"]
REGEX_CHARS = set(".*+?|[](){}\\^$")
DESCRIPTIONS = {
    "upos": "part of speech (Universal POS tags)",
    "xpos": "Penn Treebank tags; prefer upos and feats",
    "feats": "morphological features, one Feature=Value per condition",
    "deprel": "syntactic function (UD dependency relation)",
}


def lexicons():
    """Value -> frequency per attribute, from the vertical file. Stands in
    for Corpus.topAttributeValues / attributeValues in the app. feats is
    MULTIVALUE (sep "|"), so its values are counted one feature at a time."""
    lex = {c: {} for c in COLUMNS}
    genres = {}
    for line in open(os.path.join(UD, "ud-en-ewt.vert")):
        if line.startswith("<doc "):
            g = re.search(r'genre="([^"]*)"', line).group(1)
            genres[g] = genres.get(g, 0) + 1
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) != len(COLUMNS):
            continue
        for c, v in zip(COLUMNS, cols):
            for part in (v.split("|") if c == "feats" else [v]):
                lex[c][part] = lex[c].get(part, 0) + 1
    return lex, genres


def facts(lex, genres):
    """The corpus section of the prompt, as QueryContextBuilder will build it."""
    top = lambda c, n: ", ".join(v for v, _ in sorted(lex[c].items(), key=lambda kv: -kv[1])[:n] if v != "_")
    lines = ["- word: the word form. lemma: dictionary form."]
    for c, n in (("upos", 20), ("feats", 80), ("deprel", 45), ("xpos", 50)):
        lines.append(f"- {c} ({DESCRIPTIONS[c]}): {top(c, n)}")
    lines.append(f"- doc.genre values: {', '.join(sorted(genres))}")
    return "\n".join(lines)


def problems(plan, lex, got):
    """What the app's validation step would tell the model, or None."""
    out = []
    for p in plan["positions"]:
        for c in p["conditions"]:
            v, a = c["value"], c["attribute"]
            if c["op"] == "=" and not (set(v) & REGEX_CHARS) and v not in lex[a]:
                near = [x for x in lex[a] if x.lower().startswith(v.split("=")[0].lower())][:8]
                hint = f" Existing values like it: {', '.join(near)}." if near else ""
                out.append(f'No token has {a}="{v}".{hint}')
    if not out and got is not None and got[0] == 0:
        out.append("The query finds nothing in this corpus.")
    return " ".join(out) or None


def gold_hits(gold):
    """Hit keys of the gold query and its acceptable alternatives, which
    follow it separated by " || " (other reasonable readings of the request,
    e.g. word!= where the gold has lemma!=)."""
    keys = []
    for g in gold.split(" || "):
        h, err = hits(g)
        assert err is None, f"gold query broken: {g}: {err}"
        keys.append(h)
    return keys


def judge(got, golds):
    """EXACT: same hits as the gold query; OK: as an acceptable alternative."""
    if got is None:
        return "ERROR"
    if got == golds[0]:
        return "EXACT"
    if got in golds[1:]:
        return "OK"
    return f"DIFF {got[0]} vs {golds[0][0]}"


def summary(verdicts):
    n, exact = len(verdicts), verdicts.count("EXACT")
    return (f"{exact}/{n} exact, {exact + verdicts.count('OK')}/{n} acceptable "
            f"(same count + same first 5 hits)")


def rescore(results, requests):
    """Re-judge a results file against the current gold file, without a model."""
    golds = {}
    for line in open(requests):
        r, g = line.rstrip("\n").split("\t")
        golds[r] = gold_hits(g)
    verdicts = []
    for line in open(results):
        cols = line.rstrip("\n").split("\t")
        got, _ = hits(cols[2]) if cols[2] else (None, None)
        verdicts.append(judge(got, golds[cols[0]]))
    print(f"{os.path.basename(results)}: {summary(verdicts)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("requests", nargs="?", default=os.path.join(HERE, "requests.tsv"))
    ap.add_argument("--instructions", default=os.path.join(HERE, "instructions.txt"))
    ap.add_argument("--retry", action="store_true", help="one validation retry, as the app does")
    ap.add_argument("--prompts", metavar="JSONL",
                    help="system/user prompts per request from `korpora-assistant prompts`, "
                         "instead of --instructions")
    ap.add_argument("--schema", default=os.path.join(HERE, "schema.json"),
                    help="generation JSON Schema (e.g. from `korpora-assistant schema`)")
    ap.add_argument("--tag", default="", help="suffix for the results file name")
    ap.add_argument("--rescore", metavar="RESULTS_TSV",
                    help="re-judge a results file against REQUESTS; no model run (MODEL is ignored)")
    args = ap.parse_args()
    if args.rescore:
        return rescore(args.rescore, args.requests)

    model, tokenizer = load(args.model)
    info = xgr.TokenizerInfo.from_huggingface(tokenizer._tokenizer, vocab_size=model.args.vocab_size
                                              if hasattr(model, "args") and hasattr(model.args, "vocab_size") else None)
    schema = open(args.schema).read()
    # Compact JSON: no free whitespace between tokens, so a small model can't
    # stall emitting blanks (the app gets the same effect from
    # WhitespaceTokenBias).
    compiled = xgr.GrammarCompiler(info).compile_json_schema(schema, any_whitespace=False)
    lex, genres = lexicons()
    instructions = open(args.instructions).read().replace("{FACTS}", facts(lex, genres))
    prompts = {}
    if args.prompts:
        for line in open(args.prompts):
            record = json.loads(line)
            prompts[record["request"]] = (record["system"], record["user"])
    eos_id = tokenizer.eos_token_id

    def ask(messages):
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                               enable_thinking=False)
        text = generate(model, tokenizer, prompt, max_tokens=400, verbose=False,
                        sampler=make_sampler(temp=0.0),
                        logits_processors=[GrammarProcessor(compiled, eos_id)])
        try:
            plan = json.loads(text)
            cql = to_cql(plan)
            got, err = hits(cql)
        except Exception as e:  # truncated output (max_tokens) or bad JSON
            cql, got, err, plan = "", None, f"generation failed: {e}: {text[:200]}", {}
        return text, plan, cql, got, err

    rows, retries, t_total = [], 0, 0.0
    for line in open(args.requests):
        request, gold = line.rstrip("\n").split("\t")
        golds = gold_hits(gold)
        system, user = prompts.get(request) or (instructions, f"Request: {request}")
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        t0 = time.time()
        text, plan, cql, got, err = ask(messages)
        note = ""
        if args.retry and plan:
            feedback = err or problems(plan, lex, got)
            if feedback:
                retries += 1
                note = f"retried ({feedback}; first: {cql})"
                messages += [{"role": "assistant", "content": text},
                             {"role": "user", "content": f"{feedback} Fix the QueryPlan."}]
                text, plan, cql, got, err = ask(messages)
        dt = time.time() - t0
        t_total += dt
        verdict = judge(got, golds)
        rows.append((request, gold, cql, verdict, err or "", note, plan.get("explanation", ""), f"{dt:.1f}"))
        print(f"{verdict:18} {request}  ({dt:.1f}s)\n{'':18} gold: {gold}\n"
              f"{'':18} got:  {cql}{('  ! ' + err) if err else ''}"
              + (f"\n{'':18} {note}" if note else ""), flush=True)
    os.makedirs(OUT, exist_ok=True)
    name = args.model.rstrip("/").split("/")[-1] + args.tag
    with open(os.path.join(OUT, f"results-{name}.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"\n{args.model}{args.tag}: {summary([r[3] for r in rows])}, "
          f"{retries} retries, {t_total / len(rows):.1f}s per request")


if __name__ == "__main__":
    main()
