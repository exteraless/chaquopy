from cpython.version cimport PY_MAJOR_VERSION

from itertools import chain
import re

from cpython.object cimport PyObject
from cpython.ref cimport Py_INCREF
from libc.float cimport FLT_MAX

numpy = None  # Initialized by importer.py.


# In order of size.
INT_TYPES = OrderedDict([("J", "Long"), ("I", "Integer"), ("S", "Short"), ("B", "Byte")])
FLOAT_TYPES = OrderedDict([("D", "Double"), ("F", "Float")])
NUMERIC_TYPES = OrderedDict(list(FLOAT_TYPES.items()) + list(INT_TYPES.items()))
PRIMITIVE_TYPES = dict([("C", "Character"), ("Z", "Boolean")] + list(NUMERIC_TYPES.items()))

UNBOX_METHODS = {f"Ljava/lang/{boxed};": f"{unboxed}Value" for boxed, unboxed in
                 [("Boolean", "boolean"), ("Byte", "byte"), ("Short", "short"), ("Integer", "int"),
                  ("Long", "long"), ("Float", "float"), ("Double", "double"), ("Character", "char")]}

ARRAY_CONVERSIONS = ["Ljava/lang/Object;", "Ljava/lang/Cloneable;", "Ljava/io/Serializable;"]

# This must be a DEF to allow Cython to generate optimized calls of the decode and encode
# functions. We don't currently support any big-endian platforms, and the unit tests will
# detect if that ever changes.
DEF JCHAR_ENCODING = "UTF-16-LE"


# Useful if d is an OrderedDict.
cdef dict_index(d, key):
    for i, k in enumerate(d):
        if k == key:
            return i
    raise KeyError(key)


# Copy back any modifications the Java method may have made to mutable parameters.
cdef copy_output_args(CQPEnv env, args, p2j_args):
    for arg, p2j_arg in zip(args, p2j_args):
        if isinstance(p2j_arg, JNIRef) and p2j_arg and \
           not isinstance(arg, (unicode, int, float, JavaObject)):
            argtype = klass_info(env.j_env, (<JNIRef>p2j_arg).obj).sig
            if argtype[0] == "[" and not isinstance(arg, JavaArray):
                ret = jarray(argtype[1:])(instance=p2j_arg)
                try:
                    arg[:] = ret
                except TypeError:
                    pass    # The arg was a tuple or other read-only sequence.


# Cython auto-generates range checking code for the integral types.
cdef populate_args(JavaMethod jm, list p2j_args, jvalue *j_args):
    cdef const char *codes = jm.arg_codes
    cdef Py_ssize_t index
    cdef char c
    for index in range(len(p2j_args)):
        py_arg = p2j_args[index]
        c = codes[index]
        if c == c'Z':
            j_args[index].z = py_arg
        elif c == c'B':
            j_args[index].b = py_arg
        elif c == c'C':
            check_range_char(py_arg)
            j_args[index].c = ord(py_arg)
        elif c == c'S':
            j_args[index].s = py_arg
        elif c == c'I':
            j_args[index].i = py_arg
        elif c == c'J':
            j_args[index].j = py_arg
        elif c == c'F':
            check_range_float32(py_arg)
            j_args[index].f = py_arg
        elif c == c'D':
            j_args[index].d = py_arg
        elif c == c'L' or c == c'[':
            j_args[index].l = (<JNIRef?>py_arg).obj


cdef j2p(JNIEnv *j_env, JNIRef j_object):
    if not j_object:
        return None
    cdef KlassInfo info = klass_info(j_env, j_object.obj)
    cdef int kind = info.kind
    if kind == KIND_OBJECT:
        cls = info.python_class()
        if info.plain:
            return plain_instance(cls, j_object, info.sig[0] == "[")
        if info.dyn_proxy:
            self = instance_cache.get((cls, j_object))
            if self is not None:
                return self
        return cls(instance=j_object)
    if kind == KIND_STRING:
        return j2p_string(j_env, j_object)
    if kind == KIND_PYOBJECT:
        return j2p_pyobject(j_env, j_object.obj)
    return j2p_unbox(j_env, info, j_object.obj)


