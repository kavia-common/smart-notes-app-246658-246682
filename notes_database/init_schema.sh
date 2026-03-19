#!/bin/bash
set -euo pipefail

# Smart Notes PostgreSQL schema initializer (idempotent).
# Reads connection info from db_connection.txt (required by container workflow) and
# creates/updates the schema using safe, repeatable DDL (IF NOT EXISTS / OR REPLACE).

DB_CONNECTION_FILE="db_connection.txt"

if [ ! -f "${DB_CONNECTION_FILE}" ]; then
  echo "ERROR: ${DB_CONNECTION_FILE} not found."
  echo "Run ./startup.sh first to provision PostgreSQL and generate ${DB_CONNECTION_FILE}."
  exit 1
fi

LINE="$(head -n 1 "${DB_CONNECTION_FILE}" | tr -d '\r')"
if [[ "${LINE}" == psql\ * ]]; then
  CONN_URI="${LINE#psql }"
else
  CONN_URI="${LINE}"
fi

# Prefer the system PostgreSQL binary path (matches startup.sh), fall back to PATH.
PG_VERSION="$(ls /usr/lib/postgresql/ 2>/dev/null | head -1 || true)"
if [ -n "${PG_VERSION}" ] && [ -x "/usr/lib/postgresql/${PG_VERSION}/bin/psql" ]; then
  PSQL_BIN="/usr/lib/postgresql/${PG_VERSION}/bin/psql"
else
  PSQL_BIN="psql"
fi

run_sql() {
  local sql="$1"
  "${PSQL_BIN}" "${CONN_URI}" -v ON_ERROR_STOP=1 -c "${sql}"
}

echo "Initializing Smart Notes schema using ${DB_CONNECTION_FILE}..."
echo "Using psql binary: ${PSQL_BIN}"

# --- Metadata -----------------------------------------------------------------
run_sql "CREATE TABLE IF NOT EXISTS app_meta (meta_key TEXT PRIMARY KEY, meta_value TEXT NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run_sql "INSERT INTO app_meta (meta_key, meta_value) VALUES ('schema_version', '1') ON CONFLICT (meta_key) DO NOTHING;"
run_sql "INSERT INTO app_meta (meta_key, meta_value) VALUES ('app_name', 'smart-notes') ON CONFLICT (meta_key) DO NOTHING;"

# --- Utility triggers ----------------------------------------------------------
run_sql "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS \$\$ BEGIN NEW.updated_at = now(); RETURN NEW; END; \$\$ LANGUAGE plpgsql;"

# Notes: bump version + manage deleted_at + updated_at
run_sql "CREATE OR REPLACE FUNCTION notes_before_update() RETURNS trigger AS \$\$ BEGIN NEW.updated_at = now(); NEW.version = COALESCE(OLD.version, 0) + 1; IF NEW.is_deleted AND NOT OLD.is_deleted THEN NEW.deleted_at = COALESCE(NEW.deleted_at, now()); ELSIF NOT NEW.is_deleted THEN NEW.deleted_at = NULL; END IF; RETURN NEW; END; \$\$ LANGUAGE plpgsql;"

# --- Core tables ---------------------------------------------------------------
# Users
run_sql "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email TEXT NOT NULL, password_hash TEXT NOT NULL, display_name TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_login_at TIMESTAMPTZ);"
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_uq ON users ((lower(email)));"

# Sessions (for refresh token / revocation workflows)
run_sql "CREATE TABLE IF NOT EXISTS user_sessions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, refresh_token_hash TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), expires_at TIMESTAMPTZ NOT NULL, revoked_at TIMESTAMPTZ);"
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS user_sessions_refresh_token_hash_uq ON user_sessions (refresh_token_hash);"
run_sql "CREATE INDEX IF NOT EXISTS user_sessions_user_id_idx ON user_sessions (user_id);"

# Per-user settings (theme etc.)
run_sql "CREATE TABLE IF NOT EXISTS user_settings (user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, theme TEXT NOT NULL DEFAULT 'light', created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

# Tags
run_sql "CREATE TABLE IF NOT EXISTS tags (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, name TEXT NOT NULL, color TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS tags_user_name_lower_uq ON tags (user_id, (lower(name)));"
run_sql "CREATE INDEX IF NOT EXISTS tags_user_id_idx ON tags (user_id);"

# Notes
run_sql "CREATE TABLE IF NOT EXISTS notes (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, title TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '', is_pinned BOOLEAN NOT NULL DEFAULT FALSE, is_favorite BOOLEAN NOT NULL DEFAULT FALSE, is_deleted BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ, version BIGINT NOT NULL DEFAULT 0, client_updated_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title,'') || ' ' || coalesce(content,''))) STORED);"
run_sql "CREATE INDEX IF NOT EXISTS notes_user_updated_idx ON notes (user_id, updated_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS notes_user_pinned_idx ON notes (user_id, is_pinned);"
run_sql "CREATE INDEX IF NOT EXISTS notes_user_favorite_idx ON notes (user_id, is_favorite);"
run_sql "CREATE INDEX IF NOT EXISTS notes_user_deleted_idx ON notes (user_id, is_deleted);"
run_sql "CREATE INDEX IF NOT EXISTS notes_search_gin_idx ON notes USING GIN (search_vector);"

# Note <-> Tag join
run_sql "CREATE TABLE IF NOT EXISTS note_tags (note_id UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE, tag_id UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (note_id, tag_id));"
run_sql "CREATE INDEX IF NOT EXISTS note_tags_tag_id_idx ON note_tags (tag_id);"

# Sync state per device (offline-first support)
run_sql "CREATE TABLE IF NOT EXISTS sync_state (user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, device_id TEXT NOT NULL, last_sync_at TIMESTAMPTZ, cursor BIGINT NOT NULL DEFAULT 0, PRIMARY KEY (user_id, device_id));"

# --- Triggers (repeatable: guarded by existence checks) ------------------------
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'users_set_updated_at') THEN CREATE TRIGGER users_set_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tags_set_updated_at') THEN CREATE TRIGGER tags_set_updated_at BEFORE UPDATE ON tags FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'user_settings_set_updated_at') THEN CREATE TRIGGER user_settings_set_updated_at BEFORE UPDATE ON user_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'notes_before_update_trg') THEN CREATE TRIGGER notes_before_update_trg BEFORE UPDATE ON notes FOR EACH ROW EXECUTE FUNCTION notes_before_update(); END IF; END \$\$;"

echo "✓ Smart Notes schema initialization complete."
