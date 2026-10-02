#!/usr/bin/env python3
"""Recompute today's API-equivalent spend from ~/.claude/projects to cross-check `claude-usage-cli stats`."""
import datetime
import glob
import json
import os

PRICES = [  # prefix, input, output, cache read  ($/MTok, spec §9)
    ("claude-fable-5-1", 10, 50, 0.25), ("claude-fable-5", 10, 50, 1.00),
    ("claude-opus-5-5", 4, 20, 0.20), ("claude-opus-5", 5, 25, 0.50), ("claude-opus-4-8", 5, 25, 0.50),
    ("claude-opus-4-7", 5, 25, 0.50), ("claude-opus-4-6", 5, 25, 0.50),
    ("claude-sonnet-5-5", 2, 10, 0.20), ("claude-sonnet-5", 2, 10, 0.20), ("claude-sonnet-4-6", 3, 15, 0.30),
    ("claude-haiku-4-5", 1, 5, 0.10),
]


def price(model):
    matches = [p for p in PRICES if model.startswith(p[0])]
    return max(matches, key=lambda p: len(p[0])) if matches else None


def main():
    start = datetime.datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    seen, total = set(), 0.0
    files = sorted(glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True))
    for path in files:
        with open(path, "rb") as handle:
            for raw in handle:
                if b'"type":"assistant"' not in raw or not raw.endswith(b"\n"):
                    continue
                try:
                    line = json.loads(raw)
                except ValueError:
                    continue
                message = line.get("message") or {}
                mid, model, usage = message.get("id"), message.get("model"), message.get("usage")
                if line.get("type") != "assistant" or not mid or not model or model == "<synthetic>" or not usage:
                    continue
                if mid in seen:
                    continue
                seen.add(mid)
                ts = datetime.datetime.fromisoformat(line["timestamp"].replace("Z", "+00:00")).timestamp()
                if (ts // 3600) * 3600 < start:
                    continue
                p = price(model)
                if not p:
                    continue
                detail = usage.get("cache_creation")
                cw1h = (detail or {}).get("ephemeral_1h_input_tokens") or 0
                cw5m = (detail or {}).get("ephemeral_5m_input_tokens") or 0 if detail else usage.get("cache_creation_input_tokens") or 0
                cost = ((usage.get("input_tokens") or 0) * p[1] + (usage.get("output_tokens") or 0) * p[2]
                        + (usage.get("cache_read_input_tokens") or 0) * p[3] + cw5m * p[1] * 1.25 + cw1h * p[1] * 2.0)
                if usage.get("speed") == "fast":
                    cost *= 2
                total += cost
    print(f"today ${total / 1e6:.2f}")


if __name__ == "__main__":
    main()
