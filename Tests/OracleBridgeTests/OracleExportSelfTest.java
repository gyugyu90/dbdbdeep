import java.io.*;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;

public final class OracleExportSelfTest {
    static final String LONG_NOTE = "한글 🌷,\"quoted\"\n" + "긴 텍스트".repeat(10000);

    static final class Cursor {
        int row, failAt, fetchSize;
        boolean resultClosed, statementClosed;
        String sql;
        ResultSetMetaData metadata = proxy(ResultSetMetaData.class, (p, m, args) -> switch (m.getName()) {
            case "getColumnCount" -> 3;
            case "getColumnLabel" -> new String[]{"id", "note", "raw"}[(int)args[0] - 1];
            case "getColumnType" -> new int[]{Types.INTEGER, Types.CLOB, Types.BLOB}[(int)args[0] - 1];
            default -> null;
        });
        ResultSet result = proxy(ResultSet.class, (p, m, args) -> switch (m.getName()) {
            case "next" -> {
                row++;
                if (row == failAt) throw new SQLException("simulated fetch failure");
                yield row <= 2500;
            }
            case "getMetaData" -> metadata;
            case "getString" -> Integer.toString(row);
            case "getCharacterStream" -> row == 2 ? null : new StringReader(row == 1 ? LONG_NOTE : "row " + row);
            case "getBinaryStream" -> new ByteArrayInputStream(new byte[]{0, (byte)255, 34});
            case "close" -> { resultClosed = true; yield null; }
            default -> null;
        });
        PreparedStatement statement = proxy(PreparedStatement.class, (p, m, args) -> switch (m.getName()) {
            case "executeQuery" -> result;
            case "setFetchSize" -> { fetchSize = (int)args[0]; yield null; }
            case "close" -> { statementClosed = true; yield null; }
            default -> throw new AssertionError("Unexpected statement action: " + m.getName());
        });
        Connection connection = proxy(Connection.class, (p, m, args) -> {
            if (!m.getName().equals("prepareStatement")) throw new AssertionError("Export must not alter a transaction: " + m.getName());
            sql = (String)args[0];
            if ((int)args[1] != ResultSet.TYPE_FORWARD_ONLY || (int)args[2] != ResultSet.CONCUR_READ_ONLY) throw new AssertionError("Cursor mode");
            return statement;
        });
    }

    @SuppressWarnings("unchecked")
    static <T> T proxy(Class<T> type, InvocationHandler handler) {
        return (T)Proxy.newProxyInstance(OracleExportSelfTest.class.getClassLoader(), new Class<?>[]{type}, handler);
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("dbdbdeep-oracle-export-");
        try {
            for (String sql : List.of("SELECT 1 FROM dual;", "-- note\nWITH x AS(SELECT 1 FROM dual) SELECT * FROM x;", "WITH \"UPDATE\" AS(SELECT q'{) ' DELETE}' FROM dual) SELECT * FROM \"UPDATE\"")) {
                if (!OracleBridge.isSelectQuery(sql)) throw new AssertionError("Rejected SELECT: " + sql);
            }
            for (String sql : List.of("DELETE FROM notes", "WITH x AS(SELECT 1 FROM dual) UPDATE notes SET x=1", "SELECT 1 FROM dual; DELETE FROM notes", "WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 1; END; SELECT f FROM dual")) {
                if (OracleBridge.isSelectQuery(sql)) throw new AssertionError("Accepted non-SELECT: " + sql);
            }
            Cursor cursor = new Cursor();
            List<Long> progress = new ArrayList<>();
            Path path = directory.resolve("all.csv");
            OracleBridge.ExportResult summary = OracleBridge.exportCSV(cursor.connection, "SELECT * FROM fixture;", path, progress::add);
            String csv = Files.readString(path, StandardCharsets.UTF_8);
            if (summary.rows() != 2500 || summary.bytes() != Files.size(path)) throw new AssertionError("All cursor rows");
            if (!csv.startsWith("\"id\",\"note\",\"raw\"\r\n\"1\",\"" + LONG_NOTE.replace("\"", "\"\"") + "\",\"0x00FF22\"\r\n")) throw new AssertionError("Full CLOB, escaping, or binary encoding");
            if (!csv.contains("\"2\",,\"0x00FF22\"\r\n") || !csv.endsWith("\"2500\",\"row 2500\",\"0x00FF22\"\r\n")) throw new AssertionError("Null and final row");
            if (!cursor.resultClosed || !cursor.statementClosed || cursor.fetchSize != 1000 || !cursor.sql.equals("SELECT * FROM fixture")) throw new AssertionError("Cursor lifetime or configuration");
            if (progress.isEmpty() || progress.get(progress.size() - 1) != 2500) throw new AssertionError("Progress");
            Cursor failure = new Cursor(); failure.failAt = 1500;
            try { OracleBridge.exportCSV(failure.connection, "SELECT * FROM fixture", directory.resolve("failed.csv"), rows -> {}); throw new AssertionError("Fetch failure was ignored"); }
            catch (SQLException expected) { if (!failure.resultClosed || !failure.statementClosed) throw new AssertionError("Failed cursor was not closed"); }
            Path existing = directory.resolve("existing.csv"); Files.writeString(existing, "original");
            Cursor diskFailure = new Cursor();
            try { OracleBridge.exportCSV(diskFailure.connection, "SELECT * FROM fixture", existing, rows -> {}); throw new AssertionError("Existing temporary file was overwritten"); }
            catch (FileAlreadyExistsException expected) { if (!Files.readString(existing).equals("original") || !diskFailure.resultClosed || !diskFailure.statementClosed) throw new AssertionError("File or cursor preservation"); }
            System.out.println("Oracle cursor export, full CLOB, CSV escaping, and failure cleanup passed.");
        } finally {
            try (var files = Files.list(directory)) { for (Path path : files.toList()) Files.deleteIfExists(path); }
            Files.deleteIfExists(directory);
        }
    }
}
