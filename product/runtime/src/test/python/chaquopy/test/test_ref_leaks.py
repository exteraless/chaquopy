import gc
import threading

from java import cast, dynamic_proxy, jarray, jclass, jint
from java.chaquopy import jni_ref_counts

from .test_utils import FilterWarningsCase
from com.chaquo.python import TestProxy as TP


N = 3000
SLACK = 50

ArrayList = jclass("java.util.ArrayList")
Collections = jclass("java.util.Collections")
HashMap = jclass("java.util.HashMap")
Integer = jclass("java.lang.Integer")
NumberFormatException = jclass("java.lang.NumberFormatException")
Runnable = jclass("java.lang.Runnable")
String = jclass("java.lang.String")
StringBuilder = jclass("java.lang.StringBuilder")
System = jclass("java.lang.System")
Comparator = jclass("java.util.Comparator")
Consumer = jclass("java.util.function.Consumer")


class Task(dynamic_proxy(Runnable)):
    def run(self):
        pass


class Counter(dynamic_proxy(Consumer)):
    def __init__(self):
        super().__init__()
        self.count = 0

    def accept(self, value):
        self.count += 1


class Cmp(dynamic_proxy(Comparator)):
    def compare(self, a, b):
        return (a > b) - (a < b)


class Adder(dynamic_proxy(TP.Adder)):
    def add(self, x):
        return x + 1


class TestRefLeaks(FilterWarningsCase):

    def assertNoLeak(self, scenario):
        scenario(10)
        gc.collect()
        before = jni_ref_counts()
        scenario(N)
        gc.collect()
        after = jni_ref_counts()
        for kind in ("global", "weak", "local"):
            grown = after[kind] - before[kind]
            self.assertLess(grown, SLACK, f"{kind} refs grew by {grown} over {N} iterations")

    def test_counts_move(self):
        before = jni_ref_counts()
        held = [ArrayList() for _ in range(20)]
        self.assertGreaterEqual(jni_ref_counts()["global"] - before["global"], 20)
        del held
        gc.collect()
        self.assertLess(jni_ref_counts()["global"] - before["global"], 5)

    def test_proxy_create(self):
        def scenario(n):
            for _ in range(n):
                Task()
        self.assertNoLeak(scenario)

    def test_proxy_passed_to_java(self):
        lst = ArrayList()
        def scenario(n):
            for _ in range(n):
                lst.add(Task())
                lst.clear()
        self.assertNoLeak(scenario)

    def test_proxy_rewrapped_from_java(self):
        TP.a1 = Adder()
        def scenario(n):
            for _ in range(n):
                a = TP.a1
                TP.a2 = a
                a = None
        try:
            self.assertNoLeak(scenario)
        finally:
            TP.a1 = TP.a2 = None

    def test_java_to_python_callbacks(self):
        source = ArrayList()
        for i in range(50):
            source.add(i)
        def scenario(n):
            c = Counter()
            for _ in range(max(1, n // 50)):
                source.forEach(c)
            lst = ArrayList(source)
            for _ in range(max(1, n // 200)):
                Collections.shuffle(lst)
                Collections.sort(lst, Cmp())
        self.assertNoLeak(scenario)

    def test_objects_and_calls(self):
        def scenario(n):
            m = HashMap()
            for i in range(n):
                o = ArrayList()
                o.add(i)
                o.get(0)
                m.put(str(i % 50), o)
                m.get("1")
        self.assertNoLeak(scenario)

    def test_strings(self):
        def scenario(n):
            for i in range(n):
                sb = StringBuilder()
                sb.append("x").append(i).append(String.valueOf(i))
                str(sb.toString())
                String("abc").length()
        self.assertNoLeak(scenario)

    def test_arrays(self):
        def scenario(n):
            for i in range(n):
                a = jarray(jint)([1, 2, 3])
                a[0] = i
                list(a)
                jarray(String)(["a", "b"])[1]
        self.assertNoLeak(scenario)

    def test_exceptions(self):
        def scenario(n):
            for _ in range(n):
                try:
                    Integer.parseInt("x")
                except NumberFormatException:
                    pass
        self.assertNoLeak(scenario)

    def test_cast_and_static(self):
        def scenario(n):
            for _ in range(n):
                cast(jclass("java.util.List"), ArrayList()).size()
                Integer.MAX_VALUE
                System.identityHashCode(None)
        self.assertNoLeak(scenario)

    def test_reflection(self):
        Access = jclass("com.chaquo.python.TestReflect$Access")
        obj = Access()
        def scenario(n):
            for _ in range(n):
                f = Access.getClass().getDeclaredField("priv")
                f.setAccessible(True)
                str(f.get(obj))
                m = Access.getClass().getDeclaredMethod("getPriv")
                m.setAccessible(True)
                m.invoke(obj)
        self.assertNoLeak(scenario)

    def test_iteration(self):
        lst = ArrayList()
        for i in range(20):
            lst.add(i)
        def scenario(n):
            for _ in range(max(1, n // 20)):
                it = lst.iterator()
                while it.hasNext():
                    it.next()
        self.assertNoLeak(scenario)

    def test_threads(self):
        def work():
            ArrayList().add(Task())
        def scenario(n):
            for _ in range(max(1, n // 30)):
                t = threading.Thread(target=work)
                t.start()
                t.join()
        self.assertNoLeak(scenario)
