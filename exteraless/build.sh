#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HERE/../../chaquopy-build}"
mkdir -p "$WORKSPACE"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
SRC="${SRC:-$HERE/../product/runtime}"
ABI="${ABI:-arm64-v8a}"
PYTHON="${PYTHON:-python3}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
PYTHON_TARGET="${PYTHON_TARGET:-3.11.14-0}"
NDK="${NDK:-$HOME/Android/Sdk/ndk/27.2.12479018}"
CMAKE="${CMAKE:-$(command -v cmake || ls -d "$HOME"/Android/Sdk/cmake/*/bin/cmake 2>/dev/null | sort -V | tail -1)}"
OUT="${OUT:-$WORKSPACE/out/$ABI}"
VENV="$WORKSPACE/venv"
CY="$WORKSPACE/build/cython-$ABI"
WORK="$WORKSPACE/build/cmake-$ABI"
PREFIX="$WORKSPACE/prefix/$ABI"

if [ -z "${PYTHON_TARGET_ZIP:-}" ]; then
    PYTHON_TARGET_ZIP=$(ls "$HOME"/.gradle/caches/modules-2/files-2.1/com.chaquo.python/target/"$PYTHON_TARGET"/*/target-"$PYTHON_TARGET"-"$ABI".zip | head -1)
fi

if [ ! -x "$VENV/bin/cython" ]; then
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/pip" install -q Cython==3.0.11
fi

if [ "$(cat "$PREFIX/source" 2>/dev/null)" != "$PYTHON_TARGET_ZIP" ]; then
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX/lib"
    unzip -q -o "$PYTHON_TARGET_ZIP" 'include/*' -d "$PREFIX"
    unzip -q -o -j "$PYTHON_TARGET_ZIP" "jniLibs/$ABI/libpython$PYTHON_VERSION.so" -d "$PREFIX/lib"
    echo "$PYTHON_TARGET_ZIP" > "$PREFIX/source"
fi

rm -rf "$CY" "$WORK"
mkdir -p "$CY" "$WORK" "$OUT"

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

NINJA="$(dirname "$CMAKE")/ninja"
[ -x "$NINJA" ] || NINJA="$(command -v ninja || true)"
GENERATOR=()
[ -n "$NINJA" ] && GENERATOR=(-GNinja -DCMAKE_MAKE_PROGRAM="$NINJA")

echo "add_compile_options(\"-ffile-prefix-map=$CY/=\")" > "$WORK/prefix-map.cmake"

"$CMAKE" -S "$SRC" -B "$WORK" "${GENERATOR[@]}" \
    -DCMAKE_PROJECT_INCLUDE="$WORK/prefix-map.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCHAQUOPY_SRC_DIR="$CY" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_NATIVE_API_LEVEL=24 \
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
    -DCHAQUOPY_PYTHON_VERSION="$PYTHON_VERSION" \
    -DCHAQUOPY_INCLUDE_PYTHON="$PREFIX/include" \
    -DCHAQUOPY_LIB_DIRS="$PREFIX/lib" \
    -DCHAQUOPY_PY_SUFFIX=.so >/dev/null
"$CMAKE" --build "$WORK" >/dev/null

cp "$WORK/chaquopy.so" "$OUT/chaquopy.so"
cp "$WORK/libchaquopy_java.so" "$OUT/libchaquopy_java.so"
ls -la "$OUT"
