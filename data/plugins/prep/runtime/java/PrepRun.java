import java.io.IOException;
import java.lang.reflect.Array;
import java.lang.reflect.Constructor;
import java.lang.reflect.GenericArrayType;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.lang.reflect.WildcardType;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.Set;

/**
 * Compiles beside the candidate's Solution class.
 * With PREP_SPEC set, each sample is parsed and passed to the named method.
 * Otherwise Solution.main runs when it exists.
 */
public class PrepRun {
    static final String SOLUTION = "Solution";

    public static void main(String[] args) {
        String spec = System.getenv("PREP_SPEC");
        if (spec != null && spec.length() > 0) {
            try {
                runExamples(spec);
            } catch (Exception ex) {
                ex.printStackTrace(System.err);
                System.exit(1);
            }
            return;
        }
        runUserMain();
    }

    static void runUserMain() {
        Class<?> cls;
        try {
            cls = Class.forName(SOLUTION);
        } catch (ClassNotFoundException ex) {
            System.err.println("Define a class named Solution to run this file.");
            System.exit(1);
            return;
        } catch (Throwable ex) {
            root(ex).printStackTrace(System.err);
            System.exit(1);
            return;
        }
        Method main;
        try {
            main = cls.getDeclaredMethod("main", String[].class);
        } catch (NoSuchMethodException ex) {
            return;
        }
        if (!Modifier.isStatic(main.getModifiers())) return;
        try {
            main.setAccessible(true);
            main.invoke(null, (Object) new String[0]);
        } catch (InvocationTargetException ex) {
            root(ex).printStackTrace(System.err);
            System.exit(1);
        } catch (Exception ex) {
            ex.printStackTrace(System.err);
            System.exit(1);
        }
    }

    static void runExamples(String path) throws IOException {
        String text = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
        if (text.startsWith("\uFEFF")) text = text.substring(1);
        Object root = Json.parse(text);
        if (!(root instanceof Map)) throw new IllegalArgumentException("example spec is not an object");
        Map<?, ?> spec = (Map<?, ?>) root;
        String name = spec.get("name") == null ? "solve" : String.valueOf(spec.get("name"));
        List<?> params = spec.get("params") instanceof List ? (List<?>) spec.get("params") : new ArrayList<Object>();
        String examples = spec.get("examples") == null ? "" : String.valueOf(spec.get("examples"));
        List<String> lines = new ArrayList<String>();
        for (String line : examples.split("\r?\n", -1)) {
            if (line.trim().length() > 0) lines.add(line);
        }
        if (lines.isEmpty()) {
            System.out.println("No examples.");
            return;
        }
        Class<?> cls;
        try {
            cls = Class.forName(SOLUTION);
        } catch (ClassNotFoundException ex) {
            System.out.println("Define Solution." + name + " or a function named " + name + " to run examples.");
            return;
        } catch (Throwable ex) {
            root(ex).printStackTrace(System.err);
            System.exit(1);
            return;
        }
        int width = params.size();
        List<Method> methods = findMethods(cls, name, width);
        if (methods.isEmpty()) {
            System.out.println("Define Solution." + name + " or a function named " + name + " to run examples.");
            return;
        }
        if (width == 0) {
            callExample(methods, new ArrayList<String>(), 1);
            return;
        }
        int index = 0;
        int example = 1;
        while (index < lines.size()) {
            if (index + width > lines.size()) {
                System.out.println("Example " + example + ": not enough lines for " + width + " parameters");
                break;
            }
            callExample(methods, lines.subList(index, index + width), example);
            index += width;
            example += 1;
        }
    }

    static void callExample(List<Method> methods, List<String> chunk, int example) {
        IllegalArgumentException last = null;
        for (Method method : methods) {
            Object[] args;
            try {
                args = bind(method, chunk);
            } catch (IllegalArgumentException ex) {
                last = ex;
                continue;
            }
            Object receiver = null;
            if (!Modifier.isStatic(method.getModifiers())) {
                try {
                    receiver = receiverFor(method);
                } catch (Exception ex) {
                    System.out.println("Example " + example + ": Solution() failed: " + message(ex));
                    return;
                }
            }
            try {
                method.setAccessible(true);
                if (method.getReturnType() == void.class) {
                    method.invoke(receiver, args);
                    System.out.println("Example " + example + ":");
                } else {
                    Object result = method.invoke(receiver, args);
                    System.out.println("Example " + example + ": " + show(result));
                }
                return;
            } catch (InvocationTargetException ex) {
                System.out.println("Example " + example + ":");
                root(ex).printStackTrace(System.err);
                return;
            } catch (IllegalArgumentException ex) {
                last = ex;
            } catch (Exception ex) {
                System.out.println("Example " + example + ": " + message(ex));
                return;
            }
        }
        String why = last == null ? "no matching method" : last.getMessage();
        System.out.println("Example " + example + ": could not parse input (" + why + ")");
    }

