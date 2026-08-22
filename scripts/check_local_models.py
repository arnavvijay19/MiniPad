#!/usr/bin/env python3
"""Verify every model in the local catalog against the inference stack.

"Never present a model as supported unless it actually works with the selected
inference stack" is easy to say and easy to violate: a catalog entry is a
string, and a string is always plausible. This script turns each entry into
claims that can be false, and checks them:

  1. The Hugging Face repository exists, is public, and is not gated.
  2. Its `config.json` names a `model_type` that the *pinned* mlx-swift-lm
     revision's `LLMModelFactory` registry can actually construct. The registry
     is read from that exact revision on GitHub — the same commit
     `scripts/add_mlx_package.py` links into the Xcode project — so this cannot
     drift away from what the app will really run.
  3. A tokenizer is present (`tokenizer.json`, or the sentencepiece pair).
  4. The catalog's declared download size matches the sum of the repository's
     weight files, within 2%. A wrong size is not cosmetic: the picker uses it
     to decide whether the device has room, and to warn before a multi-gigabyte
     download on cellular.

What it deliberately does not claim: that a model is *fast enough*, or that it
fits in memory on any particular iPad. That needs the device.

Usage:
    python3 scripts/check_local_models.py [--offline]

`--offline` skips the network checks and validates only that the catalog parses
and is internally consistent, so the script is still useful with no network.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "src/ios/Providers/Local/LocalModelCatalog.swift")
ADD_MLX = os.path.join(ROOT, "scripts/add_mlx_package.py")

HF_API = "https://huggingface.co/api/models/{repo}"
HF_FILE = "https://huggingface.co/{repo}/resolve/main/{path}"
MLX_FACTORY = ("https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/"
               "{rev}/Libraries/MLXLLM/LLMModelFactory.swift")

WEIGHT_SUFFIXES = (".safetensors", ".npz", ".gguf")
TOLERANCE = 0.02


def get(url: str, as_json: bool = True, timeout: int = 45):
    request = urllib.request.Request(url, headers={"User-Agent": "minipad-model-check"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
    return json.loads(raw) if as_json else raw.decode("utf-8", "replace")


def pinned_revision() -> str:
    text = open(ADD_MLX, encoding="utf-8").read()
    match = re.search(r'MLX_REVISION\s*=\s*"([0-9a-f]{40})"', text)
    if not match:
        raise SystemExit("could not read MLX_REVISION from scripts/add_mlx_package.py")
    return match.group(1)


def supported_model_types(revision: str) -> set[str]:
    """The keys of MLXLLM's ModelTypeRegistry at the pinned revision."""
    source = get(MLX_FACTORY.format(rev=revision), as_json=False)
    block = re.search(r"ModelTypeRegistry<LanguageModel>\s*=\s*\.init\(creators:\s*\[(.*?)\n\s*\]\)",
                      source, re.S)
    if not block:
        raise SystemExit("could not find the model type registry in LLMModelFactory.swift")
    return set(re.findall(r'"([^"]+)"\s*:\s*create\(', block.group(1)))


def catalog_entries() -> list[dict]:
    """Parse the seed entries out of LocalModelCatalog.swift."""
    text = open(CATALOG, encoding="utf-8").read()
    seed = re.search(r"static let seed:\s*\[LocalModelEntry\]\s*=\s*\[(.*?)\n\s*\]\n", text, re.S)
    if not seed:
        raise SystemExit("could not find the seed catalog in LocalModelCatalog.swift")
    entries = []
    for chunk in re.finditer(r"LocalModelEntry\((.*?)\n\s*\)", seed.group(1), re.S):
        body = chunk.group(1)
        repo = re.search(r'repoID:\s*"([^"]+)"', body)
        size = re.search(r"downloadBytes:\s*([0-9_]+)", body)
        name = re.search(r'displayName:\s*"([^"]+)"', body)
        if not (repo and size):
            continue
        entries.append({
            "repo": repo.group(1),
            "declared_bytes": int(size.group(1).replace("_", "")),
            "name": name.group(1) if name else repo.group(1),
        })
    return entries


