import com.chaquo.python.PyObject;

public class BenchHelper {
    public static class Param {
        public Object thisObject;
        public Object[] args;
        private Object result;

        public Object getResult() { return result; }
        public void setResult(Object result) { this.result = result; }
    }

    public static int callSame(PyObject f, Object arg, int n) {
        for (int i = 0; i < n; i++) {
            f.call(arg);
        }
        return n;
    }

    public static int callFresh(PyObject f, int n) {
        for (int i = 0; i < n; i++) {
            Param p = new Param();
            p.args = new Object[] {i};
            f.call(p);
        }
        return n;
    }

    public static int callInt(PyObject f, int n) {
        for (int i = 0; i < n; i++) {
            f.call(i);
        }
        return n;
    }
}
