import unittest

from java import cast, dynamic_proxy, jclass
from java.chaquopy import get_reflection_policy, set_reflection_policy

from com.chaquo.python import TestBasics
from com.chaquo.python import TestReflect as TR
from java.lang import Object, String
from java.lang.reflect import InvocationHandler, Proxy
from java.lang import Runnable

from .test_utils import FilterWarningsCase


ACCESS = "com.chaquo.python.TestReflect$Access"
RUNNABLE = "java.lang.Runnable"
UNSAFE = "sun.misc.Unsafe"


class ReflectionGateCase(FilterWarningsCase):

    def setUp(self):
        super().setUp()
        self.calls = []
        self.deny = set()
        self.policy = self.make_policy()
        set_reflection_policy(self.policy)

    def tearDown(self):
        set_reflection_policy(None)
        super().tearDown()

    def make_policy(self):
        def policy(op, target, member):
            self.calls.append((op, target, member))
            if isinstance(target, tuple):
                return all(item not in self.deny for item in target)
            return target not in self.deny
        return policy

    def last_call(self):
        self.assertTrue(self.calls)
        return self.calls[-1]


class ReflectionGatePolicy(ReflectionGateCase):

    def test_get_and_set(self):
        self.assertIs(get_reflection_policy(), self.policy)
        set_reflection_policy(None)
        self.assertIsNone(get_reflection_policy())
        set_reflection_policy(self.policy)
        self.assertIs(get_reflection_policy(), self.policy)

    def test_set_rejects_non_callable(self):
        with self.assertRaises(TypeError):
            set_reflection_policy(42)
        self.assertIs(get_reflection_policy(), self.policy)

    def test_policy_exception_propagates(self):
        def bad_policy(op, target, member):
            raise RuntimeError("policy failure")
        set_reflection_policy(bad_policy)
        with self.assertRaisesRegex(RuntimeError, "policy failure"):
            jclass("java.lang.Class").forName("java.lang.String")

    def test_policy_not_consulted_when_unset(self):
        set_reflection_policy(None)
        self.calls.clear()
        cls = jclass("java.lang.Class").forName(ACCESS)
        self.assertEqual(str(cls.getName()), ACCESS)
        self.assertEqual(self.calls, [])


class ReflectionGateClassOps(ReflectionGateCase):

    def test_for_name_denied(self):
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Class.forName"):
            jclass("java.lang.Class").forName(ACCESS)

    def test_for_name_allowed(self):
        cls = jclass("java.lang.Class").forName(ACCESS)
        self.assertEqual(str(cls.getName()), ACCESS)
        self.assertEqual(self.last_call(), ("Class.forName", ACCESS, None))

    def test_for_name_overload_with_loader(self):
        loader = TR.Access.getClass().getClassLoader()
        cls = jclass("java.lang.Class").forName(ACCESS, False, loader)
        self.assertEqual(str(cls.getName()), ACCESS)
        self.assertEqual(self.last_call(), ("Class.forName", ACCESS, None))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Class.forName"):
            jclass("java.lang.Class").forName(ACCESS, False, loader)

    def test_for_name_overload_with_module(self):
        module = String.getClass().getModule()
        cls = jclass("java.lang.Class").forName(module, "java.lang.String")
        self.assertEqual(str(cls.getName()), "java.lang.String")
        self.assertEqual(self.last_call(), ("Class.forName", "java.lang.String", None))

    def test_load_class_denied(self):
        loader = TR.Access.getClass().getClassLoader()
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "ClassLoader.loadClass"):
            loader.loadClass(ACCESS)

    def test_load_class_allowed(self):
        loader = TR.Access.getClass().getClassLoader()
        cls = loader.loadClass("com.chaquo.python.TestBasics")
        self.assertEqual(str(cls.getName()), "com.chaquo.python.TestBasics")
        self.assertEqual(self.last_call(),
                         ("ClassLoader.loadClass", "com.chaquo.python.TestBasics", None))

    def test_class_new_instance(self):
        cls = TR.Access.getClass()
        obj = cls.newInstance()
        self.assertIsInstance(obj, TR.Access)
        self.assertEqual(self.last_call(), ("Class.newInstance", ACCESS, None))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Class.newInstance"):
            cls.newInstance()

    def test_class_member_queries(self):
        cls = TR.Access.getClass()
        field = cls.getDeclaredField("priv")
        self.assertEqual(self.last_call(), ("Class.getDeclaredField", ACCESS, "priv"))
        method = cls.getDeclaredMethod("getPriv")
        self.assertEqual(self.last_call(), ("Class.getDeclaredMethod", ACCESS, "getPriv"))
        ctor = cls.getDeclaredConstructor()
        self.assertEqual(self.last_call(), ("Class.getDeclaredConstructor", ACCESS, None))
        public_method = cls.getMethod("getPubl")
        self.assertEqual(self.last_call(), ("Class.getMethod", ACCESS, "getPubl"))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Class.getDeclaredField"):
            cls.getDeclaredField("priv")
        with self.assertRaisesRegex(PermissionError, "Class.getDeclaredMethod"):
            cls.getDeclaredMethod("getPriv")
        with self.assertRaisesRegex(PermissionError, "Class.getDeclaredConstructor"):
            cls.getDeclaredConstructor()
        with self.assertRaisesRegex(PermissionError, "Class.getMethod"):
            cls.getMethod("getPubl")

    def test_class_listing_not_gated(self):
        cls = TR.Access.getClass()
        self.assertTrue(list(cls.getDeclaredFields()))
        self.assertTrue(list(cls.getDeclaredMethods()))
        self.assertTrue(list(cls.getMethods()))
        self.assertTrue(list(cls.getFields()))
        self.assertEqual(self.calls, [])

    def test_class_name_not_gated(self):
        cls = TR.Access.getClass()
        self.assertEqual(str(cls.getName()), ACCESS)
        self.assertEqual(self.calls, [])


