import java.sql.*;

public final class OracleResultMetadataSelfTest {
    public static void main(String[] args) throws Exception {
        String[] names = {"NUMBER", "VARCHAR2", "DATE", "CLOB", "NUMBER", null};
        int[] precisions = {10, 80, 7, 0, 12, 0};
        int[] scales = {0, 0, 0, 0, 2, 0};
        ResultSetMetaData metadata = OracleExportSelfTest.proxy(ResultSetMetaData.class, (p, m, values) -> switch (m.getName()) {
            case "getColumnCount" -> names.length;
            case "getColumnLabel" -> "ALIAS_" + values[0];
            case "getColumnTypeName" -> names[(int)values[0] - 1];
            case "getPrecision" -> precisions[(int)values[0] - 1];
            case "getScale" -> scales[(int)values[0] - 1];
            default -> throw new AssertionError(m.getName());
        });
        ResultSet cursor = OracleExportSelfTest.proxy(ResultSet.class, (p, m, values) -> switch (m.getName()) {
            case "getMetaData" -> metadata;
            case "next" -> false;
            case "close" -> null;
            default -> throw new AssertionError(m.getName());
        });
        Statement statement = OracleExportSelfTest.proxy(Statement.class, (p, m, values) -> switch (m.getName()) {
            case "execute" -> true;
            case "getResultSet" -> cursor;
            case "setQueryTimeout", "setFetchSize", "close" -> null;
            default -> throw new AssertionError(m.getName());
        });
        Connection connection = OracleExportSelfTest.proxy(Connection.class, (p, m, values) -> {
            if (!m.getName().equals("createStatement")) throw new AssertionError(m.getName());
            return statement;
        });
        String result = OracleBridge.execute(connection, "SELECT * FROM fixture", 1000);
        String expected = "\"columnMetadata\":[{\"type\":\"NUMBER(10)\"},{\"type\":\"VARCHAR2(80)\"},{\"type\":\"DATE\"},{\"type\":\"CLOB\"},{\"type\":\"NUMBER(12,2)\"},{\"type\":null}]";
        if (!result.contains(expected)) throw new AssertionError("Missing result column types: " + result);
        if (!result.contains("\"columns\":[\"ALIAS_1\",\"ALIAS_2\",\"ALIAS_3\",\"ALIAS_4\",\"ALIAS_5\",\"ALIAS_6\"]")) throw new AssertionError("Column labels changed");
        if (!result.contains("\"rows\":[]")) throw new AssertionError("Empty result changed");
        System.out.println("Oracle result column types and empty-result metadata passed.");
    }
}