    static Object[] bind(Method method, List<String> chunk) {
        Type[] types = method.getGenericParameterTypes();
        Object[] args = new Object[types.length];
        for (int i = 0; i < types.length; i++) {
            args[i] = convert(Json.parse(chunk.get(i)), types[i]);
        }
        return args;
    }

    static Object receiverFor(Method method) throws Exception {
        Constructor<?> ctor = method.getDeclaringClass().getDeclaredConstructor();
        ctor.setAccessible(true);
        return ctor.newInstance();
    }

    static List<Method> findMethods(Class<?> cls, String name, int argc) {
        List<Method> found = new ArrayList<Method>();
        for (Method method : cls.getDeclaredMethods()) {
            if (method.isBridge() || method.isSynthetic()) continue;
            if (method.getName().equals(name) && method.getParameterCount() == argc) found.add(method);
        }
        return found;
    }

    static Throwable root(Throwable ex) {
        Throwable cur = ex;
        while (cur.getCause() != null && cur.getCause() != cur) cur = cur.getCause();
        return cur;
    }

    static String message(Throwable ex) {
        Throwable cur = root(ex);
        String msg = cur.getMessage();
        if (msg == null || msg.length() == 0) return cur.getClass().getSimpleName();
        return msg;
    }

    static Object convert(Object json, Type type) {
        if (type instanceof WildcardType) {
            Type[] upper = ((WildcardType) type).getUpperBounds();
            if (upper.length > 0) return convert(json, upper[0]);
            return json;
        }
        if (type instanceof GenericArrayType) {
            throw new IllegalArgumentException("unsupported generic array");
        }
        if (type instanceof ParameterizedType) {
            ParameterizedType pt = (ParameterizedType) type;
            if (!(pt.getRawType() instanceof Class)) {
                throw new IllegalArgumentException("unsupported type");
            }
            Class<?> cls = (Class<?>) pt.getRawType();
            Type[] args = pt.getActualTypeArguments();
            Type first = args.length > 0 ? args[0] : Object.class;
            Type second = args.length > 1 ? args[1] : Object.class;
            if (Map.class.isAssignableFrom(cls)) return toMap(json, cls, first, second);
            if (Set.class.isAssignableFrom(cls)) return toCollection(json, cls, first, true);
            if (Collection.class.isAssignableFrom(cls)) return toCollection(json, cls, first, false);
            return convert(json, cls);
        }
        if (type instanceof Class) return convertClass(json, (Class<?>) type);
        return json;
    }

    static Object convertClass(Object json, Class<?> cls) {
        if (json == null) {
            if (cls.isPrimitive()) throw new IllegalArgumentException("null for " + cls.getSimpleName());
            return null;
        }
        if (cls == int.class || cls == Integer.class) return Integer.valueOf(toInt(json));
        if (cls == long.class || cls == Long.class) return Long.valueOf(toLong(json));
        if (cls == short.class || cls == Short.class) return Short.valueOf(toShort(json));
        if (cls == byte.class || cls == Byte.class) return Byte.valueOf(toByte(json));
        if (cls == double.class || cls == Double.class) return Double.valueOf(toDouble(json));
        if (cls == float.class || cls == Float.class) return Float.valueOf((float) toDouble(json));
        if (cls == boolean.class || cls == Boolean.class) {
            if (json instanceof Boolean) return json;
            throw new IllegalArgumentException("expected boolean, got " + json);
        }
        if (cls == char.class || cls == Character.class) return Character.valueOf(toChar(json));
        if (cls == String.class) {
            if (json instanceof String) return json;
            throw new IllegalArgumentException("expected string, got " + json);
        }
        if (cls == ListNode.class) return toListNode(json);
        if (cls == TreeNode.class) return toTreeNode(json);
        if (cls == Object.class) return json;
        if (cls.isArray()) return toArray(json, cls);
        throw new IllegalArgumentException("unsupported type " + cls.getSimpleName());
    }

