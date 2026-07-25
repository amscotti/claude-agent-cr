# Reference Postgres SessionStore (not compiled into the main shard).
#
# Requires the `pg` shard:
#
#   dependencies:
#     pg:
#       github: will/crystal-pg
#
# Schema (one row per JSONL entry; order via BIGSERIAL), matching the TS example:
#
#   CREATE TABLE claude_session_entries (
#     id          BIGSERIAL PRIMARY KEY,
#     project_key TEXT NOT NULL,
#     session_id  TEXT NOT NULL,
#     subpath     TEXT,
#     entry       JSONB NOT NULL,
#     created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
#   );
#   CREATE INDEX ON claude_session_entries (project_key, session_id, subpath, id);
#
# Usage sketch:
#
#   require "pg"
#   db = DB.open("postgres://…")
#   store = PostgresSessionStore.new(db)
#   store.ensure_schema
#   ClaudeAgent::SessionStoreConformance.run(store)

require "../../src/claude-agent-cr"
require "json"

module Examples
  # Minimal DB surface (adapt to crystal-pg / DB.pool).
  abstract class SqlDB
    abstract def exec(query : String, *args)
    abstract def query_all(query : String, *args, as type : T.class) forall T
  end

  class PostgresSessionStore < ClaudeAgent::SessionStore
    def initialize(@db : SqlDB, @table : String = "claude_session_entries")
      unless @table.matches?(/^[A-Za-z_][A-Za-z0-9_]*$/)
        raise ArgumentError.new("invalid table name: #{@table}")
      end
    end

    def ensure_schema : Nil
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS #{@table} (
          id          BIGSERIAL PRIMARY KEY,
          project_key TEXT NOT NULL,
          session_id  TEXT NOT NULL,
          subpath     TEXT,
          entry       JSONB NOT NULL,
          created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      SQL
      @db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS #{@table}_key_idx
          ON #{@table} (project_key, session_id, subpath, id)
      SQL
    end

    def append(key : ClaudeAgent::SessionKey, entries : Array(ClaudeAgent::SessionStoreEntry)) : Nil
      return if entries.empty?

      entries.each do |entry|
        @db.exec(
          "INSERT INTO #{@table} (project_key, session_id, subpath, entry) VALUES ($1,$2,$3,$4::jsonb)",
          key.project_key,
          key.session_id,
          key.subpath,
          entry.to_h.to_json,
        )
      end
    end

    def load(key : ClaudeAgent::SessionKey) : Array(ClaudeAgent::SessionStoreEntry)?
      # IS NOT DISTINCT FROM matches NULL subpath for main transcripts.
      rows = @db.query_all(
        "SELECT entry::text FROM #{@table}
           WHERE project_key = $1 AND session_id = $2
             AND subpath IS NOT DISTINCT FROM $3
           ORDER BY id",
        key.project_key,
        key.session_id,
        key.subpath,
        as: String,
      )
      return nil if rows.empty?

      rows.compact_map do |line|
        h = JSON.parse(line).as_h?
        ClaudeAgent::SessionStoreEntry.from_hash(h) if h
      end
    end

    def list_sessions(project_key : String) : Array(ClaudeAgent::SessionStoreListEntry)
      # Implement with: SELECT session_id, EXTRACT(EPOCH FROM MAX(created_at))*1000
      # WHERE project_key=$1 AND subpath IS NULL GROUP BY session_id
      [] of ClaudeAgent::SessionStoreListEntry
    end

    def delete(key : ClaudeAgent::SessionKey) : Nil
      if key.subpath
        @db.exec(
          "DELETE FROM #{@table} WHERE project_key=$1 AND session_id=$2 AND subpath=$3",
          key.project_key, key.session_id, key.subpath,
        )
      else
        @db.exec(
          "DELETE FROM #{@table} WHERE project_key=$1 AND session_id=$2",
          key.project_key, key.session_id,
        )
      end
    end

    def list_subkeys(key : ClaudeAgent::SessionListSubkeysKey) : Array(String)
      # SELECT DISTINCT subpath WHERE project_key=$1 AND session_id=$2 AND subpath IS NOT NULL
      [] of String
    end

    def supports_list_sessions? : Bool
      true
    end

    def supports_delete? : Bool
      true
    end

    def supports_list_subkeys? : Bool
      true
    end
  end
end

puts "PostgresSessionStore is a reference adapter."
puts "Wire crystal-pg and complete list_sessions/list_subkeys queries for production."
