#!/usr/bin/env python3
"""Entry point Cinder starts for each rooted filesystem operation (one process each).

A script run directly is compiled from source on every start; an imported module runs
from its cached bytecode in __pycache__/. Importing rooted_fs from here saves that
compile, about 4.6 ms of a 28 ms start (#707).
"""

import os
import sys

# Not left to Python's own "script directory first" rule, which PYTHONSAFEPATH turns off.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rooted_fs  # noqa: E402

rooted_fs.run()
