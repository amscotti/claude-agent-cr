# Reference Redis SessionStore (not compiled into the main shard).
#
# Requires the `redis` shard:
#
#   dependencies:
#     redis:
#       github: stefanwille/crystal-redis
#
# Key scheme (matches the TypeScript RedisSessionStore example):
#   {prefix}{project}:{session}              — LIST of JSON entries (main)
#   {prefix}{project}:{session}:{subpath}    — LIST for subkeys
#   {prefix}{project}:{session}:__subkeys    — SET of subpaths
#   {prefix}{project}:__sessions             — ZSET sessionId → mtime_ms
#
# Usage sketch:
#
#   require "redis"
#   # paste/adapt this class into your app
#   client = Redis.new(host: "127.0.0.1", port: 6379)
#   store = RedisSessionStore.new(client, prefix: "claude:")
#   ClaudeAgent::SessionStoreConformance.run(store)

require "../../src/claude-agent-cr"

# Uncomment when using crystal-redis:
# require "redis"

module Examples
  class RedisSessionStore < ClaudeAgent::SessionStore
    SUBKEYS  = "__subkeys"
    SESSIONS = "__sessions"

    def initialize(@client : RedisClient, @prefix : String = "")
      @prefix = @prefix.empty? ? "" : @prefix.rstrip(':') + ":"
    end

    # Minimal surface expected from a Redis client (adapt to crystal-redis API).
    abstract class RedisClient
      abstract def rpush(key : String, *values : String)
      abstract def lrange(key : String, start : Int32, stop : Int32) : Array(String)
      abstract def del(*keys : String)
      abstract def sadd(key : String, *members : String)
      abstract def srem(key : String, *members : String)
      abstract def smembers(key : String) : Array(String)
      abstract def zadd(key : String, score : Float64 | Int64, member : String)
      abstract def zrem(key : String, member : String)
      abstract def zrange_with_scores(key : String, start : Int32, stop : Int32) : Array({String, Float64})
    end

    def append(key : ClaudeAgent::SessionKey, entries : Array(ClaudeAgent::SessionStoreEntry)) : Nil
      return if entries.empty?

      payload = entries.map(&.to_h.to_json)
      @client.rpush(entry_key(key), *payload)
      if sub = key.subpath
        @client.sadd(subkeys_key(key.project_key, key.session_id), sub)
      else
        @client.zadd(sessions_key(key.project_key), Time.utc.to_unix_ms, key.session_id)
      end
    end

    def load(key : ClaudeAgent::SessionKey) : Array(ClaudeAgent::SessionStoreEntry)?
      raw = @client.lrange(entry_key(key), 0, -1)
      return nil if raw.empty?

      out = [] of ClaudeAgent::SessionStoreEntry
      raw.each do |line|
        begin
          h = JSON.parse(line).as_h?
          out << ClaudeAgent::SessionStoreEntry.from_hash(h) if h
        rescue
        end
      end
      out.empty? ? nil : out
    end

    def list_sessions(project_key : String) : Array(ClaudeAgent::SessionStoreListEntry)
      @client.zrange_with_scores(sessions_key(project_key), 0, -1).map do |member, score|
        ClaudeAgent::SessionStoreListEntry.new(member, score.to_i64)
      end
    end

    def delete(key : ClaudeAgent::SessionKey) : Nil
      if sub = key.subpath
        @client.del(entry_key(key))
        @client.srem(subkeys_key(key.project_key, key.session_id), sub)
        return
      end
      subpaths = @client.smembers(subkeys_key(key.project_key, key.session_id))
      keys = [entry_key(key), subkeys_key(key.project_key, key.session_id)]
      subpaths.each do |subpath|
        keys << entry_key(ClaudeAgent::SessionKey.new(key.project_key, key.session_id, subpath))
      end
      @client.del(*keys) unless keys.empty?
      @client.zrem(sessions_key(key.project_key), key.session_id)
    end

    def list_subkeys(key : ClaudeAgent::SessionListSubkeysKey) : Array(String)
      @client.smembers(subkeys_key(key.project_key, key.session_id))
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

    private def entry_key(key : ClaudeAgent::SessionKey) : String
      parts = [key.project_key, key.session_id]
      if sub = key.subpath
        parts << sub
      end
      @prefix + parts.join(":")
    end

    private def subkeys_key(project_key : String, session_id : String) : String
      "#{@prefix}#{project_key}:#{session_id}:#{SUBKEYS}"
    end

    private def sessions_key(project_key : String) : String
      "#{@prefix}#{project_key}:#{SESSIONS}"
    end
  end
end

puts "RedisSessionStore is a reference adapter."
puts "Wire a real Redis client implementing RedisClient and run SessionStoreConformance."
