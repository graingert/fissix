#!/bin/bash

set -e

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_MODE=1
fi

finish() {
    set +x
    echo $2
    exit $1
}

if [[ ! -d "fissix" ]]; then
    finish 1 "ERROR: Must be run from root of fissix repository"
fi

# debug mode
set -x

# Find a working black command: .venv first, then bare python
if [[ -x .venv/bin/python ]]; then
    BLACK=".venv/bin/python -m black"
else
    BLACK="python -m black"
fi

# ── sync: replay the upstream import ──
#
# This function rsyncs lib2to3 from the cpython submodule into fissix/,
# restores the custom __init__.py, applies fissix-specific patches, renames
# lib2to3 → fissix in all .py files, and reformats with black.
#
# It is used by both normal update mode and --check mode.
sync() {
    # copy from cpython
    rsync -av cpython/Lib/lib2to3/ fissix/
    rsync -av cpython/Lib/test/test_lib2to3/ fissix/tests/

    # restore fissix's custom __init__.py (rsync overwrites with plain cpython version)
    # and update version markers from cpython
    PY_VERSION=$(awk -F '"' '/define PY_VERSION /{print $2}' cpython/Include/patchlevel.h)
    CPYTHON_REV=$(git -C cpython describe)
    cat > fissix/__init__.py << FISSIX_INIT
# copyright 2022 Amethyst Reese
# Licensed under the PSF license V2


"""
Monkeypatches to override default behavior of lib2to3.
"""

import logging
import os
import sys
import tempfile
from pathlib import Path

from platformdirs import user_cache_dir

from .__version__ import __version__
from .pgen2 import driver, grammar, pgen

__base_version__ = "${PY_VERSION}"
__base_revision__ = "${CPYTHON_REV}"

CACHE_DIR = Path(user_cache_dir("fissix", version=__version__))


def _generate_pickle_name(gt):
    path = Path(gt)
    filename = f"{path.stem}{__base_version__}.pickle"
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return (CACHE_DIR / filename).as_posix()


def load_grammar(gt="Grammar.txt", gp=None, save=True, force=False, logger=None):
    """Load the grammar (maybe from a pickle)."""
    if logger is None:
        logger = logging.getLogger()
    gp = _generate_pickle_name(gt) if gp is None else gp
    if force or not driver._newer(gp, gt):
        logger.info("Generating grammar tables from %s", gt)
        g = pgen.generate_grammar(gt)
        if save:
            logger.info("Writing grammar tables to %s", gp)
            # Change here...
            with tempfile.TemporaryDirectory(dir=os.path.dirname(gp)) as d:
                tempfilename = os.path.join(d, os.path.basename(gp))
                try:
                    g.dump(tempfilename)
                    os.rename(tempfilename, gp)
                except OSError as e:
                    logger.info("Writing failed: %s", e)
    else:
        g = grammar.Grammar()
        g.load(gp)
    return g


driver._generate_pickle_name = _generate_pickle_name
driver.load_grammar = load_grammar
FISSIX_INIT

    # apply fissix-specific patches before renaming lib2to3 -> fissix
    patch -p0 < scripts/patches/tokenize_async_with.patch
    patch -p0 < scripts/patches/main_commonpath.patch
    patch -p0 < scripts/patches/test_fixers_support_import.patch
    patch -p0 < scripts/patches/test_main_xfail.patch
    patch -p0 < scripts/patches/test_parser_xfail.patch

    # replace lib2to3 references with fissix
    find fissix/ -name "*.py" -exec sed -i 's/\blib2to3\b/fissix/g' {} +

    # reformat, ignore any failures
    $BLACK --fast fissix/ || true
}

# ── --check mode: verify the tree matches what sync() produces ──
if [[ $CHECK_MODE -eq 1 ]]; then
    sync

    DRIFT=0

    # check for modified tracked files
    if ! git diff --exit-code fissix/; then
        DRIFT=1
    fi

    # check for untracked files (upstream added a file we haven't committed)
    UNTRACKED=$(git ls-files --others --exclude-standard fissix/)
    if [[ -n "$UNTRACKED" ]]; then
        echo "Untracked files in fissix/ after sync:"
        echo "$UNTRACKED"
        DRIFT=1
    fi

    if [[ $DRIFT -ne 0 ]]; then
        finish 1 "ERROR: fissix/ has drifted from what update.sh produces. Re-run scripts/update.sh."
    fi

    finish 0 "OK: fissix/ is in sync with cpython submodule and patches."
fi

# ── normal update mode ──

# make sure no local changes
git update-index -q --refresh
if ! git diff-index --quiet HEAD --; then
    finish 1 "ERROR: local changes present; stash or commit then retry"
fi

# switch to base branch, and discard local commits
git checkout -f base
git reset --hard origin/base

# update cpython to latest 3.12
git submodule update --init
git -C cpython checkout -f 3.12
git -C cpython clean -xfd

sync

# Stop early if no changes
git update-index -q --refresh
if git diff-index --quiet HEAD --; then
    git checkout -f main
    finish 0 "DONE: No upstream changes to lib2to3"
fi

# checkpoint on base branch
REV=$(git -C cpython describe)
git commit -am "Import upstream lib2to3 from $REV"

# cherry-pick this to main branch
git checkout -f main
if ! git cherry-pick base --no-commit; then
    while ! git update-index --refresh; do
        read -p "Merge conflicts present; resolve then press Enter to continue" choice
        echo "checking ..."
    done
fi

# reformat to catch merge conflicts
$BLACK --fast fissix/ || true

# Update version markers
scripts/version.sh

# Amend formatting and version markers to cherry-pick commit
git commit -am "Merge upstream lib2to3 from $REV"

finish 0 "Update completed; be sure to push both main and base branches"
