#!/usr/bin/env python3
"""Link the on-device inference packages into the Minis app target.

Until now `MLXLocalProvider` was behind `#if canImport(MLXLLM)`, which meant
the on-device inference path compiled only when it was switched off — the code
was never type-checked against the real package by any build. This script adds
the package so it is, and so a local model is a genuinely selectable provider
rather than a code path waiting for someone to wire it up.

Three things it does, all idempotent:

  1. mlx-swift-lm, pinned to an exact revision. Not a branch:
     `scripts/typecheck_mlx_adapter.sh` asserts two dozen specific facts about
     this package's API, and those assertions are only meaningful if the build
     and the assertions see the same commit. Both pin MLX_REVISION below.

  2. swift-transformers and swift-huggingface, for the `Tokenizers` and
     `HuggingFace` modules that `#huggingFaceLoadModelContainer` expands into.
     See the comment on PACKAGES — this is not an optional extra.

  3. Raises the app target's iOS deployment target to 17.0. mlx-swift-lm
     declares `.iOS(.v17)`, so a 16.0 target refuses to link it. This is the
     one piece of upstream divergence the package forces, and it is the
     minimum the package allows.

Usage:  python3 scripts/add_mlx_package.py [--check]
"""
from __future__ import annotations

import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "src/ios/Minis.xcodeproj/project.pbxproj")

MLX_URL = "https://github.com/ml-explore/mlx-swift-lm"
# Pinned. `scripts/typecheck_mlx_adapter.sh` verifies the adapter against this
# exact commit; see docs/design/unified-agent/ARCHITECTURE.md §3.
MLX_REVISION = "d7dc03d8447ee6b42b54a1c5295b4e56ee9274f3"

# Three packages, and the third and fourth are not optional extras.
#
# `#huggingFaceLoadModelContainer` is a *macro*. Its expansion is inserted into
# the calling file and references `HuggingFace.HubClient` and
# `Tokenizers.AutoTokenizer` by name — but mlx-swift-lm depends on neither
# (its only dependencies are mlx-swift, swift-syntax and swift-docc-plugin).
# The macro's own source even carries `// import Tokenizers` as a note to the
# caller. So the two modules the expansion needs have to be linked here:
#
#   Tokenizers   <- huggingface/swift-transformers
#   HuggingFace  <- huggingface/swift-huggingface
#
# Without them the app fails to compile with "no such module 'HuggingFace'"
# the first time MLXLocalProvider is built with MLX present — which is to say,
# the first time the on-device path is compiled at all.
PACKAGES = [
    {
        "name": "mlx-swift-lm",
        "url": MLX_URL,
        "requirement": f"kind = revision;\n\t\t\t\trevision = {MLX_REVISION};",
        "products": ["MLXLLM", "MLXLMCommon", "MLXHuggingFace"],
    },
    {
        "name": "swift-transformers",
        "url": "https://github.com/huggingface/swift-transformers",
        "requirement": "kind = upToNextMinorVersion;\n\t\t\t\tminimumVersion = 1.3.3;",
        "products": ["Tokenizers"],
    },
    {
        "name": "swift-huggingface",
        "url": "https://github.com/huggingface/swift-huggingface",
        "requirement": "kind = upToNextMinorVersion;\n\t\t\t\tminimumVersion = 0.9.0;",
        "products": ["HuggingFace"],
    },
]

APP_TARGET = "E51000040"          # PBXNativeTarget "Minis"
APP_FRAMEWORKS = "E51000020"      # its Frameworks build phase
PROJECT_OBJ = "E51000060"         # PBXProject


def stable_id(seed: str) -> str:
    return hashlib.sha1(("minipad-mlx:" + seed).encode()).hexdigest()[:24].upper()


def package_ref(name: str) -> str:
    return stable_id("package:" + name)