cdef enum:
    KIND_OBJECT, KIND_STRING, KIND_PYOBJECT,
    KIND_Z, KIND_B, KIND_C, KIND_S, KIND_I, KIND_J, KIND_F, KIND_D

UNBOX_KINDS = {"Z": KIND_Z, "B": KIND_B, "C": KIND_C, "S": KIND_S,
               "I": KIND_I, "J": KIND_J, "F": KIND_F, "D": KIND_D}


@cython.final
cdef class KlassInfo(object):
    cdef GlobalRef klass
    cdef int kind
    cdef object sig
    cdef jmethodID unbox_mid
    cdef object cls
    cdef unsigned long cls_gen
    cdef bint plain
    cdef bint dyn_proxy

    @staticmethod
    cdef KlassInfo create(CQPEnv env, JNIRef j_klass):
        cdef KlassInfo self = KlassInfo.__new__(KlassInfo)
        self.klass = j_klass.global_ref()
        self.sig = sig = klass_sig(env, j_klass)
        self.kind = KIND_OBJECT
        if sig == 'Ljava/lang/String;':
            self.kind = KIND_STRING
        elif sig == 'Lcom/chaquo/python/PyObject;':
            self.kind = KIND_PYOBJECT
        else:
            unbox_method = UNBOX_METHODS.get(sig)
            if unbox_method:
                unboxed = PRIMITIVES_BY_BOX[sig]
                self.unbox_mid = env.GetMethodID(j_klass, unbox_method, "()" + unboxed)
                self.kind = UNBOX_KINDS[unboxed]
        return self

    cdef python_class(self):
        cls = self.cls
        if cls is None or self.cls_gen != jclass_gen:
            cls = jclass_from_j_klass(self.sig, self.klass)
            exact = CQPEnv().IsSameObject(cls._chaquopy_j_klass, self.klass)
            self.plain = exact and (type(cls) is JavaClass or type(cls) is ArrayClass)
            self.dyn_proxy = exact and type(cls) is DynamicProxyClass
            self.cls = cls
            self.cls_gen = jclass_gen
        return cls


PRIMITIVES_BY_BOX = {f"Ljava/lang/{boxed};": unboxed for unboxed, boxed in PRIMITIVE_TYPES.items()}

DEF KLASS_MRU_SIZE = 4
cdef list klass_mru = [None] * KLASS_MRU_SIZE
cdef int klass_mru_next = 0
cdef dict klass_infos = {}

cdef KlassInfo klass_info(JNIEnv *j_env, jobject obj):
    global klass_mru_next
    cdef jobject raw_klass = j_env[0].GetObjectClass(j_env, obj)
    cdef KlassInfo info
    cdef int i
    for i in range(KLASS_MRU_SIZE):
        info = <KlassInfo>klass_mru[i]
        if info is not None and j_env[0].IsSameObject(j_env, info.klass.obj, raw_klass):
            j_env[0].DeleteLocalRef(j_env, raw_klass)
            return info

    j_klass = LocalRef.adopt(j_env, raw_klass)
    info = klass_infos.get(j_klass)
    if info is None:
        info = KlassInfo.create(CQPEnv.wrap(j_env), j_klass)
        klass_infos[info.klass] = info
    klass_mru[klass_mru_next] = info
    klass_mru_next = (klass_mru_next + 1) % KLASS_MRU_SIZE
    return info


cdef j2p_unbox(JNIEnv *j_env, KlassInfo info, jobject obj):
    cdef int kind = info.kind
    cdef jmethodID mid = info.unbox_mid
    if kind == KIND_I:
        result = j_env[0].CallIntMethod(j_env, obj, mid)
    elif kind == KIND_J:
        result = j_env[0].CallLongMethod(j_env, obj, mid)
    elif kind == KIND_Z:
        result = bool(j_env[0].CallBooleanMethod(j_env, obj, mid))
    elif kind == KIND_D:
        result = j_env[0].CallDoubleMethod(j_env, obj, mid)
    elif kind == KIND_F:
        result = j_env[0].CallFloatMethod(j_env, obj, mid)
    elif kind == KIND_C:
        result = chr(j_env[0].CallCharMethod(j_env, obj, mid))
    elif kind == KIND_S:
        result = j_env[0].CallShortMethod(j_env, obj, mid)
    else:
        result = j_env[0].CallByteMethod(j_env, obj, mid)
    CQPEnv.wrap(j_env).check_exception()
    return result


