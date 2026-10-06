global_class("com.chaquo.python.PyProxy")


PROXY_BASE_NAME = "_chaquopy_proxy"


class ProxyClass(JavaClass):
    def __new__(metacls, cls_name, bases, cls_dict):
        if cls_name == PROXY_BASE_NAME:
            return type.__new__(metacls, cls_name, bases, cls_dict)
        else:
            if not (bases and bases[0].__name__ == PROXY_BASE_NAME):
                raise TypeError(f"{metacls.proxy_func} must be used first in class bases")
            if any([b.__name__ == PROXY_BASE_NAME for b in bases[1:]]):
                raise TypeError(f"{metacls.proxy_func} can only be used once in class bases")

            klass = metacls.get_klass(cls_name, bases[0])
            cls_dict["_chaquopy_j_klass"] = klass._chaquopy_this
            cls_dict["_chaquopy_name"] = klass.getName()
            cls = JavaClass.__new__(metacls, cls_name,
                                    get_bases(klass) + bases[1:],
                                    cls_dict)

            metacls.add_members(cls)
            return cls

    @classmethod
    def add_members(metacls, cls):
        for name in ["<init>", "_chaquopyGetDict", "_chaquopySetDict"]:
            type.__setattr__(cls, name, find_member(cls, name))


# -------------------------------------------------------------------------------------------------


global_class("java.lang.reflect.Proxy")
global_class("com.chaquo.python.PyInvocationHandler")


def dynamic_proxy(*implements):
    """If you use the return value of this function as the first base of a class declaration, then
    the `java.lang.reflect.Proxy
    <https://docs.oracle.com/javase/7/docs/api/java/lang/reflect/Proxy.html>`_ mechanism will
    be used to generate a Java class for it at runtime. All arguments must be Java interface
    types.
    """
    for i in implements:
        if not (isinstance(i, type) and issubclass(i, JavaObject) and
                i.getClass().isInterface()):
            raise TypeError(f"{i!r} is not a Java interface")
    return DynamicProxyClass(PROXY_BASE_NAME, (), dict(implements=implements))


class DynamicProxyClass(ProxyClass):
    proxy_func = "dynamic_proxy"

    def __call__(cls, *args, JNIRef instance=None, **kwargs):
        if instance:
            actual_cls = dynamic_proxy_type(instance)
            if actual_cls is not None and \
               (actual_cls is cls or CQPEnv().IsInstanceOf(instance, cls._chaquopy_j_klass)):
                return JavaClass.__call__(actual_cls, instance=instance)

        self = JavaClass.__call__(cls, *args, instance=instance, **kwargs)
        if instance:
            # jclass_cache will contain the most recently-created Python class for the given
            # sequence of interfaces, but the Python-Java class mapping may be many-to-one.
            actual_cls = self._chaquopyGetType()
            if actual_cls is not cls:
                self = actual_cls(instance=instance)
        return self

    @classmethod
    def get_klass(metacls, cls_name, proxy_base):
        global DynamicProxy
        return Proxy.getProxyClass(DynamicProxy.getClass().getClassLoader(),
                                   (DynamicProxy,) + proxy_base.implements)

    @classmethod
    def add_members(metacls, cls):
        ProxyClass.add_members(cls)
        for name in ["_chaquopyGetType"]:
            type.__setattr__(cls, name, find_member(cls, name))


cdef GlobalRef j_reflect_Proxy = None
cdef jmethodID mid_getInvocationHandler = NULL
cdef GlobalRef j_PyInvocationHandler = None
cdef jfieldID fid_PyInvocationHandler_type = NULL
cdef jfieldID fid_PyInvocationHandler_dict = NULL

cdef LocalRef dynamic_proxy_handler(CQPEnv env, JNIRef instance):
    global j_reflect_Proxy, mid_getInvocationHandler, j_PyInvocationHandler
    global fid_PyInvocationHandler_type, fid_PyInvocationHandler_dict
    if mid_getInvocationHandler == NULL:
        j_reflect_Proxy = env.FindClass("java.lang.reflect.Proxy")
        j_PyInvocationHandler = env.FindClass("com.chaquo.python.PyInvocationHandler")
        fid_PyInvocationHandler_type = env.GetFieldID(
            j_PyInvocationHandler, "type", "Lcom/chaquo/python/PyObject;")
        fid_PyInvocationHandler_dict = env.GetFieldID(
            j_PyInvocationHandler, "dict", "Lcom/chaquo/python/PyObject;")
        mid_getInvocationHandler = env.GetStaticMethodID(
            j_reflect_Proxy, "getInvocationHandler",
            "(Ljava/lang/Object;)Ljava/lang/reflect/InvocationHandler;")

    cdef jvalue arg
    arg.l = instance.obj
    handler = env.CallStaticObjectMethodA(j_reflect_Proxy, mid_getInvocationHandler, &arg)
    if not (handler and env.IsInstanceOf(handler, j_PyInvocationHandler)):
        return None
    return handler