class ReflectionGateMemberOps(ReflectionGateCase):

    def field_for_read(self):
        cls = TR.Access.getClass()
        field = cls.getDeclaredField("priv")
        field.setAccessible(True)
        self.calls.clear()
        return field

    def method_for_invoke(self):
        cls = TR.Access.getClass()
        method = cls.getDeclaredMethod("getPriv")
        method.setAccessible(True)
        self.calls.clear()
        return method

    def test_set_accessible(self):
        cls = TR.Access.getClass()
        field = cls.getDeclaredField("priv")
        self.calls.clear()
        field.setAccessible(True)
        self.assertEqual(self.last_call(), ("AccessibleObject.setAccessible", ACCESS, "priv"))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "AccessibleObject.setAccessible"):
            field.setAccessible(True)

    def test_field_read(self):
        field = self.field_for_read()
        self.assertEqual(str(field.get(TR.Access())), "private")
        self.assertEqual(self.last_call(), ("Field.get", ACCESS, "priv"))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Field.get"):
            field.get(TR.Access())

    def test_field_write(self):
        field = self.field_for_read()
        field.set(TR.Access(), "written")
        self.assertEqual(self.last_call(), ("Field.set", ACCESS, "priv"))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Field.set"):
            field.set(TR.Access(), "written")

    def test_typed_field_accessors(self):
        cls = TestBasics.getClass()
        field = cls.getDeclaredField("fieldZ")
        field.setAccessible(True)
        obj = TestBasics()
        self.calls.clear()
        self.assertIsInstance(field.getBoolean(obj), bool)
        self.assertEqual(self.last_call(),
                         ("Field.get", "com.chaquo.python.TestBasics", "fieldZ"))
        field.setBoolean(obj, True)
        self.assertEqual(self.last_call(),
                         ("Field.set", "com.chaquo.python.TestBasics", "fieldZ"))
        self.deny.add("com.chaquo.python.TestBasics")
        with self.assertRaisesRegex(PermissionError, "Field.get"):
            field.getBoolean(obj)
        with self.assertRaisesRegex(PermissionError, "Field.set"):
            field.setBoolean(obj, True)

    def test_method_invoke_denied(self):
        method = self.method_for_invoke()
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Method.invoke"):
            method.invoke(TR.Access())

    def test_method_invoke_allowed(self):
        method = self.method_for_invoke()
        self.assertEqual(str(method.invoke(TR.Access())), "private")
        self.assertEqual(self.last_call(), ("Method.invoke", ACCESS, "getPriv"))
        method.invoke(TR.Access())
        self.assertEqual(self.last_call(), ("Method.invoke", ACCESS, "getPriv"))

    def test_method_invoke_unbound(self):
        method = self.method_for_invoke()
        Method = jclass("java.lang.reflect.Method")
        self.assertEqual(str(Method.invoke(method, TR.Access())), "private")
        self.assertEqual(self.last_call(), ("Method.invoke", ACCESS, "getPriv"))

    def test_constructor_new_instance(self):
        cls = TR.Access.getClass()
        ctor = cls.getDeclaredConstructor()
        self.calls.clear()
        obj = ctor.newInstance()
        self.assertIsInstance(obj, TR.Access)
        self.assertEqual(self.last_call()[0], "Constructor.newInstance")
        self.assertEqual(self.last_call()[1], ACCESS)
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "Constructor.newInstance"):
            ctor.newInstance()

    def test_target_cached_on_wrapper(self):
        cls = TR.Access.getClass()
        field = cls.getDeclaredField("priv")
        field.setAccessible(True)
        self.calls.clear()
        field.get(TR.Access())
        field.get(TR.Access())
        self.assertEqual(self.calls[-2:], [("Field.get", ACCESS, "priv"),
                                           ("Field.get", ACCESS, "priv")])


