import com.mongodb.*;
import com.mongodb.client.*;
import org.bson.*;
import org.bson.json.JsonMode;
import org.bson.json.JsonWriterSettings;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.logging.*;

public final class MongoBridge {
    private static final DataInputStream input = new DataInputStream(System.in);
    private static final DataOutputStream output = new DataOutputStream(System.out);
    private static final int ROW_LIMIT = 1000;
    private static final JsonWriterSettings documentJSON = JsonWriterSettings.builder().outputMode(JsonMode.EXTENDED).build();

    private static String read() throws IOException {
        int size = input.readInt();
        if (size < 0 || size > 32_000_000) throw new IOException("Invalid request size");
        byte[] bytes = input.readNBytes(size);
        if (bytes.length != size) throw new EOFException();
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static void send(Document frame) throws IOException {
        byte[] bytes = frame.toJson().getBytes(StandardCharsets.UTF_8);
        if (bytes.length > 64_000_000) throw new IOException("Response exceeds 64 MB; narrow the query projection or limit.");
        output.writeInt(bytes.length);
        output.write(bytes);
        output.flush();
    }

    private static void event(String stage, String message) throws IOException {
        send(new Document("event", new Document("stage", stage).append("level", "info").append("message", message)));
    }

    private static Document result(String message) {
        return new Document("columns", List.of()).append("rows", List.of()).append("affected", 0)
            .append("elapsed", 0.0).append("truncated", false).append("message", message);
    }

    private static String cell(BsonValue value) {
        if (value == null || value.isNull()) return null;
        if (value.isString()) return value.asString().getValue();
        String wrapped = new BsonDocument("v", value).toJson();
        return wrapped.substring(wrapped.indexOf(':') + 1, wrapped.length() - 1).strip();
    }

    static Document grid(List<BsonDocument> documents, boolean truncated) {
        LinkedHashSet<String> names = new LinkedHashSet<>();
        for (BsonDocument document : documents) names.addAll(document.keySet());
        List<List<String>> rows = new ArrayList<>();
        for (BsonDocument document : documents) {
            List<String> row = new ArrayList<>();
            for (String name : names) {
                String value = cell(document.get(name));
                row.add(value != null && value.length() > 16384 ? value.substring(0, 16384) + "…" : value);
            }
            rows.add(row);
        }
        List<String> originals = documents.stream().map(document -> document.toJson(documentJSON)).toList();
        return result("Query completed").append("columns", new ArrayList<>(names)).append("rows", rows)
            .append("documents", originals).append("truncated", truncated);
    }

    private static Document collect(MongoIterable<BsonDocument> iterable) {
        List<BsonDocument> documents = new ArrayList<>();
        boolean truncated = false;
        long characters = 0;
        try (MongoCursor<BsonDocument> cursor = iterable.iterator()) {
            while (documents.size() < ROW_LIMIT && cursor.hasNext()) {
                BsonDocument document = cursor.next();
                long size = document.toJson(documentJSON).length();
                if (!documents.isEmpty() && characters + size > 16_000_000) { truncated = true; break; }
                documents.add(document);
                characters += size;
            }
            truncated = truncated || cursor.hasNext();
        }
        return grid(documents, truncated);
    }

    private static void allowed(Document command, String... fields) {
        Set<String> supported = new HashSet<>(Arrays.asList(fields));
        for (String key : command.keySet()) {
            if (!supported.contains(key)) throw new IllegalArgumentException("Unsupported option for this command: " + key);
        }
    }

    private static Document execute(MongoDatabase database, String json) {
        long start = System.nanoTime();
        Document command = MongoShellQuery.command(json);
        if (command.isEmpty()) throw new IllegalArgumentException("Enter one MongoDB command as a JSON object.");
        Document response;
        String operation = command.keySet().iterator().next();
        if (operation.equals("find")) {
            allowed(command, "find", "filter", "projection", "sort", "skip", "limit", "batchSize", "maxTimeMS");
            int limit = ((Number) command.getOrDefault("limit", 0)).intValue();
            if (limit < 0) throw new IllegalArgumentException("limit must be zero or positive.");
            FindIterable<BsonDocument> find = database.getCollection(command.getString("find"), BsonDocument.class)
                .find(command.get("filter", new Document()))
                .limit(limit == 0 ? ROW_LIMIT + 1 : Math.min(limit, ROW_LIMIT + 1))
                .maxTime(((Number) command.getOrDefault("maxTimeMS", 60000)).longValue(), TimeUnit.MILLISECONDS);
            if (command.containsKey("projection")) find.projection(command.get("projection", Document.class));
            if (command.containsKey("sort")) find.sort(command.get("sort", Document.class));
            if (command.containsKey("skip")) find.skip(((Number) command.get("skip")).intValue());
            if (command.containsKey("batchSize")) find.batchSize(((Number) command.get("batchSize")).intValue());
            response = collect(find);
        } else if (operation.equals("aggregate") && command.get("aggregate") instanceof String) {
            allowed(command, "aggregate", "pipeline", "cursor", "allowDiskUse", "maxTimeMS");
            AggregateIterable<BsonDocument> aggregate = database.getCollection(command.getString("aggregate"), BsonDocument.class)
                .aggregate(command.getList("pipeline", Document.class))
                .maxTime(((Number) command.getOrDefault("maxTimeMS", 60000)).longValue(), TimeUnit.MILLISECONDS);
            if (command.containsKey("allowDiskUse")) aggregate.allowDiskUse(command.getBoolean("allowDiskUse"));
            if (command.containsKey("cursor")) {
                Document cursor = command.get("cursor", Document.class);
                allowed(cursor, "batchSize");
                if (cursor.containsKey("batchSize")) aggregate.batchSize(((Number) cursor.get("batchSize")).intValue());
            }
            response = collect(aggregate);
        } else {
            BsonDocument output = database.runCommand(command, BsonDocument.class);
            if (output.containsKey("writeErrors") || output.containsKey("writeConcernError")) {
                throw new IllegalStateException("MongoDB reported a write error. Inspect the command outcome before retrying: " + output.toJson());
            }
            response = grid(List.of(output), false);
            if (output.get("n") instanceof BsonNumber count) response.put("affected", count.intValue());
        }
        response.put("elapsed", (System.nanoTime() - start) / 1e9);
        return response;
    }

    private static Document schema(MongoDatabase database) {
        List<List<String>> rows = new ArrayList<>();
        try (MongoCursor<String> collections = database.listCollectionNames().iterator()) {
            while (collections.hasNext()) {
                if (rows.size() == 100_000) throw new IllegalStateException("More than 100,000 collections; narrow the database.");
                rows.add(List.of(collections.next()));
            }
        }
        rows.sort(Comparator.comparing(row -> row.get(0)));
        return result("Collections loaded").append("columns", List.of("name")).append("rows", rows);
    }

    private static void inspectFields(BsonDocument document, String prefix, int depth, Map<String, SortedSet<String>> fields) {
        if (depth > 4) return;
        for (Map.Entry<String, BsonValue> entry : document.entrySet()) {
            if (fields.size() >= 500) return;
            String name = prefix.isEmpty() ? entry.getKey() : prefix + "." + entry.getKey();
            if (name.length() > 512) continue;
            BsonValue value = entry.getValue();
            fields.computeIfAbsent(name, key -> new TreeSet<>()).add(value.getBsonType().name());
            if (value.isDocument()) inspectFields(value.asDocument(), name, depth + 1, fields);
            else if (value.isArray()) {
                int count = 0;
                for (BsonValue item : value.asArray()) {
                    if (++count > 3) break;
                    if (item.isDocument()) inspectFields(item.asDocument(), name, depth + 1, fields);
                }
            }
        }
    }

    private static Document fields(MongoDatabase database, String collection) {
        Map<String, SortedSet<String>> fields = new TreeMap<>();
        FindIterable<BsonDocument> sample = database.getCollection(collection, BsonDocument.class)
            .find().limit(10).batchSize(10).maxTime(1500, TimeUnit.MILLISECONDS);
        try (MongoCursor<BsonDocument> cursor = sample.iterator()) {
            while (cursor.hasNext() && fields.size() < 500) inspectFields(cursor.next(), "", 0, fields);
        }
        List<List<String>> rows = new ArrayList<>();
        fields.forEach((name, types) -> rows.add(List.of(name, String.join(" | ", types))));
        return result("Sampled field names and types").append("columns", List.of("name", "type")).append("rows", rows);
    }

    static MongoClientSettings settings(Document config) {
        ConnectionString uri = new ConnectionString(config.getString("uri"));
        if (uri.getCredential() != null) throw new IllegalArgumentException("Enter credentials in the separate username and password fields.");
        MongoClientSettings.Builder builder = MongoClientSettings.builder().applyConnectionString(uri)
            .applicationName("dbdbdeep").retryReads(false).retryWrites(false)
            .applyToClusterSettings(value -> value.serverSelectionTimeout(10, TimeUnit.SECONDS))
            .applyToSocketSettings(value -> value.connectTimeout(8, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS));
        String username = config.getString("username");
        if (username != null && !username.isEmpty()) {
            builder.credential(MongoCredential.createCredential(username, config.getString("authSource"), config.getString("password").toCharArray()));
        }
        return builder.build();
    }

    private static Document failure(Throwable error, String stage, String password) {
        String message = Objects.toString(error.getMessage(), error.getClass().getSimpleName());
        if (!password.isEmpty()) message = message.replace(password, "[REDACTED]");
        return new Document("error", message).append("stage", stage)
            .append("errorCode", error instanceof MongoException mongo ? mongo.getCode() : null);
    }

    private static void selfTest() {
        MongoShellQuery.selfTest();
        Document config = new Document("uri", "mongodb://localhost:27017/?tls=false").append("username", "app")
            .append("password", "s:e@cret").append("authSource", "admin");
        MongoClientSettings settings = settings(config);
        if (!settings.getCredential().getSource().equals("admin") || settings.getRetryWrites()) throw new AssertionError("Credential settings");
        Document multi = new Document(config).append("uri", "mongodb://one.example.com:27017,two.example.com:27018,three.example.com:27019/app?authSource=app")
            .append("authSource", "app");
        MongoClientSettings replica = settings(multi);
        if (replica.getClusterSettings().getHosts().size() != 3 || !replica.getCredential().getSource().equals("app")) throw new AssertionError("Seed list and auth source");
        Document result = grid(List.of(BsonDocument.parse("{\"name\":\"한글 🌱\",\"nested\":{\"x\":1},\"nil\":null}"), BsonDocument.parse("{\"extra\":true}")), true);
        if (!result.getList("columns", String.class).equals(List.of("name", "nested", "nil", "extra"))) throw new AssertionError("Columns");
        if (!result.getList("rows", List.class).get(0).get(0).equals("한글 🌱")) throw new AssertionError("Unicode");
        BsonDocument typed = BsonDocument.parse("{\"large\":{\"$numberLong\":\"9223372036854775807\"},\"decimal\":{\"$numberDecimal\":\"1234.567890123456789012345678901234\"},\"date\":{\"$date\":{\"$numberLong\":\"0\"}},\"nested\":{\"items\":[1,null,{}]},\"text\":\"" + "x".repeat(20000) + "\"}");
        Document tree = grid(List.of(typed, new BsonDocument("missing", BsonNull.VALUE)), false);
        if (!BsonDocument.parse(tree.getList("documents", String.class).get(0)).equals(typed)) throw new AssertionError("Document BSON round-trip");
        if (tree.getList("documents", String.class).get(0).length() < 20000) throw new AssertionError("Full document values");
        if (!grid(List.of(new BsonDocument()), false).getList("documents", String.class).equals(List.of("{}"))) throw new AssertionError("Empty document");
        if (!failure(new Exception("s:e@cret"), "connecting", "s:e@cret").getString("error").equals("[REDACTED]")) throw new AssertionError("Redaction");
        Map<String, SortedSet<String>> fields = new TreeMap<>();
        inspectFields(BsonDocument.parse("{\"nested\":{\"city\":\"Seoul\"},\"items\":[{\"price\":2}],\"mixed\":1}"), "", 0, fields);
        inspectFields(BsonDocument.parse("{\"mixed\":\"one\"}"), "", 0, fields);
        if (!fields.containsKey("nested.city") || !fields.containsKey("items.price") || fields.get("mixed").size() != 2) throw new AssertionError("Sampled fields");
        System.out.println("MongoDB settings, BSON grid and redaction passed.");
    }

    public static void main(String[] args) throws Exception {
        Logger.getLogger("org.mongodb.driver").setLevel(Level.OFF);
        if (args.length > 0 && args[0].equals("--self-test")) { selfTest(); return; }
        MongoClient client = null;
        String password = "";
        String stage = "driver";
        try {
            Document config = Document.parse(read());
            password = config.getString("password");
            event("driver", "Bundled MongoDB Java sync driver loaded.");
            MongoClientSettings settings = settings(config);
            stage = "connecting";
            event(stage, "Connecting and authenticating; server selection timeout 10s.");
            client = MongoClients.create(settings);
            MongoDatabase database = client.getDatabase(config.getString("database"));
            stage = "verification";
            event(stage, "Running {\"ping\": 1} on the selected database.");
            database.runCommand(new Document("ping", 1));
            send(result("MongoDB connection verified"));
            while (true) {
                String action;
                try { action = read(); } catch (EOFException end) { break; }
                String text = read();
                try {
                    switch (action) {
                        case "execute": send(execute(database, text)); break;
                        case "schema": send(schema(database)); break;
                        case "fields": send(fields(database, text)); break;
                        case "validate": database.runCommand(new Document("ping", 1)); send(result("Connection valid")); break;
                        default: throw new IllegalArgumentException("Unsupported MongoDB action: " + action);
                    }
                } catch (Exception error) { send(failure(error, action.equals("schema") ? "schema" : "session", password)); }
            }
        } catch (Exception error) { send(failure(error, stage, password)); }
        finally { if (client != null) client.close(); }
    }
}
