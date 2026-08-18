#!/usr/bin/env python3
"""Link mlx-swift-lm into the Minis app target.

Until now `MLXLocalProvider` was behind `#if canImport(MLXLLM)`, which meant
the on-device inference path compiled only when it was switched off — the code
was never type-checked against the real package by any build. This script adds
the package so it is, and so a local model is a genuinely selectable provider
rather than a code path waiting for someone to wire it up.

Three things it does, all idempotent:

  1. An XCRemoteSwiftPackageReference pinned to an exact revision. Not a branch:
     `scripts/typecheck_mlx_adapter.sh` asserts seventeen specific facts about
     this package's API, and those assertions are only meaningful if the build
     and the assertions see the same commit. Both pin MLX_REVISION below.

  2. XCSwiftPackageProductDependency for MLXLLM, MLXLMCommon and MLXHuggingFace,
     added to the app target's package product list and its Frameworks phase.
     MLXHuggingFace is the one that supplies `#huggingFaceLoadModelContainer`.

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
PRODUCTS = ["MLXLLM", "MLXLMCommon", "MLXHuggingFace"]

APP_TARGET = "E51000040"          # PBXNativeTarget "Minis"
APP_FRAMEWORKS = "E51000020"      # its Frameworks build phase
PROJECT_OBJ = "E51000060"         # PBXProject


def stable_id(seed: str) -> str:
    return hashlib.sha1(("minipad-mlx:" + seed).encode()).hexdigest()[:24].upper()


PKG_REF = stable_id("package:mlx-swift-lm")


def main() -> int:
    src = open(PBXPROJ, encoding="utf-8").read()
    original = src

    # 1. The package reference -------------------------------------------------
    if "mlx-swift-lm" not in src:
        block = (
            f'\t\t{PKG_REF} /* XCRemoteSwiftPackageReference "mlx-swift-lm" */ = {{\n'
            f"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
            f'\t\t\trepositoryURL = "{MLX_URL}";\n'
            f"\t\t\trequirement = {{\n"
            f"\t\t\t\tkind = revision;\n"
            f"\t\t\t\trevision = {MLX_REVISION};\n"
            f"\t\t\t}};\n"
            f"\t\t}};\n"
        )
        src = src.replace(
            "/* End XCRemoteSwiftPackageReference section */",
            block + "/* End XCRemoteSwiftPackageReference section */", 1)

        # Register it on the project.
        m = re.search(
            re.escape(PROJECT_OBJ) + r" /\* Project object \*/ = \{.*?packageReferences = \(\n",
            src, re.S)
        if not m:
            raise SystemExit("could not find the project's packageReferences list")
        entry = (f'\t\t\t\t{PKG_REF} /* XCRemoteSwiftPackageReference "mlx-swift-lm" */,\n')
        src = src[:m.end()] + entry + src[m.end():]

    # 2. Product dependencies --------------------------------------------------
    for product in PRODUCTS:
        dep_id = stable_id("product:" + product)
        build_id = stable_id("buildfile:" + product)

        if f"/* {product} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;" not in src:
            block = (
                f"\t\t{dep_id} /* {product} */ = {{\n"
                f"\t\t\tisa = XCSwiftPackageProductDependency;\n"
                f'\t\t\tpackage = {PKG_REF} /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;\n'
                f"\t\t\tproductName = {product};\n"
                f"\t\t}};\n"
            )
            src = src.replace(
                "/* End XCSwiftPackageProductDependency section */",
                block + "/* End XCSwiftPackageProductDependency section */", 1)

        if f"/* {product} in Frameworks */" not in src:
            line = (f"\t\t{build_id} /* {product} in Frameworks */ = {{isa = PBXBuildFile; "
                    f"productRef = {dep_id} /* {product} */; }};\n")
            src = src.replace("/* End PBXBuildFile section */",
                              line + "/* End PBXBuildFile section */", 1)

            m = re.search(
                re.escape(APP_FRAMEWORKS) + r" /\* Frameworks \*/ = \{.*?files = \(\n",
                src, re.S)
            if not m:
                raise SystemExit("could not find the app target's Frameworks phase")
            src = (src[:m.end()]
                   + f"\t\t\t\t{build_id} /* {product} in Frameworks */,\n"
                   + src[m.end():])

        m = re.search(
            re.escape(APP_TARGET) + r" /\* Minis \*/ = \{.*?packageProductDependencies = \(\n",
            src, re.S)
        if not m:
            raise SystemExit("could not find the app target's packageProductDependencies")
        if f"{dep_id} /* {product} */,\n" not in src[m.end():m.end() + 600]:
            src = src[:m.end()] + f"\t\t\t\t{dep_id} /* {product} */,\n" + src[m.end():]

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

    if "--check" in sys.argv:
        if src != original:
            print("project.pbxproj does not have mlx-swift-lm fully wired", file=sys.stderr)
            return 1
        print("OK  mlx-swift-lm is linked into the Minis target")
        return 0

    if src == original:
        print("No changes — mlx-swift-lm is already linked.")
        return 0

    open(PBXPROJ, "w", encoding="utf-8").write(src)
    print(f"Linked mlx-swift-lm @ {MLX_REVISION[:12]} "
          f"({', '.join(PRODUCTS)}); app target now iOS 17.0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
