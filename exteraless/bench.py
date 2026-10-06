import json
import os
import sys
import time

from java import jclass, dynamic_proxy, jarray, jint

TARGET_S = float(os.environ.get("TARGET_S", "0.3"))
REPEATS = int(os.environ.get("REPEATS", "5"))


def measure(fn):
    n = 1
    while True:
        start = time.perf_counter_ns()
        fn(n)
        elapsed = time.perf_counter_ns() - start
        if elapsed > TARGET_S * 1e9 / 4 or n > 1 << 24:
            break
        n *= 2
    best = None
    for _ in range(REPEATS):
        start = time.perf_counter_ns()
        ops = fn(n)
        per = (time.perf_counter_ns() - start) / (ops or n)
        best = per if best is None else min(best, per)
    return best


def build_tests():
    String = jclass("java.lang.String")
    StringBuilder = jclass("java.lang.StringBuilder")
    HashMap = jclass("java.util.HashMap")
    ArrayList = jclass("java.util.ArrayList")
    System = jclass("java.lang.System")
    Integer = jclass("java.lang.Integer")
    Collections = jclass("java.util.Collections")
    Point = jclass("java.awt.Point")
    Consumer = jclass("java.util.function.Consumer")
    Comparator = jclass("java.util.Comparator")
    Runnable = jclass("java.lang.Runnable")

    class Counter(dynamic_proxy(Consumer)):
        def __init__(self):
            super().__init__()
            self.count = 0

        def accept(self, value):
            self.count += 1

    class Cmp(dynamic_proxy(Comparator)):
        def compare(self, a, b):
            return (a > b) - (a < b)

    class Task(dynamic_proxy(Runnable)):
        def run(self):
            pass

    def find_class(n):
        for _ in range(n):
            jclass("java.util.ArrayList")
        return n

    def static_call(n):
        f = System.currentTimeMillis
        for _ in range(n):
            f()
        return n

    def static_call_args(n):
        f = Integer.toString
        for i in range(n):
            f(i)
        return n

    s = String("benchmark string")

    def instance_call(n):
        for _ in range(n):
            s.length()
        return n

    def str_to_java(n):
        for _ in range(n):
            String("benchmark").length()
        return n

    def str_from_java(n):
        for _ in range(n):
            str(s.toString())
        return n

    def builder(n):
        for _ in range(n):
            sb = StringBuilder()
            for _ in range(5):
                sb.append("ab")
            sb.toString()
        return n

    def new_object(n):
        for i in range(n):
            Point(i, i)
        return n

    p = Point(3, 4)

    def field_read(n):
        for _ in range(n):
            p.x
        return n

    def field_write(n):
        for i in range(n):
            p.x = i
        return n

    def arraylist(n):
        lst = ArrayList()
        add, get = lst.add, lst.get
        for i in range(n):
            add(i)
        for i in range(0, n, 4):
            get(i)
        return n

    def hashmap(n):
        m = HashMap()
        put, get = m.put, m.get
        for i in range(n):
            put(i & 255, i)
            get(i & 127)
        return n

    def jarray_create(n):
        data = list(range(1000))
        loops = max(1, n // 1000)
        for _ in range(loops):
            jarray(jint)(data)
        return loops * 1000

    source = ArrayList()
    for i in range(1000):
        source.add(i)

    def consumer(n):
        c = Counter()
        loops = max(1, n // 1000)
        for _ in range(loops):
            source.forEach(c)
        return c.count

    values = list(range(500))

    def comparator(n):
        import random
        cmp = Cmp()
        loops = max(1, n // 4000)
        calls = 0
        for _ in range(loops):
            random.shuffle(values)
            lst = ArrayList()
            for v in values:
                lst.add(v)
            Collections.sort(lst, cmp)
            calls += 4000
        return calls

    def proxy_create(n):
        for _ in range(n):
            Task()
        return n

    tests = [
        ("find_class", find_class), ("static_call", static_call),
        ("static_call_args", static_call_args), ("instance_call", instance_call),
        ("str_to_java", str_to_java), ("str_from_java", str_from_java),
        ("stringbuilder_x5", builder), ("new_object", new_object),
        ("field_read", field_read), ("field_write", field_write),
        ("arraylist_add_get", arraylist), ("hashmap_put_get", hashmap),
        ("jarray_create_per_elem", jarray_create), ("java_to_python_consumer", consumer),
        ("java_to_python_comparator", comparator), ("dynamic_proxy_create", proxy_create),
    ]
    return tests


def main():
    tests = build_tests()
    only = set(sys.argv[1:])
    results = {}
    for name, fn in tests:
        if only and name not in only:
            continue
        results[name] = measure(fn)
        print(f"{name:28s} {results[name] / 1000:10.2f} us", flush=True)
    out = os.environ.get("BENCH_OUT")
    if out:
        with open(out, "w") as f:
            json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
