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

# replace lib2to3 references with fissix
find fissix/ -name "*.py" -exec sed -i 's/\blib2to3\b/fissix/g' {} +
# fix test imports that use stdlib's test.test_lib2to3 instead of relative import
find fissix/tests/ -name "*.py" -exec sed -i 's/from test\.test_lib2to3 import support/from . import support/g' {} +
# fix tokenize.py to handle async with/for outside async functions (handle both quote styles)
sed -i 's/if token in ("def", "for"):/if token in ("def", "for", "with"):/' fissix/pgen2/tokenize.py
sed -i "s/if token in ('def', 'for'):/if token in ('def', 'for', 'with'):/" fissix/pgen2/tokenize.py
# replace deprecated os.path.commonprefix() with os.path.commonpath() in main.py
python3 - <<'COMMONPATH'
import re
with open('fissix/main.py') as f:
    content = f.read()
# Replace the commonprefix block with the cleaner commonpath version
content = re.sub(
    r'input_base_dir = os\.path\.commonprefix\(args\)\n'
    r'    if \(input_base_dir and not input_base_dir\.endswith\(os\.sep\)\n'
    r'        and not os\.path\.isdir\(input_base_dir\)\):\n'
    r'        # One or more similar names were passed, their directory is the base\.\n'
    r'        # os\.path\.commonprefix\(\) is ignorant of path elements, this corrects\n'
    r'        # for that weird API\.\n'
    r'        input_base_dir = os\.path\.dirname\(input_base_dir\)',
    'if args:\n        input_base_dir = os.path.commonpath(args)\n'
    '        if not os.path.isdir(input_base_dir):\n'
    '            # args are filenames, use their common parent directory.\n'
    '            input_base_dir = os.path.dirname(input_base_dir)\n'
    '    else:\n        input_base_dir = ""',
    content
)
with open('fissix/main.py', 'w') as f:
    f.write(content)
COMMONPATH
# restore xfail markers removed by rsync
python3 - <<'PYEOF'
import re

for filepath, pattern, replacement in [
    ('fissix/tests/test_main.py',
     '    def test_filename_changing_on_output_single_dir(',
     '    @pytest.mark.xfail\n    def test_filename_changing_on_output_single_dir('),
    ('fissix/tests/test_main.py',
     '    def test_filename_changing_on_output_two_files(',
     '    @pytest.mark.xfail\n    def test_filename_changing_on_output_two_files('),
    ('fissix/tests/test_main.py',
     '    def test_filename_changing_on_output_single_file(',
     '    @pytest.mark.xfail\n    def test_filename_changing_on_output_single_file('),
]:
    with open(filepath) as f:
        content = f.read()
    if replacement not in content:
        content = content.replace(pattern, replacement)
    if 'import pytest' not in content:
        content = content.replace('from fissix import main', 'import pytest\n\nfrom fissix import main')
    with open(filepath, 'w') as f:
        f.write(content)

# test_parser.py xfail
filepath = 'fissix/tests/test_parser.py'
with open(filepath) as f:
    content = f.read()
marker = '@pytest.mark.xfail\n    @unittest.skipIf(sys.executable is None'
if marker not in content:
    import re
    content = re.sub(
        r'(@unittest\.skipIf\(sys\.executable is None, ["\']sys\.executable required["\']\)\n    @unittest\.skipIf\(\n        sys\.platform in \{["\']emscripten["\'], ["\']wasi["\']\}, ["\']requires working subprocess["\']\n    \)\n    def test_load_grammar_from_subprocess\()',
        r'@pytest.mark.xfail\n    \1',
        content
    )
if 'import pytest' not in content:
    content = content.replace('import unittest', 'import pytest\nimport unittest')
with open(filepath, 'w') as f:
    f.write(content)
PYEOF

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
