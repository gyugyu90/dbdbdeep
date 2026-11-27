import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;

public final class OracleBridge {
    private static final DataInputStream input = new DataInputStream(System.in);
    private static final DataOutputStream output = new DataOutputStream(System.out);

    private static String read() throws IOException {
        int size = input.readInt();
        if (size < 0 || size > 8_000_000) throw new IOException("Invalid request size");
        byte[] bytes = input.readNBytes(size);
        if (bytes.length != size) throw new EOFException();
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static void send(String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        output.writeInt(bytes.length);
        output.write(bytes);
        output.flush();
    }

    private static String quote(String value) {
        if (value == null) return "null";
        StringBuilder result = new StringBuilder("\"");
        for (char c : value.toCharArray()) {
            switch (c) {
                case '"': result.append("\\\""); break;
                case '\\': result.append("\\\\"); break;
                case '\n': result.append("\\n"); break;
                case '\r': result.append("\\r"); break;
                case '\t': result.append("\\t"); break;
                default:
                    if (c < 32) result.append(String.format("\\u%04x", (int)c));
                    else result.append(c);
            }
        }
        return result.append('"').toString();
    }

    private static void event(String stage, String level, String message) throws IOException {
        send("{\"event\":{\"stage\":" + quote(stage) + ",\"level\":" + quote(level) + ",\"message\":" + quote(message) + "}}");
    }

    private static String failure(Throwable error, String stage) {
        List<String> details = new ArrayList<>();
        Set<Throwable> visited = Collections.newSetFromMap(new IdentityHashMap<>());
        Throwable cause = error;
        while (cause != null && visited.add(cause) && details.size() < 8) {
            details.add(quote(cause.getClass().getName() + ": " + Objects.toString(cause.getMessage(), "(no message)")));
            cause = cause.getCause();
        }
        if (error instanceof SQLException sql) {
            SQLException next = sql.getNextException();
            while (next != null && visited.add(next) && details.size() < 8) {
                details.add(quote(next.getClass().getName() + ": " + Objects.toString(next.getMessage(), "(no message)")));
                next = next.getNextException();
            }
        }
        return "{\"error\":" + quote(Objects.toString(error.getMessage(), error.getClass().getName())) +
            ",\"details\":[" + String.join(",", details) + "],\"stage\":" + quote(stage) +
            ",\"errorCode\":" + (error instanceof SQLException sql ? sql.getErrorCode() : "null") +
            ",\"sqlState\":" + (error instanceof SQLException sql ? quote(sql.getSQLState()) : "null") + "}";
    }

    static String normalize(String sql) {
        sql = sql.strip();
        if (sql.endsWith("/")) sql = sql.substring(0, sql.length() - 1).stripTrailing();
        String prefix = sql.replaceFirst("(?s)^(?:\\s|--[^\\n]*(?:\\n|$)|/\\*.*?\\*/)*", "").toUpperCase(Locale.ROOT);
        boolean block = prefix.matches("(?s)^(BEGIN|DECLARE)\\b.*") ||
            prefix.matches("(?s)^CREATE\\s+(OR\\s+REPLACE\\s+)?(EDITIONABLE\\s+|NONEDITIONABLE\\s+)?(PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE)\\b.*");
        if (!block && sql.endsWith(";")) sql = sql.substring(0, sql.length() - 1).stripTrailing();
        return sql;
    }

    static String columnType(ResultSetMetaData meta, int index) throws SQLException {
        String name = meta.getColumnTypeName(index);
        if (name == null) return null;
        int precision = meta.getPrecision(index);
        if (precision > 0 && Set.of("CHAR", "NCHAR", "VARCHAR", "VARCHAR2", "NVARCHAR2", "RAW").contains(name)) return name + "(" + precision + ")";
        if (precision > 0 && "NUMBER".equals(name)) {
            int scale = meta.getScale(index);
            return name + "(" + precision + (scale == 0 ? "" : "," + scale) + ")";
        }
        return name;
    }

    static String execute(Connection connection, String sql, int rowLimit) throws SQLException, IOException {
        long start = System.nanoTime();
        StringBuilder columns = new StringBuilder("[");
        StringBuilder columnMetadata = new StringBuilder("[");
        StringBuilder rows = new StringBuilder("[");
        int affected = 0;
        boolean truncated = false;
        try (Statement statement = connection.createStatement()) {
            statement.setQueryTimeout(60);
            statement.setFetchSize(100);
            if (statement.execute(normalize(sql))) {
                try (ResultSet rs = statement.getResultSet()) {
                    ResultSetMetaData meta = rs.getMetaData();
                    int count = meta.getColumnCount();
                    for (int i = 1; i <= count; i++) {
                        if (i > 1) columns.append(',');
                        columns.append(quote(meta.getColumnLabel(i)));
                        if (i > 1) columnMetadata.append(',');
                        columnMetadata.append("{\"type\":").append(quote(columnType(meta, i))).append('}');
                    }
                    int n = 0;
                    while (rs.next()) {
                        if (n == rowLimit) { truncated = true; break; }
                        if (n++ > 0) rows.append(',');
                        rows.append('[');
                        for (int i = 1; i <= count; i++) {
                            if (i > 1) rows.append(',');
                            int type = meta.getColumnType(i);
                            String value;
                            if (type == Types.BLOB || type == Types.BINARY || type == Types.VARBINARY || type == Types.LONGVARBINARY) {
                                Object object = rs.getObject(i);
                                value = object == null ? null : "[BINARY]";
                            } else if (type == Types.CLOB || type == Types.NCLOB) {
                                Clob clob = rs.getClob(i);
                                value = clob == null ? null : clob.getSubString(1, (int)Math.min(clob.length(), 16384));
                                if (clob != null) clob.free();
                            } else {
                                value = rs.getString(i);
                            }
                            if (value != null && value.length() > 16384) value = value.substring(0, 16384) + "…";
                            rows.append(quote(value));
                        }
                        rows.append(']');
                    }
                }
            } else affected = Math.max(0, statement.getUpdateCount());
        }
        return "{\"columns\":" + columns.append(']') + ",\"columnMetadata\":" + columnMetadata.append(']') + ",\"rows\":" + rows.append(']') +
            ",\"affected\":" + affected + ",\"elapsed\":" + (System.nanoTime() - start) / 1e9 +
            ",\"truncated\":" + truncated + ",\"message\":\"Query completed\"}";
    }

    private static String empty(String message) {
        return "{\"columns\":[],\"rows\":[],\"affected\":0,\"elapsed\":0,\"truncated\":false,\"message\":" + quote(message) + "}";
    }

    interface ExportProgress { void accept(long rows) throws IOException; }
    record ExportResult(long rows, long bytes, double elapsed) {}

    static boolean isSelectQuery(String sql) {
        if (sql.indexOf('\0') >= 0) return false;
        String first = null;
        boolean select = false, ended = false;
        int depth = 0;
        for (int i = 0; i < sql.length();) {
            char c = sql.charAt(i);
            if (Character.isWhitespace(c)) { i++; continue; }
            if (sql.startsWith("--", i)) {
                while (i < sql.length() && sql.charAt(i) != '\n' && sql.charAt(i) != '\r') i++;
                continue;
            }
            if (sql.startsWith("/*", i)) {
                int end = sql.indexOf("*/", i + 2);
                if (end < 0) return false;
                i = end + 2; continue;
            }
            if (ended && c != ';') return false;
            int q = (c == 'q' || c == 'Q') && i + 1 < sql.length() && sql.charAt(i + 1) == '\'' ? 2 :
                (c == 'n' || c == 'N') && i + 2 < sql.length() && (sql.charAt(i + 1) == 'q' || sql.charAt(i + 1) == 'Q') && sql.charAt(i + 2) == '\'' ? 3 : 0;
            if (q > 0) {
                if (i + q >= sql.length()) return false;
                char opening = sql.charAt(i + q);
                char closing = switch (opening) { case '[' -> ']'; case '{' -> '}'; case '(' -> ')'; case '<' -> '>'; default -> opening; };
                int end = sql.indexOf("" + closing + '\'', i + q + 1);
                if (end < 0) return false;
                i = end + 2; continue;
            }
            if (c == '\'' || c == '"' || c == '`' || c == '[') {
                char closing = c == '[' ? ']' : c;
                boolean closed = false;
                for (i++; i < sql.length(); i++) {
                    if (sql.charAt(i) != closing) continue;
                    if (c != '[' && i + 1 < sql.length() && sql.charAt(i + 1) == closing) { i++; continue; }
                    i++; closed = true; break;
                }
                if (!closed) return false;
                continue;
            }
            if (Character.isLetter(c) || c == '_') {
                int start = i++;
                while (i < sql.length() && (Character.isLetterOrDigit(sql.charAt(i)) || "_$#".indexOf(sql.charAt(i)) >= 0)) i++;
                String word = sql.substring(start, i).toUpperCase(Locale.ROOT);
                if (first == null) {
                    first = word;
                    if (!word.equals("SELECT") && !word.equals("WITH")) return false;
                    select = word.equals("SELECT");
                } else if (!select && depth == 0) {
                    if (word.equals("SELECT")) select = true;
                    else if (Set.of("INSERT", "UPDATE", "DELETE", "MERGE", "FUNCTION", "PROCEDURE", "BEGIN", "CREATE").contains(word)) return false;
                }
                continue;
            }
            if (c == '(') depth++;
            else if (c == ')') { if (--depth < 0) return false; }
            else if (c == ';' && depth == 0) ended = true;
            i++;
        }
        return select && depth == 0;
    }

    static void csvField(Writer writer, Reader value) throws IOException {
        if (value == null) return;
        writer.write('"');
        char[] buffer = new char[8192];
        int size;
        while ((size = value.read(buffer)) != -1) {
            int start = 0;
            for (int i = 0; i < size; i++) {
                if (buffer[i] != '"') continue;
                writer.write(buffer, start, i - start + 1); writer.write('"'); start = i + 1;
            }
            writer.write(buffer, start, size - start);
        }
        writer.write('"');
    }

    static ExportResult exportCSV(Connection connection, String sql, Path path, ExportProgress progress) throws SQLException, IOException {
        if (!isSelectQuery(sql)) throw new SQLException("Full export requires one SELECT query, including SELECT with a WITH clause.");
        long start = System.nanoTime(), lastProgress = start, rows = 0;
        try (PreparedStatement statement = connection.prepareStatement(normalize(sql), ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY)) {
            statement.setFetchSize(1000);
            try (ResultSet rs = statement.executeQuery();
                 BufferedWriter writer = Files.newBufferedWriter(path, StandardCharsets.UTF_8, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                ResultSetMetaData meta = rs.getMetaData();
                int count = meta.getColumnCount();
                int[] types = new int[count];
                for (int i = 0; i < count; i++) {
                    if (i > 0) writer.write(',');
                    csvField(writer, new StringReader(meta.getColumnLabel(i + 1)));
                    types[i] = meta.getColumnType(i + 1);
                }
                writer.write("\r\n");
                while (rs.next()) {
                    for (int i = 0; i < count; i++) {
                        if (i > 0) writer.write(',');
                        int type = types[i];
                        if (type == Types.BLOB || type == Types.BINARY || type == Types.VARBINARY || type == Types.LONGVARBINARY) {
                            try (InputStream value = rs.getBinaryStream(i + 1)) {
                                if (value != null) {
                                    writer.write("\"0x");
                                    byte[] bytes = new byte[8192];
                                    char[] hex = new char[16384];
                                    char[] digits = "0123456789ABCDEF".toCharArray();
                                    int size;
                                    while ((size = value.read(bytes)) != -1) {
                                        for (int n = 0; n < size; n++) {
                                            hex[n * 2] = digits[(bytes[n] & 255) >>> 4]; hex[n * 2 + 1] = digits[bytes[n] & 15];
                                        }
                                        writer.write(hex, 0, size * 2);
                                    }
                                    writer.write('"');
                                }
                            }
                        } else if (type == Types.CLOB || type == Types.NCLOB || type == Types.LONGVARCHAR || type == Types.LONGNVARCHAR) {
                            try (Reader value = rs.getCharacterStream(i + 1)) { csvField(writer, value); }
                        } else {
                            String value = rs.getString(i + 1);
                            csvField(writer, value == null ? null : new StringReader(value));
                        }
                    }
                    writer.write("\r\n"); rows++;
                    if (rows % 1000 == 0 && System.nanoTime() - lastProgress >= 100_000_000) {
                        progress.accept(rows); lastProgress = System.nanoTime();
                    }
                }
            }
        }
        progress.accept(rows);
        return new ExportResult(rows, Files.size(path), (System.nanoTime() - start) / 1e9);
    }

    static void verifyConnection(Connection connection, int timeout) throws SQLException {
        try (Statement check = connection.createStatement()) {
            check.setQueryTimeout(timeout);
            try (ResultSet result = check.executeQuery("SELECT 1 FROM DUAL")) {
                if (!result.next() || result.getInt(1) != 1) throw new SQLException("Verification query returned an unexpected result");
            }
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("--charset-self-test")) {
            Class<?> charsetClass = Class.forName("oracle.sql.CharacterSet");
            int charsetID = charsetClass.getField("KO16MSWIN949_CHARSET").getInt(null);
            Object charset = charsetClass.getMethod("make", int.class).invoke(null, charsetID);
            String text = "한글 데이터 연결 확인";
            byte[] encoded = (byte[])charsetClass.getMethod("convert", String.class).invoke(charset, text);
            String decoded = (String)charsetClass.getMethod("toString", byte[].class, int.class, int.class).invoke(charset, encoded, 0, encoded.length);
            if (!text.equals(decoded)) throw new AssertionError("Korean character set round-trip failed");
            System.out.println("KO16MSWIN949 Korean character set round-trip passed.");
            return;
        }
        if (args.length > 0 && args[0].equals("--self-test")) {
            if (!normalize("select ';' from dual;").equals("select ';' from dual")) throw new AssertionError();
            if (!normalize("-- hi\nBEGIN NULL; END;\n/").endsWith("END;")) throw new AssertionError();
            if (!quote("a\n\"b").equals("\"a\\n\\\"b\"")) throw new AssertionError();
            System.out.println("Oracle bridge normalization and escaping passed.");
            return;
        }
        Connection connection = null;
        String stage = "driver";
        try {
            String url = read();
            Properties props = new Properties();
            props.setProperty("user", read());
            props.setProperty("password", read());
            props.setProperty("oracle.net.CONNECT_TIMEOUT", "8000");
            props.setProperty("oracle.net.OUTBOUND_CONNECT_TIMEOUT", "10000");
            props.setProperty("oracle.jdbc.ReadTimeout", "70000");
            event("driver", "info", "Loading Oracle JDBC Thin driver");
            Class<?> driverClass = Class.forName("oracle.jdbc.OracleDriver");
            boolean internationalization = false;
            try {
                Class.forName("oracle.i18n.text.converter.CharacterConverter");
                internationalization = true;
            } catch (ClassNotFoundException ignored) {}
            String version = Objects.toString(driverClass.getPackage().getImplementationVersion(), "available");
            event("driver", "success", "Oracle JDBC Thin " + version + " · Java " + System.getProperty("java.version") + (internationalization ? " · orai18n charset support loaded" : " · no orai18n library selected"));
            stage = "connecting";
            event(stage, "info", "Oracle listener connection and account authentication · " + url);
            connection = DriverManager.getConnection(url, props);
            props.remove("password");
            stage = "session";
            connection.setAutoCommit(false);
            event(stage, "success", "Authenticated session established · manual commit");
            stage = "verification";
            event(stage, "info", "SELECT 1 FROM DUAL · query timeout 10s");
            verifyConnection(connection, 10);
            event(stage, "success", "Verification passed · " + connection.getMetaData().getDatabaseProductVersion());
            send(empty("Connected and verified"));
            while (true) {
                String action = read();
                String sql = read();
                try {
                    switch (action) {
                        case "validate": verifyConnection(connection, 5); send(empty("Connection verified")); break;
                        case "commit": connection.commit(); send(empty("Changes committed")); break;
                        case "rollback": connection.rollback(); send(empty("Changes rolled back")); break;
                        case "close": return;
                        case "schema": send(execute(connection, sql, 100000)); break;
                        case "exportCSV": {
                            Path path = Path.of(read());
                            ExportResult result = exportCSV(connection, sql, path, rows -> send("{\"exportProgress\":" + rows + "}"));
                            send("{\"exportComplete\":{\"rows\":" + result.rows() + ",\"bytes\":" + result.bytes() + ",\"elapsed\":" + result.elapsed() + "}}");
                            break;
                        }
                        default: send(execute(connection, sql, 1000));
                    }
                } catch (Exception error) {
                    send(failure(error, "session"));
                }
            }
        } catch (EOFException ignored) {
        } catch (Exception | LinkageError error) {
            send(failure(error, stage));
        } finally {
            if (connection != null) {
                try { connection.rollback(); } catch (SQLException ignored) {}
                connection.close();
            }
        }
    }
}