    static Object toArray(Object json, Class<?> cls) {
        if (json == null) return null;
        if (!(json instanceof List)) throw new IllegalArgumentException("expected array");
        List<?> items = (List<?>) json;
        Class<?> component = cls.getComponentType();
        Object array = Array.newInstance(component, items.size());
        for (int i = 0; i < items.size(); i++) {
            Object value = convert(items.get(i), component);
            if (value == null && component.isPrimitive()) {
                throw new IllegalArgumentException("null in a primitive array");
            }
            Array.set(array, i, value);
        }
        return array;
    }

    @SuppressWarnings("unchecked")
    static Object toCollection(Object json, Class<?> cls, Type element, boolean set) {
        if (json == null) return null;
        if (!(json instanceof List)) throw new IllegalArgumentException("expected array");
        Collection<Object> out;
        if (cls.isInterface() || Modifier.isAbstract(cls.getModifiers())) {
            if (set || Set.class.isAssignableFrom(cls)) out = new LinkedHashSet<Object>();
            else if (Queue.class.isAssignableFrom(cls)) out = new ArrayDeque<Object>();
            else out = new ArrayList<Object>();
        } else {
            try {
                Constructor<?> ctor = cls.getDeclaredConstructor();
                ctor.setAccessible(true);
                out = (Collection<Object>) ctor.newInstance();
            } catch (Exception ex) {
                out = set ? new LinkedHashSet<Object>() : new ArrayList<Object>();
            }
        }
        for (Object item : (List<?>) json) out.add(convert(item, element));
        return out;
    }

