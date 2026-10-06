import cProfile
import pstats
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
from bench import build_tests

tests = dict(build_tests())
for name in sys.argv[1:]:
    fn = tests[name]
    fn(200)
    prof = cProfile.Profile()
    prof.enable()
    fn(int(__import__("os").environ.get("N", "2000")))
    prof.disable()
    print(f"===== {name}")
    pstats.Stats(prof).sort_stats("tottime").print_stats(18)