def ensure_package(src: str, package: dict) -> str:
    """Declare the package and its products on the app target. Idempotent."""
    name = package["name"]
    ref = package_ref(name)

    # 1. The package reference itself.
    if f'XCRemoteSwiftPackageReference "{name}"' not in src:
        block = (
            f'\t\t{ref} /* XCRemoteSwiftPackageReference "{name}" */ = {{\n'
            f"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
            f'\t\t\trepositoryURL = "{package["url"]}";\n'
            f"\t\t\trequirement = {{\n"
            f"\t\t\t\t{package['requirement']}\n"
            f"\t\t\t}};\n"
            f"\t\t}};\n"
        )
        src = src.replace("/* End XCRemoteSwiftPackageReference section */",
                          block + "/* End XCRemoteSwiftPackageReference section */", 1)
        match = re.search(
            re.escape(PROJECT_OBJ) + r" /\* Project object \*/ = \{.*?packageReferences = \(\n",
            src, re.S)
        if not match:
            raise SystemExit("could not find the project's packageReferences list")
        entry = f'\t\t\t\t{ref} /* XCRemoteSwiftPackageReference "{name}" */,\n'
        src = src[:match.end()] + entry + src[match.end():]

    # 2. Each product: a dependency object, a build file, the Frameworks phase,
    #    and the target's package product list.
    for product in package["products"]:
        dep_id = stable_id("product:" + product)
        build_id = stable_id("buildfile:" + product)

        if f"/* {product} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;" not in src:
            block = (
                f"\t\t{dep_id} /* {product} */ = {{\n"
                f"\t\t\tisa = XCSwiftPackageProductDependency;\n"
                f'\t\t\tpackage = {ref} /* XCRemoteSwiftPackageReference "{name}" */;\n'
                f"\t\t\tproductName = {product};\n"
                f"\t\t}};\n"
            )
            src = src.replace("/* End XCSwiftPackageProductDependency section */",
                              block + "/* End XCSwiftPackageProductDependency section */", 1)

        if f"/* {product} in Frameworks */" not in src:
            line = (f"\t\t{build_id} /* {product} in Frameworks */ = {{isa = PBXBuildFile; "
                    f"productRef = {dep_id} /* {product} */; }};\n")
            src = src.replace("/* End PBXBuildFile section */",
                              line + "/* End PBXBuildFile section */", 1)
            match = re.search(
                re.escape(APP_FRAMEWORKS) + r" /\* Frameworks \*/ = \{.*?files = \(\n",
                src, re.S)
            if not match:
                raise SystemExit("could not find the app target's Frameworks phase")
            src = (src[:match.end()]
                   + f"\t\t\t\t{build_id} /* {product} in Frameworks */,\n"
                   + src[match.end():])

        match = re.search(
            re.escape(APP_TARGET) + r" /\* Minis \*/ = \{.*?packageProductDependencies = \(\n",
            src, re.S)
        if not match:
            raise SystemExit("could not find the app target's packageProductDependencies")
        if f"{dep_id} /* {product} */,\n" not in src[match.end():match.end() + 900]:
            src = src[:match.end()] + f"\t\t\t\t{dep_id} /* {product} */,\n" + src[match.end():]

    return src


def main() -> int:
    src = open(PBXPROJ, encoding="utf-8").read()
    original = src

    for package in PACKAGES:
        src = ensure_package(src, package)

    # 3. Deployment target -----------------------------------------------------
    # Only the app target's two configurations; the extensions do not link MLX
    # and there is no reason to move them.
    def raise_target(text: str, config_id: str) -> str:
        m = re.search(re.escape(config_id) + r" /\* \w+ \*/ = \{.*?^\t\t\};",
                      text, re.S | re.M)
        if not m:
            raise SystemExit(f"could not find build configuration {config_id}")
        block = m.group(0)
        if "IPHONEOS_DEPLOYMENT_TARGET = 17.0;" in block:
            return text
        new = block.replace("IPHONEOS_DEPLOYMENT_TARGET = 16.0;",
                            "IPHONEOS_DEPLOYMENT_TARGET = 17.0;")
        return text[:m.start()] + new + text[m.end():]

    for config in ("E51000072", "E51000073"):   # Minis Debug / Release
        src = raise_target(src, config)

    summary = "; ".join(f"{p['name']} ({', '.join(p['products'])})" for p in PACKAGES)

    if "--check" in sys.argv:
        if src != original:
            print("project.pbxproj is missing part of the on-device inference "
                  "wiring — run this script without --check", file=sys.stderr)
            return 1
        print(f"OK  linked: {summary}; app target iOS 17.0")
        return 0

    if src == original:
        print(f"No changes — already linked: {summary}")
        return 0

    open(PBXPROJ, "w", encoding="utf-8").write(src)
    print(f"Linked {summary}; app target now iOS 17.0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
