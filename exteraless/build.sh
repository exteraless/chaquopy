#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HERE/../../chaquopy-build}"
VENV="$WORKSPACE/venv"
SRC="$HERE/../product/runtime"
ABI="${ABI:-arm64-v8a}"
NDK="${NDK:-$HOME/Android/Sdk/ndk/27.2.12479018}"
CMAKE_DIR="$HOME/Android/Sdk/cmake/3.22.1/bin"
OUT="$WORKSPACE/out/$ABI"
CY="$WORKSPACE/build/cython"
WORK="$WORKSPACE/build/cmake-$ABI"

mkdir -p "$CY" "$OUT"

if [ ! -x "$VENV/bin/cython" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q Cython==3.0.11
fi

if [ ! -f "$WORKSPACE/prefix/$ABI/lib/libpython3.11.so" ]; then
    ZIP=$(ls "$HOME"/.gradle/caches/modules-2/files-2.1/com.chaquo.python/target/3.11.14-0/*/target-3.11.14-0-"$ABI".zip | head -1)
    mkdir -p "$WORKSPACE/prefix/$ABI/lib"
    unzip -q -o "$ZIP" 'include/*' -d "$WORKSPACE/prefix/$ABI"
    unzip -q -o -j "$ZIP" "jniLibs/$ABI/libpython3.11.so" -d "$WORKSPACE/prefix/$ABI/lib"
fi

cythonize() {
    local dir="$1" pyx="$2" stem="${2%.pyx}"
    (cd "$dir" && "$VENV/bin/cython" -Wextra -Werror "$pyx" -I "$CY" -o "$CY/$stem.c")
    sed -i -E \
        -e 's|^__PYX_EXTERN_C (\w+)|/* cythonTask altered */ __PYX_EXTERN_C JNIEXPORT \1 JNICALL|' \
        -e 's|(__pyx_insert_code_object\(c_line)|// cythonTask disabled: \1|' \
        "$CY/$stem.c"
}

cythonize "$SRC/src/main/python/java" chaquopy.pyx
cythonize "$SRC/src/main/python" chaquopy_java.pyx

rm -rf "$WORK"
mkdir -p "$WORK"
"$CMAKE_DIR/cmake" -S "$SRC" -B "$WORK" -GNinja \
    -DCMAKE_MAKE_PROGRAM="$CMAKE_DIR/ninja" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCHAQUOPY_SRC_DIR="$CY" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_NATIVE_API_LEVEL=24 \
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
    -DCHAQUOPY_PYTHON_VERSION=3.11 \
    -DCHAQUOPY_INCLUDE_PYTHON="$WORKSPACE/prefix/$ABI/include" \
    -DCHAQUOPY_LIB_DIRS="$WORKSPACE/prefix/$ABI/lib" \
    -DCHAQUOPY_PY_SUFFIX=.so >/dev/null
"$CMAKE_DIR/cmake" --build "$WORK" >/dev/null

cp "$WORK/chaquopy.so" "$OUT/chaquopy.so"
cp "$WORK/libchaquopy_java.so" "$OUT/libchaquopy_java.so"
ls -la "$OUT"
