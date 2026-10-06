#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HERE/../../chaquopy-build}"
VENV="$WORKSPACE/venv"
SRC="$HERE/../product/runtime"
JDK="${JDK:-$HOME/.gradle/jdks/jetbrains_s_r_o_-21-amd64-linux.2}"
ANDROID_JAR="${ANDROID_JAR:-$HOME/Android/Sdk/platforms/android-36/android.jar}"
ANNOTATIONS_JAR="${ANNOTATIONS_JAR:-$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.jetbrains/annotations" -name 'annotations-*.jar' ! -name '*sources*' | sort | tail -1)}"
PY="${PY:-python3.12}"
HOST="$WORKSPACE/host"
CY="$HOST/cython"

if [ ! -x "$VENV/bin/cython" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q Cython==3.0.11
fi

rm -rf "$HOST"
mkdir -p "$CY" "$HOST/classes" "$HOST/lib" "$HOST/py"

cythonize() {
    local dir="$1" pyx="$2" stem="${2%.pyx}"
    (cd "$dir" && "$VENV/bin/cython" ${CYFLAGS:-} -Wextra -Werror "$pyx" -I "$CY" -o "$CY/$stem.c")
    sed -i -E \
        -e 's|^__PYX_EXTERN_C (\w+)|/* cythonTask altered */ __PYX_EXTERN_C JNIEXPORT \1 JNICALL|' \
        -e 's|(__pyx_insert_code_object\(c_line)|// cythonTask disabled: \1|' \
        "$CY/$stem.c"
}

cythonize "$SRC/src/main/python/java" chaquopy.pyx
cythonize "$SRC/src/main/python" chaquopy_java.pyx

"$JDK/bin/javac" -nowarn -d "$HOST/classes" -cp "$ANDROID_JAR:$ANNOTATIONS_JAR" \
    $(find "$SRC/src/main/java/com/chaquo/python" -maxdepth 1 -name '*.java')

PYINC="$($PY -c 'import sysconfig; print(sysconfig.get_paths()["include"])')"
PYVER="$($PY -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
SUFFIX="$($PY -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')"
CFLAGS=(-O2 -fPIC -shared -DNDEBUG -I "$SRC/src/main/c" -I "$PYINC" -I "$JDK/include" -I "$JDK/include/linux")

cp -r "$SRC/src/main/python/java" "$HOST/py/java"
gcc "${CFLAGS[@]}" "$CY/chaquopy.c" -o "$HOST/py/java/chaquopy$SUFFIX" -lpython$PYVER -ldl
gcc "${CFLAGS[@]}" "$CY/chaquopy_java.c" -o "$HOST/lib/libchaquopy_java.so" -lpython$PYVER

echo "host runtime ready in $HOST"
