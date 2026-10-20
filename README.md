# dbdbdeep

A cheerful macOS app for exploring Oracle databases, running SQL, and keeping your favorite queries close. Includes a local SQLite playground to try things out without a server.

**Version 0.1.1**

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

- Place the cursor in a SQL statement and click **Run statement** or press `⌘↵` to run just that statement. Separate statements with semicolons. Selecting text switches to **Run selection**, which runs only the selected text. Oracle accepts one SQL statement or PL/SQL block at a time.
- Schema suggestions appear as you type: tables after `FROM` or `JOIN`, and columns in expressions such as `SELECT` and `WHERE`. Table aliases work too (`c.`). Use `↑`/`↓` to choose, `Tab` or `Return` to insert, `Esc` to close, or `Control-Space` to request suggestions. Connect first to load your Oracle schema.
- Before running SQL, the app checks the session and reconnects if needed. If the connection fails during execution, the query is not automatically repeated; check the outcome before running it again.
- Changes use **manual commit**. Press `⌘⇧↵` to commit, or choose **Query → Rollback changes** to undo uncommitted changes. Oracle DDL follows its [implicit commit rules](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/COMMIT.html).
- Results show up to 1,000 rows. Filter the fetched rows, double-click a value to copy it, or press `⌘⇧E` to export them as CSV. Export includes all fetched rows, regardless of the filter; long Oracle text values are previews.
- Open **History** to reload a recent query without running it.

## Save favorite queries

Press `⌘D` to bookmark SQL with a name, color, emoji, and optional connection. Click a bookmark to load it; it won't run automatically. Search or filter your bookmarks, and right-click to edit, copy, or delete them.

Connections, bookmarks, and query drafts are saved locally. History and results last for the current app session.

## Make it yours

Choose **View → Appearance → Use System Setting**, **Light**, or **Dark**. The default follows macOS, and your choice is remembered. Dark mode gives the mascot and Dock icon little pink devil horns.

Drag the panel dividers to resize the workspace. The left sidebar can expand to about one-third of the window. Toggle bookmarks with the top-right sidebar button, and double-click the header to maximize or restore the window.