# j_string MUST be a (possibly-null) String, or there may be a native crash.
cdef unicode j2p_string(JNIEnv *j_env, JNIRef j_string):
    if not j_string:
        raise ValueError("String cannot be null")

    cdef const jchar *jchar_str = j_env[0].GetStringChars(j_env, j_string.obj, NULL)
    if jchar_str == NULL:
        raise Exception("GetStringChars failed")
    cdef int str_len = j_env[0].GetStringLength(j_env, j_string.obj)
    s = (<char*>jchar_str)[:str_len * 2].decode(JCHAR_ENCODING)  # 2 bytes/char for UTF-16.
    j_env[0].ReleaseStringChars(j_env, j_string.obj, jchar_str)
    return s


# jpyobject MUST be a (possibly-null) PyObject, or there may be a native crash.
#
# This function is called from PyObject.getInstance, which is synchronized on PyObject.cache.
# To avoid deadlocks, it must not do anything which requires a lock, including calling jclass()
# or creating jclass instances.
cdef j2p_pyobject(JNIEnv *j_env, jobject jpyobject):
    if jpyobject == NULL:
        return None

    global fid_PyObject_addr
    if not fid_PyObject_addr:
        env = CQPEnv.wrap(j_env)
        j_PyObject = env.FindClass("com.chaquo.python.PyObject")
        fid_PyObject_addr = env.GetFieldID(j_PyObject, "addr", "J")

    cdef PyObject *po = <PyObject*> j_env[0].GetLongField(j_env, jpyobject, fid_PyObject_addr)
    if po == NULL:
        raise ValueError("PyObject is closed")
    return <object>po

cdef jfieldID fid_PyObject_addr = NULL