class ReflectionGateProxyOps(ReflectionGateCase):

    def handler(self):
        class Handler(dynamic_proxy(InvocationHandler)):
            def invoke(self, proxy, method, args):
                return None
        return Handler()

    def test_new_proxy_instance_allowed(self):
        loader = TR.Access.getClass().getClassLoader()
        proxy = Proxy.newProxyInstance(loader, [Runnable], self.handler())
        proxy.run()
        self.assertIn(("Proxy.newProxyInstance", (RUNNABLE,), None), self.calls)

    def test_new_proxy_instance_denied(self):
        loader = TR.Access.getClass().getClassLoader()
        self.deny.add(RUNNABLE)
        with self.assertRaisesRegex(PermissionError, "Proxy.newProxyInstance"):
            Proxy.newProxyInstance(loader, [Runnable], self.handler())

    def test_get_proxy_class_allowed(self):
        loader = TR.Access.getClass().getClassLoader()
        klass = Proxy.getProxyClass(loader, Runnable)
        self.assertTrue(klass)
        self.assertIn(("Proxy.getProxyClass", (RUNNABLE,), None), self.calls)

    def test_get_proxy_class_denied(self):
        loader = TR.Access.getClass().getClassLoader()
        self.deny.add(RUNNABLE)
        with self.assertRaisesRegex(PermissionError, "Proxy.getProxyClass"):
            Proxy.getProxyClass(loader, Runnable)

    def test_dynamic_proxy_internal_proxy_class(self):
        self.handler()
        self.assertIn("Proxy.getProxyClass",
                      [op for op, target, member in self.calls
                       if isinstance(target, tuple) and
                       "com.chaquo.python.DynamicProxy" in target])


class ReflectionGateLookupOps(ReflectionGateCase):

    def lookup(self):
        return jclass("java.lang.invoke.MethodHandles").publicLookup()

    def test_lookup_method_itself_not_gated(self):
        self.lookup()
        self.assertEqual(self.calls, [])

    def test_find_class(self):
        lookup = self.lookup()
        cls = lookup.findClass("java.lang.String")
        self.assertEqual(str(cls.getName()), "java.lang.String")
        self.assertEqual(self.last_call(),
                         ("MethodHandles.Lookup", "java.lang.String", None))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "MethodHandles.Lookup"):
            lookup.findClass(ACCESS)

    def test_find_virtual(self):
        lookup = self.lookup()
        MethodType = jclass("java.lang.invoke.MethodType")
        method_type = MethodType.methodType(String.getClass())
        handle = lookup.findVirtual(TestBasics.getClass(), "toString", method_type)
        self.assertTrue(handle)
        self.assertEqual(self.last_call(),
                         ("MethodHandles.Lookup", "com.chaquo.python.TestBasics",
                          "toString"))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "MethodHandles.Lookup"):
            lookup.findVirtual(TR.Access.getClass(), "toString", method_type)

    def test_private_lookup_in(self):
        MethodHandles = jclass("java.lang.invoke.MethodHandles")
        lookup = MethodHandles.publicLookup()
        self.calls.clear()
        try:
            MethodHandles.privateLookupIn(TestBasics.getClass(), lookup)
        except Exception:
            pass
        self.assertEqual(self.last_call(),
                         ("MethodHandles.privateLookupIn", "com.chaquo.python.TestBasics",
                          None))
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "MethodHandles.privateLookupIn"):
            MethodHandles.privateLookupIn(TR.Access.getClass(), lookup)


