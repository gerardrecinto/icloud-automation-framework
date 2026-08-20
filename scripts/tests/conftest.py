import sys
from pathlib import Path

# triage.py and coverage_gap.py are standalone CLI scripts, not a
# package, so make the scripts/ dir importable for these tests.
SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
