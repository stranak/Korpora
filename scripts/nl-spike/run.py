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
    ... run.py MODEL [requests.tsv] [--instructions FILE]

Writes data/nl-spike/results-<model>.tsv and prints a summary.
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("requests", nargs="?", default=os.path.join(HERE, "requests.tsv"))
    ap.add_argument("--instructions", default=os.path.join(HERE, "instructions.txt"))
    args = ap.parse_args()

    model, tokenizer = load(args.model)
    info = xgr.TokenizerInfo.from_huggingface(tokenizer._tokenizer, vocab_size=model.args.vocab_size
                                              if hasattr(model, "args") and hasattr(model.args, "vocab_size") else None)
    schema = open(os.path.join(HERE, "schema.json")).read()
    # Compact JSON: no free whitespace between tokens, so a small model can't
    # stall emitting blanks (the app gets the same effect from
    # WhitespaceTokenBias).
    compiled = xgr.GrammarCompiler(info).compile_json_schema(schema, any_whitespace=False)
    instructions = open(args.instructions).read()
    eos_id = tokenizer.eos_token_id

    rows, exact, t_total = [], 0, 0.0
    for line in open(args.requests):
        request, gold = line.rstrip("\n").split("\t")
        gold_hits, gerr = hits(gold)
        assert gerr is None, f"gold query broken: {gold}: {gerr}"
        messages = [{"role": "system", "content": instructions},
                    {"role": "user", "content": f"Request: {request}"}]
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                               enable_thinking=False)
        t0 = time.time()
        text = generate(model, tokenizer, prompt, max_tokens=400, verbose=False,
                        sampler=make_sampler(temp=0.0),
                        logits_processors=[GrammarProcessor(compiled, eos_id)])
        dt = time.time() - t0
        t_total += dt
        try:
            plan = json.loads(text)
            cql = to_cql(plan)
            got, err = hits(cql)
        except Exception as e:  # truncated output (max_tokens) or bad JSON
            cql, got, err, plan = "", None, f"generation failed: {e}: {text[:200]}", {}
        ok = got is not None and got == gold_hits
        exact += ok
        verdict = "EXACT" if ok else ("ERROR" if got is None else f"DIFF {got[0]} vs {gold_hits[0]}")
        rows.append((request, gold, cql, verdict, err or "", plan.get("explanation", ""), f"{dt:.1f}"))
        print(f"{verdict:18} {request}  ({dt:.1f}s)\n{'':18} gold: {gold}\n"
              f"{'':18} got:  {cql}{('  ! ' + err) if err else ''}", flush=True)
    os.makedirs(OUT, exist_ok=True)
    name = args.model.rstrip("/").split("/")[-1]
    with open(os.path.join(OUT, f"results-{name}.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"\n{args.model}: {exact}/{len(rows)} matches (same count + same first 5 hits), "
          f"{t_total / len(rows):.1f}s per request")


if __name__ == "__main__":
    main()
