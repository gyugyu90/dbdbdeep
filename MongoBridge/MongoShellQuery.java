import org.bson.Document;
import java.util.*;

final class MongoShellQuery {
    private final String source;
    private int position;

    private MongoShellQuery(String source) { this.source = source; }

    static Document command(String source) {
        MongoShellQuery parser = new MongoShellQuery(source);
        parser.trivia();
        if (parser.peek() == '{') return Document.parse(source);
        Document command = parser.query();
        parser.trivia();
        if (parser.peek() == ';') { parser.position++; parser.trivia(); }
        if (parser.position != source.length()) throw parser.failure("Run one complete MongoDB query at a time.");
        return command;
    }

    static void selfTest() {
        Document query = command("db.customers.find({status: 'active', _id: ObjectId('507f1f77bcf86cd799439011'), created: ISODate('2026-01-01T00:00:00Z'), name: /a[{}]/i}, {name: 1}).sort({name: -1}).skip(2).limit(10).toArray();");
        if (!query.getString("find").equals("customers") || query.getInteger("skip") != 2 || query.getInteger("limit") != 10) throw new AssertionError("Shell query translation");
        if (!query.get("filter", Document.class).getObjectId("_id").toHexString().equals("507f1f77bcf86cd799439011")) throw new AssertionError("ObjectId literal");
        if (!command("db.getCollection('with.dots').findOne({})").getString("find").equals("with.dots")) throw new AssertionError("Collection access");
        if (!command("db['한글 🌱'].find()").getString("find").equals("한글 🌱")) throw new AssertionError("Bracket access");
        if (!command("db.audit.logs.find({})").getString("find").equals("audit.logs")) throw new AssertionError("Dotted collection name");
        if (!command("db.runCommand({ping:1})").containsKey("ping")) throw new AssertionError("runCommand");
        if (!command("// header\ndb.items.find({ /* note */ name: 'brace ); // text' }).limit(1)").containsKey("find")) throw new AssertionError("Comments");
        for (String invalid : List.of("db.items.find({}).forEach(print)", "db.items.find({}) + dangerous()", "db.items.find({}).limit(-1)", "db.items.findOne({}).limit(10)", "db.items.find({}); db.items.drop()", "db.items.find(function(){return true})")) {
            try { command(invalid); throw new AssertionError("Accepted unsupported syntax: " + invalid); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("MongoDB shell query parsing and BSON literals passed.");
    }

    private Document query() {
        if (!identifier().equals("db")) throw failure("Start with db.collection.find(...) or a JSON command.");
        String collection;
        if (peek() == '[') {
            position++;
            collection = stringValue(argument(']'));
            expect(']');
            expect('.');
        } else {
            expect('.');
            String name = identifier();
            if (name.equals("runCommand") && peek() == '(') {
                List<String> arguments = arguments();
                count(arguments, 1, 1);
                return object(arguments.get(0));
            }
            if (name.equals("getCollection") && peek() == '(') {
                List<String> arguments = arguments();
                count(arguments, 1, 1);
                collection = stringValue(arguments.get(0));
            } else { collection = name; }
            expect('.');
        }
        String method = identifier();
        while (peek() == '.') {
            position++;
            collection += "." + method;
            method = identifier();
        }
        List<String> arguments = arguments();
        Document command;
        if (method.equals("find") || method.equals("findOne")) {
            count(arguments, 0, 2);
            command = new Document("find", collection).append("filter", arguments.isEmpty() ? new Document() : object(arguments.get(0)));
            if (arguments.size() > 1 && !arguments.get(1).equals("null")) command.append("projection", object(arguments.get(1)));
            if (method.equals("findOne")) command.append("limit", 1);
        } else {
            throw failure("Unsupported collection method: " + method + ". Use find(), findOne(), or a JSON command.");
        }
        boolean terminal = method.equals("findOne");
        while (peek() == '.') {
            if (terminal) throw failure("Cursor methods must precede toArray(); findOne() returns one document.");
            position++;
            String option = identifier();
            List<String> values = arguments();
            switch (option) {
                case "sort":
                    count(values, 1, 1);
                    command.put("sort", object(values.get(0)));
                    break;
                case "limit": case "skip": case "batchSize": case "maxTimeMS":
                    count(values, 1, 1);
                    String value = values.get(0).strip();
                    if (!value.matches("[0-9]+")) throw failure(option + " requires a nonnegative integer.");
                    try { command.put(option, Integer.parseInt(value)); }
                    catch (NumberFormatException error) { throw failure(option + " is too large."); }
                    break;
                case "pretty": case "toArray":
                    count(values, 0, 0);
                    terminal = option.equals("toArray");
                    break;
                default: throw failure("Unsupported cursor method: " + option + ". Supported: sort, skip, limit, batchSize, maxTimeMS, pretty, toArray.");
            }
        }
        return command;
    }

    private List<String> arguments() {
        expect('(');
        List<String> arguments = new ArrayList<>();
        if (peek() != ')') {
            do {
                String value = argument(')');
                if (value.isEmpty()) throw failure("Enter a value for each argument.");
                arguments.add(value);
                if (peek() != ',') break;
                position++;
            } while (peek() != ')');
        }
        expect(')');
        return arguments;
    }

    private String argument(char end) {
        StringBuilder value = new StringBuilder();
        Deque<Character> closers = new ArrayDeque<>();
        char previous = 0;
        while (position < source.length()) {
            int before = position;
            trivia();
            if (position != before) value.append(' ');
            if (position == source.length()) break;
            char c = source.charAt(position);
            if (closers.isEmpty() && (c == ',' || c == end)) break;
            if (c == '\'' || c == '"' || (c == '/' && ":,([{".indexOf(previous) >= 0)) {
                int start = position++;
                boolean escaped = false;
                boolean bracket = false;
                boolean closed = false;
                while (position < source.length()) {
                    char next = source.charAt(position++);
                    if (escaped) { escaped = false; continue; }
                    if (next == '\\') { escaped = true; continue; }
                    if (c == '/' && next == '[') bracket = true;
                    else if (c == '/' && next == ']') bracket = false;
                    else if (next == c && !bracket) { closed = true; break; }
                }
                if (!closed) throw failure("Close the string or regular expression.");
                value.append(source, start, position);
                previous = c;
                continue;
            }
            if (c == '(') closers.push(')');
            else if (c == '{') closers.push('}');
            else if (c == '[') closers.push(']');
            else if (c == ')' || c == '}' || c == ']') {
                if (closers.isEmpty() || closers.pop() != c) throw failure("Mismatched query delimiters.");
            }
            value.append(c);
            position++;
            previous = c;
        }
        if (!closers.isEmpty()) throw failure("Complete the query before running it.");
        return value.toString().strip();
    }

    private Document object(String text) {
        if (text.equals("null")) return new Document();
        if (!text.stripLeading().startsWith("{")) throw failure("Query filters, projections and sorts must be document literals.");
        return Document.parse(text);
    }

    private String stringValue(String text) {
        if (!(text.startsWith("\"") || text.startsWith("'"))) throw failure("Use a quoted collection name.");
        Object value = Document.parse("{v:" + text + "}").get("v");
        if (!(value instanceof String name) || name.isEmpty()) throw failure("Enter a collection name.");
        return name;
    }

    private String identifier() {
        trivia();
        int start = position;
        while (position < source.length()) {
            char c = source.charAt(position);
            if (!(Character.isUnicodeIdentifierPart(c) || c == '$')) break;
            position++;
        }
        if (start == position) throw failure("Expected a collection or method name.");
        return source.substring(start, position);
    }

    private char peek() { trivia(); return position < source.length() ? source.charAt(position) : 0; }
    private void expect(char token) { if (peek() != token) throw failure("Expected '" + token + "'."); position++; }
    private void count(List<String> values, int min, int max) {
        if (values.size() < min || values.size() > max) throw failure("Unexpected number of method arguments.");
    }
    private IllegalArgumentException failure(String message) { return new IllegalArgumentException(message); }

    private void trivia() {
        while (position < source.length()) {
            if (Character.isWhitespace(source.charAt(position))) { position++; continue; }
            if (source.startsWith("//", position)) {
                while (position < source.length() && source.charAt(position) != '\n' && source.charAt(position) != '\r') position++;
            } else if (source.startsWith("/*", position)) {
                int end = source.indexOf("*/", position + 2);
                if (end < 0) throw failure("Close the block comment.");
                position = end + 2;
            } else { break; }
        }
    }
}