# If the definition is for a Java object or array, returns a JNIRef.
# If the definition is for a Java primitive, returns a Python int/float/bool/str.
cdef p2j(JNIEnv *j_env, definition, obj, bint autobox=True):
    # Can happen when calling a proxy method. If the Python implementation returns anything but
    # None, the error at the bottom of this function will be raised.
    if definition == 'V':
        if obj is None:
            return LocalRef()

    # For primitive types we simply check type check and then return the Python value: it's
    # the caller's responsibility to convert it to the C type. It's also the caller's
    # responsibility to perform range checks: see note at is_applicable_arg for why we can't do
    # it here.
    #
    # We don't do auto-unboxing here, because boxed types are automatically unboxed by j2p and
    # will therefore never be touched by Python user code unless created explicitly.
    # Auto-boxing, on the other hand, will be done if necessary below.
    elif definition == 'Z':
        if isinstance(obj, bool):
            return obj
        if isinstance(obj, primitive.jboolean):
            return obj.value
        if numpy and isinstance(obj, numpy.bool_):
            return obj.item()
    elif definition in INT_TYPES:
        # Java allows a char to be implicitly converted to an int or larger, but this would
        # be surprising in Python. Require the user to be explicit and use the function `ord`.
        #
        # bool is a subclass of int in Python, but allowing implicit conversion from Python
        # bool to Java integer types could cause ambiguity in overloads.
        if isinstance(obj, int) and not isinstance(obj, bool):
            return obj
        if isinstance(obj, IntPrimitive) and \
           dict_index(INT_TYPES, obj.sig) >= dict_index(INT_TYPES, definition):
            return obj.value
        if numpy and isinstance(obj, numpy.integer):
            return obj.item()
    elif definition in FLOAT_TYPES:
        if isinstance(obj, (float, int)) and not isinstance(obj, bool):
            return obj
        if isinstance(obj, NumericPrimitive) and \
           dict_index(NUMERIC_TYPES, obj.sig) >= dict_index(NUMERIC_TYPES, definition):
            return obj.value
        if numpy and isinstance(obj, (numpy.integer, numpy.floating)):
            return obj.item()
    elif definition == "C":
        # We don't check that len(obj) == 1; see note above about range checks.
        if isinstance(obj, unicode):
            return obj
        if isinstance(obj, primitive.jchar):
            return obj.value

    elif definition[0] == 'L':
        env = CQPEnv.wrap(j_env)
        j_klass = env.FindClass(definition)

        if obj is None:
            return LocalRef()
        elif isinstance(obj, NoneCast):
            if env.IsAssignableFrom(env.FindClass(obj.sig), j_klass):
                return LocalRef()

        elif isinstance(obj, (unicode, primitive.jchar)):
            if isinstance(obj, unicode):
                if env.IsAssignableFrom(env.FindClass("java.lang.String"), j_klass):
                    return p2j_string(j_env, obj)
            if autobox:
                boxed = p2j_box(env, j_klass, "Character", obj)
                if boxed: return boxed

        elif isinstance(obj, (bool, primitive.jboolean)):
            if autobox:
                boxed = p2j_box(env, j_klass, "Boolean", obj)
                if boxed: return boxed
        elif isinstance(obj, (int, primitive.IntPrimitive)):
            if autobox:
                # Automatic primitive conversion cannot be combined with autoboxing (JLS 5.3).
                box_cls_names = ([NUMERIC_TYPES[obj.sig]] if isinstance(obj, IntPrimitive)
                                 else chain(INT_TYPES.values(), FLOAT_TYPES.values()))
                for box_cls_name in box_cls_names:
                    boxed = p2j_box(env, j_klass, box_cls_name, obj)
                    if boxed: return boxed
        elif isinstance(obj, (float, FloatPrimitive)):
            if autobox:
                # Automatic primitive conversion cannot be combined with autoboxing (JLS 5.3).
                box_cls_names = ([FLOAT_TYPES[obj.sig]] if isinstance(obj, FloatPrimitive)
                                 else FLOAT_TYPES.values())
                for box_cls_name in box_cls_names:
                    boxed = p2j_box(env, j_klass, box_cls_name, obj)
                    if boxed: return boxed

        elif isinstance(obj, JavaObject):
            # See note at is_applicable_arg for why we don't use IsInstanceOf with _chaquopy_this.
            if env.IsAssignableFrom(<JNIRef?>type(obj)._chaquopy_j_klass, j_klass):
                return obj._chaquopy_this
        elif isinstance(obj, JavaClass):
            if env.IsAssignableFrom(env.FindClass("java.lang.Class"), j_klass):
                return <JNIRef?>obj._chaquopy_j_klass
        elif assignable_to_array(env, definition, obj):  # Can only be via ARRAY_CONVERSIONS
            return p2j_array("Ljava/lang/Object;", obj)

        # Anything, including the above types, can be converted to a PyObject. (We don't use
        # IsAssignableFrom here, because allowing conversion to Object could cause excessive
        # ambiguity in overload resolution.)
        if definition == "Lcom/chaquo/python/PyObject;":
            return p2j_pyobject_ref(env, obj)

    elif definition[0] == '[':
        env = CQPEnv.wrap(j_env)
        if assignable_to_array(env, definition, obj):
            return p2j_array(definition[1:], obj)

    else:
        raise ValueError(f"Invalid signature '{definition}'")

    raise TypeError(f"Cannot convert {type(obj).__name__} object to {sig_to_java(definition)}")


# Because of the caching in JavaMultipleMethod, the result of this function must only be
# affected by the object type, not its value.
cdef assignable_to_array(CQPEnv env, definition, obj):
    if not (definition.startswith("[") or (definition in ARRAY_CONVERSIONS)):
        return False
    if obj is None:
        return True
    if isinstance(obj, (JavaArray, NoneCast)):
        return env.IsAssignableFrom(env.FindClass(jni_sig(type(obj))),
                                    env.FindClass(definition))

    # All other iterable types are assignable to all array types, except strings, which would
    # introduce too many complications in overload resolution.
    try:
        iter(obj)
        return not isinstance(obj, unicode)
    except TypeError:
        return False


cdef JNIRef p2j_array(element_type, obj):
    if obj is None or isinstance(obj, NoneCast):
        return LocalRef()

    if isinstance(obj, JavaArray):
        java_array = obj
    else:
        java_array = jarray(element_type)(obj)
    return java_array._chaquopy_this