class ReflectionGateUnsafeOps(ReflectionGateCase):

    def the_unsafe(self):
        try:
            Unsafe = jclass(UNSAFE)
            field = Unsafe.getClass().getDeclaredField("theUnsafe")
            field.setAccessible(True)
            return field.get(None)
        except Exception as e:
            self.skipTest(f"sun.misc.Unsafe unavailable: {e}")

    def test_unsafe_method_denied(self):
        unsafe = self.the_unsafe()
        self.calls.clear()
        self.deny.add(UNSAFE)
        with self.assertRaisesRegex(PermissionError, "Unsafe"):
            unsafe.addressSize()

    def test_unsafe_method_allowed(self):
        unsafe = self.the_unsafe()
        self.calls.clear()
        self.assertIsInstance(unsafe.addressSize(), int)
        self.assertEqual(self.last_call(), ("Unsafe", UNSAFE, "addressSize"))


class ReflectionGateCast(ReflectionGateCase):

    def test_cast_denied(self):
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "cast"):
            cast(f"L{ACCESS.replace('.', '/')};", TR.Access())

    def test_cast_allowed(self):
        b = String("hello")
        b_object = cast(Object, b)
        self.assertEqual(b, b_object)
        self.assertEqual(self.last_call(), ("cast", "java.lang.Object", None))
        b_string = cast("Ljava/lang/String;", b_object)
        self.assertIs(b, b_string)
        self.assertEqual(self.last_call(), ("cast", "java.lang.String", None))

    def test_cast_null_and_none(self):
        self.deny.add(ACCESS)
        with self.assertRaisesRegex(PermissionError, "cast"):
            cast(f"L{ACCESS.replace('.', '/')};", None)
        with self.assertRaisesRegex(PermissionError, "cast"):
            cast(TR.Access, None)

    def test_cast_error_preserved(self):
        with self.assertRaisesRegex(ValueError, "Invalid JNI signature"):
            cast("java.lang.Object", Object())
        for cls in [0, True, None, int, str]:
            with self.subTest(cls=cls):
                with self.assertRaisesRegex(TypeError, "is not a Java type"):
                    cast(cls, Object())
        with self.assertRaisesRegex(jclass("java.lang.NoClassDefFoundError"),
                                    "java.lang.Nonexistent"):
            cast("Ljava/lang/Nonexistent;", Object())
        self.assertEqual(self.calls, [("cast", "java.lang.Object", None),
                                      ("cast", "java.lang.Nonexistent", None)])


class ReflectionGateOrdinaryCalls(ReflectionGateCase):

    def test_ordinary_calls_not_gated(self):
        s = String("hello")
        self.assertEqual(s.length(), 5)
        self.assertEqual(len(s.toCharArray()), 5)
        t = TestBasics()
        t.fieldString = "x"
        self.assertEqual(str(t.fieldString), "x")
        self.assertEqual(self.calls, [])

    def test_constructor_not_gated(self):
        obj = TR.Access()
        self.assertIsInstance(obj, TR.Access)
        self.assertEqual(self.calls, [])

    def test_denied_class_object_still_usable_directly(self):
        self.deny.add(ACCESS)
        obj = TR.Access()
        self.assertEqual(str(obj.getPubl()), "public")
        obj2 = TR.Access()
        self.assertEqual(self.calls, [])
