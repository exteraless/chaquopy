#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HERE/../../chaquopy-build}"
HOST="$WORKSPACE/host"
SRC="$HERE/../product/runtime"
TESTPY="$SRC/src/test/python"
JDK="${JDK:-$HOME/.gradle/jdks/jetbrains_s_r_o_-21-amd64-linux.2}"
ANDROID_JAR="${ANDROID_JAR:-$HOME/Android/Sdk/platforms/android-36/android.jar}"
M2="$HOME/.gradle/caches/modules-2/files-2.1"
JUNIT="$(find "$M2/junit/junit/4.13.2" -name 'junit-4.13.2.jar' | head -1)"
HAMCREST="$(find "$M2/org.hamcrest" -name 'hamcrest-core-1.3.jar' -o -name 'hamcrest-library-1.3.jar' | paste -sd:)"
PY="${PY:-python3.12}"
OUT="$HOST/test"

rm -rf "$OUT"
mkdir -p "$OUT/proxy" "$OUT/classes"

PYTHONPATH="$SRC/../gradle-plugin/src/main/python" "$PY" -m chaquopy.static_proxy \
    --path "$TESTPY" --java "$OUT/proxy" \
    chaquopy.test.static_proxy.basic chaquopy.test.static_proxy.header chaquopy.test.static_proxy.method

"$JDK/bin/javac" -nowarn -d "$OUT/classes" \
    -cp "$HOST/classes:$ANDROID_JAR:$JUNIT:$HAMCREST" \
    $(find "$SRC/src/test/java" "$OUT/proxy" -name '*.java' ! -name 'AndroidPlatformTest.java' ! -name 'TestSuite.java') 2>&1 | grep -v '^Note:' || true

export JAVA_HOME="$JDK"
export CLASSPATH="$HOST/classes:$OUT/classes:$JUNIT:$HAMCREST"
export PYTHONPATH="$HOST/py:$TESTPY"
export LD_LIBRARY_PATH="$HOST/lib:$JDK/lib/server"
cd "$TESTPY"
"$PY" -m unittest "${@:-chaquopy.test}"

[ $# -gt 0 ] && exit 0
PYLIB="$($PY -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR") + "/" + sysconfig.get_config_var("LDLIBRARY"))')"
LD_PRELOAD="$PYLIB" "$JDK/bin/java" -Djava.library.path="$HOST/lib" org.junit.runner.JUnitCore \
    com.chaquo.java.GenericPlatformTest com.chaquo.java.ListTest com.chaquo.java.MapTest \
    com.chaquo.java.PyObjectTest com.chaquo.java.PythonTest com.chaquo.java.SetTest \
    com.chaquo.java.StaticProxyTest
