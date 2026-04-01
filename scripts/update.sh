#!/bin/bash

set -e

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


# reformat lib2to3, ignore any failures
.venv/bin/python -m black --fast fissix/ || true

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
.venv/bin/python -m black --fast fissix/ || true

# Update version markers
scripts/version.sh

# Amend formatting and version markers to cherry-pick commit
git commit -am "Merge upstream lib2to3 from $REV"

finish 0 "Update completed; be sure to push both main and base branches"
