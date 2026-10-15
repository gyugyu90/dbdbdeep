import java.io.*;
import java.nio.charset.StandardCharsets;
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

    static String normalize(String sql) {
        sql = sql.strip();
        if (sql.endsWith("/")) sql = sql.substring(0, sql.length() - 1).stripTrailing();
        String prefix = sql.replaceFirst("(?s)^(?:\\s|--[^\\n]*(?:\\n|$)|/\\*.*?\\*/)*", "").toUpperCase(Locale.ROOT);
        boolean block = prefix.matches("(?s)^(BEGIN|DECLARE)\\b.*") ||
            prefix.matches("(?s)^CREATE\\s+(OR\\s+REPLACE\\s+)?(EDITIONABLE\\s+|NONEDITIONABLE\\s+)?(PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE)\\b.*");
        if (!block && sql.endsWith(";")) sql = sql.substring(0, sql.length() - 1).stripTrailing();
        return sql;
    }

    private static String execute(Connection connection, String sql, int rowLimit) throws SQLException, IOException {
        long start = System.nanoTime();
        StringBuilder columns = new StringBuilder("[");
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
        return "{\"columns\":" + columns.append(']') + ",\"rows\":" + rows.append(']') +
            ",\"affected\":" + affected + ",\"elapsed\":" + (System.nanoTime() - start) / 1e9 +
            ",\"truncated\":" + truncated + ",\"message\":\"Query completed\"}";
    }

    private static String empty(String message) {
        return "{\"columns\":[],\"rows\":[],\"affected\":0,\"elapsed\":0,\"truncated\":false,\"message\":" + quote(message) + "}";
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("--self-test")) {
            if (!normalize("select ';' from dual;").equals("select ';' from dual")) throw new AssertionError();
            if (!normalize("-- hi\nBEGIN NULL; END;\n/").endsWith("END;")) throw new AssertionError();
            if (!quote("a\n\"b").equals("\"a\\n\\\"b\"")) throw new AssertionError();
            System.out.println("Oracle bridge normalization and escaping passed.");
            return;
        }
        Connection connection = null;
        try {
            String url = read();
            Properties props = new Properties();
            props.setProperty("user", read());
            props.setProperty("password", read());
            props.setProperty("oracle.net.CONNECT_TIMEOUT", "8000");
            props.setProperty("oracle.net.OUTBOUND_CONNECT_TIMEOUT", "10000");
            props.setProperty("oracle.jdbc.ReadTimeout", "70000");
            Class.forName("oracle.jdbc.OracleDriver");
            connection = DriverManager.getConnection(url, props);
            props.remove("password");
            connection.setAutoCommit(false);
            send(empty("Connected"));
            while (true) {
                String action = read();
                String sql = read();
                try {
                    switch (action) {
                        case "commit": connection.commit(); send(empty("Changes committed")); break;
                        case "rollback": connection.rollback(); send(empty("Changes rolled back")); break;
                        case "close": return;
                        case "schema": send(execute(connection, sql, 100000)); break;
                        default: send(execute(connection, sql, 1000));
                    }
                } catch (SQLException error) {
                    send("{\"error\":" + quote(error.getMessage()) + "}");
                }
            }
        } catch (EOFException ignored) {
        } catch (Exception error) {
            send("{\"error\":" + quote(error.getMessage()) + "}");
        } finally {
            if (connection != null) {
                try { connection.rollback(); } catch (SQLException ignored) {}
                connection.close();
            }
        }
    }
}
