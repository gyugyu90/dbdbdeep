# dbdbdeep

A cheerful macOS app for exploring Oracle databases, running SQL, and keeping your favorite queries close. Includes a local SQLite playground to try things out without a server.

**Version 0.2.0**

## Get started

1. Download the DMG for Apple Silicon from [GitHub Releases](https://github.com/gyugyu90/dbdbdeep/releases/latest).
2. Open the DMG and drag **dbdbdeep.app** into **Applications**.
3. Open dbdbdeep from Applications, then eject the disk image.

Requires **macOS 14 or later** on an **Apple Silicon Mac**. Java and the Oracle drivers are included. This early build is locally signed and has not been notarized by Apple.

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

Passwords stay in macOS Keychain. Click the info icon beside **Password** for details.

If connecting fails, **Connection details** shows the attempted settings, progress, and error details. You can copy the report without including your password. For character-set errors such as ORA-17056, enable **Bundled orai18n.jar** under **Driver libraries**. It's on by default. Use **Add JAR…** for additional libraries; keep those files at their selected locations.

## Run queries

- Place the cursor in a SQL statement and click **Run statement** or press `⌘↵` to run just that statement. In the whitespace between statements or after the final query, both Run statement and bookmarking target the nearest statement before the cursor. Separate statements with semicolons. Selecting text switches to **Run selection**, which runs only the selected text. Oracle accepts one SQL statement or PL/SQL block at a time.
- Schema suggestions appear as you type: tables after `FROM` or `JOIN`, and columns in expressions such as `SELECT` and `WHERE`. Table aliases work too (`c.`). Use `↑`/`↓` to choose, `Tab` or `Return` to insert, `Esc` to close, or `Control-Space` to request suggestions. Connect first to load your Oracle schema.
- Before running SQL, the app checks the session and reconnects if needed. If the connection fails during execution, the query is not automatically repeated; check the outcome before running it again.
- Changes use **manual commit**. Press `⌘⇧↵` to commit, or choose **Query → Rollback changes** to undo uncommitted changes. Oracle DDL follows its [implicit commit rules](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/COMMIT.html).
- Results show up to 1,000 rows. Filter the fetched rows, double-click a value to copy it, or press `⌘⇧E` to export them as CSV. Export includes all fetched rows, regardless of the filter; long Oracle text values are previews.
- Click a column name to toggle ascending/descending sorting for that column. Drag its right edge to resize it, or its left handle to reorder columns. These adjustments apply to fetched results and reset with each new result; CSV export keeps the original query order.
- Open **History** to reload a recent query without running it.

## Save favorite queries

Each connection has its own library. Press `⌘D` to bookmark the statement at the cursor, or the previous statement when the cursor is between queries. Each bookmark holds one SQL statement or PL/SQL block, with a name, color, and emoji, and belongs to the selected connection. A filled bookmark button means it's already saved in this connection; click it to edit. The matching library card is highlighted as you move the cursor. Click a card to focus its query in the console; if missing, the query is appended without replacing your work. Click the card’s play button to run only that saved query, or right-click to edit, copy, or delete it.

Older bookmarks without a connection, and bookmarks from removed connections, stay under **Unassigned queries**. Select a connection and click **Move here** to add one to its library.

Connections, bookmarks, and query drafts are saved locally. History and results last for the current app session.

## Make it yours

Choose **View → Appearance → Use System Setting**, **Light**, or **Dark**. The default follows macOS, and your choice is remembered. Dark mode gives the mascot and Dock icon little pink devil horns.

Drag the panel dividers to resize the workspace. Both sidebars can expand to about one-third of the window. Toggle bookmarks with the top-right sidebar button, and double-click the header to maximize or restore the window.
