"""Run the production SQL from both native sources against an in-memory fixture."""
import pathlib
import re
import sqlite3

root = pathlib.Path(__file__).resolve().parents[1]
for platform, path in [
    ('Windows', 'src/windows/WorkBuddyMonitor.cs'),
    ('macOS', 'src/macos/Sources/AgentHaloCore/WorkBuddyMonitor.swift'),
]:
    if not (root / path).exists():
        print(f'SKIP {platform}: monitor is not present on this branch')
        continue
    source = (root / path).read_text()
    # Query literals deliberately contain no native-code logic. Exercise exactly
    # that SQL with IDs encoded the same way as the platform's query builder.
    if platform == 'Windows':
        match = re.search(r'internal const string SessionQueryTemplate = @"(.*?)";', source, re.S)
        if match:
            template = match[1].replace('""', '"')
        else:
            query = re.search(r'db.QueryRows\((.*?), 8\)', source, re.S)[1]
            template = ''.join(re.findall(r'"([^"]*)"', query))
    else:
        template = re.search(r'(?:sessionQuery|sessionQueryTemplate) = """\n(.*?)\n    """', source, re.S)[1]
    db = sqlite3.connect(':memory:')
    db.executescript('''CREATE TABLE sessions (id TEXT PRIMARY KEY, status TEXT, custom_title TEXT,
        title TEXT, cwd TEXT, model TEXT, updated_at INTEGER, deleted_at INTEGER);
        CREATE TABLE session_usage(session_id TEXT, used INTEGER, size INTEGER);''')
    live_ids = ["live", "waiting-'雪'); DROP TABLE sessions; --"]
    for index, session_id in enumerate(live_ids):
        db.execute('INSERT INTO sessions VALUES (?, ?, NULL, ?, ?, ?, ?, NULL)',
                   (session_id, ['working', 'waiting_permission'][index], 'Live', '/work', 'model', 1000))
    for i in range(80):
        db.execute('INSERT INTO sessions VALUES (?, ?, NULL, ?, ?, ?, ?, NULL)',
                   (f'history-{i}', 'completed', 'History', '/work', 'model', 2000 + i))
    db.execute("INSERT INTO sessions VALUES ('deleted', 'working', NULL, 'Deleted', '/work', 'model', 3000, 1)")
    ids = ','.join("CAST(X'" + value.encode().hex() + "' AS TEXT)" for value in live_ids + ['deleted'])
    rows = db.execute(template.replace('{0}', ids)).fetchall()
    actual = {row[0] for row in rows}
    assert set(live_ids) <= actual, f'{platform}: newer history hid live sessions'
    assert 'deleted' not in actual
    assert len(rows) == 66, f'{platform}: expected two live + 64 history rows, got {len(rows)}'
    assert len(db.execute(template.replace('{0}', 'SELECT NULL WHERE 0')).fetchall()) == 64
    print(f'PASS {platform}: live SQL selection, 80 histories, deleted IDs, SQL metacharacters, empty live set')