# Unlike with integers, Cython doesn't do any checks for overflow (to infinity) or
# underflow (to zero) when converting a 64-bit Python float to a 32-bit C float. We
# currently check for overflow and not underflow, but since this behavior of float types
# is well-known, maybe we shouldn't be checking for either
# (https://github.com/cython/cython/issues/1709).
#
# cpdef because it's called from primitive.py.
cpdef check_range_float32(value):
    if value not in [float("nan"), float("inf"), float("-inf")] and \
       (value < -FLT_MAX or value > FLT_MAX):
        # Same wording as Cython integer overflow errors.
        raise OverflowError("value too large to convert to float")


# cpdef because it's called from primitive.py.
cpdef check_range_char(value):
    # In our current version of Cython, `ord` will raise a ValueError if not passed a string of
    # length 1.
    if ord(value) > 0xFFFF:
        raise TypeError("Cannot convert non-BMP character to char")


cdef JNIRef p2j_string(JNIEnv *j_env, unicode s):
    # Python strings can contain invalid surrogates, but Java strings cannot.
    # "backslashreplace" would retain some information about the invalid character, but
    # we don't know what context this string will be used in, so changing its length
    # could cause much worse confusion.
    utf16 = s.encode(JCHAR_ENCODING, errors="replace")
    return LocalRef.adopt(j_env, j_env[0].NewString(
        j_env, <jchar*><char*>utf16, len(utf16)//2))  # 2 bytes/char for UTF-16.


cdef box_sig(JNIEnv *j_env, JNIRef j_klass):
    original_sig = klass_sig(CQPEnv.wrap(j_env), j_klass)
    box_cls_name = PRIMITIVE_TYPES.get(original_sig)
    return f"Ljava/lang/{box_cls_name};" if box_cls_name else original_sig


cdef JNIRef p2j_box(CQPEnv env, JNIRef j_klass, str box_cls_name, value):
    full_box_cls_name = "java.lang." + box_cls_name
    j_box_klass = env.FindClass(full_box_cls_name)
    if not env.IsAssignableFrom(j_box_klass, j_klass):
        return None

    if isinstance(value, Primitive):
        value = value.value

    if box_cls_name == "Float":
        check_range_float32(value)

    cdef str sig = BOX_PRIMITIVE_SIGS[box_cls_name]
    cdef jmethodID mid
    cached = box_value_of.get(box_cls_name)
    if cached is None:
        mid = env.GetStaticMethodID(j_box_klass, "valueOf",
                                    f"({sig})Ljava/lang/{box_cls_name};")
        box_value_of[box_cls_name] = <size_t>mid
    else:
        mid = <jmethodID><size_t>cached

    cdef jvalue arg
    if sig == "Z":
        arg.z = value
    elif sig == "B":
        arg.b = value
    elif sig == "C":
        check_range_char(value)
        arg.c = ord(value)
    elif sig == "S":
        arg.s = value
    elif sig == "I":
        arg.i = value
    elif sig == "J":
        arg.j = value
    elif sig == "F":
        arg.f = value
    else:
        arg.d = value
    return env.CallStaticObjectMethodA(j_box_klass, mid, &arg)


cdef dict box_value_of = {}
cdef dict BOX_PRIMITIVE_SIGS = {
    "Boolean": "Z", "Byte": "B", "Character": "C", "Short": "S",
    "Integer": "I", "Long": "J", "Float": "F", "Double": "D",
}


cdef jlong p2j_pyobject(JNIEnv *j_env, obj) except? 0:
    if obj is None:
        return 0
    else:
        Py_INCREF(obj)  # Matches with DECREF in closeNative.
        return <jlong><PyObject*>obj


cdef GlobalRef j_PyObject
cdef jmethodID mid_PyObject_getInstance = NULL

cdef JNIRef p2j_pyobject_ref(CQPEnv env, obj):
    # Can't call getInstance() using jclass because that'll immediately unwrap the
    # returned proxy object (see j2p)
    global j_PyObject, mid_PyObject_getInstance
    if not mid_PyObject_getInstance:
        j_PyObject = env.FindClass("com.chaquo.python.PyObject")
        mid_PyObject_getInstance = env.GetStaticMethodID(j_PyObject, "getInstance",
                                                         "(J)Lcom/chaquo/python/PyObject;")
    cdef jvalue j_args[1]
    j_args[0].j = p2j_pyobject(env.j_env, obj)
    return env.CallStaticObjectMethodA(j_PyObject, mid_PyObject_getInstance, j_args)
