# dbdbdeep

A cheerful macOS app for exploring Oracle and MongoDB databases, running queries, and keeping your favorite queries close. Includes a local SQLite playground to try things out without a server.

**Version 0.3.3**

## Get started

1. Download the DMG for Apple Silicon from [GitHub Releases](https://github.com/gyugyu90/dbdbdeep/releases/latest).
2. Open the DMG and drag **dbdbdeep.app** into **Applications**.
3. Open dbdbdeep from Applications, then eject the disk image.

Requires **macOS 14 or later** on an **Apple Silicon Mac**. Java and the database drivers are included. This early build is locally signed and has not been notarized by Apple.

Your first launch opens **Little playground**, with sample tables ready to explore.

<details>
<summary>Build from source instead</summary>

You'll need macOS 14+, Xcode or Command Line Tools with Swift 5.10+, JDK 21 discoverable by `/usr/libexec/java_home -v 21`, and internet access for the first build.

```sh
git clone https://github.com/gyugyu90/dbdbdeep.git
cd dbdbdeep
./scripts/build-app.sh
open build/dbdbdeep.app
```

</details>

## Connect to Oracle

1. Click **Add connection** or press `⌘N`.
2. Enter the host, port, service name or SID, username, and password.
3. Click **Test connection**, then **Save & connect**.

Your tables, views, and columns appear in the left sidebar. Click a table to preview up to 100 rows. Right-click a connection to edit, remove, or reconnect. Running a query opens a saved connection automatically when needed, including after an idle session expires.

Expand an Oracle table or view to see its columns. Column comments appear below each name in smaller text; hover over a column to read the full comment. Use **Refresh schema** after changing comments in the database.

Table and collection previews keep your console text. The preview query is appended or focused if it already exists, and only that query runs. If the console has an unfinished statement or no room within the line limit, the preview runs without changing the editor.

Passwords stay in macOS Keychain. Click the info icon beside **Password** for details.

If connecting fails, **Connection details** shows the attempted settings, progress, and error details. You can copy the report without including your password. For character-set errors such as ORA-17056, enable **Bundled orai18n.jar** under **Driver libraries**. It's on by default. Use **Add JAR…** for additional libraries; keep those files at their selected locations.

## Connect to MongoDB

1. Click **Add connection** and select **MongoDB**.
2. Paste your connection string into **Connection URI** and click **Import URI**, or enter the hosts, default port (`27017`), and database manually. Multiple hosts can be separated by commas, with a separate `:port` for each host. The URI importer supports `authSource`, `tls`/`ssl`, and `replicaSet`; unsupported options are reported.
3. Add a username and password when authentication is enabled. **Authentication DB** is optional: leave it blank to use the selected database, or enter the database where the user was created (for example `admin`). A URI with no database or `authSource` defaults authentication to `admin`. Leave credentials blank for a server without authentication.
4. Enable **TLS** if required. For Atlas, use the cluster hostname and enable **DNS SRV (Atlas)**; TLS is enabled automatically and the port is discovered. Set **Replica set** when needed.
5. Click **Test connection**, then **Save & connect**. Click a collection in the left sidebar to preview its documents.

The console accepts familiar [MongoDB find queries](https://www.mongodb.com/docs/manual/reference/method/db.collection.find/):

```javascript
db.customers.find({status: 'active'}).sort({name: 1}).limit(100)
```

Supported helpers are `find()` and `findOne()`, including the optional projection argument, `db.getCollection("name")`, and `db["name"]`. `find()` supports `.sort()`, `.skip()`, `.limit()`, `.batchSize()`, `.maxTimeMS()`, `.pretty()`, and `.toArray()`. Document literals can use unquoted field names, single-quoted strings, `ObjectId()`, `ISODate()`, and regular expressions. Each complete query can be run or bookmarked at the cursor. The console supports these query helpers rather than general JavaScript programs.

[JSON commands](https://www.mongodb.com/docs/manual/reference/command/) and `db.runCommand({...})` also work:

```json
{"find": "customers", "filter": {"status": "active"}, "limit": 100}
```

Use JSON `insert`, `update`, and `delete` commands for writes, or `aggregate` with a pipeline. Put the command name first. Each command can be saved in the connection’s library. The app shows up to 1,000 documents. The `find` command supports `filter`, `projection`, `sort`, `skip`, `limit`, `batchSize`, and `maxTimeMS`; `aggregate` supports `pipeline`, `cursor.batchSize`, `allowDiskUse`, and `maxTimeMS`.

MongoDB results open in **Tree** view. Expand or collapse documents, objects, and arrays with the disclosure arrows; BSON types such as ObjectId, Date, Int64, and Decimal128 stay distinguishable. Select a field to inspect or copy its value. Switch between **Table** and **Tree** above the results without rerunning the query; your view preference and expanded branches are retained while browsing the same result. Filtering searches the fetched documents, including nested fields. Table cells show previews of long values; Tree retains the full fetched values. Details load in the background as a compact preview of up to 4,096 characters, with limits on depth and entries. **Copy value** prepares the full selected value in the background when clicked.

Autocomplete suggests collections after `db.` or inside `getCollection("…")`, supported helper methods, and fields in filters, projections, and sorts. JSON command collection names and field keys work too. Matches are ranked like SQL suggestions; use `↑`/`↓` and `Tab`/`Return`, or request suggestions with `Control-Space`. Connect first. Field suggestions sample up to 10 documents from the collection being edited and cache names and types for one minute; fields missing from that sample may not appear. Nested fields use dotted paths.

**MongoDB writes are applied immediately.** Manual commit, rollback, and multi-command transactions are unavailable.

## Run queries

- The query console supports up to 100,000 lines. Longer input is truncated with a warning.
- Press `⌘F` or click the console's magnifying glass to search; `⌘G` / `⇧⌘G` move to the next / previous match, and `Esc` closes search. Shortcuts work with Korean input enabled too.
- Use `⌘/` or `⌘-` to toggle `-- ` comments on selected lines, and `Tab` / `Shift-Tab` to indent / outdent them by four spaces.
- Place the cursor in a SQL statement and click **Run statement** or press `⌘↵` (Return or keypad Enter) to run just that statement. In the whitespace between statements or after the final query, both Run statement and bookmarking target the nearest statement before the cursor. Separate statements with semicolons. Selecting text switches to **Run selection**, which runs only the selected text. Oracle accepts one SQL statement or PL/SQL block at a time.
- Schema suggestions appear as you type: tables after `FROM` or `JOIN`, and columns in expressions such as `SELECT` and `WHERE`. Table aliases work too (`c.`). Use `↑`/`↓` to choose, `Tab` or `Return` to insert, `Esc` to close, or `Control-Space` to request suggestions. Connect first to load your Oracle schema.
- Before running SQL, the app checks the session and reconnects if needed. If the connection fails during execution, the query is not automatically repeated; check the outcome before running it again.
- Oracle and SQLite changes use **manual commit**. Press `⌘⇧↵` to commit, or choose **Query → Rollback changes** to undo uncommitted changes. Oracle DDL follows its [implicit commit rules](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/COMMIT.html).
- Results preview up to 1,000 rows. Filter the fetched rows or double-click a value to copy it; long Oracle text values are previews.
- For Oracle and SQLite SELECT results, press `⌘⇧E` or choose **Export all query rows as CSV…** from the export menu to read every row through a database cursor. The original SELECT runs again on the same connection; explicit `LIMIT` and `FETCH FIRST` clauses still apply. Progress shows the processed row count. Long text/CLOB values are exported in full, nulls become empty fields, and binary values use `0x` hexadecimal text. The destination is replaced only after a successful export. **Export fetched rows as CSV…** saves the current preview without rerunning the query; this is also the available CSV export for MongoDB results.
- Click a column name to toggle ascending/descending sorting for that column. Drag its right edge to resize it, or its left handle to reorder columns. These adjustments apply to fetched results and reset with each new result; CSV export keeps the original query order.
- Hover over a result column name to see its data type and the available source column comment.
- Drag across grid cells to select a purple rectangle; the grid scrolls at the edges while dragging. Press `⌘C` to copy the selection as TSV, or right-click and choose **Copy selection as CSV**. Only selected values are copied, in the displayed row and column order, with no headers; nulls become empty fields. Sorting, filtering, moving columns, or refreshing results clears the selection.
- Open **History** to reload a recent query without running it.
- With focus inside **Results**, press `⌘R` or click its refresh button to rerun the query that produced that result. Editing the console or moving its cursor does not change the refresh target. `⌘⇧R` still refreshes the schema.

## Save favorite queries

Each connection has its own library. Press `⌘D` to bookmark the statement at the cursor, or the previous statement when the cursor is between queries. Each bookmark holds one SQL statement or PL/SQL block, with a name, color, and emoji, and belongs to the selected connection. A filled bookmark button means it's already saved in this connection; click it to edit. The matching library card is highlighted as you move the cursor. Click a card to focus its query in the console; if missing, the query is appended without replacing your work. Click the card’s play button to run only that saved query, or right-click to edit, copy, or delete it.

Older bookmarks without a connection, and bookmarks from removed connections, stay under **Unassigned queries**. Select a connection and click **Move here** to add one to its library.

Saving a bookmark adds `/* emoji title */` above its query, including the matching query in the console. Renaming it updates the title comment.

Connections, bookmarks, and query drafts are saved locally. History and results last for the current app session.

Console text also autosaves separately after a brief pause in typing, and reopens for each connection. Safety copies live in `~/Library/Application Support/DBDeep/ConsoleDrafts/`: `current.json`, `previous.json`, and up to 20 checkpoints in `History`. Checkpoints are kept about every five minutes of saved edits and before clearing a console. If the current file is damaged, the app tries the previous copy and checkpoints. Removing a connection keeps its console safety copy.

## Make it yours

Choose **View → Appearance → Use System Setting**, **Light**, or **Dark**. The default follows macOS, and your choice is remembered. Dark mode gives the mascot and Dock icon little pink devil horns.

Drag the panel dividers to resize the workspace. Both sidebars can expand to about one-third of the window. Toggle bookmarks with the top-right sidebar button, and double-click the header to maximize or restore the window.
