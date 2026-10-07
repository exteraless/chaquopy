# Chaquopy for exteraless

This branch is [Chaquopy](https://github.com/chaquo/chaquopy) 17.0.0 with changes to the
Python ↔ Java bridge used by the [exteraless](https://github.com/exteraless/exteraless) plugin
engine. Only the native runtime libraries change: `chaquopy.so` and `libchaquopy_java.so`.
The Gradle plugin, the Java classes and the Python builds are the stock 17.0.0 ones.

The exteraless app includes this repository as a git submodule (`TMessagesProj/chaquopy`) and
builds both libraries from it on every build, so the APK contains exactly the code published
here.

## What is changed

- Faster method calls, attribute access and object wrapping in the bridge: Cython-level caches
  for classes, members and wrappers, and argument conversion without intermediate tuples.
- JNI reference fixes: dynamic proxy wrappers and their weak references are released right
  after use instead of waiting for Java or Python finalization.
- A settable reflection policy (`set_reflection_policy`) that the app uses to restrict
  reflective calls from plugins.
- `GuardedMethod` and a constructor call fallback used by the app's plugin SDK.

The full list is the commit history on top of the `17.0.0` tag.

## Building

`build.sh` builds both libraries for one ABI. It needs bash, Python 3, the Android NDK, CMake,
and the Chaquopy Python target archive (`com.chaquo.python:target`).

```sh
ABI=arm64-v8a OUT=out/arm64-v8a exteraless/build.sh
```

| Variable | Default |
|---|---|
| `ABI` | `arm64-v8a` |
| `OUT` | `$WORKSPACE/out/$ABI` |
| `WORKSPACE` | `../chaquopy-build` next to the checkout |
| `NDK` | `~/Android/Sdk/ndk/27.2.12479018` |
| `CMAKE` | `cmake` on `PATH`, else the newest one in the Android SDK |
| `PYTHON` | `python3`, used to create a venv with Cython 3.0.11 |
| `PYTHON_VERSION` | `3.11` |
| `PYTHON_TARGET_ZIP` | the target archive from the Gradle cache |

The app's Gradle build sets all of these itself.

## Tests

`host.sh` builds the runtime for the host machine. `test.sh` then runs the Chaquopy Python and
JUnit tests against it, including the reference leak and reflection policy tests added here.
`bench.sh` runs the bridge benchmarks.

## License

MIT, same as upstream Chaquopy. See `LICENSE.txt`.
