require "json"
require "mutex"

module ClaudeAgent
  # SessionStore adapter surface, InMemorySessionStore, and summary folding.
  # Live turn mirroring is in TranscriptMirrorBatcher + AgentClient
  # (--session-mirror CLI flag).

  # Identifies a session transcript or subagent transcript in a store.
  # Main transcripts omit `subpath`; subagent transcripts use a subpath like
  # "subagents/agent-{id}" that mirrors the on-disk directory structure.
  struct SessionKey
    include JSON::Serializable

    getter project_key : String
    getter session_id : String
    getter subpath : String?

    def initialize(
      @project_key : String,
      @session_id : String,
      @subpath : String? = nil,
    )
    end

    def storage_key : String
      if sub = @subpath
        "#{@project_key}/#{@session_id}/#{sub}"
      else
        "#{@project_key}/#{@session_id}"
      end
    end

    def main? : Bool
      @subpath.nil?
    end
  end

  # One JSONL transcript line as observed by a SessionStore adapter.
  # Entries are opaque pass-through blobs; only `type` is required by the
  # protocol. Adapters should treat `uuid` as an idempotency key when present.
  struct SessionStoreEntry
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter type : String
    getter uuid : String?
    getter timestamp : String?

    def initialize(
      @type : String,
      @uuid : String? = nil,
      @timestamp : String? = nil,
      unmapped : Hash(String, JSON::Any)? = nil,
    )
      @unmapped = unmapped || {} of String => JSON::Any
    end

    # Build from a full JSON object (typical JSONL line).
    def self.from_hash(hash : Hash(String, JSON::Any)) : SessionStoreEntry
      type = hash["type"]?.try(&.as_s?) || raise ArgumentError.new("SessionStoreEntry requires type")
      uuid = hash["uuid"]?.try(&.as_s?)
      timestamp = hash["timestamp"]?.try(&.as_s?)
      rest = {} of String => JSON::Any
      hash.each do |key, value|
        next if key == "type" || key == "uuid" || key == "timestamp"
        rest[key] = value
      end
      new(type, uuid, timestamp, rest)
    end

    def self.from_json_any(value : JSON::Any) : SessionStoreEntry
      hash = value.as_h? || raise ArgumentError.new("SessionStoreEntry must be a JSON object")
      from_hash(hash)
    end

    # Full object for store persistence / JSONL round-trip (type first).
    def to_h : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      result["type"] = JSON::Any.new(@type)
      result["uuid"] = JSON::Any.new(@uuid) if @uuid
      result["timestamp"] = JSON::Any.new(@timestamp) if @timestamp
      @unmapped.each { |k, v| result[k] = v }
      result
    end

    def [](key : String) : JSON::Any
      case key
      when "type"      then JSON::Any.new(@type)
      when "uuid"      then @uuid ? JSON::Any.new(@uuid) : JSON::Any.new(nil)
      when "timestamp" then @timestamp ? JSON::Any.new(@timestamp) : JSON::Any.new(nil)
      else                  @unmapped[key]? || JSON::Any.new(nil)
      end
    end

    def []?(key : String) : JSON::Any?
      case key
      when "type"
        JSON::Any.new(@type)
      when "uuid"
        @uuid ? JSON::Any.new(@uuid) : nil
      when "timestamp"
        @timestamp ? JSON::Any.new(@timestamp) : nil
      else
        @unmapped[key]?
      end
    end

    def string_field(key : String) : String?
      self[key]?.try(&.as_s?)
    end

    def bool_field(key : String) : Bool
      self[key]?.try(&.as_bool?) == true
    end
  end

  # Entry returned by SessionStore#list_sessions.
  struct SessionStoreListEntry
    include JSON::Serializable

    getter session_id : String
    # Last-modified time in Unix epoch milliseconds.
    getter mtime : Int64

    def initialize(@session_id : String, @mtime : Int64)
    end
  end

  # Incrementally-maintained session summary sidecar.
  # `data` is opaque SDK-owned state — stores MUST NOT interpret it.
  struct SessionSummaryEntry
    include JSON::Serializable

    getter session_id : String
    # Storage write time in Unix epoch milliseconds (same clock as list mtime).
    property mtime : Int64
    getter data : Hash(String, JSON::Any)

    def initialize(
      @session_id : String,
      @mtime : Int64 = 0_i64,
      @data : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    def dup_data : SessionSummaryEntry
      SessionSummaryEntry.new(@session_id, @mtime, @data.dup)
    end
  end

  # Key argument to SessionStore#list_subkeys (no subpath).
  struct SessionListSubkeysKey
    include JSON::Serializable

    getter project_key : String
    getter session_id : String

    def initialize(@project_key : String, @session_id : String)
    end
  end

  # Controls when transcript-mirror entries are flushed to a SessionStore.
  # - batched (default): buffer and flush once per turn / size threshold
  # - eager: flush after every transcript_mirror frame
  enum SessionStoreFlushMode
    Batched
    Eager

    def self.parse(value : String) : SessionStoreFlushMode
      case value.downcase
      when "batched" then Batched
      when "eager"   then Eager
      else
        raise ArgumentError.new("session_store_flush must be \"batched\" or \"eager\", got #{value.inspect}")
      end
    end

    def to_s : String
      case self
      when Batched then "batched"
      when Eager   then "eager"
      else              "batched"
      end
    end
  end

  # Raised when an optional SessionStore method is not implemented.
  class SessionStoreNotImplementedError < Error
    getter method_name : String

    def initialize(@method_name : String)
      super("SessionStore##{method_name} is not implemented")
    end
  end

  # Adapter for mirroring session transcripts to external storage.
  #
  # Only `#append` and `#load` are required. Optional methods raise
  # `SessionStoreNotImplementedError` by default; override them and the
  # corresponding `supports_*?` predicates in concrete adapters.
  #
  # The SDK never deletes from a store unless `delete_session_via_store` is
  # called with `#delete` implemented. Retention is the adapter's concern.
  abstract class SessionStore
    # Mirror a batch of transcript entries. Entries with a stable `uuid`
    # should be treated as an idempotency key (upsert / ignore-duplicate).
    # Entries without a uuid (titles, tags) should be appended without dedup.
    abstract def append(key : SessionKey, entries : Array(SessionStoreEntry)) : Nil

    # Load a full session for resume. Return `nil` for a key that was never
    # written. Returned entries must be deep-equal to what was appended
    # (byte-equal serialization is NOT required).
    abstract def load(key : SessionKey) : Array(SessionStoreEntry)?

    def list_sessions(project_key : String) : Array(SessionStoreListEntry)
      raise SessionStoreNotImplementedError.new("list_sessions")
    end

    def list_session_summaries(project_key : String) : Array(SessionSummaryEntry)
      raise SessionStoreNotImplementedError.new("list_session_summaries")
    end

    # Deleting a main-transcript key (no subpath) must cascade to all subkeys.
    # A targeted delete with an explicit subpath removes only that one entry.
    def delete(key : SessionKey) : Nil
      raise SessionStoreNotImplementedError.new("delete")
    end

    def list_subkeys(key : SessionListSubkeysKey) : Array(String)
      raise SessionStoreNotImplementedError.new("list_subkeys")
    end

    def supports_list_sessions? : Bool
      false
    end

    def supports_list_session_summaries? : Bool
      false
    end

    def supports_delete? : Bool
      false
    end

    def supports_list_subkeys? : Bool
      false
    end
  end

  # In-memory SessionStore for testing and development.
  # Not suitable for production — data is lost when the process exits.
  # UUID-bearing entries are idempotent: re-appending the same uuid is a no-op.
  class InMemorySessionStore < SessionStore
    def initialize
      @store = {} of String => Array(SessionStoreEntry)
      @mtimes = {} of String => Int64
      @summaries = {} of String => SessionSummaryEntry
      @uuid_index = {} of String => Set(String)
      @last_mtime = 0_i64
      @mutex = Mutex.new
    end

    def append(key : SessionKey, entries : Array(SessionStoreEntry)) : Nil
      return if entries.empty?

      @mutex.synchronize do
        k = key.storage_key
        list = @store[k] ||= [] of SessionStoreEntry
        seen = @uuid_index[k] ||= Set(String).new

        accepted = [] of SessionStoreEntry
        entries.each do |entry|
          if uuid = entry.uuid
            next if seen.includes?(uuid)
            seen.add(uuid)
          end
          list << entry
          accepted << entry
        end

        return if accepted.empty?

        now_ms = next_mtime
        @mtimes[k] = now_ms

        if key.main?
          sk = summary_key(key)
          folded = ClaudeAgent.fold_session_summary(@summaries[sk]?, key, accepted)
          folded.mtime = now_ms
          @summaries[sk] = folded
        end
      end
    end

    def load(key : SessionKey) : Array(SessionStoreEntry)?
      @mutex.synchronize do
        entries = @store[key.storage_key]?
        entries ? entries.dup : nil
      end
    end

    def list_sessions(project_key : String) : Array(SessionStoreListEntry)
      @mutex.synchronize do
        results = [] of SessionStoreListEntry
        prefix = "#{project_key}/"
        @store.each_key do |k|
          next unless k.starts_with?(prefix)
          rest = k[prefix.size..]
          # Main transcripts only (no second '/').
          next if rest.includes?('/')
          results << SessionStoreListEntry.new(rest, @mtimes[k]? || 0_i64)
        end
        results
      end
    end

    def list_session_summaries(project_key : String) : Array(SessionSummaryEntry)
      @mutex.synchronize do
        prefix = "#{project_key}/"
        @summaries.compact_map do |store_key, summary|
          rest = store_key[prefix.size..]
          summary if store_key.starts_with?(prefix) && !rest.includes?('/')
        end
      end
    end

    def delete(key : SessionKey) : Nil
      @mutex.synchronize do
        k = key.storage_key
        @store.delete(k)
        @mtimes.delete(k)
        @uuid_index.delete(k)

        if key.main?
          @summaries.delete(summary_key(key))
          prefix = "#{key.project_key}/#{key.session_id}/"
          to_remove = @store.keys.select(&.starts_with?(prefix))
          to_remove.each do |store_key|
            @store.delete(store_key)
            @mtimes.delete(store_key)
            @uuid_index.delete(store_key)
          end
        end
      end
    end

    def list_subkeys(key : SessionListSubkeysKey) : Array(String)
      @mutex.synchronize do
        prefix = "#{key.project_key}/#{key.session_id}/"
        @store.keys.compact_map do |k|
          k[prefix.size..] if k.starts_with?(prefix)
        end
      end
    end

    def supports_list_sessions? : Bool
      true
    end

    def supports_list_session_summaries? : Bool
      true
    end

    def supports_delete? : Bool
      true
    end

    def supports_list_subkeys? : Bool
      true
    end

    # Test helper — get all entries for a key (empty list if absent).
    def get_entries(key : SessionKey) : Array(SessionStoreEntry)
      @mutex.synchronize { (@store[key.storage_key]? || [] of SessionStoreEntry).dup }
    end

    # Test helper — number of stored main transcripts.
    def size : Int32
      @mutex.synchronize do
        count = 0
        @store.each_key do |k|
          first = k.index('/')
          next unless first
          count += 1 unless k[(first + 1)..].includes?('/')
        end
        count
      end
    end

    def clear : Nil
      @mutex.synchronize do
        @store.clear
        @mtimes.clear
        @summaries.clear
        @uuid_index.clear
        @last_mtime = 0_i64
      end
    end

    private def next_mtime : Int64
      now_ms = Time.utc.to_unix_ms
      if now_ms <= @last_mtime
        now_ms = @last_mtime + 1
      end
      @last_mtime = now_ms
      now_ms
    end

    private def summary_key(key : SessionKey) : String
      "#{key.project_key}/#{key.session_id}"
    end
  end

  # Map of JSONL entry keys → SessionSummaryEntry data keys for last-wins strings.
  private LAST_WINS_SUMMARY_FIELDS = {
    "customTitle" => "custom_title",
    "aiTitle"     => "ai_title",
    "lastPrompt"  => "last_prompt",
    "summary"     => "summary_hint",
    "gitBranch"   => "git_branch",
  }

  private COMMAND_NAME_SUMMARY_REGEX = /<command-name>(.*?)<\/command-name>/
  private SKIP_FIRST_PROMPT_SUMMARY  = /^(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|\[Request interrupted by user[^\]]*\]|\s*<ide_opened_file>[\s\S]*<\/ide_opened_file>\s*$|\s*<ide_selection>[\s\S]*<\/ide_selection>\s*$)/

  # Fold a batch of appended entries into the running summary for `key`.
  # Do not call for keys with a `subpath` — subagent transcripts must not
  # contribute to the main session's summary. `mtime` is NOT set here; the
  # adapter stamps storage write time after persisting.
  def self.fold_session_summary(
    prev : SessionSummaryEntry?,
    key : SessionKey,
    entries : Array(SessionStoreEntry),
  ) : SessionSummaryEntry
    summary = if prev
                prev.dup_data
              else
                SessionSummaryEntry.new(key.session_id, 0_i64, {} of String => JSON::Any)
              end
    data = summary.data

    entries.each do |entry|
      ms = iso_to_epoch_ms(entry.timestamp)

      unless data.has_key?("is_sidechain")
        data["is_sidechain"] = JSON::Any.new(entry.bool_field("isSidechain"))
      end

      if !data.has_key?("created_at") && ms
        data["created_at"] = JSON::Any.new(ms)
      end

      unless data.has_key?("cwd")
        if cwd = entry.string_field("cwd")
          data["cwd"] = JSON::Any.new(cwd) unless cwd.empty?
        end
      end

      fold_first_prompt(data, entry)

      LAST_WINS_SUMMARY_FIELDS.each do |src, dst|
        if val = entry.string_field(src)
          data[dst] = JSON::Any.new(val)
        end
      end

      if entry.type == "tag"
        tag_val = entry.string_field("tag")
        if tag_val && !tag_val.empty?
          data["tag"] = JSON::Any.new(tag_val)
        else
          data.delete("tag")
        end
      end
    end

    summary
  end

  # Derive a SessionKey from an absolute transcript file path under projects_dir.
  # Main: `<projects_dir>/<project_key>/<session_id>.jsonl`
  # Subagent: `<projects_dir>/<project_key>/<session_id>/subagents/.../agent-<id>.jsonl`
  def self.file_path_to_session_key(file_path : String, projects_dir : String) : SessionKey?
    rel = Path[file_path].relative_to(projects_dir).to_s
    return if rel.starts_with?("..") || Path[rel].absolute?

    parts = Path[rel].parts
    return if parts.size < 2

    project_key = parts[0]
    second = parts[1]

    if parts.size == 2 && second.ends_with?(".jsonl")
      return SessionKey.new(project_key, second.rchop(".jsonl"))
    end

    if parts.size >= 4
      subpath_parts = parts[2..].map(&.to_s)
      last = subpath_parts[-1]
      subpath_parts[-1] = last.rchop(".jsonl") if last.ends_with?(".jsonl")
      return SessionKey.new(project_key, second, subpath_parts.join("/"))
    end

    nil
  rescue
    nil
  end

  private def self.iso_to_epoch_ms(ts : String?) : Int64?
    return unless ts

    begin
      Time::Format::ISO_8601_DATE_TIME.parse(ts, Time::Location::UTC).to_unix_ms
    rescue Time::Format::Error
      begin
        Time.parse(ts, "%Y-%m-%dT%H:%M:%S.%L%z", Time::Location::UTC).to_unix_ms
      rescue
        nil
      end
    end
  end

  private def self.fold_first_prompt(data : Hash(String, JSON::Any), entry : SessionStoreEntry) : Nil
    return if data["first_prompt_locked"]?.try(&.as_bool?)
    return unless entry.type == "user"
    return if entry.bool_field("isMeta") || entry.bool_field("isCompactSummary")

    message = entry["message"]?.try(&.as_h?)
    return unless message
    return if message_has_tool_result?(message)

    apply_first_prompt_from_texts(data, entry_text_blocks(message))
  end

  private def self.message_has_tool_result?(message : Hash(String, JSON::Any)) : Bool
    content = message["content"]?
    return false unless content
    blocks = content.as_a?
    return false unless blocks

    blocks.any? do |block|
      hash = block.as_h?
      hash && hash["type"]?.try(&.as_s?) == "tool_result"
    end
  end

  private def self.apply_first_prompt_from_texts(
    data : Hash(String, JSON::Any),
    texts : Array(String),
  ) : Nil
    texts.each do |raw|
      result = raw.gsub('\n', ' ').strip
      next if result.empty?

      if match = COMMAND_NAME_SUMMARY_REGEX.match(result)
        data["command_fallback"] = JSON::Any.new(match[1]) unless data.has_key?("command_fallback")
        next
      end

      next if SKIP_FIRST_PROMPT_SUMMARY.matches?(result)

      if result.size > 200
        result = result[0, 200].rstrip + "…"
      end
      data["first_prompt"] = JSON::Any.new(result)
      data["first_prompt_locked"] = JSON::Any.new(true)
      return
    end
  end

  private def self.entry_text_blocks(message : Hash(String, JSON::Any)) : Array(String)
    content = message["content"]?
    return [] of String unless content

    if text = content.as_s?
      return [text]
    end

    blocks = content.as_a?
    return [] of String unless blocks

    texts = [] of String
    blocks.each do |block|
      hash = block.as_h?
      next unless hash
      next unless hash["type"]?.try(&.as_s?) == "text"
      if text = hash["text"]?.try(&.as_s?)
        texts << text
      end
    end
    texts
  end
end