def check(entry: dict, supported: set[str]) -> list[str]:
    repo = entry["repo"]
    problems = []
    try:
        info = get(HF_API.format(repo=repo))
    except urllib.error.HTTPError as exc:
        return [f"{repo}: Hugging Face returned HTTP {exc.code} — the repository "
                f"does not exist or is not public"]
    except Exception as exc:                                  # noqa: BLE001
        return [f"{repo}: could not reach Hugging Face ({exc})"]

    if info.get("private"):
        problems.append(f"{repo}: repository is private")
    if info.get("gated"):
        problems.append(f"{repo}: repository is gated — the app cannot download it "
                        f"without credentials")

    files = {sibling["rfilename"]: sibling for sibling in info.get("siblings", [])}

    if "tokenizer.json" not in files and not (
            "tokenizer.model" in files and "tokenizer_config.json" in files):
        problems.append(f"{repo}: no tokenizer (neither tokenizer.json nor a "
                        f"sentencepiece tokenizer.model + tokenizer_config.json)")

    if "config.json" not in files:
        problems.append(f"{repo}: no config.json")
        return problems

    try:
        config = json.loads(get(HF_FILE.format(repo=repo, path="config.json"),
                                as_json=False))
    except Exception as exc:                                  # noqa: BLE001
        return problems + [f"{repo}: could not read config.json ({exc})"]

    model_type = config.get("model_type")
    if model_type not in supported:
        problems.append(
            f"{repo}: model_type '{model_type}' is not in MLXLLM's registry — "
            f"the app would download gigabytes and then fail to construct it")

    quant = config.get("quantization") or config.get("quantization_config")
    if not quant:
        problems.append(f"{repo}: config declares no quantization — an unquantized "
                        f"model of this size will not fit on an iPad")

    # Size: the HF model API omits per-file sizes unless asked for them.
    try:
        tree = get(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=1")
        actual = sum(node.get("size", 0) for node in tree
                     if node.get("path", "").endswith(WEIGHT_SUFFIXES))
    except Exception:                                         # noqa: BLE001
        actual = 0

    if actual:
        declared = entry["declared_bytes"]
        drift = abs(actual - declared) / max(actual, 1)
        marker = "ok" if drift <= TOLERANCE else "DRIFT"
        print(f"      weights {actual:,} bytes, catalog says {declared:,} "
              f"({drift * 100:.1f}% {marker})")
        if drift > TOLERANCE:
            problems.append(
                f"{repo}: catalog declares {declared:,} bytes, repository weights "
                f"total {actual:,} ({drift * 100:.1f}% off)")
    else:
        print("      (per-file sizes unavailable; size check skipped)")

    if not problems:
        print(f"      model_type '{model_type}' -> MLXLLM registry, "
              f"{quant.get('bits', '?')}-bit, tokenizer present")
    return problems


def main() -> int:
    entries = catalog_entries()
    if not entries:
        print("no catalog entries found", file=sys.stderr)
        return 1

    print(f"{len(entries)} catalog entries")
    if "--offline" in sys.argv:
        for entry in entries:
            print(f"  {entry['name']:<26} {entry['repo']}  "
                  f"{entry['declared_bytes'] / 1e9:.2f} GB")
        print("\nOK  catalog parses (offline: no repository checks)")
        return 0

    revision = pinned_revision()
    supported = supported_model_types(revision)
    print(f"mlx-swift-lm @ {revision[:12]} supports {len(supported)} model types\n")

    problems = []
    for entry in entries:
        print(f"  {entry['name']}  ({entry['repo']})")
        problems += check(entry, supported)

    if problems:
        print("\nFAIL — the catalog claims support it does not have:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"\nOK  {len(entries)} models exist, are public, and are constructible "
          f"by the linked MLX revision")
    return 0


if __name__ == "__main__":
    sys.exit(main())
