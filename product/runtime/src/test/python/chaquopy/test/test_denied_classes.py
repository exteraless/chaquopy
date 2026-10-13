import os
import subprocess
import sys
import unittest

from java import cast, jarray, jclass
from java.chaquopy import get_reflection_policy, set_reflection_policy

from com.chaquo.python import TestReflect as TR

from .test_utils import FilterWarningsCase


KEYSTORE = "java.security.KeyStore"
DENIED = TR.DeniedClasses


class DeniedClasses(FilterWarningsCase):

    def setUp(self):
        super().setUp()
        self.saved_policy = get_reflection_policy()
        set_reflection_policy(None)

    def tearDown(self):
        set_reflection_policy(self.saved_policy)
        super().tearDown()

    def assertDenied(self, fn):
        with self.assertRaisesRegex(PermissionError, "not available from Python"):
            fn()

    def test_jclass(self):
        self.assertDenied(lambda: jclass(KEYSTORE))
        self.assertDenied(lambda: jclass("java.security.KeyStore$PrivateKeyEntry"))
        self.assertDenied(lambda: jclass("Ljava/security/KeyStore;"))
        self.assertDenied(lambda: jclass("java.security.KeyStoreSpi"))
        self.assertDenied(lambda: jclass("android.security.keystore.KeyGenParameterSpec"))
        self.assertDenied(lambda: jclass("org.telegram.ui.Wallet.GramWallet"))
        self.assertDenied(lambda: jclass("org.telegram.tgnet.tl.TL_wallet$exportSecretPhrase"))

    def test_arrays(self):
        self.assertDenied(lambda: jclass("[Ljava/security/KeyStore;"))
        self.assertDenied(lambda: jarray("Ljava/security/KeyStore;"))
        self.assertDenied(lambda: jclass("[[Ljava.security.KeyStore;"))

    def test_import(self):
        def imp():
            from java.security import KeyStore  # noqa: F401
        self.assertDenied(imp)

    def test_cast(self):
        self.assertDenied(lambda: cast("Ljava/security/KeyStore;", None))

    def test_allowed_neighbours(self):
        self.assertEqual(str(jclass("java.security.MessageDigest").getInstance("SHA-256")
                             .getAlgorithm()), "SHA-256")
        jclass("java.security.Key")

    def test_returned_object(self):
        self.assertDenied(DENIED.keyStore)

    def test_returned_class_object(self):
        self.assertDenied(DENIED.keyStoreClass)

    def test_array_element(self):
        arr = DENIED.keyStoreArray()
        self.assertEqual(arr[0], "plain")
        self.assertDenied(lambda: arr[1])

    def test_collection_element(self):
        lst = DENIED.keyStoreList()
        self.assertEqual(lst.size(), 1)
        self.assertDenied(lambda: lst.get(0))

    def test_primitive_results_still_work(self):
        self.assertEqual(str(DENIED.keyStoreType()),
                         str(jclass("java.lang.System").getProperty("keystore.type", "pkcs12")))

    def test_for_name(self):
        Class = jclass("java.lang.Class")
        self.assertDenied(lambda: Class.forName(KEYSTORE))
        self.assertDenied(lambda: Class.forName("android.security.keystore.KeyProperties"))

    def test_load_class(self):
        loader = jclass("java.lang.ClassLoader").getSystemClassLoader()
        self.assertDenied(lambda: loader.loadClass(KEYSTORE))

    def test_class_from_reflection(self):
        Class = jclass("java.lang.Class")
        kmf = Class.forName("javax.net.ssl.KeyManagerFactory")
        for m in kmf.getMethods():
            if str(m.getName()) != "init":
                continue
            types = m.getParameterTypes()
            if len(types) == 2:
                self.assertDenied(lambda: types[0])
                self.assertEqual(str(types[1].getName()), "[C")
                return
        self.fail("KeyManagerFactory.init(KeyStore, char[]) not found")

    def test_policy_cannot_allow(self):
        set_reflection_policy(lambda op, target, member: True)
        self.assertDenied(lambda: jclass("java.lang.Class").forName(KEYSTORE))
        self.assertDenied(lambda: jclass(KEYSTORE))


class SealedPolicy(unittest.TestCase):

    def test_seal(self):
        code = (
            "from java.chaquopy import set_reflection_policy, seal_reflection_policy, "
            "get_reflection_policy\n"
            "p = lambda op, target, member: True\n"
            "set_reflection_policy(p)\n"
            "seal_reflection_policy()\n"
            "for value in (None, lambda *a: True):\n"
            "    try:\n"
            "        set_reflection_policy(value)\n"
            "    except PermissionError:\n"
            "        pass\n"
            "    else:\n"
            "        raise SystemExit('policy changed after seal')\n"
            "assert get_reflection_policy() is p\n"
            "print('sealed-ok')\n"
        )
        result = subprocess.run([sys.executable, "-c", code], env=os.environ,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("sealed-ok", result.stdout)