    @SuppressWarnings("unchecked")
    static Object toMap(Object json, Class<?> cls, Type keyType, Type valueType) {
        if (json == null) return null;
        if (!(json instanceof Map)) throw new IllegalArgumentException("expected object");
        Map<Object, Object> out;
        if (cls.isInterface() || Modifier.isAbstract(cls.getModifiers())) {
            out = new LinkedHashMap<Object, Object>();
        } else {
            try {
                Constructor<?> ctor = cls.getDeclaredConstructor();
                ctor.setAccessible(true);
                out = (Map<Object, Object>) ctor.newInstance();
            } catch (Exception ex) {
                out = new LinkedHashMap<Object, Object>();
            }
        }
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) json).entrySet()) {
            out.put(convert(entry.getKey(), keyType), convert(entry.getValue(), valueType));
        }
        return out;
    }

    static ListNode toListNode(Object json) {
        if (json == null) return null;
        if (!(json instanceof List)) throw new IllegalArgumentException("expected list for ListNode");
        ListNode dummy = new ListNode();
        ListNode cur = dummy;
        for (Object value : (List<?>) json) {
            if (value == null) throw new IllegalArgumentException("null in ListNode");
            cur.next = new ListNode(toInt(value));
            cur = cur.next;
        }
        return dummy.next;
    }

    static TreeNode toTreeNode(Object json) {
        if (json == null) return null;
        if (!(json instanceof List)) throw new IllegalArgumentException("expected list for TreeNode");
        List<?> values = (List<?>) json;
        if (values.isEmpty() || values.get(0) == null) return null;
        TreeNode root = new TreeNode(toInt(values.get(0)));
        ArrayDeque<TreeNode> queue = new ArrayDeque<TreeNode>();
        queue.add(root);
        int index = 1;
        while (!queue.isEmpty() && index < values.size()) {
            TreeNode node = queue.removeFirst();
            if (index < values.size() && values.get(index) != null) {
                node.left = new TreeNode(toInt(values.get(index)));
                queue.add(node.left);
            }
            index += 1;
            if (index < values.size() && values.get(index) != null) {
                node.right = new TreeNode(toInt(values.get(index)));
                queue.add(node.right);
            }
            index += 1;
        }
        return root;
    }

    static long toLong(Object json) {
        if (json instanceof BigDecimal) {
            try {
                return ((BigDecimal) json).longValueExact();
            } catch (ArithmeticException ex) {
                throw new IllegalArgumentException("integer out of range");
            }
        }
        if (json instanceof Double || json instanceof Float) {
            double d = ((Number) json).doubleValue();
            if (!Double.isFinite(d) || d != Math.rint(d)) {
                throw new IllegalArgumentException("expected integer, got " + json);
            }
            if (d > Long.MAX_VALUE || d < Long.MIN_VALUE) {
                throw new IllegalArgumentException("integer out of range");
            }
            return (long) d;
        }
        if (json instanceof Number) return ((Number) json).longValue();
        if (json instanceof String) return Long.parseLong((String) json);
        throw new IllegalArgumentException("expected integer, got " + json);
    }

    static int toInt(Object json) {
        long value = toLong(json);
        if (value > Integer.MAX_VALUE || value < Integer.MIN_VALUE) {
            throw new IllegalArgumentException("integer out of range: " + value);
        }
        return (int) value;
    }

    static short toShort(Object json) {
        int value = toInt(json);
        if (value > Short.MAX_VALUE || value < Short.MIN_VALUE) {
            throw new IllegalArgumentException("short out of range: " + value);
        }
        return (short) value;
    }

    static byte toByte(Object json) {
        int value = toInt(json);
        if (value > Byte.MAX_VALUE || value < Byte.MIN_VALUE) {
            throw new IllegalArgumentException("byte out of range: " + value);
        }
        return (byte) value;
    }

    static double toDouble(Object json) {
        if (json instanceof Number) return ((Number) json).doubleValue();
        if (json instanceof String) return Double.parseDouble((String) json);
        throw new IllegalArgumentException("expected number, got " + json);
    }

    static char toChar(Object json) {
        if (json instanceof String) {
            String text = (String) json;
            if (text.length() != 1) throw new IllegalArgumentException("expected one character");
            return text.charAt(0);
        }
        return (char) toInt(json);
    }

    static String show(Object value) {
        if (value == null) return "null";
        if (value instanceof ListNode) return showNode((ListNode) value);
        if (value instanceof TreeNode) return showTree((TreeNode) value);
        if (value instanceof String) return quote((String) value);
        if (value instanceof Character) return quote(String.valueOf(((Character) value).charValue()));
        if (value instanceof Boolean || value instanceof Number) return String.valueOf(value);
        if (value.getClass().isArray()) return showArray(value);
        if (value instanceof Map) return showMap((Map<?, ?>) value);
        if (value instanceof Iterable) return showIterable((Iterable<?>) value);
        return quote(String.valueOf(value));
    }

    static String showArray(Object array) {
        int n = Array.getLength(array);
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        for (int i = 0; i < n; i++) {
            if (i > 0) sb.append(", ");
            sb.append(show(Array.get(array, i)));
        }
        sb.append(']');
        return sb.toString();
    }

    static String showIterable(Iterable<?> values) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        boolean first = true;
        for (Object value : values) {
            if (!first) sb.append(", ");
            first = false;
            sb.append(show(value));
        }
        sb.append(']');
        return sb.toString();
    }

    static String showMap(Map<?, ?> values) {
        StringBuilder sb = new StringBuilder();
        sb.append('{');
        boolean first = true;
        for (Map.Entry<?, ?> entry : values.entrySet()) {
            if (!first) sb.append(", ");
            first = false;
            sb.append(show(entry.getKey()));
            sb.append(": ");
            sb.append(show(entry.getValue()));
        }
        sb.append('}');
        return sb.toString();
    }

    static String showNode(ListNode node) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        IdentityHashMap<ListNode, Boolean> seen = new IdentityHashMap<ListNode, Boolean>();
        boolean first = true;
        int count = 0;
        while (node != null && !seen.containsKey(node)) {
            seen.put(node, Boolean.TRUE);
            if (!first) sb.append(',');
            first = false;
            sb.append(node.val);
            node = node.next;
            count += 1;
            if (count > 64) {
                sb.append(",...");
                break;
            }
        }
        sb.append(']');
        return sb.toString();
    }

    static String showTree(TreeNode node) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        ArrayDeque<TreeNode> queue = new ArrayDeque<TreeNode>();
        queue.add(node);
        boolean first = true;
        int count = 0;
        while (!queue.isEmpty()) {
            if (count > 4096) {
                if (!first) sb.append(',');
                sb.append("...");
                break;
            }
            TreeNode current = queue.removeFirst();
            if (!first) sb.append(',');
            first = false;
            count += 1;
            if (current == null) {
                sb.append("null");
                continue;
            }
            sb.append(current.val);
            queue.add(current.left);
            queue.add(current.right);
        }
        int end = sb.length();
        while (end >= 5 && sb.substring(end - 5).equals(",null")) end -= 5;
        sb.setLength(end);
        sb.append(']');
        return sb.toString();
    }

    static String quote(String text) {
        StringBuilder sb = new StringBuilder();
        sb.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        sb.append('"');
        return sb.toString();
    }

    /** JSON subset used by example lines and the spec file. */
    static final class Json {
        static Object parse(String text) {
            Parser parser = new Parser(text);
            Object value = parser.parseValue();
            parser.skip();
            if (parser.i != parser.s.length()) throw new IllegalArgumentException("trailing data");
            return value;
        }

        static final class Parser {
            final String s;
            int i;

            Parser(String s) { this.s = s; }

            void skip() {
                while (i < s.length()) {
                    char c = s.charAt(i);
                    if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i += 1;
                    else break;
                }
            }

            char peek() {
                skip();
                if (i >= s.length()) throw new IllegalArgumentException("unexpected end");
                return s.charAt(i);
            }

            Object parseValue() {
                char c = peek();
                if (c == '{') return parseObject();
                if (c == '[') return parseArray();
                if (c == '"') return parseString();
                if (c == 't') return literal("true", Boolean.TRUE);
                if (c == 'f') return literal("false", Boolean.FALSE);
                if (c == 'n') return literal("null", null);
                return parseNumber();
            }

            Object literal(String word, Object value) {
                if (!s.startsWith(word, i)) throw new IllegalArgumentException("expected " + word);
                i += word.length();
                return value;
            }

            Map<String, Object> parseObject() {
                i += 1;
                Map<String, Object> out = new LinkedHashMap<String, Object>();
                if (peek() == '}') { i += 1; return out; }
                while (true) {
                    if (peek() != '"') throw new IllegalArgumentException("expected string key");
                    String key = parseString();
                    if (peek() != ':') throw new IllegalArgumentException("expected ':'");
                    i += 1;
                    out.put(key, parseValue());
                    char c = peek();
                    if (c == ',') { i += 1; continue; }
                    if (c == '}') { i += 1; return out; }
                    throw new IllegalArgumentException("expected ',' or '}'");
                }
            }

            List<Object> parseArray() {
                i += 1;
                List<Object> out = new ArrayList<Object>();
                if (peek() == ']') { i += 1; return out; }
                while (true) {
                    out.add(parseValue());
                    char c = peek();
                    if (c == ',') { i += 1; continue; }
                    if (c == ']') { i += 1; return out; }
                    throw new IllegalArgumentException("expected ',' or ']'");
                }
            }

            String parseString() {
                if (peek() != '"') throw new IllegalArgumentException("expected string");
                i += 1;
                StringBuilder sb = new StringBuilder();
                while (i < s.length()) {
                    char c = s.charAt(i);
                    i += 1;
                    if (c == '"') return sb.toString();
                    if (c == '\\') {
                        if (i >= s.length()) throw new IllegalArgumentException("bad escape");
                        char e = s.charAt(i);
                        i += 1;
                        switch (e) {
                            case '"':
                            case '\\':
                            case '/': sb.append(e); break;
                            case 'b': sb.append('\b'); break;
                            case 'f': sb.append('\f'); break;
                            case 'n': sb.append('\n'); break;
                            case 'r': sb.append('\r'); break;
                            case 't': sb.append('\t'); break;
                            case 'u':
                                if (i + 4 > s.length()) throw new IllegalArgumentException("bad unicode escape");
                                int code = Integer.parseInt(s.substring(i, i + 4), 16);
                                sb.append((char) code);
                                i += 4;
                                break;
                            default: throw new IllegalArgumentException("bad escape");
                        }
                    } else {
                        sb.append(c);
                    }
                }
                throw new IllegalArgumentException("unterminated string");
            }

            Object parseNumber() {
                int start = i;
                if (i < s.length() && s.charAt(i) == '-') i += 1;
                if (i >= s.length() || !digit(s.charAt(i))) throw new IllegalArgumentException("expected number");
                while (i < s.length() && digit(s.charAt(i))) i += 1;
                boolean real = false;
                if (i < s.length() && s.charAt(i) == '.') {
                    real = true;
                    i += 1;
                    if (i >= s.length() || !digit(s.charAt(i))) throw new IllegalArgumentException("expected digit");
                    while (i < s.length() && digit(s.charAt(i))) i += 1;
                }
                if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
                    real = true;
                    i += 1;
                    if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i += 1;
                    if (i >= s.length() || !digit(s.charAt(i))) throw new IllegalArgumentException("expected exponent");
                    while (i < s.length() && digit(s.charAt(i))) i += 1;
                }
                String literal = s.substring(start, i);
                if (real) return Double.valueOf(literal);
                try {
                    return Long.valueOf(literal);
                } catch (NumberFormatException ex) {
                    return new BigDecimal(literal);
                }
            }

            static boolean digit(char c) { return c >= '0' && c <= '9'; }
        }
    }
}