cdef dynamic_proxy_type(JNIRef instance):
    env = CQPEnv()
    handler = dynamic_proxy_handler(env, instance)
    if handler is None:
        return None
    j_type = LocalRef.adopt(env.j_env, env.j_env[0].GetObjectField(
        env.j_env, handler.obj, fid_PyInvocationHandler_type))
    return j2p_pyobject(env.j_env, j_type.obj)

cdef bint dynamic_proxy_attach_dict(self, JNIRef this) except -1:
    env = CQPEnv()
    handler = dynamic_proxy_handler(env, this)
    if handler is None:
        return False
    j_dict = LocalRef.adopt(env.j_env, env.j_env[0].GetObjectField(
        env.j_env, handler.obj, fid_PyInvocationHandler_dict))
    java_dict = j2p_pyobject(env.j_env, j_dict.obj)
    if java_dict is None:
        py_dict = p2j_pyobject_ref(env, PyObject_GenericGetAttr(self, "__dict__"))
        env.j_env[0].SetObjectField(env.j_env, handler.obj, fid_PyInvocationHandler_dict,
                                    py_dict.obj)
    else:
        PyObject_GenericSetAttr(self, "__dict__", java_dict)
    return True


def DynamicProxy_init(self):
    global PyInvocationHandler
    JavaObject.__init__(self, PyInvocationHandler(type(self)))

global_class("com.chaquo.python.DynamicProxy", cls_dict={"__init__": DynamicProxy_init})


# -------------------------------------------------------------------------------------------------


global_class("com.chaquo.python.PyCtorMarker")

def static_proxy(extends=None, *implements, package=None, modifiers="public"):
    """If you use the return value of this function as the first base of a class declaration, and pass
    the containing module to the :ref:`static proxy generator <static-proxy-generator>` tool,
    then it will create a Java source file allowing the class to be instantiated and accessed
    by Java code.

    * `extends` must be a Java class type. Pass `None` if you only want to implement interfaces.
    * All other positional arguments must be Java interface types to implement.
    * `package` is the name of the Java package in which the Java class will be generated,
      defaulting to the same as the Python module name.
    * `modifiers` is described below.
    """
    if extends is None:
        extends = JavaObject
    if package is None:
        # _getframe(0) returns the closest Python frame, ignoring Cython frames.
        package = sys._getframe(0).f_globals["__name__"]
    return StaticProxyClass(PROXY_BASE_NAME, (), dict(extends=extends, implements=implements,
                                                      package=package))

class StaticProxyClass(ProxyClass):
    proxy_func = "static_proxy"

    @classmethod
    def get_klass(metacls, cls_name, proxy_base):
        global StaticProxy
        java_name = proxy_base.package + "." + cls_name
        klass = Class(instance=CQPEnv().FindClass(java_name))

        def verify(what, expected, actual):
            if expected != actual:
                raise TypeError(f"expected {what} {expected}, but Java class actually "
                                f"{what} {actual}")
        verify("extends", proxy_base.extends.getClass().getName(), klass.getSuperclass().getName())
        verify("implements",
               [str(i.getClass().getName()) for i in proxy_base.implements + (StaticProxy,)],
               [str(i.getName()) for i in klass.getInterfaces()])
        return klass


def StaticProxy_init(self):
    global PyCtorMarker
    if hasattr(self, "_chaquopy_this"):     # Java-initiated construction
        pass
    else:                                   # Python-initiated construction
        JavaObject.__init__(self, PyCtorMarker())

global_class("com.chaquo.python.StaticProxy", cls_dict={"__init__": StaticProxy_init})


# Member decorators currently have no effect at runtime.
def constructor(arg_types, *, modifiers="public", throws=None):
    """Same as :any:`method`, except it generates a Java constructor. This decorator can only be
    used on the `__init__` method. Note there is no return type.
    """
    return lambda f: f


def method(return_type, arg_types, *, modifiers="public", throws=None):
    """Generates a Java method.

    * `return_type` must be a single Java type, or :any:`jvoid`.
    * `arg_types` must be a (possibly empty) list or tuple of Java types.
    * `modifiers` is a string which is copied to the generated Java declaration. For example,
      to make a method synchronized, you can pass `modifiers="public synchronized"`.
    * `throws` is a list or tuple of `java.lang.Throwable` subclasses.

    All Java types must be specified as one of the following:

    * A Java class imported using the `import hook`_.
    * One of the :ref:`primitive types <primitives>`.
    * A :any:`jarray` type.

    Multiple decorators may be used on the same method, in which case multiple Java signatures
    will be generated for it (see notes below on overloading).
    """
    return lambda f: f


def Override(return_type, arg_types, *, modifiers="public", throws=None):
    """Same as :any:`method`, but adds the `@Override
    <https://docs.oracle.com/javase/8/docs/api/java/lang/Override.html>`_ annotation.
    """
    return lambda f: f
