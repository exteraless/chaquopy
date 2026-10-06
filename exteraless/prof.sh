#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HERE/../../chaquopy-build}"
HOST="$WORKSPACE/host"
export JAVA_HOME="${JDK:-$HOME/.gradle/jdks/jetbrains_s_r_o_-21-amd64-linux.2}"
export CLASSPATH="$HOST/classes"
export PYTHONPATH="$HOST/py"
export JAVA_TOOL_OPTIONS="-Djava.library.path=$HOST/lib"
export LD_LIBRARY_PATH="$HOST/lib:$JAVA_HOME/lib/server"
exec "${PY:-python3.12}" "$HERE/prof_run.py" "$@"
