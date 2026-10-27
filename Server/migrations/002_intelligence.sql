CREATE TABLE issues(id TEXT PRIMARY KEY, category TEXT NOT NULL, segment_id TEXT NOT NULL, side TEXT NOT NULL, level TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL, first_observed REAL NOT NULL, last_observed REAL NOT NULL, expires_at REAL NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1, updated_at REAL NOT NULL, merged_into TEXT REFERENCES issues(id));
CREATE TABLE issue_members(report_id TEXT PRIMARY KEY REFERENCES reports(id), issue_id TEXT NOT NULL REFERENCES issues(id));
CREATE INDEX issue_member_issue ON issue_members(issue_id);
CREATE TABLE confirmations(issue_id TEXT NOT NULL REFERENCES issues(id), user_id TEXT NOT NULL REFERENCES users(id), observed_at REAL NOT NULL, expires_at REAL NOT NULL, PRIMARY KEY(issue_id,user_id));
CREATE TABLE issue_audit(id INTEGER PRIMARY KEY AUTOINCREMENT, issue_id TEXT NOT NULL REFERENCES issues(id), actor_id TEXT NOT NULL, action TEXT NOT NULL, reason TEXT NOT NULL, at REAL NOT NULL);
CREATE TABLE issue_merges(source_id TEXT PRIMARY KEY REFERENCES issues(id), target_id TEXT NOT NULL REFERENCES issues(id), report_ids TEXT NOT NULL, undone INTEGER NOT NULL DEFAULT 0);
CREATE TABLE report_applicability(report_id TEXT PRIMARY KEY REFERENCES reports(id), active INTEGER NOT NULL);
PRAGMA user_version=2;
