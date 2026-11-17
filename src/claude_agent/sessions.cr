require "json"
require "set"
require "uuid"
require "file_utils"

module ClaudeAgent
  struct SDKSessionInfo
    include JSON::Serializable

    getter session_id : String
    getter summary : String
    getter last_modified : Int64
    getter file_size : Int64
    getter custom_title : String?
    getter first_prompt : String?
    getter git_branch : String?
    getter cwd : String?
    getter tag : String?
    getter created_at : Int64?
    getter archived : Bool? = nil

    def initialize(
      @session_id : String,
      @summary : String,
      @last_modified : Int64,
      @file_size : Int64,
      @custom_title : String? = nil,
      @first_prompt : String? = nil,
      @git_branch : String? = nil,
      @cwd : String? = nil,
      @tag : String? = nil,
      @created_at : Int64? = nil,
      @archived : Bool? = nil,
    )
    end
  end

  struct SessionMessage
    include JSON::Serializable

    getter type : String
    getter uuid : String
    getter session_id : String
    getter message : Hash(String, JSON::Any)
    getter parent_tool_use_id : String?
    # When set, this message belongs to a nested (depth-2+) subagent and
    # identifies the parent agent in the tree. Present on disk-persisted
    # subagent transcripts (TS SDK 0.3.202+). Nil for top-level sessions.
    getter parent_agent_id : String?

    def initialize(
      @type : String,
      @uuid : String,
      @session_id : String,
      @message : Hash(String, JSON::Any),
      @parent_tool_use_id : String? = nil,
      @parent_agent_id : String? = nil,
    )
    end
  end

  # Returned by `fork_session`.
  struct ForkSessionResult
    getter session_id : String

    def initialize(@session_id : String)
    end
  end

  # `agent-<id>.jsonl` -> `agent-<id>.meta.json` (same directory).
  # Single definition of the subagent metadata sidecar naming
  # convention, shared by the disk read path (`SessionStorage`) and
  # resume materialization (`materialize_resume_session`). Mirrors
  # Python's `_agent_metadata_sidecar_path` (0.2.140).
  def self.agent_metadata_sidecar_path(transcript_path : String) : String
    base = transcript_path.ends_with?(".jsonl") ? transcript_path[0...-".jsonl".size] : transcript_path
    "#{base}.meta.json"
  end

  module SessionStorage
    extend self

    private alias TranscriptEntry = Hash(String, JSON::Any)
    private alias DeliveryCounts = Hash(String, Int32)

    MAX_SANITIZED_LENGTH       =  200
    MAX_ARCHIVED_SIDECAR_BYTES = 4096
    DELETE_MAX_ATTEMPTS        =    3
    DELETE_BACKOFF_BASE_MS     =   50
    UUID_REGEX                 = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    COMMAND_NAME_REGEX         = /<command-name>(.*?)<\/command-name>/
    SKIP_FIRST_PROMPT          = /^(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|\[Request interrupted by user[^\]]*\]|\s*<ide_opened_file>[\s\S]*<\/ide_opened_file>\s*$|\s*<ide_selection>[\s\S]*<\/ide_selection>\s*$)/
    VISIBLE_META_ORIGINS       = Set{"channel", "observer", "observer-activity", "slack-ping", "voice-call", "peer"}
    INTERRUPTED_USER_PREFIXES  = {
      "[Request interrupted by user]",
      "[Request interrupted: the session ended before this agent finished. Nobody asked it to stop.]",
      "[Agent call interrupted: the process running this conversation stopped before this agent finished, " \
      "so it returned no result. Nobody asked it to stop.]",
      "[Request interrupted by user for tool use]",
      "[Tool call did not complete: the turn was ended to deliver the message that follows. " \
      "Nothing refused it; re-run it if still needed.]",
      "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is " \
      "unknown. Check whether it took effect before relying on it or running it again.]",
      "[Tool call result not in this copy: this session was copied from another session before that session " \
      "recorded this call's result. The call may have finished there, may still be running there, or may " \
      "never have run. Check whether it took effect before relying on it or running it again.]",
      "The user doesn't want to take this action right now. STOP what you are doing and wait for the user " \
      "to tell you how to proceed.",
      "[Tool call skipped: the turn was stopped before this call ran, by the check whose denial is on " \
      "another call in this batch. Nothing refused this call and it had no effects; re-run it if still needed.]",
      "[Tool call skipped: the turn ended to deliver the message that follows before this call ran. " \
      "Nothing refused it; re-run it if still needed.]",
    }

    def list_sessions(
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
      include_worktrees : Bool = true,
    ) : Array(SDKSessionInfo)
      if directory
        list_sessions_for_project(directory, limit, offset, include_worktrees)
      else
        list_all_sessions(limit, offset)
      end
    end

    def get_session_info(
      session_id : String,
      directory : String? = nil,
    ) : SDKSessionInfo?
      return unless valid_uuid?(session_id)

      file_path = resolve_session_file_path(session_id, directory)
      return unless file_path

      build_session_info(session_id, file_path, directory)
    end

    def rename_session(
      session_id : String,
      title : String,
      directory : String? = nil,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      stripped = title.strip
      raise ArgumentError.new("title must be non-empty") if stripped.empty?

      append_to_session(
        session_id,
        %({"type":"custom-title","customTitle":#{stripped.to_json},"sessionId":#{session_id.to_json}}\n),
        directory,
      )
    end

    def tag_session(
      session_id : String,
      tag : String?,
      directory : String? = nil,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      sanitized_tag = if tag
                        value = sanitize_unicode(tag).strip
                        raise ArgumentError.new("tag must be non-empty (use nil to clear)") if value.empty?
                        value
                      end

      append_to_session(
        session_id,
        %({"type":"tag","tag":#{(sanitized_tag || "").to_json},"sessionId":#{session_id.to_json}}\n),
        directory,
      )
    end

    # Archive a session by writing `<projectDir>/<sessionId>/archived.json`.
    def archive_session(session_id : String, directory : String? = nil) : Nil
      set_session_archived(session_id, true, directory)
    end

    # Unarchive a session by updating `<projectDir>/<sessionId>/archived.json`.
    def unarchive_session(session_id : String, directory : String? = nil) : Nil
      set_session_archived(session_id, false, directory)
    end

    # Delete a session by removing its JSONL file and sibling subagent
    # transcript directory (if any). Raises File::NotFoundError if the
    # session cannot be located, and propagates File::Error if removing the
    # subagent directory fails after 3 attempts.
    def delete_session(session_id : String, directory : String? = nil) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      file_path = resolve_session_file_path(session_id, directory)
      unless file_path
        missing = directory ? File.join(directory, "#{session_id}.jsonl") : "#{session_id}.jsonl"
        raise File::NotFoundError.new("Session #{session_id} not found", file: missing)
      end

      File.delete(file_path)

      subagent_dir = File.join(Path[file_path].parent.to_s, session_id)
      remove_tree_with_retry(subagent_dir)
    end

    # List subagent IDs associated with a session. Subagent transcripts are
    # stored under `<projectDir>/<sessionId>/subagents/` and may be nested
    # in subdirectories.
    def list_subagents(session_id : String, directory : String? = nil) : Array(String)
      return [] of String unless valid_uuid?(session_id)

      subagents_dir = resolve_subagents_dir(session_id, directory)
      return [] of String unless subagents_dir

      collect_agent_files(subagents_dir).map { |tuple| tuple[0] }
    end

    # Read a subagent's conversation messages from its JSONL transcript.
    def get_subagent_messages(
      session_id : String,
      agent_id : String,
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
    ) : Array(SessionMessage)
      return [] of SessionMessage unless valid_uuid?(session_id)
      return [] of SessionMessage if agent_id.empty?

      subagents_dir = resolve_subagents_dir(session_id, directory)
      return [] of SessionMessage unless subagents_dir

      match = collect_agent_files(subagents_dir).find { |tuple| tuple[0] == agent_id }
      return [] of SessionMessage unless match

      content = File.read(match[1])
      entries = parse_transcript_entries(content)
      parent_tool_use_id, parent_agent_id = subagent_parent_ids(match[1])
      messages = subagent_entries_to_messages(entries, parent_tool_use_id, parent_agent_id)
      paginate_session_messages(messages, limit, offset)
    rescue File::Error
      [] of SessionMessage
    end

    # Fork a session into a new branch with fresh UUIDs. Copies transcript
    # messages, remapping every message UUID and preserving the `parentUuid`
    # chain. When `up_to_message_id` is provided, the transcript is sliced
    # at (and including) that message.
    def fork_session(
      session_id : String,
      directory : String? = nil,
      up_to_message_id : String? = nil,
      title : String? = nil,
    ) : ForkSessionResult
      validate_fork_inputs!(session_id, up_to_message_id)

      file_path, project_dir = locate_fork_source!(session_id, directory)
      content = File.read(file_path)
      raise ArgumentError.new("Session #{session_id} has no messages to fork") if content.empty?

      forked_session_id = UUID.random.to_s
      lines = prepare_and_build_fork_lines(content, session_id, forked_session_id, up_to_message_id, title)

      fork_path = File.join(project_dir, "#{forked_session_id}.jsonl")
      File.open(fork_path, "w") do |file|
        lines.each { |line| file << line << "\n" }
      end

      ForkSessionResult.new(forked_session_id)
    end

    private def prepare_and_build_fork_lines(
      content : String,
      session_id : String,
      forked_session_id : String,
      up_to_message_id : String?,
      title : String?,
    ) : Array(String)
      transcript, content_replacements = prepare_fork_transcript(content, session_id, up_to_message_id)
      uuid_mapping = build_fork_uuid_mapping(transcript)
      writable = transcript.reject { |entry| string_field(entry, "type") == "progress" }
      raise ArgumentError.new("Session #{session_id} has no messages to fork") if writable.empty?

      writable_mapping = build_writable_uuid_mapping(writable, uuid_mapping)
      by_uuid = index_transcript(transcript)

      lines = build_fork_lines(
        writable,
        by_uuid,
        uuid_mapping,
        writable_mapping,
        forked_session_id,
        session_id,
      )
      append_fork_footer(lines, forked_session_id, content, content_replacements, title)
      lines
    end

    private def validate_fork_inputs!(session_id : String, up_to_message_id : String?)
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)
      if up_to_message_id && up_to_message_id.strip.empty?
        raise ArgumentError.new("Invalid up_to_message_id: #{up_to_message_id.inspect}")
      end
    end

    private def locate_fork_source!(
      session_id : String,
      directory : String?,
    ) : Tuple(String, String)
      source = find_session_file_with_dir(session_id, directory)
      return source if source

      raise File::NotFoundError.new("Session #{session_id} not found", file: "#{session_id}.jsonl")
    end

    private def prepare_fork_transcript(
      content : String,
      session_id : String,
      up_to_message_id : String?,
    ) : Tuple(Array(TranscriptEntry), Array(JSON::Any))
      transcript, content_replacements = parse_fork_transcript(content, session_id)
      transcript.reject! { |entry| bool_field(entry, "isSidechain") }
      raise ArgumentError.new("Session #{session_id} has no messages to fork") if transcript.empty?

      if up_to_message_id
        cutoff = find_fork_cutoff_index(transcript, up_to_message_id)
        unless cutoff
          raise ArgumentError.new("Message #{up_to_message_id} not found in session #{session_id}")
        end
        cutoff_uuid = string_field(transcript[cutoff], "uuid")
        sliced = trim_trailing_compaction_boundary(transcript[0..cutoff])
        sliced = strip_fork_cutoff_boundary_preservation(cutoff_uuid, sliced)
        transcript = prune_orphaned_compaction_branches(sliced)
      end

      {transcript, content_replacements}
    end

    private def build_fork_uuid_mapping(transcript : Array(TranscriptEntry)) : Hash(String, String)
      mapping = {} of String => String
      transcript.each do |entry|
        uuid = string_field(entry, "uuid")
        mapping[uuid] = UUID.random.to_s if uuid
      end
      mapping
    end

    private def build_writable_uuid_mapping(
      writable : Array(TranscriptEntry),
      uuid_mapping : Hash(String, String),
    ) : Hash(String, String)
      mapping = {} of String => String
      writable.each do |entry|
        uuid = string_field(entry, "uuid")
        next unless uuid
        if mapped = uuid_mapping[uuid]?
          mapping[uuid] = mapped
        end
      end
      mapping
    end

    private def index_transcript(transcript : Array(TranscriptEntry)) : Hash(String, TranscriptEntry)
      by_uuid = {} of String => TranscriptEntry
      transcript.each do |entry|
        uuid = string_field(entry, "uuid")
        by_uuid[uuid] = entry if uuid
      end
      by_uuid
    end

    private def build_fork_lines(
      writable : Array(TranscriptEntry),
      by_uuid : Hash(String, TranscriptEntry),
      uuid_mapping : Hash(String, String),
      writable_mapping : Hash(String, String),
      forked_session_id : String,
      original_session_id : String,
    ) : Array(String)
      lines = [] of String
      now = Time.utc.to_rfc3339

      writable.each_with_index do |original, index|
        original_uuid = string_field(original, "uuid")
        next unless original_uuid

        new_uuid = uuid_mapping[original_uuid]?
        next unless new_uuid

        entry = remap_fork_entry(
          original,
          original_uuid,
          new_uuid,
          by_uuid,
          uuid_mapping,
          writable_mapping,
          writable,
          forked_session_id,
          original_session_id,
          index == writable.size - 1,
          now,
        )
        lines << entry.to_json
      end

      lines
    end

    private def remap_fork_entry(
      original : TranscriptEntry,
      original_uuid : String,
      new_uuid : String,
      by_uuid : Hash(String, TranscriptEntry),
      uuid_mapping : Hash(String, String),
      writable_mapping : Hash(String, String),
      writable : Array(TranscriptEntry),
      forked_session_id : String,
      original_session_id : String,
      is_leaf : Bool,
      now : String,
    ) : Hash(String, JSON::Any)
      forked = {} of String => JSON::Any
      original.each { |k, v| forked[k] = v }

      new_parent = resolve_fork_parent(original, by_uuid, uuid_mapping)
      timestamp = is_leaf ? now : (string_field(original, "timestamp") || now)
      logical_parent = string_field(original, "logicalParentUuid")

      forked["uuid"] = JSON::Any.new(new_uuid)
      forked["parentUuid"] = new_parent ? JSON::Any.new(new_parent) : JSON::Any.new(nil)
      if logical_parent
        forked["logicalParentUuid"] = JSON::Any.new(uuid_mapping[logical_parent]? || logical_parent)
      end
      forked["sessionId"] = JSON::Any.new(forked_session_id)
      forked["timestamp"] = JSON::Any.new(timestamp)
      forked["isSidechain"] = JSON::Any.new(false)
      forked["forkedFrom"] = JSON::Any.new({
        "sessionId"   => JSON::Any.new(original_session_id),
        "messageUuid" => JSON::Any.new(original_uuid),
      })
      remap_fork_entry_metadata!(forked, uuid_mapping, writable_mapping, writable)
      %w[
        teamName agentName slug sourceToolAssistantUUID
        sessionKind summarizedTurnPromptUuids droppedPromptUuids turnAttributionKey
      ].each { |key| forked.delete(key) }
      forked
    end

    private def append_fork_footer(
      lines : Array(String),
      forked_session_id : String,
      content : String,
      content_replacements : Array(JSON::Any),
      explicit_title : String?,
    ) : Nil
      unless content_replacements.empty?
        lines << {
          "type"         => JSON::Any.new("content-replacement"),
          "sessionId"    => JSON::Any.new(forked_session_id),
          "replacements" => JSON::Any.new(content_replacements),
        }.to_json
      end

      title = explicit_title.try(&.strip)
      title = nil if title && title.empty?
      title ||= derive_fork_title(content)

      lines << {
        "type"        => JSON::Any.new("custom-title"),
        "sessionId"   => JSON::Any.new(forked_session_id),
        "customTitle" => JSON::Any.new(title),
      }.to_json
    end

    def get_session_messages(
      session_id : String,
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
      include_system_messages : Bool = false,
    ) : Array(SessionMessage)
      return [] of SessionMessage unless valid_uuid?(session_id)

      content = read_session_file(session_id, directory)
      return [] of SessionMessage unless content

      # Filter sidechain-first sessions consistently with list_sessions
      first_entry = first_json_entry(content)
      return [] of SessionMessage if first_entry && bool_field(first_entry, "isSidechain")

      entries, delivered = parse_transcript_with_delivery(content)
      entries_to_session_messages(entries, limit, offset, include_system_messages, delivered)
    end

    def sanitize_path(path : String) : String
      sanitized = path.gsub(/[^a-zA-Z0-9]/, "-")
      return sanitized if sanitized.size <= MAX_SANITIZED_LENGTH

      prefix = sanitized[0, MAX_SANITIZED_LENGTH]
      "#{prefix}-#{simple_hash(path)}"
    end

    private def list_all_sessions(limit : Int32?, offset : Int32) : Array(SDKSessionInfo)
      projects_dir = projects_dir_path
      return [] of SDKSessionInfo unless Dir.exists?(projects_dir)

      sessions = [] of SDKSessionInfo
      Dir.children(projects_dir).each do |entry|
        project_dir = File.join(projects_dir, entry)
        next unless Dir.exists?(project_dir)
        sessions.concat(read_sessions_from_dir(project_dir))
      end

      apply_sort_limit_and_offset(deduplicate_by_session_id(sessions), limit, offset)
    rescue File::Error
      [] of SDKSessionInfo
    end

    private def list_sessions_for_project(
      directory : String,
      limit : Int32?,
      offset : Int32,
      include_worktrees : Bool,
    ) : Array(SDKSessionInfo)
      canonical_dir = canonicalize_path(directory)
      scan_paths = Set{canonical_dir}

      if include_worktrees
        worktree_paths(canonical_dir).each { |path| scan_paths.add(path) }
      end

      sessions = [] of SDKSessionInfo
      scan_paths.each do |path|
        project_dir = find_project_dir(path)
        next unless project_dir
        sessions.concat(read_sessions_from_dir(project_dir, path))
      end

      apply_sort_limit_and_offset(deduplicate_by_session_id(sessions), limit, offset)
    end

    private def read_sessions_from_dir(project_dir : String, project_path : String? = nil) : Array(SDKSessionInfo)
      sessions = [] of SDKSessionInfo

      Dir.children(project_dir).each do |entry|
        next unless entry.ends_with?(".jsonl")

        session_id = entry.rchop(".jsonl")
        next unless valid_uuid?(session_id)

        file_path = File.join(project_dir, entry)
        if session_info = build_session_info(session_id, file_path, project_path)
          sessions << session_info
        end
      end

      sessions
    rescue File::Error
      [] of SDKSessionInfo
    end

    private def read_session_file(session_id : String, directory : String?) : String?
      file_path = resolve_session_file_path(session_id, directory)
      return unless file_path

      File.read(file_path)
    rescue File::Error
      nil
    end

    private def parse_jsonl_entries(content : String) : Array(TranscriptEntry)
      entries = [] of TranscriptEntry

      content.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          data = JSON.parse(line)
          hash = data.as_h?
          entries << hash if hash
        rescue JSON::ParseException
        end
      end

      entries
    end

    private def parse_transcript_entries(content : String) : Array(TranscriptEntry)
      parse_jsonl_entries(content).select { |entry| transcript_entry?(entry) }
    end

    private def parse_transcript_with_delivery(content : String) : {Array(TranscriptEntry), DeliveryCounts}
      entries = [] of TranscriptEntry
      tracker = DeliveryTracker.new

      parse_jsonl_entries(content).each do |entry|
        tracker.process(entry)
        entries << entry if transcript_entry?(entry)
      end

      {entries, tracker.finalize}
    end

    private def transcript_entry?(entry : TranscriptEntry) : Bool
      type = string_field(entry, "type")
      uuid = string_field(entry, "uuid")
      !uuid.nil? && !type.nil? && {"user", "assistant", "progress", "system", "attachment"}.includes?(type)
    end

    private def build_conversation_chain(entries : Array(TranscriptEntry)) : Array(TranscriptEntry)
      build_conversation_chain_context(entries)[:chain]
    end

    private def build_conversation_chain_context(
      entries : Array(TranscriptEntry),
    ) : {chain: Array(TranscriptEntry), leaf: TranscriptEntry?, by_uuid: Hash(String, TranscriptEntry)}
      if entries.empty?
        return {chain: [] of TranscriptEntry, leaf: nil, by_uuid: {} of String => TranscriptEntry}
      end

      by_uuid, entry_index = relink_compaction_entries(entries)
      leaf = select_active_leaf(by_uuid, entry_index)
      return {chain: [] of TranscriptEntry, leaf: nil, by_uuid: by_uuid} unless leaf

      chain = build_chain_from_leaf(leaf, by_uuid)
      {chain: chain, leaf: leaf, by_uuid: by_uuid}
    end

    private def relink_compaction_entries(
      entries : Array(TranscriptEntry),
    ) : {Hash(String, TranscriptEntry), Hash(String, Int32)}
      by_uuid = {} of String => TranscriptEntry
      entry_index = {} of String => Int32

      entries.each_with_index do |entry, index|
        uuid = string_field(entry, "uuid")
        next unless uuid
        by_uuid[uuid] = entry.dup
        entry_index[uuid] = index
      end

      by_uuid.values.each do |entry|
        apply_compaction_relink(entry, by_uuid)
      end

      {by_uuid, entry_index}
    end

    private def apply_compaction_relink(
      entry : TranscriptEntry,
      by_uuid : Hash(String, TranscriptEntry),
    ) : Nil
      return unless string_field(entry, "type") == "system" && string_field(entry, "subtype") == "compact_boundary"

      meta = hash_field(entry, "compactMetadata")
      return unless meta

      if pm = hash_field(meta, "preservedMessages")
        relink_preserved_messages(pm, by_uuid)
      elsif ps = hash_field(meta, "preservedSegment")
        relink_preserved_segment(ps, by_uuid)
      end
    end

    private def relink_preserved_messages(
      pm : Hash(String, JSON::Any),
      by_uuid : Hash(String, TranscriptEntry),
    ) : Nil
      uuids = json_string_array(pm["uuids"]?)
      anchor = string_field(pm, "anchorUuid")
      return if uuids.empty? || anchor.nil? || uuids.any? { |uid| !by_uuid.has_key?(uid) }

      prev = anchor
      uuids.each do |uid|
        by_uuid[uid]["parentUuid"] = JSON::Any.new(prev)
        prev = uid
      end

      first_u = uuids.first
      last_u = uuids.last
      by_uuid.each do |uid, entry|
        if string_field(entry, "parentUuid") == anchor && uid != first_u
          entry["parentUuid"] = JSON::Any.new(last_u)
        end
      end
    end

    private def relink_preserved_segment(
      ps : Hash(String, JSON::Any),
      by_uuid : Hash(String, TranscriptEntry),
    ) : Nil
      head_uuid = string_field(ps, "headUuid")
      anchor = string_field(ps, "anchorUuid")
      tail_uuid = string_field(ps, "tailUuid")
      return unless head_uuid && anchor && tail_uuid
      return unless by_uuid.has_key?(head_uuid) && by_uuid.has_key?(tail_uuid)

      by_uuid[head_uuid]["parentUuid"] = JSON::Any.new(anchor)
      by_uuid.each do |uid, entry|
        if string_field(entry, "parentUuid") == anchor && uid != head_uuid
          entry["parentUuid"] = JSON::Any.new(tail_uuid)
        end
      end
    end

    private def select_active_leaf(
      by_uuid : Hash(String, TranscriptEntry),
      entry_index : Hash(String, Int32),
    ) : TranscriptEntry?
      if leaf = select_main_active_leaf(by_uuid, entry_index)
        return leaf
      end

      leaves = collect_leaf_candidates(terminal_entries(by_uuid.values), by_uuid)
      return if leaves.empty?

      main_leaves = leaves.reject do |candidate|
        bool_field(candidate, "isSidechain") ||
          bool_field(candidate, "isMeta") ||
          !string_field(candidate, "teamName").nil?
      end

      pick_best_leaf(main_leaves.empty? ? leaves : main_leaves, entry_index)
    end

    private def select_main_active_leaf(
      by_uuid : Hash(String, TranscriptEntry),
      entry_index : Hash(String, Int32),
    ) : TranscriptEntry?
      select_main_active_leaf_with_terminal(by_uuid, entry_index).try(&.[0])
    end

    private def select_main_active_leaf_with_terminal(
      by_uuid : Hash(String, TranscriptEntry),
      entry_index : Hash(String, Int32),
    ) : {TranscriptEntry, TranscriptEntry}?
      main_parents = Set(String).new
      by_uuid.each_value do |entry|
        next unless main_chain_candidate?(entry)
        if parent = string_field(entry, "parentUuid")
          main_parents.add(parent)
        end
      end

      main_terminals = by_uuid.values.select do |entry|
        uuid = string_field(entry, "uuid")
        uuid && main_chain_candidate?(entry) && !main_parents.includes?(uuid)
      end
      main_terminals.sort_by! { |entry| -(entry_index[string_field(entry, "uuid") || ""]? || -1) }

      dead_ends = Set(String).new
      main_terminals.each do |terminal|
        if found = walk_to_main_leaf(terminal, by_uuid, dead_ends)
          return {found, terminal}
        end
      end
      nil
    end

    private def main_chain_candidate?(entry : TranscriptEntry) : Bool
      return false if bool_field(entry, "isSidechain") || !string_field(entry, "teamName").nil?
      type = string_field(entry, "type")
      return false if type == "progress"
      if type == "attachment"
        att = hash_field(entry, "attachment")
        return false if att && string_field(att, "type") == "fork_briefing"
      end

      true
    end

    private def walk_to_main_leaf(
      terminal : TranscriptEntry,
      by_uuid : Hash(String, TranscriptEntry),
      dead_ends : Set(String),
    ) : TranscriptEntry?
      visited = [] of String
      walk_seen = Set(String).new
      current : TranscriptEntry? = terminal

      while current
        uuid = string_field(current, "uuid")
        break unless uuid
        break if dead_ends.includes?(uuid) || walk_seen.includes?(uuid)

        case string_field(current, "type")
        when "user", "assistant"
          return current
        end

        walk_seen.add(uuid)
        visited << uuid
        parent = string_field(current, "parentUuid")
        current = parent ? by_uuid[parent]? : nil
      end

      visited.each { |uid| dead_ends.add(uid) }
      nil
    end

    private def terminal_entries(entries : Array(TranscriptEntry)) : Array(TranscriptEntry)
      parent_uuids = Set(String).new
      entries.each do |entry|
        if parent = string_field(entry, "parentUuid")
          parent_uuids.add(parent)
        end
      end

      entries.reject do |entry|
        uuid = string_field(entry, "uuid")
        uuid && parent_uuids.includes?(uuid)
      end
    end

    private def collect_leaf_candidates(
      terminals : Array(TranscriptEntry),
      by_uuid : Hash(String, TranscriptEntry),
    ) : Array(TranscriptEntry)
      terminals.compact_map do |terminal|
        walk_to_leaf(terminal, by_uuid)
      end
    end

    private def walk_to_leaf(
      terminal : TranscriptEntry,
      by_uuid : Hash(String, TranscriptEntry),
    ) : TranscriptEntry?
      current = terminal
      seen = Set(String).new

      loop do
        uuid = string_field(current, "uuid")
        return unless uuid
        return if seen.includes?(uuid)
        seen.add(uuid)

        case string_field(current, "type")
        when "user", "assistant"
          return current
        end

        parent = string_field(current, "parentUuid")
        return unless parent

        next_entry = by_uuid[parent]?
        return unless next_entry
        current = next_entry
      end
    end

    private def build_chain_from_leaf(
      leaf : TranscriptEntry,
      by_uuid : Hash(String, TranscriptEntry),
    ) : Array(TranscriptEntry)
      chain = [] of TranscriptEntry
      seen = Set(String).new
      current = leaf

      loop do
        uuid = string_field(current, "uuid")
        break unless uuid
        break if seen.includes?(uuid)

        seen.add(uuid)
        chain << current

        parent = string_field(current, "parentUuid")
        break unless parent

        next_entry = by_uuid[parent]?
        break unless next_entry
        current = next_entry
      end

      chain.reverse!
      recover_orphaned_parallel_tool_results(by_uuid, chain, seen)
    end

    private def pick_best_leaf(
      leaves : Array(TranscriptEntry),
      entry_index : Hash(String, Int32),
    ) : TranscriptEntry?
      return if leaves.empty?

      leaves.max_by do |entry|
        uuid = string_field(entry, "uuid")
        uuid ? entry_index[uuid]? || -1 : -1
      end
    end

    private def visible_message?(
      entry : TranscriptEntry,
      include_system_messages : Bool = false,
    ) : Bool
      type = string_field(entry, "type")
      allowed = include_system_messages ? {"user", "assistant", "system"} : {"user", "assistant"}
      return false unless allowed.includes?(type)
      if bool_field(entry, "isMeta") && !visible_meta_origin?(hash_field(entry, "origin"))
        return false
      end
      return false if bool_field(entry, "isSidechain")

      string_field(entry, "teamName").nil?
    end

    private def visible_meta_origin?(origin : Hash(String, JSON::Any)?) : Bool
      return false unless origin

      kind = string_field(origin, "kind")
      !kind.nil? && VISIBLE_META_ORIGINS.includes?(kind)
    end

    private def to_session_message(
      entry : TranscriptEntry,
      parent_tool_use_id : String? = nil,
      parent_agent_id : String? = nil,
    ) : SessionMessage?
      type = string_field(entry, "type")
      uuid = string_field(entry, "uuid")
      session_id = string_field(entry, "sessionId") || string_field(entry, "session_id")
      message = hash_field(entry, "message")
      return unless type && uuid && session_id && message

      SessionMessage.new(
        type: type,
        uuid: uuid,
        session_id: session_id,
        message: message,
        parent_tool_use_id: string_field(entry, "parentToolUseId") ||
                            string_field(entry, "parent_tool_use_id") || parent_tool_use_id,
        parent_agent_id: string_field(entry, "parentAgentId") ||
                         string_field(entry, "parent_agent_id") || parent_agent_id,
      )
    end

    # Read the `.meta.json` sidecar beside a subagent transcript. Returns
    # nil when the sidecar is missing, unreadable-as-absent
    # (`File::NotFoundError`), not valid JSON, or not a JSON object — an
    # unusable optional sidecar degrades to an absent one. Other read
    # errors propagate to the caller, which degrades them the same way.
    # Mirrors Python's `_read_agent_metadata_sidecar` (0.2.140).
    private def read_agent_metadata_sidecar(transcript_path : String) : Hash(String, JSON::Any)?
      raw = begin
        File.read(ClaudeAgent.agent_metadata_sidecar_path(transcript_path))
      rescue File::NotFoundError
        return
      end
      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParseException
        return
      end
      parsed.as_h?
    end

    # Extract `(tool_use_id, parent_agent_id)` from an agent metadata
    # dict — the on-disk `.meta.json` sidecar or the synthetic
    # `agent_metadata` entry a `SessionStore` carries in its place.
    # Mirrors Python's `_parent_ids_from_agent_metadata` (0.2.140).
    private def parent_ids_from_agent_metadata(meta : Hash(String, JSON::Any)?) : {String?, String?}
      return {nil, nil} unless meta

      tool_use_id = meta["toolUseId"]?.try(&.as_s?)
      parent_agent_id = meta["parentAgentId"]?.try(&.as_s?)
      {tool_use_id, parent_agent_id}
    end

    # Recover `(parent_tool_use_id, parent_agent_id)` for a subagent
    # transcript from its `.meta.json` sidecar. Like the transcript read
    # itself, any failure to read the sidecar degrades to "no metadata"
    # rather than raising from this best-effort read helper. Mirrors
    # Python's `get_subagent_messages` (0.2.140).
    private def subagent_parent_ids(transcript_path : String) : {String?, String?}
      parent_ids_from_agent_metadata(read_agent_metadata_sidecar(transcript_path))
    rescue File::Error
      {nil, nil}
    end

    # Separate the synthetic `agent_metadata` entry from transcript
    # lines. A subagent's `SessionStore` stream carries its `.meta.json`
    # sidecar as `{"type": "agent_metadata", ...}` entries alongside the
    # transcript. Returns `(metadata, transcript)` where metadata is the
    # *last* such entry (rewritten on resume, so last wins) or nil.
    # Mirrors Python's `_split_agent_metadata` (0.2.140).
    private def split_agent_metadata(
      entries : Array(SessionStoreEntry),
    ) : {Hash(String, JSON::Any)?, Array(Hash(String, JSON::Any))}
      metadata = nil.as(Hash(String, JSON::Any)?)
      transcript = [] of Hash(String, JSON::Any)
      entries.each do |entry|
        if entry.type == "agent_metadata"
          metadata = entry.to_h
        else
          transcript << entry.to_h
        end
      end
      {metadata, transcript}
    end

    private def extract_first_prompt(entries : Array(TranscriptEntry)) : String?
      command_fallback = nil.as(String?)

      entries.each do |entry|
        next unless string_field(entry, "type") == "user"
        next if bool_field(entry, "isMeta")
        next if bool_field(entry, "isCompactSummary")

        message = hash_field(entry, "message")
        next unless message

        texts = extract_message_texts(message)
        next if texts.empty?

        texts.each do |text|
          normalized = text.gsub('\n', ' ').strip
          next if normalized.empty?

          if match = COMMAND_NAME_REGEX.match(normalized)
            command_fallback ||= match[1]
            next
          end

          next if SKIP_FIRST_PROMPT.matches?(normalized)

          return truncate_prompt(normalized)
        end
      end

      command_fallback
    end

    private def extract_message_texts(message : Hash(String, JSON::Any)) : Array(String)
      content = message["content"]?
      return [] of String unless content

      if text = content.as_s?
        return [text]
      end

      blocks = content.as_a?
      return [] of String unless blocks

      return [] of String if blocks.any? { |block| hash = block.as_h?; hash && string_field(hash, "type") == "tool_result" }

      texts = [] of String
      blocks.each do |block|
        hash = block.as_h?
        next unless hash
        next unless string_field(hash, "type") == "text"

        if text = string_field(hash, "text")
          texts << text
        end
      end
      texts
    end

    private def truncate_prompt(prompt : String) : String
      return prompt if prompt.size <= 200

      truncated = prompt[0, 197]
      "#{truncated.rstrip}..."
    end

    private def deduplicate_by_session_id(sessions : Array(SDKSessionInfo)) : Array(SDKSessionInfo)
      by_id = {} of String => SDKSessionInfo

      sessions.each do |session|
        existing = by_id[session.session_id]?
        if existing.nil? || session.last_modified > existing.last_modified
          by_id[session.session_id] = session
        end
      end

      by_id.values
    end

    private def apply_sort_limit_and_offset(
      sessions : Array(SDKSessionInfo),
      limit : Int32?,
      offset : Int32,
    ) : Array(SDKSessionInfo)
      sorted = sessions.sort_by(&.last_modified)
      sorted.reverse!

      start = Math.max(offset, 0)
      return [] of SDKSessionInfo if start >= sorted.size

      page = sorted[start..] || [] of SDKSessionInfo
      return page unless limit && limit > 0

      page.first(limit)
    end

    private def build_session_info(
      session_id : String,
      file_path : String,
      project_path : String? = nil,
    ) : SDKSessionInfo?
      content = File.read(file_path)
      return if content.empty?

      first_entry = first_json_entry(content)
      return if first_entry && bool_field(first_entry, "isSidechain")

      entries = parse_jsonl_entries(content)
      return if entries.empty?

      custom_title = last_string_field(entries, "customTitle")
      first_prompt = extract_first_prompt(entries)
      summary = custom_title || last_string_field(entries, "summary") || first_prompt
      return unless summary

      info = File.info(file_path)
      git_branch = last_string_field(entries, "gitBranch") || first_string_field(entries, "gitBranch")
      session_cwd = first_string_field(entries, "cwd") || project_path
      tag = last_string_field(entries, "tag")
      tag = nil if tag == ""
      archived = resolve_archived_state(session_id, file_path, entries)

      SDKSessionInfo.new(
        session_id: session_id,
        summary: summary,
        last_modified: info.modification_time.to_unix_ms,
        file_size: info.size,
        custom_title: custom_title,
        first_prompt: first_prompt,
        git_branch: git_branch,
        cwd: session_cwd,
        tag: tag,
        created_at: first_timestamp_ms(entries),
        archived: archived,
      )
    rescue File::Error
      nil
    end

    private def resolve_session_file_path(session_id : String, directory : String?) : String?
      resolve_session_file_paths(session_id, directory).first?
    end

    private def resolve_session_file_paths(session_id : String, directory : String?) : Array(String)
      file_name = "#{session_id}.jsonl"
      paths = [] of String
      seen = Set(String).new

      if directory
        canonical_dir = canonicalize_path(directory)
        search_paths = Set{canonical_dir}
        worktree_paths(canonical_dir).each { |path| search_paths.add(path) }

        search_paths.each do |path|
          project_dir = find_project_dir(path)
          next unless project_dir

          file_path = File.join(project_dir, file_name)
          if File.exists?(file_path) && !seen.includes?(file_path)
            seen.add(file_path)
            paths << file_path
          end
        end

        return paths
      end

      projects_dir = projects_dir_path
      return paths unless Dir.exists?(projects_dir)

      Dir.children(projects_dir).each do |entry|
        project_dir = File.join(projects_dir, entry)
        next unless Dir.exists?(project_dir)

        file_path = File.join(project_dir, file_name)
        if File.exists?(file_path) && !seen.includes?(file_path)
          seen.add(file_path)
          paths << file_path
        end
      end

      paths
    rescue File::Error
      [] of String
    end

    private def append_to_session(session_id : String, data : String, directory : String?) : Nil
      file_path = resolve_append_path(session_id, directory)
      unless file_path
        missing_file = directory ? File.join(directory, "#{session_id}.jsonl") : "#{session_id}.jsonl"
        raise File::NotFoundError.new("Session #{session_id} not found", file: missing_file)
      end

      File.open(file_path, "a") do |file|
        file << data
      end
    end

    private def resolve_append_path(session_id : String, directory : String?) : String?
      file_name = "#{session_id}.jsonl"

      if directory
        canonical_dir = canonicalize_path(directory)
        project_dir = find_project_dir(canonical_dir)
        if project_dir
          path = File.join(project_dir, file_name)
          return path if appendable_session_file?(path)
        end

        worktree_paths(canonical_dir).each do |worktree_path|
          next if worktree_path == canonical_dir

          worktree_dir = find_project_dir(worktree_path)
          next unless worktree_dir

          candidate = File.join(worktree_dir, file_name)
          return candidate if appendable_session_file?(candidate)
        end

        return
      end

      projects_dir = projects_dir_path
      return unless Dir.exists?(projects_dir)

      Dir.children(projects_dir).each do |entry|
        candidate = File.join(projects_dir, entry, file_name)
        return candidate if appendable_session_file?(candidate)
      end

      nil
    end

    private def appendable_session_file?(file_path : String) : Bool
      return false unless File.exists?(file_path)

      File.info(file_path).size > 0
    rescue File::Error
      false
    end

    private def worktree_paths(cwd : String) : Array(String)
      output = IO::Memory.new
      Process.run(
        "git",
        ["worktree", "list", "--porcelain"],
        chdir: cwd,
        output: output,
        error: Process::Redirect::Close,
      )

      return [] of String unless $?.success?

      output.to_s.each_line.compact_map do |line|
        next unless line.starts_with?("worktree ")
        canonicalize_path(line.lchop("worktree ").strip)
      end.to_a
    rescue
      [] of String
    end

    private def valid_uuid?(value : String) : Bool
      UUID_REGEX.matches?(value)
    end

    private def first_json_entry(content : String) : TranscriptEntry?
      content.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          data = JSON.parse(line)
          hash = data.as_h?
          return hash if hash
        rescue JSON::ParseException
          return
        end
      end

      nil
    end

    private def first_string_field(entries : Array(TranscriptEntry), key : String) : String?
      entries.each do |entry|
        if value = string_field(entry, key)
          return value
        end
      end

      nil
    end

    private def last_string_field(entries : Array(TranscriptEntry), key : String) : String?
      value = nil.as(String?)
      entries.each do |entry|
        value = string_field(entry, key) || value
      end
      value
    end

    private def first_timestamp_ms(entries : Array(TranscriptEntry)) : Int64?
      timestamp = first_string_field(entries, "timestamp")
      return unless timestamp

      Time::Format::ISO_8601_DATE_TIME.parse(timestamp, Time::Location::UTC).to_unix_ms
    rescue Time::Format::Error
      nil
    end

    private def string_field(entry : TranscriptEntry, key : String) : String?
      entry[key]?.try(&.as_s?)
    end

    private def bool_field(entry : TranscriptEntry, key : String) : Bool
      entry[key]?.try(&.as_bool?) == true
    end

    private def hash_field(entry : TranscriptEntry, key : String) : Hash(String, JSON::Any)?
      entry[key]?.try(&.as_h?)
    end

    private def config_home_dir : String
      ENV["CLAUDE_CONFIG_DIR"]? || File.join(ENV["HOME"]? || ".", ".claude")
    end

    private def sanitize_unicode(value : String) : String
      current = value

      10.times do
        previous = current
        current = current.unicode_normalize(:nfkc)
        current = current.each_char.reject { |char| dangerous_unicode_char?(char) }.join
        break if current == previous
      end

      current
    end

    private def dangerous_unicode_char?(char : Char) : Bool
      ord = char.ord
      return true if 0x200B <= ord <= 0x200F
      return true if 0x202A <= ord <= 0x202E
      return true if 0x2066 <= ord <= 0x2069
      return true if ord == 0xFEFF
      return true if 0xE000 <= ord <= 0xF8FF

      false
    end

    private def projects_dir_path : String
      File.join(config_home_dir, "projects")
    end

    private def canonicalize_path(path : String) : String
      File.realpath(path)
    rescue File::Error
      File.expand_path(path)
    end

    private def find_project_dir(project_path : String) : String?
      exact = File.join(projects_dir_path, sanitize_path(project_path))
      return exact if Dir.exists?(exact)

      sanitized = sanitize_path(project_path)
      return if sanitized.size <= MAX_SANITIZED_LENGTH
      return unless Dir.exists?(projects_dir_path)

      prefix = sanitized[0, MAX_SANITIZED_LENGTH]
      Dir.children(projects_dir_path).each do |entry|
        full_path = File.join(projects_dir_path, entry)
        return full_path if Dir.exists?(full_path) && entry.starts_with?("#{prefix}-")
      end

      nil
    rescue File::Error
      nil
    end

    private def resolve_subagents_dir(session_id : String, directory : String?) : String?
      file_path = resolve_session_file_path(session_id, directory)
      return unless file_path

      project_dir = Path[file_path].parent.to_s
      File.join(project_dir, session_id, "subagents")
    end

    private def collect_agent_files(base_dir : String) : Array({String, String})
      results = [] of {String, String}
      return results unless Dir.exists?(base_dir)

      walk_agent_files(base_dir, results)
      results
    end

    private def walk_agent_files(current : String, results : Array({String, String})) : Nil
      entries = begin
        Dir.children(current).sort!
      rescue File::Error
        return
      end

      entries.each do |entry|
        path = File.join(current, entry)
        if File.file?(path) && entry.starts_with?("agent-") && entry.ends_with?(".jsonl")
          agent_id = entry.lchop("agent-").rchop(".jsonl")
          results << {agent_id, path}
        elsif Dir.exists?(path)
          walk_agent_files(path, results)
        end
      end
    end

    private def build_subagent_chain(entries : Array(TranscriptEntry)) : Array(TranscriptEntry)
      return [] of TranscriptEntry if entries.empty?

      by_uuid = {} of String => TranscriptEntry
      entries.each do |entry|
        uuid = string_field(entry, "uuid")
        by_uuid[uuid] = entry if uuid
      end

      leaf = nil.as(TranscriptEntry?)
      entries.reverse_each do |entry|
        type = string_field(entry, "type")
        if type == "user" || type == "assistant"
          leaf = entry
          break
        end
      end

      return [] of TranscriptEntry unless leaf

      chain = [] of TranscriptEntry
      seen = Set(String).new
      current = leaf

      loop do
        break unless current
        uuid = string_field(current, "uuid")
        break unless uuid
        break if seen.includes?(uuid)

        seen.add(uuid)
        chain << current

        parent = string_field(current, "parentUuid")
        break unless parent
        current = by_uuid[parent]?
      end

      chain.reverse!
      chain
    end

    private def find_session_file_with_dir(
      session_id : String,
      directory : String?,
    ) : Tuple(String, String)?
      file_name = "#{session_id}.jsonl"

      if directory
        canonical_dir = canonicalize_path(directory)
        project_dir = find_project_dir(canonical_dir)
        if project_dir
          path = File.join(project_dir, file_name)
          return {path, project_dir} if appendable_session_file?(path)
        end

        worktree_paths(canonical_dir).each do |worktree_path|
          next if worktree_path == canonical_dir
          worktree_dir = find_project_dir(worktree_path)
          next unless worktree_dir
          candidate = File.join(worktree_dir, file_name)
          return {candidate, worktree_dir} if appendable_session_file?(candidate)
        end

        return
      end

      projects_dir = projects_dir_path
      return unless Dir.exists?(projects_dir)

      Dir.children(projects_dir).each do |entry|
        project_dir = File.join(projects_dir, entry)
        next unless Dir.exists?(project_dir)

        candidate = File.join(project_dir, file_name)
        return {candidate, project_dir} if appendable_session_file?(candidate)
      end

      nil
    rescue File::Error
      nil
    end

    private def parse_fork_transcript(
      content : String,
      session_id : String,
    ) : Tuple(Array(TranscriptEntry), Array(JSON::Any))
      transcript = [] of TranscriptEntry
      content_replacements = [] of JSON::Any
      transcript_types = {"user", "assistant", "attachment", "system", "progress"}

      content.each_line do |raw_line|
        line = raw_line.strip
        next if line.empty?

        begin
          data = JSON.parse(line)
          entry = data.as_h?
          next unless entry

          type = string_field(entry, "type")
          uuid = string_field(entry, "uuid")
          if type && uuid && transcript_types.includes?(type)
            transcript << entry
          elsif type == "content-replacement" && string_field(entry, "sessionId") == session_id
            replacements = entry["replacements"]?.try(&.as_a?)
            replacements.try(&.each { |item| content_replacements << item })
          end
        rescue JSON::ParseException
        end
      end

      {transcript, content_replacements}
    end

    private def resolve_fork_parent(
      original : TranscriptEntry,
      by_uuid : Hash(String, TranscriptEntry),
      uuid_mapping : Hash(String, String),
    ) : String?
      parent_id = string_field(original, "parentUuid")

      while parent_id
        parent = by_uuid[parent_id]?
        break unless parent

        if string_field(parent, "type") != "progress"
          return uuid_mapping[parent_id]?
        end

        parent_id = string_field(parent, "parentUuid")
      end

      nil
    end

    private def derive_fork_title(content : String) : String
      entries = parse_jsonl_entries(content)
      base = last_string_field(entries, "customTitle") ||
             last_string_field(entries, "aiTitle") ||
             extract_first_prompt(entries) ||
             "Forked session"
      "#{base} (fork)"
    end

    private def simple_hash(value : String) : String
      hash = 0_i64

      value.each_char do |char|
        hash = ((hash << 5) - hash + char.ord.to_i64) & 0xFFFF_FFFF
        hash -= 0x1_0000_0000 if hash >= 0x8000_0000
      end

      number = hash.abs
      return "0" if number == 0

      digits = "0123456789abcdefghijklmnopqrstuvwxyz"
      chars = [] of Char

      while number > 0
        chars << digits[(number % 36).to_i]
        number //= 36
      end

      chars.reverse.join
    end

    # ------------------------------------------------------------------
    # SessionStore-backed helpers
    # ------------------------------------------------------------------

    DEFAULT_IMPORT_BATCH_SIZE = 500
    MAX_IMPORT_BATCH_BYTES    = 1 << 20 # 1 MiB

    def project_key_for_directory(directory : String? = nil) : String
      abs_path = canonicalize_path(directory || ".")
      sanitize_path(abs_path)
    end

    # Replay a local on-disk session transcript into a SessionStore.
    def import_session_to_store(
      session_id : String,
      store : SessionStore,
      directory : String? = nil,
      include_subagents : Bool = true,
      batch_size : Int32 = DEFAULT_IMPORT_BATCH_SIZE,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      file_path = resolve_session_file_path(session_id, directory)
      unless file_path
        missing = directory ? File.join(directory, "#{session_id}.jsonl") : "#{session_id}.jsonl"
        raise File::NotFoundError.new("Session #{session_id} not found", file: missing)
      end

      project_key = Path[file_path].parent.basename
      effective_batch = batch_size > 0 ? batch_size : DEFAULT_IMPORT_BATCH_SIZE
      main_key = SessionKey.new(project_key, session_id)
      append_jsonl_file_in_batches(file_path, main_key, store, effective_batch)

      return unless include_subagents

      session_dir = file_path.rchop(".jsonl")
      subagents_dir = File.join(session_dir, "subagents")
      collect_jsonl_files(subagents_dir).each do |sub_path|
        rel = Path[sub_path].relative_to(session_dir).to_s
        subpath = rel.ends_with?(".jsonl") ? rel.rchop(".jsonl") : rel
        sub_key = SessionKey.new(project_key, session_id, subpath)
        append_jsonl_file_in_batches(sub_path, sub_key, store, effective_batch)

        meta_path = sub_path.rchop(".jsonl") + ".meta.json"
        next unless File.exists?(meta_path)

        # A missing, corrupt, or non-object sidecar is treated as absent
        # (the transcript is still imported); other read errors
        # propagate. Mirrors Python's `import_session_to_store` (0.2.140):
        # the synthetic discriminator is assigned (not merged) so a
        # stray "type" key in the CLI-owned sidecar can never shadow it.
        begin
          parsed = JSON.parse(File.read(meta_path))
          if meta = parsed.as_h?
            meta = meta.dup
            meta["type"] = JSON::Any.new("agent_metadata")
            store.append(sub_key, [SessionStoreEntry.from_hash(meta)])
          end
        rescue JSON::ParseException
        end
      end
    end

    def list_sessions_from_store(
      store : SessionStore,
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
    ) : Array(SDKSessionInfo)
      project_path = canonicalize_path(directory || ".")
      project_key = sanitize_path(project_path)

      unless store.supports_list_sessions? || store.supports_list_session_summaries?
        raise ArgumentError.new(
          "session_store implements neither list_session_summaries() nor " \
          "list_sessions() -- cannot list sessions. Provide a store with at " \
          "least one of those methods."
        )
      end

      results = [] of SDKSessionInfo

      if store.supports_list_session_summaries?
        begin
          store.list_session_summaries(project_key).each do |summary|
            if info = summary_entry_to_sdk_info(summary, project_path)
              results << info
            end
          end
        rescue SessionStoreNotImplementedError
        end
      end

      if results.empty? && store.supports_list_sessions?
        store.list_sessions(project_key).each do |entry|
          if info = get_session_info_from_store(store, entry.session_id, directory)
            # Prefer store mtime when available.
            results << SDKSessionInfo.new(
              session_id: info.session_id,
              summary: info.summary,
              last_modified: entry.mtime,
              file_size: info.file_size,
              custom_title: info.custom_title,
              first_prompt: info.first_prompt,
              git_branch: info.git_branch,
              cwd: info.cwd,
              tag: info.tag,
              created_at: info.created_at,
            )
          end
        end
      end

      apply_sort_limit_and_offset(results, limit, offset)
    end

    def get_session_info_from_store(
      store : SessionStore,
      session_id : String,
      directory : String? = nil,
    ) : SDKSessionInfo?
      return unless valid_uuid?(session_id)

      project_key = project_key_for_directory(directory)
      key = SessionKey.new(project_key, session_id)
      entries = store.load(key)
      return if entries.nil? || entries.empty?

      build_session_info_from_store_entries(session_id, entries, directory)
    end

    def get_session_messages_from_store(
      store : SessionStore,
      session_id : String,
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
      include_system_messages : Bool = false,
    ) : Array(SessionMessage)
      return [] of SessionMessage unless valid_uuid?(session_id)

      project_key = project_key_for_directory(directory)
      key = SessionKey.new(project_key, session_id)
      entries = store.load(key)
      return [] of SessionMessage if entries.nil? || entries.empty?

      if first = entries.first?
        return [] of SessionMessage if first.bool_field("isSidechain")
      end

      transcript, delivered = filter_store_transcript_with_delivery(entries)
      entries_to_session_messages(transcript, limit, offset, include_system_messages, delivered)
    end

    def rename_session_via_store(
      store : SessionStore,
      session_id : String,
      title : String,
      directory : String? = nil,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)
      stripped = title.strip
      raise ArgumentError.new("title must be non-empty") if stripped.empty?

      key = SessionKey.new(project_key_for_directory(directory), session_id)
      entry = SessionStoreEntry.from_hash({
        "type"        => JSON::Any.new("custom-title"),
        "customTitle" => JSON::Any.new(stripped),
        "sessionId"   => JSON::Any.new(session_id),
        "uuid"        => JSON::Any.new(UUID.random.to_s),
        "timestamp"   => JSON::Any.new(Time.utc.to_rfc3339),
      })
      store.append(key, [entry])
    end

    def tag_session_via_store(
      store : SessionStore,
      session_id : String,
      tag : String?,
      directory : String? = nil,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      sanitized_tag = if tag
                        value = sanitize_unicode(tag).strip
                        raise ArgumentError.new("tag must be non-empty (use nil to clear)") if value.empty?
                        value
                      end

      key = SessionKey.new(project_key_for_directory(directory), session_id)
      entry = SessionStoreEntry.from_hash({
        "type"      => JSON::Any.new("tag"),
        "tag"       => JSON::Any.new(sanitized_tag || ""),
        "sessionId" => JSON::Any.new(session_id),
        "uuid"      => JSON::Any.new(UUID.random.to_s),
        "timestamp" => JSON::Any.new(Time.utc.to_rfc3339),
      })
      store.append(key, [entry])
    end

    def delete_session_via_store(
      store : SessionStore,
      session_id : String,
      directory : String? = nil,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)
      return unless store.supports_delete?

      key = SessionKey.new(project_key_for_directory(directory), session_id)
      store.delete(key)
    end

    def fork_session_via_store(
      store : SessionStore,
      session_id : String,
      directory : String? = nil,
      up_to_message_id : String? = nil,
      title : String? = nil,
    ) : ForkSessionResult
      validate_fork_inputs!(session_id, up_to_message_id)

      project_key = project_key_for_directory(directory)
      src_key = SessionKey.new(project_key, session_id)
      loaded = store.load(src_key)
      raise File::NotFoundError.new("Session #{session_id} not found", file: "#{session_id}.jsonl") unless loaded
      raise ArgumentError.new("Session #{session_id} has no messages to fork") if loaded.empty?

      content = loaded.map(&.to_h.to_json).join("\n") + "\n"
      forked_session_id = UUID.random.to_s
      lines = prepare_and_build_fork_lines(content, session_id, forked_session_id, up_to_message_id, title)

      forked_entries = lines.compact_map do |line|
        fork_entry_from_line(line)
      end

      dst_key = SessionKey.new(project_key, forked_session_id)
      store.append(dst_key, forked_entries)
      ForkSessionResult.new(forked_session_id)
    end

    def list_subagents_from_store(
      store : SessionStore,
      session_id : String,
      directory : String? = nil,
    ) : Array(String)
      return [] of String unless valid_uuid?(session_id)
      unless store.supports_list_subkeys?
        raise ArgumentError.new(
          "session_store does not implement list_subkeys() -- cannot list " \
          "subagents. Provide a store with a list_subkeys() method."
        )
      end

      project_key = project_key_for_directory(directory)
      subkeys = store.list_subkeys(SessionListSubkeysKey.new(project_key, session_id))
      seen = Set(String).new
      ids = [] of String
      subkeys.each do |subpath|
        next unless subpath.starts_with?("subagents/")
        last = subpath.split('/').last
        next unless last.starts_with?("agent-")
        agent_id = last.lchop("agent-")
        unless seen.includes?(agent_id)
          seen.add(agent_id)
          ids << agent_id
        end
      end
      ids
    end

    def get_subagent_messages_from_store(
      store : SessionStore,
      session_id : String,
      agent_id : String,
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
    ) : Array(SessionMessage)
      return [] of SessionMessage unless valid_uuid?(session_id)
      return [] of SessionMessage if agent_id.empty?

      project_key = project_key_for_directory(directory)
      subpath = resolve_store_subagent_subpath(store, project_key, session_id, agent_id)
      return [] of SessionMessage unless subpath

      entries = store.load(SessionKey.new(project_key, session_id, subpath))
      return [] of SessionMessage unless entries

      messages = session_messages_from_store_entries(entries)
      paginate_session_messages(messages, limit, offset)
    end

    private def resolve_store_subagent_subpath(
      store : SessionStore,
      project_key : String,
      session_id : String,
      agent_id : String,
    ) : String?
      default_path = "subagents/agent-#{agent_id}"
      return default_path unless store.supports_list_subkeys?

      target = "agent-#{agent_id}"
      store.list_subkeys(SessionListSubkeysKey.new(project_key, session_id)).find do |subkey|
        subkey.starts_with?("subagents/") && subkey.split('/').last == target
      end
    end

    private def session_messages_from_store_entries(
      entries : Array(SessionStoreEntry),
    ) : Array(SessionMessage)
      metadata, transcript = split_agent_metadata(entries)
      parent_tool_use_id, parent_agent_id = parent_ids_from_agent_metadata(metadata)
      subagent_entries_to_messages(filter_transcript_hashes(transcript), parent_tool_use_id, parent_agent_id)
    end

    # Parse one forked JSONL line, skipping lines that do not decode.
    # A corrupt line must not abort the fork of the remaining lines.
    private def fork_entry_from_line(line : String) : SessionStoreEntry?
      SessionStoreEntry.from_hash(JSON.parse(line).as_h)
    rescue
      nil
    end

    private def paginate_session_messages(
      messages : Array(SessionMessage),
      limit : Int32?,
      offset : Int32,
    ) : Array(SessionMessage)
      start = Math.max(offset, 0)
      return [] of SessionMessage if start >= messages.size

      if limit && limit > 0
        messages[start, limit]? || [] of SessionMessage
      else
        messages[start..] || [] of SessionMessage
      end
    end

    # Convert a SessionSummaryEntry to SDKSessionInfo.
    def summary_entry_to_sdk_info(
      entry : SessionSummaryEntry,
      project_path : String? = nil,
    ) : SDKSessionInfo?
      data = entry.data
      return if data["is_sidechain"]?.try(&.as_bool?) == true

      first_prompt = if data["first_prompt_locked"]?.try(&.as_bool?)
                       data["first_prompt"]?.try(&.as_s?)
                     else
                       data["command_fallback"]?.try(&.as_s?)
                     end

      custom_title = data["custom_title"]?.try(&.as_s?) || data["ai_title"]?.try(&.as_s?)
      summary = custom_title ||
                data["last_prompt"]?.try(&.as_s?) ||
                data["summary_hint"]?.try(&.as_s?) ||
                first_prompt
      return unless summary

      SDKSessionInfo.new(
        session_id: entry.session_id,
        summary: summary,
        last_modified: entry.mtime,
        file_size: 0_i64,
        custom_title: custom_title,
        first_prompt: first_prompt,
        git_branch: data["git_branch"]?.try(&.as_s?),
        cwd: data["cwd"]?.try(&.as_s?) || project_path,
        tag: data["tag"]?.try(&.as_s?),
        created_at: data["created_at"]?.try(&.as_i64?),
      )
    end

    private def build_session_info_from_store_entries(
      session_id : String,
      entries : Array(SessionStoreEntry),
      directory : String?,
    ) : SDKSessionInfo?
      return if entries.first.bool_field("isSidechain")

      hashes = entries.map(&.to_h)
      custom_title = last_string_field(hashes, "customTitle")
      first_prompt = extract_first_prompt(hashes)
      summary = custom_title || last_string_field(hashes, "summary") || first_prompt
      return unless summary

      mtime = entries.reverse_each.compact_map do |entry|
        iso_timestamp_ms(entry.timestamp)
      end.first? || Time.utc.to_unix_ms

      project_path = canonicalize_path(directory || ".")
      tag = last_string_field(hashes, "tag")
      tag = nil if tag && tag.empty?

      SDKSessionInfo.new(
        session_id: session_id,
        summary: summary,
        last_modified: mtime,
        file_size: 0_i64,
        custom_title: custom_title,
        first_prompt: first_prompt,
        git_branch: last_string_field(hashes, "gitBranch") || first_string_field(hashes, "gitBranch"),
        cwd: first_string_field(hashes, "cwd") || project_path,
        tag: tag,
        created_at: first_timestamp_ms(hashes),
      )
    end

    private def append_jsonl_file_in_batches(
      file_path : String,
      key : SessionKey,
      store : SessionStore,
      batch_size : Int32,
    ) : Nil
      batch = [] of SessionStoreEntry
      nbytes = 0

      File.each_line(file_path) do |line|
        line = line.rstrip('\n').rstrip('\r')
        next if line.empty?

        begin
          hash = JSON.parse(line).as_h
          batch << SessionStoreEntry.from_hash(hash)
          nbytes += line.bytesize
          if batch.size >= batch_size || nbytes >= MAX_IMPORT_BATCH_BYTES
            store.append(key, batch)
            batch = [] of SessionStoreEntry
            nbytes = 0
          end
        rescue JSON::ParseException
        end
      end

      store.append(key, batch) unless batch.empty?
    end

    private def collect_jsonl_files(base_dir : String) : Array(String)
      results = [] of String
      return results unless Dir.exists?(base_dir)
      walk_jsonl_files(base_dir, results)
      results
    end

    private def walk_jsonl_files(current : String, results : Array(String)) : Nil
      entries = begin
        Dir.children(current).sort!
      rescue File::Error
        return
      end

      entries.each do |entry|
        path = File.join(current, entry)
        if File.file?(path) && entry.ends_with?(".jsonl")
          results << path
        elsif Dir.exists?(path)
          walk_jsonl_files(path, results)
        end
      end
    end

    private def filter_transcript_entries(entries : Array(SessionStoreEntry)) : Array(TranscriptEntry)
      types = {"user", "assistant", "progress", "system", "attachment"}
      entries.compact_map do |entry|
        next unless entry.uuid
        next unless types.includes?(entry.type)
        entry.to_h
      end
    end

    private def filter_transcript_hashes(entries : Array(TranscriptEntry)) : Array(TranscriptEntry)
      types = {"user", "assistant", "progress", "system", "attachment"}
      entries.select do |entry|
        type = string_field(entry, "type")
        uuid = string_field(entry, "uuid")
        uuid && type && types.includes?(type)
      end
    end

    private def iso_timestamp_ms(ts : String?) : Int64?
      parse_iso_time(ts).try(&.to_unix_ms)
    end

    private def parse_iso_time(ts : String?) : Time?
      return unless ts
      Time::Format::ISO_8601_DATE_TIME.parse(ts, Time::Location::UTC)
    rescue Time::Format::Error
      nil
    end

    private def json_any_present?(entry : TranscriptEntry, key : String) : Bool
      val = entry[key]?
      !val.nil? && !val.raw.nil?
    end

    private def json_string_array(any : JSON::Any?) : Array(String)
      arr = any.try(&.as_a?)
      return [] of String unless arr
      arr.compact_map(&.as_s?)
    end

    # ------------------------------------------------------------------
    # Archive / unarchive sidecar helpers
    # ------------------------------------------------------------------

    private def set_session_archived(
      session_id : String,
      archived : Bool,
      directory : String?,
    ) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      file_paths = resolve_session_file_paths(session_id, directory)
      if file_paths.empty?
        missing = directory ? File.join(directory, "#{session_id}.jsonl") : "#{session_id}.jsonl"
        raise File::NotFoundError.new("Session #{session_id} not found", file: missing)
      end

      payload = {
        "archived" => JSON::Any.new(archived),
        "at"       => JSON::Any.new(Time.utc.to_rfc3339(fraction_digits: 3)),
        "by"       => JSON::Any.new("sdk"),
      }.to_json

      file_paths.each do |file_path|
        write_archived_sidecar(file_path, session_id, payload)
      end
    end

    private def write_archived_sidecar(file_path : String, session_id : String, payload : String) : Nil
      sidecar_dir = File.join(Path[file_path].parent.to_s, session_id)
      existed = Dir.exists?(sidecar_dir)
      Dir.mkdir_p(sidecar_dir, 0o700) unless existed
      File.chmod(sidecar_dir, 0o700) unless existed

      sidecar_path = File.join(sidecar_dir, "archived.json")
      File.write(sidecar_path, payload)
      File.chmod(sidecar_path, 0o600)
    end

    private def resolve_archived_state(
      session_id : String,
      file_path : String,
      entries : Array(TranscriptEntry),
    ) : Bool?
      sidecar = read_archived_sidecar(session_id, file_path)
      return unless sidecar

      archived, at_time = sidecar
      return false unless archived

      auto_unarchived = entries.any? { |entry| newer_unarchiving_prompt?(entry, at_time) }
      auto_unarchived ? false : true
    end

    private def read_archived_sidecar(session_id : String, file_path : String) : {Bool, Time}?
      sidecar_path = File.join(Path[file_path].parent.to_s, session_id, "archived.json")
      info = File.info?(sidecar_path)
      return unless info && info.file? && info.size <= MAX_ARCHIVED_SIDECAR_BYTES

      parsed = JSON.parse(File.read(sidecar_path)).as_h?
      return unless parsed

      archived = parsed["archived"]?.try(&.as_bool?)
      return if archived.nil?

      at_time = parse_iso_time(parsed["at"]?.try(&.as_s?))
      return unless at_time

      {archived, at_time}
    rescue File::Error | JSON::ParseException
      nil
    end

    private def newer_unarchiving_prompt?(entry : TranscriptEntry, at_time : Time) : Bool
      return false if bool_field(entry, "isSidechain")

      entry_time = parse_iso_time(string_field(entry, "timestamp"))
      return false unless entry_time && entry_time > at_time

      case string_field(entry, "type")
      when "user"
        valid_unarchiving_user_entry?(entry)
      when "attachment"
        att = queued_command_hash(entry)
        att ? valid_unarchiving_queued_entry?(att) : false
      when "queued_command"
        valid_unarchiving_queued_entry?(entry)
      else
        false
      end
    end

    private def valid_unarchiving_user_entry?(entry : TranscriptEntry) : Bool
      rejected_flags = {
        "isCompactSummary", "isMeta", "isVirtual", "isVisibleInTranscriptOnly",
        "textNotTyped", "handedOff", "queueSkipAttachments",
      }
      return false if rejected_flags.any? { |flag| bool_field(entry, flag) }
      return false if %w[persist wakeupSource scheduledTaskId toolUseResult].any? { |k| json_any_present?(entry, k) }

      origin = hash_field(entry, "origin")
      if json_any_present?(entry, "origin")
        return false unless origin && string_field(origin, "kind") == "human"
      end

      message = hash_field(entry, "message")
      return false unless message

      unarchiving_prompt_content?(
        message["content"]?,
        has_origin: !origin.nil?,
        has_prompt_source: !string_field(entry, "promptSource").nil?,
      )
    end

    private def valid_unarchiving_queued_entry?(obj : TranscriptEntry) : Bool
      return false if bool_field(obj, "isMeta")

      origin = hash_field(obj, "origin")
      if json_any_present?(obj, "origin")
        return false unless origin && string_field(origin, "kind") == "human"
      end

      content = obj["prompt"]? || hash_field(obj, "message").try(&.["content"]?)
      unarchiving_prompt_content?(content, has_origin: !origin.nil?, has_prompt_source: false)
    end

    private def unarchiving_prompt_content?(
      content : JSON::Any?,
      has_origin : Bool,
      has_prompt_source : Bool,
    ) : Bool
      return false unless content

      texts = unarchiving_texts_from_content(content)
      return false unless texts
      return true if texts.is_a?(Symbol)

      if has_origin || has_prompt_source
        trimmed = texts.map(&.lstrip)
        return trimmed.any? { |text| !text.empty? } && !trimmed.any?(&.starts_with?("<command-name>"))
      end

      texts.any? { |text| meaningful_unarchiving_text?(text) }
    end

    private def unarchiving_texts_from_content(content : JSON::Any) : (Array(String) | Symbol)?
      if text = content.as_s?
        return [text]
      end

      blocks = content.as_a?
      return unless blocks

      has_media = false
      texts = [] of String
      blocks.each do |block|
        hash = block.as_h?
        next unless hash

        block_type = string_field(hash, "type")
        return if block_type == "tool_result"

        if block_type == "image" || block_type == "document"
          has_media = true
        elsif block_type == "text"
          if text = string_field(hash, "text")
            texts << text
          end
        end
      end

      return :media if has_media
      texts
    end

    private def meaningful_unarchiving_text?(text : String) : Bool
      lstrip = text.lstrip
      return true if lstrip.starts_with?("<command-message>") || lstrip.starts_with?("<bash-input>")

      normalized = text.gsub('\n', ' ').strip
      return false if normalized.empty?
      return false if COMMAND_NAME_REGEX.matches?(normalized)
      return false if SKIP_FIRST_PROMPT.matches?(normalized)

      true
    end

    # ------------------------------------------------------------------
    # Recursive directory removal with retry (TS 0.3.319)
    # ------------------------------------------------------------------

    private def remove_tree_with_retry(path : String) : Nil
      return unless File.info?(path, follow_symlinks: false)

      attempt = 1
      loop do
        begin
          FileUtils.rm_r(path)
          return
        rescue ex : File::NotFoundError
          return unless File.info?(path, follow_symlinks: false)
          raise ex if attempt >= DELETE_MAX_ATTEMPTS
        rescue ex : File::Error
          raise ex if attempt >= DELETE_MAX_ATTEMPTS
        end

        sleep (DELETE_BACKOFF_BASE_MS * attempt).milliseconds
        attempt += 1
      end
    end

    # ------------------------------------------------------------------
    # Transcript chain assembly, parallel tool recovery & queued prompts
    # ------------------------------------------------------------------

    private class DeliveryTracker
      def initialize
        @counts = {} of String => Int32
        @copies = {} of String => String
        @mixed = Set(String).new
        @delivery_copies = {} of String => Array(String)
        @delivery_copy_uuids = Set(String).new
      end

      def process(entry : TranscriptEntry) : Nil
        if entry["type"]?.try(&.as_s?) == "queue-operation"
          record_queue_removal(entry)
          return
        end

        return unless entry["type"]?.try(&.as_s?) && (entry_uuid = entry["uuid"]?.try(&.as_s?))

        att = entry["type"]?.try(&.as_s?) == "attachment" ? entry["attachment"]?.try(&.as_h?) : nil
        return unless att && att["type"]?.try(&.as_s?) == "queued_command"

        if did = non_empty_string(att["delivery_id"]?)
          record_delivery_copy(did, entry_uuid)
        elsif suid = non_empty_string(att["source_uuid"]?)
          record_source_copy(suid, att)
        end
      end

      def finalize : DeliveryCounts
        @mixed.each { |suid| @counts.delete("uuid:#{suid}") }
        @delivery_copies.each do |key, uuids|
          count = @counts[key]? || 0
          start = Math.max(0, uuids.size - count)
          uuids[start..].each { |uid| @counts["entry:#{uid}"] = 1 }
        end
        @counts
      end

      private def record_queue_removal(entry : TranscriptEntry) : Nil
        return unless entry["operation"]?.try(&.as_s?) == "remove"
        return unless entry["reason"]?.try(&.as_s?) == "absorbed_mid_turn"

        did = non_empty_string(entry["deliveryId"]?)
        cid = non_empty_string(entry["commandUuid"]?)
        key = if did
                "delivery:#{did}"
              elsif cid
                "uuid:#{cid}"
              end
        @counts[key] = (@counts[key]? || 0) + 1 if key
      end

      private def record_delivery_copy(did : String, entry_uuid : String) : Nil
        return if @delivery_copy_uuids.includes?(entry_uuid)

        @delivery_copy_uuids.add(entry_uuid)
        (@delivery_copies["delivery:#{did}"] ||= [] of String) << entry_uuid
      end

      private def record_source_copy(suid : String, att : Hash(String, JSON::Any)) : Nil
        serialized = att.to_json
        if prev = @copies[suid]?
          @mixed.add(suid) if prev != serialized
        else
          @copies[suid] = serialized
        end
      end

      private def non_empty_string(any : JSON::Any?) : String?
        val = any.try(&.as_s?)
        val && !val.empty? ? val : nil
      end
    end

    private def entries_to_session_messages(
      entries : Array(TranscriptEntry),
      limit : Int32? = nil,
      offset : Int32 = 0,
      include_system_messages : Bool = false,
      delivered : DeliveryCounts? = nil,
    ) : Array(SessionMessage)
      context = build_conversation_chain_context(entries)
      chain = context[:chain]
      trailing = collect_trailing_queued_commands(entries, context[:by_uuid], chain, context[:leaf])
      trailing_ids = trailing.compact_map { |entry| string_field(entry, "uuid") }.to_set

      transformed = transform_queued_commands(
        chain + trailing,
        keep_meta: false,
        trailing_ids: trailing_ids,
        delivered: delivered,
      )

      messages = transformed.compact_map do |entry|
        next unless visible_message?(entry, include_system_messages)
        to_session_message(entry)
      end

      paginate_session_messages(messages, limit, offset)
    end

    private def filter_store_transcript_with_delivery(
      entries : Array(SessionStoreEntry),
    ) : {Array(TranscriptEntry), DeliveryCounts}
      transcript = [] of TranscriptEntry
      tracker = DeliveryTracker.new

      entries.each do |entry|
        hash = entry.to_h
        tracker.process(hash)
        transcript << hash if transcript_entry?(hash)
      end

      {transcript, tracker.finalize}
    end

    private def subagent_entries_to_messages(
      entries : Array(TranscriptEntry),
      parent_tool_use_id : String?,
      parent_agent_id : String?,
    ) : Array(SessionMessage)
      chain = build_subagent_chain(entries)
      transformed = transform_queued_commands(chain, keep_meta: true)
      transformed.compact_map do |entry|
        next unless {"user", "assistant"}.includes?(string_field(entry, "type"))
        to_session_message(entry, parent_tool_use_id, parent_agent_id)
      end
    end

    private def assistant_message_id(entry : TranscriptEntry) : String?
      return unless string_field(entry, "type") == "assistant"
      message = hash_field(entry, "message")
      return unless message

      message_id = string_field(message, "id")
      message_id && !message_id.empty? ? message_id : nil
    end

    private def content_block_ids(
      entry : TranscriptEntry,
      block_type : String,
      id_field : String,
    ) : Array(String)
      message = hash_field(entry, "message")
      return [] of String unless message
      content = message["content"]?.try(&.as_a?)
      return [] of String unless content

      content.compact_map do |block|
        hash = block.as_h?
        next unless hash && string_field(hash, "type") == block_type
        string_field(hash, id_field)
      end
    end

    private def tool_result_entry?(entry : TranscriptEntry) : Bool
      return false unless string_field(entry, "type") == "user"
      parent = string_field(entry, "parentUuid")
      return false if parent.nil? || parent.empty?
      message = hash_field(entry, "message")
      return false unless message
      content = message["content"]?.try(&.as_a?)
      return false unless content

      content.any? do |block|
        hash = block.as_h?
        hash && string_field(hash, "type") == "tool_result"
      end
    end

    private def same_writer?(a : TranscriptEntry, b : TranscriptEntry) : Bool
      bool_field(a, "isSidechain") == bool_field(b, "isSidechain") &&
        string_field(a, "agentId") == string_field(b, "agentId")
    end

    private def timestamp_sort_key(entry : TranscriptEntry) : String
      string_field(entry, "timestamp") || ""
    end

    private def stable_sort_by_timestamp(entries : Array(TranscriptEntry)) : Array(TranscriptEntry)
      return entries if entries.size <= 1

      entries
        .each_with_index
        .to_a
        .sort_by { |entry, idx| {timestamp_sort_key(entry), idx} }
        .map(&.[0])
    end

    private def recover_orphaned_parallel_tool_results(
      by_uuid : Hash(String, TranscriptEntry),
      chain : Array(TranscriptEntry),
      seen : Set(String),
    ) : Array(TranscriptEntry)
      chain_assistants = chain.select { |entry| string_field(entry, "type") == "assistant" }
      return chain if chain_assistants.empty?

      anchor_by_message_id = build_anchor_by_message_id(chain_assistants)
      return chain if anchor_by_message_id.empty?

      siblings_by_message_id, call_owner, tool_result_entries = collect_parallel_tool_indices(by_uuid)
      results_by_assistant = index_tool_results_by_assistant(tool_result_entries, by_uuid, call_owner)

      inserts = build_parallel_recovery_inserts(
        chain,
        chain_assistants,
        anchor_by_message_id,
        siblings_by_message_id,
        call_owner,
        results_by_assistant,
        by_uuid,
        seen,
      )
      return chain if inserts.empty?

      splice_recovered_entries(chain, inserts)
    end

    private def build_anchor_by_message_id(
      chain_assistants : Array(TranscriptEntry),
    ) : Hash(String, TranscriptEntry)
      anchors = {} of String => TranscriptEntry
      chain_assistants.each do |entry|
        if message_id = assistant_message_id(entry)
          anchors[message_id] = entry
        end
      end
      anchors
    end

    private def collect_parallel_tool_indices(
      by_uuid : Hash(String, TranscriptEntry),
    ) : {Hash(String, Array(TranscriptEntry)), Hash(String, TranscriptEntry?), Array(TranscriptEntry)}
      siblings = {} of String => Array(TranscriptEntry)
      call_owner = {} of String => TranscriptEntry?
      tool_results = [] of TranscriptEntry

      by_uuid.each_value do |entry|
        if message_id = assistant_message_id(entry)
          (siblings[message_id] ||= [] of TranscriptEntry) << entry
          record_call_owners(entry, message_id, call_owner)
        elsif tool_result_entry?(entry)
          tool_results << entry
        end
      end

      {siblings, call_owner, tool_results}
    end

    private def record_call_owners(
      entry : TranscriptEntry,
      message_id : String,
      call_owner : Hash(String, TranscriptEntry?),
    ) : Nil
      content_block_ids(entry, "tool_use", "id").each do |call_id|
        if !call_owner.has_key?(call_id)
          call_owner[call_id] = entry
        else
          owner = call_owner[call_id]
          same_response = !owner.nil? && assistant_message_id(owner) == message_id
          call_owner[call_id] = same_response ? entry : nil
        end
      end
    end

    private def index_tool_results_by_assistant(
      tool_result_entries : Array(TranscriptEntry),
      by_uuid : Hash(String, TranscriptEntry),
      call_owner : Hash(String, TranscriptEntry?),
    ) : Hash(String, Array(TranscriptEntry))
      indexed = {} of String => Array(TranscriptEntry)

      tool_result_entries.each do |result|
        if parent_uuid = string_field(result, "parentUuid")
          (indexed[parent_uuid] ||= [] of TranscriptEntry) << result
        end

        if source = string_field(result, "sourceToolAssistantUUID")
          if (source_entry = by_uuid[source]?) && same_writer?(result, source_entry)
            (indexed[source] ||= [] of TranscriptEntry) << result
          end
        end

        content_block_ids(result, "tool_result", "tool_use_id").each do |call_id|
          if (owner = call_owner[call_id]?) && same_writer?(result, owner)
            if owner_uuid = string_field(owner, "uuid")
              (indexed[owner_uuid] ||= [] of TranscriptEntry) << result
            end
          end
        end
      end

      indexed
    end

    private def build_parallel_recovery_inserts(
      chain : Array(TranscriptEntry),
      chain_assistants : Array(TranscriptEntry),
      anchor_by_message_id : Hash(String, TranscriptEntry),
      siblings_by_message_id : Hash(String, Array(TranscriptEntry)),
      call_owner : Hash(String, TranscriptEntry?),
      results_by_assistant : Hash(String, Array(TranscriptEntry)),
      by_uuid : Hash(String, TranscriptEntry),
      seen : Set(String),
    ) : Hash(String, Array(TranscriptEntry))
      answered_on_chain : Set(String)? = nil
      file_position : Hash(String, Int32)? = nil
      processed = Set(String).new
      inserts = {} of String => Array(TranscriptEntry)

      chain_assistants.each do |assistant|
        message_id = assistant_message_id(assistant)
        next if message_id.nil? || processed.includes?(message_id)
        processed.add(message_id)

        group = siblings_by_message_id[message_id]? || [assistant]
        member_uuids = group.compact_map { |member| string_field(member, "uuid") }.to_set
        orphaned_siblings = group.select { |member| (u = string_field(member, "uuid")) && !seen.includes?(u) }
        orphaned_results, strays = collect_group_results(group, member_uuids, results_by_assistant, seen)

        unless strays.empty?
          answered_on_chain ||= build_answered_on_chain(chain)
          file_position ||= build_file_position(by_uuid)
          orphaned_results.concat(
            filter_answering_strays(strays, orphaned_results, answered_on_chain, file_position, call_owner, member_uuids)
          )
        end

        next if orphaned_siblings.empty? && orphaned_results.empty?

        recovered = stable_sort_by_timestamp(orphaned_siblings) + stable_sort_by_timestamp(orphaned_results)
        recovered.each do |entry|
          if uuid = string_field(entry, "uuid")
            seen.add(uuid)
          end
        end

        if anchor_uuid = anchor_by_message_id[message_id]?.try { |a| string_field(a, "uuid") }
          inserts[anchor_uuid] = recovered
        end
      end

      inserts
    end

    private def collect_group_results(
      group : Array(TranscriptEntry),
      member_uuids : Set(String),
      results_by_assistant : Hash(String, Array(TranscriptEntry)),
      seen : Set(String),
    ) : {Array(TranscriptEntry), Array(TranscriptEntry)}
      orphaned = [] of TranscriptEntry
      strays = [] of TranscriptEntry
      collected = Set(String).new

      group.each do |member|
        member_uuid = string_field(member, "uuid")
        next unless member_uuid

        (results_by_assistant[member_uuid]? || [] of TranscriptEntry).each do |result|
          result_uuid = string_field(result, "uuid")
          next if result_uuid.nil? || seen.includes?(result_uuid) || collected.includes?(result_uuid)
          collected.add(result_uuid)

          parent = string_field(result, "parentUuid")
          if parent && member_uuids.includes?(parent)
            orphaned << result
          else
            strays << result
          end
        end
      end

      {orphaned, strays}
    end

    private def build_answered_on_chain(chain : Array(TranscriptEntry)) : Set(String)
      answered = Set(String).new
      chain.each do |entry|
        content_block_ids(entry, "tool_result", "tool_use_id").each { |cid| answered.add(cid) }
      end
      answered
    end

    private def build_file_position(by_uuid : Hash(String, TranscriptEntry)) : Hash(String, Int32)
      positions = {} of String => Int32
      by_uuid.each_key.each_with_index { |uid, i| positions[uid] = i }
      positions
    end

    private def filter_answering_strays(
      strays : Array(TranscriptEntry),
      orphaned_results : Array(TranscriptEntry),
      answered_on_chain : Set(String),
      file_position : Hash(String, Int32),
      call_owner : Hash(String, TranscriptEntry?),
      member_uuids : Set(String),
    ) : Array(TranscriptEntry)
      answered = answered_on_chain.dup
      orphaned_results.each do |result|
        content_block_ids(result, "tool_result", "tool_use_id").each { |cid| answered.add(cid) }
      end

      accepted = [] of TranscriptEntry
      sorted = strays.sort_by { |e| file_position[string_field(e, "uuid") || ""]? || Int32::MAX }
      sorted.each do |result|
        call_ids = content_block_ids(result, "tool_result", "tool_use_id")
        answers_open = call_ids.any? do |cid|
          owner = call_owner[cid]?
          owner_uuid = owner ? string_field(owner, "uuid") : nil
          !answered.includes?(cid) && !owner_uuid.nil? && member_uuids.includes?(owner_uuid)
        end
        next unless answers_open

        call_ids.each { |cid| answered.add(cid) }
        accepted << result
      end

      accepted
    end

    private def splice_recovered_entries(
      chain : Array(TranscriptEntry),
      inserts : Hash(String, Array(TranscriptEntry)),
    ) : Array(TranscriptEntry)
      result = [] of TranscriptEntry
      chain.each do |entry|
        result << entry
        if (uuid = string_field(entry, "uuid")) && (extra = inserts[uuid]?)
          result.concat(extra)
        end
      end
      result
    end

    private def queued_command_hash(entry : TranscriptEntry) : TranscriptEntry?
      return unless string_field(entry, "type") == "attachment"
      att = hash_field(entry, "attachment")
      return unless att && string_field(att, "type") == "queued_command"
      att
    end

    private def queued_command_attachment?(entry : TranscriptEntry) : Bool
      !queued_command_hash(entry).nil?
    end

    private def queued_command_field(entry : TranscriptEntry, key : String) : String?
      att = queued_command_hash(entry)
      return unless att
      val = string_field(att, key)
      val && !val.empty? ? val : nil
    end

    private def collect_trailing_queued_commands(
      entries : Array(TranscriptEntry),
      relinked : Hash(String, TranscriptEntry),
      chain : Array(TranscriptEntry),
      leaf : TranscriptEntry?,
    ) : Array(TranscriptEntry)
      return [] of TranscriptEntry unless leaf

      children_by_parent = index_non_message_children(entries, relinked)
      chain_uuids = chain.compact_map { |entry| string_field(entry, "uuid") }.to_set
      off_chain_branch = collect_off_chain_branch_parents(entries, chain_uuids)

      trailing = [] of TranscriptEntry
      stack = [leaf]
      until stack.empty?
        current = stack.pop
        current_uuid = string_field(current, "uuid")
        next unless current_uuid

        if current != leaf
          next if chain_uuids.includes?(current_uuid)
          chain_uuids.add(current_uuid)
          if queued_command_attachment?(current) && !off_chain_branch.includes?(current_uuid)
            trailing << current
          end
        end

        children = children_by_parent[current_uuid]? || [] of TranscriptEntry
        ordered = stable_sort_by_timestamp(children)
        ordered.reverse_each do |child|
          child_uuid = string_field(child, "uuid")
          stack << child if child_uuid && !chain_uuids.includes?(child_uuid)
        end
      end

      trailing
    end

    private def index_non_message_children(
      entries : Array(TranscriptEntry),
      relinked : Hash(String, TranscriptEntry),
    ) : Hash(String, Array(TranscriptEntry))
      children = {} of String => Array(TranscriptEntry)
      entries.each do |entry|
        type = string_field(entry, "type")
        next if type == "user" || type == "assistant"

        uuid = string_field(entry, "uuid")
        parents = Set(String).new
        if p1 = string_field(entry, "parentUuid")
          parents.add(p1)
        end
        if uuid && (relinked_entry = relinked[uuid]?)
          if p2 = string_field(relinked_entry, "parentUuid")
            parents.add(p2)
          end
        end
        parents.each { |parent_uuid| (children[parent_uuid] ||= [] of TranscriptEntry) << entry }
      end
      children
    end

    private def collect_off_chain_branch_parents(
      entries : Array(TranscriptEntry),
      chain_uuids : Set(String),
    ) : Set(String)
      by_uuid = index_transcript(entries)
      off_chain = Set(String).new

      entries.each do |entry|
        next unless off_chain_branch_seed?(entry, chain_uuids)
        mark_off_chain_ancestors(entry, by_uuid, chain_uuids, off_chain)
      end

      off_chain
    end

    private def off_chain_branch_seed?(entry : TranscriptEntry, chain_uuids : Set(String)) : Bool
      type = string_field(entry, "type")
      return false unless type == "user" || type == "assistant"
      return false if bool_field(entry, "isSidechain") || !string_field(entry, "teamName").nil?

      uuid = string_field(entry, "uuid")
      uuid.nil? || !chain_uuids.includes?(uuid)
    end

    private def mark_off_chain_ancestors(
      entry : TranscriptEntry,
      by_uuid : Hash(String, TranscriptEntry),
      chain_uuids : Set(String),
      off_chain : Set(String),
    ) : Nil
      parent = string_field(entry, "parentUuid")
      cur = parent ? by_uuid[parent]? : nil
      while cur
        cu = string_field(cur, "uuid")
        break if cu.nil? || chain_uuids.includes?(cu) || off_chain.includes?(cu)
        off_chain.add(cu)
        next_parent = string_field(cur, "parentUuid")
        cur = next_parent ? by_uuid[next_parent]? : nil
      end
    end

    private def transform_queued_commands(
      entries : Array(TranscriptEntry),
      *,
      keep_meta : Bool,
      trailing_ids : Set(String)? = nil,
      delivered : DeliveryCounts? = nil,
    ) : Array(TranscriptEntry)
      completed = completed_local_command_indices(entries)
      reply_after = compute_reply_after_flags(entries, completed)
      delivered_map = compute_delivered_indices(entries, delivered)
      seen_uuids = entries.compact_map { |entry| string_field(entry, "uuid") }.to_set

      entries.each_with_index.map do |entry, index|
        next entry if completed.includes?(index)

        uuid = string_field(entry, "uuid")
        include_queued = delivered_map[index]? || reply_after[index] || (uuid && trailing_ids.try(&.includes?(uuid)))
        include_queued ? materialize_queued_command(entry, seen_uuids, keep_meta) : entry
      end.to_a
    end

    private def completed_local_command_indices(entries : Array(TranscriptEntry)) : Set(Int32)
      completed = Set(Int32).new
      entries.each_with_index do |entry, offset|
        next unless string_field(entry, "type") == "user" && bool_field(entry, "isMeta")
        next unless local_command_kind(entry) == "caveat"

        seen_record = false
        ((offset + 1)...entries.size).each do |i|
          cur = entries[i]
          cur_type = string_field(cur, "type")
          break if cur_type == "assistant"
          next if cur_type != "user" || bool_field(cur, "isMeta")

          kind = local_command_kind(cur)
          if kind == "record" && !seen_record
            seen_record = true
          elsif kind != "output" || !seen_record
            break
          end
          completed.add(i)
        end
      end
      completed
    end

    private def local_command_kind(entry : TranscriptEntry) : String?
      return unless string_field(entry, "promptSource").nil?

      content = hash_field(entry, "message").try(&.["content"]?)
      return unless content

      text = extract_last_text_from_content(content)
      return unless text

      return "record" if text.starts_with?("<command-name>")
      return "output" if text.starts_with?("<local-command-stdout>") || text.starts_with?("<local-command-stderr>")
      return "caveat" if text.starts_with?("<local-command-caveat>")
      nil
    end

    private def extract_last_text_from_content(content : JSON::Any) : String?
      if str = content.as_s?
        return str
      end

      arr = content.as_a?
      return unless arr

      arr.reverse_each do |block|
        hash = block.as_h?
        next unless hash && string_field(hash, "type") == "text"
        if text = string_field(hash, "text")
          return text
        end
      end
      nil
    end

    private def compute_reply_after_flags(
      entries : Array(TranscriptEntry),
      completed : Set(Int32),
    ) : Array(Bool)
      flags = Array(Bool).new(entries.size, false)
      state : String? = nil

      (entries.size - 1).downto(0) do |i|
        entry = entries[i]
        flags[i] = (state == "reply")
        if string_field(entry, "type") == "assistant" || tool_result_entry?(entry) || interrupted_user_entry?(entry)
          state = "reply"
        elsif string_field(entry, "type") == "user" &&
              !bool_field(entry, "isMeta") &&
              !bool_field(entry, "isCompactSummary") &&
              !completed.includes?(i)
          state = "prompt"
        end
      end

      flags
    end

    private def interrupted_user_entry?(entry : TranscriptEntry) : Bool
      return false unless string_field(entry, "type") == "user"
      content = hash_field(entry, "message").try(&.["content"]?)
      return false unless content

      if text = content.as_s?
        return INTERRUPTED_USER_PREFIXES.any? { |prefix| text.starts_with?(prefix) }
      end

      blocks = content.as_a?
      return false if blocks.nil? || blocks.empty?

      blocks.all? do |block|
        hash = block.as_h?
        next false unless hash

        block_text = case string_field(hash, "type")
                     when "text"
                       string_field(hash, "text")
                     when "tool_result"
                       bool_field(hash, "is_error") ? string_field(hash, "content") : nil
                     end
        block_text && INTERRUPTED_USER_PREFIXES.any? { |prefix| block_text.starts_with?(prefix) }
      end
    end

    private def compute_delivered_indices(
      entries : Array(TranscriptEntry),
      delivered : DeliveryCounts?,
    ) : Hash(Int32, Bool)
      result = {} of Int32 => Bool
      return result if delivered.nil? || delivered.empty?

      grouped = {} of String => Array(Int32)
      entries.each_with_index do |entry, index|
        did = queued_command_field(entry, "delivery_id")
        suid = queued_command_field(entry, "source_uuid")
        key = did ? "delivery:#{did}" : (suid ? "uuid:#{suid}" : nil)
        next unless key && delivered.has_key?(key)
        (grouped[key] ||= [] of Int32) << index
      end

      grouped.each do |key, indices|
        if key.starts_with?("delivery:")
          indices.each do |idx|
            entry_uuid = string_field(entries[idx], "uuid")
            result[idx] = !entry_uuid.nil? && delivered.has_key?("entry:#{entry_uuid}")
          end
        else
          count = delivered[key]
          indices.each_with_index do |idx, pos|
            result[idx] = pos >= indices.size - count
          end
        end
      end

      result
    end

    private def materialize_queued_command(
      entry : TranscriptEntry,
      seen_uuids : Set(String),
      keep_meta : Bool,
    ) : TranscriptEntry
      att = queued_command_hash(entry)
      return entry unless att

      prompt = att["prompt"]?
      return entry unless valid_queued_prompt?(att, prompt)
      return entry unless prompt

      origin = hash_field(att, "origin")
      att_is_meta = bool_field(att, "isMeta")
      return entry if att_is_meta && !keep_meta && !visible_meta_origin?(origin)

      new_uuid = resolve_queued_command_uuid(entry, att, seen_uuids)
      return entry unless new_uuid

      seen_uuids.add(new_uuid)
      synthetic_queued_user_entry(entry, new_uuid, prompt, att_is_meta, origin)
    end

    private def valid_queued_prompt?(att : TranscriptEntry, prompt : JSON::Any?) : Bool
      return false unless prompt && (prompt.as_s? || prompt.as_a?)
      !forwarded_intent?(att)
    end

    private def resolve_queued_command_uuid(
      entry : TranscriptEntry,
      att : TranscriptEntry,
      seen_uuids : Set(String),
    ) : String?
      entry_uuid = string_field(entry, "uuid")
      return unless entry_uuid

      source_uuid = string_field(att, "source_uuid")
      new_uuid = source_uuid && !source_uuid.empty? ? source_uuid : entry_uuid
      return if new_uuid != entry_uuid && seen_uuids.includes?(new_uuid)

      new_uuid
    end

    private def forwarded_intent?(att : TranscriptEntry) : Bool
      intent = hash_field(att, "forwardedIntent")
      return false unless intent
      lineage = string_field(intent, "lineage")
      !lineage.nil? && !lineage.empty?
    end

    private def synthetic_queued_user_entry(
      entry : TranscriptEntry,
      new_uuid : String,
      prompt : JSON::Any,
      is_meta : Bool,
      origin : Hash(String, JSON::Any)?,
    ) : TranscriptEntry
      result = {
        "type"        => JSON::Any.new("user"),
        "uuid"        => JSON::Any.new(new_uuid),
        "parentUuid"  => entry["parentUuid"]? || JSON::Any.new(nil),
        "sessionId"   => entry["sessionId"]? || JSON::Any.new(""),
        "timestamp"   => entry["timestamp"]? || JSON::Any.new(""),
        "message"     => JSON::Any.new({"role" => JSON::Any.new("user"), "content" => prompt}),
        "isMeta"      => JSON::Any.new(is_meta),
        "isSidechain" => entry["isSidechain"]? || JSON::Any.new(false),
      } of String => JSON::Any
      result["origin"] = JSON::Any.new(origin) if origin
      %w[teamName parentToolUseId parent_tool_use_id parentAgentId parent_agent_id].each do |key|
        if val = entry[key]?
          result[key] = val
        end
      end
      result
    end

    # ------------------------------------------------------------------
    # Fork cutoff & compaction slicing helpers (TS 0.3.275 - 0.3.323)
    # ------------------------------------------------------------------

    private def find_fork_cutoff_index(
      transcript : Array(TranscriptEntry),
      target_id : String,
    ) : Int32?
      chain = build_conversation_chain(transcript)
      uuid_to_index = {} of String => Int32
      transcript.each_with_index do |entry, index|
        uuid = string_field(entry, "uuid")
        uuid_to_index[uuid] = index if uuid && !uuid_to_index.has_key?(uuid)
      end

      max_chain_index = -1
      chain.each do |entry|
        if uuid = string_field(entry, "uuid")
          idx = uuid_to_index[uuid]? || -1
          max_chain_index = idx if idx > max_chain_index
        end
      end

      tail = max_chain_index + 1 < transcript.size ? transcript[(max_chain_index + 1)..] : [] of TranscriptEntry
      search_pool = chain + tail
      if pool_idx = find_entry_index_by_id(search_pool, target_id)
        matched_uuid = string_field(search_pool[pool_idx], "uuid")
        return uuid_to_index[matched_uuid]? if matched_uuid
      end

      find_entry_index_by_id(transcript, target_id)
    end

    private def find_entry_index_by_id(entries : Array(TranscriptEntry), target_id : String) : Int32?
      entries.index { |entry| entry_matches_message_id?(entry, target_id, check_uuid: true) } ||
        entries.index { |entry| entry_matches_message_id?(entry, target_id, check_uuid: false) }
    end

    private def entry_matches_message_id?(
      entry : TranscriptEntry,
      target_id : String,
      *,
      check_uuid : Bool,
    ) : Bool
      return string_field(entry, "uuid") == target_id if check_uuid

      return true if string_field(entry, "delivery_id") == target_id
      return true if string_field(entry, "deliveryId") == target_id

      if att = queued_command_hash(entry)
        return true if string_field(att, "source_uuid") == target_id
        return true if string_field(att, "delivery_id") == target_id
        return true if string_field(att, "deliveryId") == target_id
      end

      false
    end

    private def compact_preservation_info(entry : TranscriptEntry) : Hash(String, JSON::Any)?
      meta = hash_field(entry, "compactMetadata")
      return unless meta

      target = hash_field(meta, "preservedMessages") || hash_field(meta, "preservedSegment")
      return unless target && target.has_key?("anchorUuid")

      target
    end

    private def compact_preservation_anchor_uuid(entry : TranscriptEntry) : String?
      compact_preservation_info(entry).try { |info| string_field(info, "anchorUuid") }
    end

    private def rewind_boundary?(entry : TranscriptEntry) : Bool
      meta = hash_field(entry, "compactMetadata")
      return false unless meta

      dur = meta["durationMs"]?
      zero_duration = dur && (dur.as_i64? == 0_i64 || dur.as_f? == 0.0)
      return false unless zero_duration

      anchor = compact_preservation_anchor_uuid(entry)
      !anchor.nil? && anchor == string_field(entry, "uuid")
    end

    private def compaction_boundary?(entry : TranscriptEntry) : Bool
      string_field(entry, "type") == "system" &&
        string_field(entry, "subtype") == "compact_boundary" &&
        !rewind_boundary?(entry)
    end

    private def compact_preserved_uuids(entry : TranscriptEntry) : Array(String)
      meta = hash_field(entry, "compactMetadata")
      return [] of String unless meta

      uuids = [] of String
      if pm = hash_field(meta, "preservedMessages")
        uuids.concat(json_string_array(pm["uuids"]?))
      end
      if ps = hash_field(meta, "preservedSegment")
        if head = string_field(ps, "headUuid")
          uuids << head
        end
        if tail = string_field(ps, "tailUuid")
          uuids << tail
        end
      end
      uuids
    end

    private def trim_trailing_compaction_boundary(slice : Array(TranscriptEntry)) : Array(TranscriptEntry)
      last_msg_idx = slice.rindex { |entry| {"user", "assistant"}.includes?(string_field(entry, "type")) } || -1
      boundary_idx = ((last_msg_idx + 1)...slice.size).find { |idx| compaction_boundary?(slice[idx]) }
      return slice unless boundary_idx

      before = slice[0...boundary_idx]
      cut_idx = resolve_compaction_cut_index(before, slice[boundary_idx])
      trimmed = cut_idx < 0 ? before : before[0..cut_idx]
      trimmed.any? { |entry| string_field(entry, "type") != "progress" } ? trimmed : slice
    end

    private def resolve_compaction_cut_index(
      before : Array(TranscriptEntry),
      boundary : TranscriptEntry,
    ) : Int32
      anchor_ids = compaction_anchor_ids(boundary)
      keep_idx = before.rindex { |entry| (uid = string_field(entry, "uuid")) && anchor_ids.includes?(uid) } || -1
      prev_anchor_idx = find_previous_compaction_anchor(before, keep_idx)
      Math.max(keep_idx, prev_anchor_idx)
    end

    private def compaction_anchor_ids(boundary : TranscriptEntry) : Set(String)
      anchor_ids = Set(String).new
      return anchor_ids if compact_preservation_anchor_uuid(boundary) == string_field(boundary, "uuid")

      compact_preserved_uuids(boundary).each { |uid| anchor_ids.add(uid) }
      if logical = string_field(boundary, "logicalParentUuid")
        anchor_ids.add(logical)
      end
      anchor_ids
    end

    private def find_previous_compaction_anchor(before : Array(TranscriptEntry), keep_idx : Int32) : Int32
      return -1 if keep_idx < 0

      prev_boundary = before.reverse_each.find do |entry|
        string_field(entry, "type") == "system" && string_field(entry, "subtype") == "compact_boundary"
      end
      return -1 unless prev_boundary
      return -1 if rewind_boundary?(prev_boundary)

      keep_uuid = string_field(before[keep_idx], "uuid")
      return -1 unless keep_uuid && compact_preserved_uuids(prev_boundary).includes?(keep_uuid)

      prev_anchor = compact_preservation_anchor_uuid(prev_boundary)
      return -1 unless prev_anchor

      before.rindex { |entry| string_field(entry, "uuid") == prev_anchor } || -1
    end

    private def strip_fork_cutoff_boundary_preservation(
      cutoff_uuid : String?,
      slice : Array(TranscriptEntry),
    ) : Array(TranscriptEntry)
      return slice unless cutoff_uuid

      slice.map do |entry|
        next entry unless compaction_boundary?(entry)
        next entry unless compact_preservation_anchor_uuid(entry) == cutoff_uuid

        meta = hash_field(entry, "compactMetadata")
        next entry unless meta

        updated_meta = meta.dup
        updated_meta.delete("preservedMessages")
        updated_meta.delete("preservedSegment")
        updated_meta.delete("postTokens")

        updated = entry.dup
        updated["compactMetadata"] = JSON::Any.new(updated_meta)
        updated
      end
    end

    private def prune_orphaned_compaction_branches(slice : Array(TranscriptEntry)) : Array(TranscriptEntry)
      last_entry = slice.last?
      last_uuid = last_entry ? string_field(last_entry, "uuid") : nil
      return slice unless last_entry && last_uuid

      normalized = slice.map { |entry| sanitize_for_fork_branch_scan(entry) }
      index_map = build_first_index_map(slice)
      target_uuids, start_idx = build_fork_branch_target(normalized, last_entry, last_uuid, index_map)
      return slice unless start_idx

      by_uuid = index_transcript(slice)
      live = collect_live_ancestors(last_uuid, target_uuids, by_uuid)
      left_out = collect_orphaned_compaction_uuids(slice, by_uuid, live, index_map, start_idx)
      prune_remaining_off_chain_branches(normalized, slice, by_uuid, live, index_map, start_idx, target_uuids, left_out)

      left_out.empty? ? slice : slice.reject { |entry| (uid = string_field(entry, "uuid")) && left_out.includes?(uid) }
    end

    private def build_first_index_map(slice : Array(TranscriptEntry)) : Hash(String, Int32)
      index_map = {} of String => Int32
      slice.each_with_index do |entry, idx|
        uuid = string_field(entry, "uuid")
        index_map[uuid] = idx if uuid && !index_map.has_key?(uuid)
      end
      index_map
    end

    private def build_fork_branch_target(
      normalized : Array(TranscriptEntry),
      last_entry : TranscriptEntry,
      last_uuid : String,
      index_map : Hash(String, Int32),
    ) : {Set(String), Int32?}
      sentinel = {
        "type"       => JSON::Any.new("system"),
        "uuid"       => JSON::Any.new(UUID.random.to_s),
        "parentUuid" => JSON::Any.new(last_uuid),
        "sessionId"  => last_entry["sessionId"]? || JSON::Any.new(""),
        "timestamp"  => last_entry["timestamp"]? || JSON::Any.new(""),
      }
      target_chain = build_conversation_chain(normalized + [sentinel])
      start_uuid = target_chain.first?.try { |entry| string_field(entry, "uuid") }
      start_idx = start_uuid ? index_map[start_uuid]? : nil
      target_uuids = target_chain.compact_map { |entry| string_field(entry, "uuid") }.to_set
      {target_uuids, start_idx}
    end

    private def collect_orphaned_compaction_uuids(
      slice : Array(TranscriptEntry),
      by_uuid : Hash(String, TranscriptEntry),
      live : Set(String),
      index_map : Hash(String, Int32),
      start_idx : Int32,
    ) : Set(String)
      left_out = Set(String).new
      slice.each do |entry|
        next unless string_field(entry, "type") == "system" && string_field(entry, "subtype") == "compact_boundary"
        next unless off_chain_since_start?(entry, live, index_map, start_idx)
        next if compact_preserved_uuids(entry).any? { |uid| live.includes?(uid) }

        mark_orphaned_branch(entry, slice, by_uuid, live, index_map, start_idx, left_out)
      end
      left_out
    end

    private def prune_remaining_off_chain_branches(
      normalized : Array(TranscriptEntry),
      slice : Array(TranscriptEntry),
      by_uuid : Hash(String, TranscriptEntry),
      live : Set(String),
      index_map : Hash(String, Int32),
      start_idx : Int32,
      target_uuids : Set(String),
      left_out : Set(String),
    ) : Nil
      loop do
        filtered = normalized.reject { |entry| (uid = string_field(entry, "uuid")) && left_out.includes?(uid) }
        rebuilt_uuid_map, entry_idx = relink_compaction_entries(filtered)
        found = select_main_active_leaf_with_terminal(rebuilt_uuid_map, entry_idx)
        rebuilt_chain = found ? build_chain_from_leaf(found[0], rebuilt_uuid_map) : [] of TranscriptEntry

        same_chain = rebuilt_chain.size == target_uuids.size &&
                     rebuilt_chain.all? { |entry| (uid = string_field(entry, "uuid")) && target_uuids.includes?(uid) }
        break if same_chain || found.nil?

        terminal = found[1]
        break unless off_chain_since_start?(terminal, live, index_map, start_idx)
        mark_orphaned_branch(terminal, slice, by_uuid, live, index_map, start_idx, left_out)
      end
    end

    private def sanitize_for_fork_branch_scan(entry : TranscriptEntry) : TranscriptEntry
      sanitized = entry.dup
      sanitized["isSidechain"] = JSON::Any.new(false)
      %w[
        teamName agentName slug sourceToolAssistantUUID
        sessionKind summarizedTurnPromptUuids droppedPromptUuids turnAttributionKey
      ].each { |key| sanitized.delete(key) }
      sanitized
    end

    private def collect_live_ancestors(
      last_uuid : String,
      target_uuids : Set(String),
      by_uuid : Hash(String, TranscriptEntry),
    ) : Set(String)
      live = Set(String).new
      seeds = [last_uuid] + target_uuids.to_a
      seeds.each do |seed|
        cur = by_uuid[seed]?
        while cur
          cu = string_field(cur, "uuid")
          break if cu.nil? || live.includes?(cu)
          live.add(cu)
          parent = string_field(cur, "parentUuid")
          cur = parent ? by_uuid[parent]? : nil
        end
      end
      live
    end

    private def off_chain_since_start?(
      entry : TranscriptEntry,
      live : Set(String),
      index_map : Hash(String, Int32),
      start_idx : Int32,
    ) : Bool
      uuid = string_field(entry, "uuid")
      return false unless uuid
      !live.includes?(uuid) && (index_map[uuid]? || start_idx) >= start_idx
    end

    private def mark_orphaned_branch(
      root : TranscriptEntry,
      slice : Array(TranscriptEntry),
      by_uuid : Hash(String, TranscriptEntry),
      live : Set(String),
      index_map : Hash(String, Int32),
      start_idx : Int32,
      left_out : Set(String),
    ) : Nil
      cur : TranscriptEntry? = root
      while cur && off_chain_since_start?(cur, live, index_map, start_idx)
        cu = string_field(cur, "uuid")
        break if cu.nil? || left_out.includes?(cu)
        left_out.add(cu)
        parent = string_field(cur, "parentUuid")
        cur = parent ? by_uuid[parent]? : nil
      end

      slice.each do |entry|
        parent = string_field(entry, "parentUuid")
        uuid = string_field(entry, "uuid")
        if parent && uuid && left_out.includes?(parent)
          left_out.add(uuid)
        end
      end
    end

    private def remap_fork_entry_metadata!(
      forked : Hash(String, JSON::Any),
      uuid_mapping : Hash(String, String),
      writable_mapping : Hash(String, String),
      writable : Array(TranscriptEntry),
    ) : Nil
      remap_compact_metadata!(forked, writable_mapping, writable)
      remap_attachment_uuids!(forked, uuid_mapping)
    end

    private def remap_compact_metadata!(
      forked : Hash(String, JSON::Any),
      writable_mapping : Hash(String, String),
      writable : Array(TranscriptEntry),
    ) : Nil
      return unless string_field(forked, "type") == "system"
      meta = hash_field(forked, "compactMetadata")
      return unless meta

      updated = meta.dup
      updated.delete("runningTurnSends")

      if pm = hash_field(updated, "preservedMessages")
        if remapped_pm = remap_preserved_messages(pm, writable_mapping)
          updated["preservedMessages"] = JSON::Any.new(remapped_pm)
        else
          updated.delete("preservedMessages")
        end
      end

      if ps = hash_field(updated, "preservedSegment")
        if remapped_ps = remap_preserved_segment(ps, writable_mapping, writable)
          updated["preservedSegment"] = JSON::Any.new(remapped_ps)
        else
          updated.delete("preservedSegment")
        end
      end

      forked["compactMetadata"] = JSON::Any.new(updated)
    end

    private def remap_preserved_messages(
      pm : Hash(String, JSON::Any),
      writable_mapping : Hash(String, String),
    ) : Hash(String, JSON::Any)?
      remapped = pm.dup

      if pm.has_key?("uuids")
        uuids = json_string_array(pm["uuids"]?).compact_map { |uid| writable_mapping[uid]? }
        return if uuids.empty?
        remapped["uuids"] = JSON::Any.new(uuids.map { |uid| JSON::Any.new(uid) })
      end

      if pm.has_key?("allUuids")
        all_uuids = json_string_array(pm["allUuids"]?).compact_map { |uid| writable_mapping[uid]? }
        remapped["allUuids"] = JSON::Any.new(all_uuids.map { |uid| JSON::Any.new(uid) })
      end

      if anchor = string_field(pm, "anchorUuid")
        remapped["anchorUuid"] = JSON::Any.new(writable_mapping[anchor]? || anchor)
      end

      remapped
    end

    private def remap_preserved_segment(
      ps : Hash(String, JSON::Any),
      writable_mapping : Hash(String, String),
      writable : Array(TranscriptEntry),
    ) : Hash(String, JSON::Any)?
      head = string_field(ps, "headUuid")
      anchor = string_field(ps, "anchorUuid")
      tail = string_field(ps, "tailUuid")
      return unless head && anchor
      return unless (mapped_head = writable_mapping[head]?) && (mapped_anchor = writable_mapping[anchor]?)

      remapped = ps.dup
      remapped["headUuid"] = JSON::Any.new(mapped_head)
      remapped["anchorUuid"] = JSON::Any.new(mapped_anchor)
      if tail
        mapped_tail = writable_mapping[tail]? || find_scoped_segment_tail(writable, head, writable_mapping)
        remapped["tailUuid"] = JSON::Any.new(mapped_tail)
      end
      remapped
    end

    private def find_scoped_segment_tail(
      writable : Array(TranscriptEntry),
      head_uuid : String,
      writable_mapping : Hash(String, String),
    ) : String
      reachable = Set{head_uuid}
      last_mapped = writable_mapping[head_uuid]

      writable.each do |entry|
        uuid = string_field(entry, "uuid")
        parent = string_field(entry, "parentUuid")
        next unless uuid && parent
        if reachable.includes?(parent)
          reachable.add(uuid)
          if mapped = writable_mapping[uuid]?
            last_mapped = mapped
          end
        end
      end

      last_mapped
    end

    private def remap_attachment_uuids!(
      forked : Hash(String, JSON::Any),
      uuid_mapping : Hash(String, String),
    ) : Nil
      return unless string_field(forked, "type") == "attachment"
      att = hash_field(forked, "attachment")
      return unless att

      att_type = string_field(att, "type")
      if att_type == "queued_command"
        if (suid = string_field(att, "source_uuid")) && (mapped = uuid_mapping[suid]?)
          updated = att.dup
          updated["source_uuid"] = JSON::Any.new(mapped)
          forked["attachment"] = JSON::Any.new(updated)
        end
      elsif att_type == "deferred_tools_record"
        if names = att["nameOnlyAnnouncements"]?.try(&.as_a?)
          remapped = names.compact_map do |item|
            (s = item.as_s?) && (m = uuid_mapping[s]?) ? JSON::Any.new(m) : nil
          end
          updated = att.dup
          updated["nameOnlyAnnouncements"] = JSON::Any.new(remapped)
          forked["attachment"] = JSON::Any.new(updated)
        end
      end
    end
  end

  def self.list_sessions(
    directory : String? = nil,
    limit : Int32? = nil,
    offset : Int32 = 0,
    include_worktrees : Bool = true,
  ) : Array(SDKSessionInfo)
    SessionStorage.list_sessions(directory, limit, offset, include_worktrees)
  end

  def self.get_session_info(
    session_id : String,
    directory : String? = nil,
  ) : SDKSessionInfo?
    SessionStorage.get_session_info(session_id, directory)
  end

  def self.get_session_messages(
    session_id : String,
    directory : String? = nil,
    limit : Int32? = nil,
    offset : Int32 = 0,
    include_system_messages : Bool = false,
  ) : Array(SessionMessage)
    SessionStorage.get_session_messages(
      session_id,
      directory,
      limit,
      offset,
      include_system_messages,
    )
  end

  def self.rename_session(
    session_id : String,
    title : String,
    directory : String? = nil,
  ) : Nil
    SessionStorage.rename_session(session_id, title, directory)
  end

  def self.tag_session(
    session_id : String,
    tag : String?,
    directory : String? = nil,
  ) : Nil
    SessionStorage.tag_session(session_id, tag, directory)
  end

  def self.archive_session(session_id : String, directory : String? = nil) : Nil
    SessionStorage.archive_session(session_id, directory)
  end

  def self.unarchive_session(session_id : String, directory : String? = nil) : Nil
    SessionStorage.unarchive_session(session_id, directory)
  end

  def self.delete_session(session_id : String, directory : String? = nil) : Nil
    SessionStorage.delete_session(session_id, directory)
  end

  def self.list_subagents(session_id : String, directory : String? = nil) : Array(String)
    SessionStorage.list_subagents(session_id, directory)
  end

  def self.get_subagent_messages(
    session_id : String,
    agent_id : String,
    directory : String? = nil,
    limit : Int32? = nil,
    offset : Int32 = 0,
  ) : Array(SessionMessage)
    SessionStorage.get_subagent_messages(session_id, agent_id, directory, limit, offset)
  end

  def self.fork_session(
    session_id : String,
    directory : String? = nil,
    up_to_message_id : String? = nil,
    title : String? = nil,
  ) : ForkSessionResult
    SessionStorage.fork_session(session_id, directory, up_to_message_id, title)
  end

  def self.project_key_for_directory(directory : String? = nil) : String
    SessionStorage.project_key_for_directory(directory)
  end

  def self.import_session_to_store(
    session_id : String,
    store : SessionStore,
    directory : String? = nil,
    include_subagents : Bool = true,
    batch_size : Int32 = SessionStorage::DEFAULT_IMPORT_BATCH_SIZE,
  ) : Nil
    SessionStorage.import_session_to_store(
      session_id, store, directory, include_subagents, batch_size
    )
  end

  def self.list_sessions_from_store(
    store : SessionStore,
    directory : String? = nil,
    limit : Int32? = nil,
    offset : Int32 = 0,
  ) : Array(SDKSessionInfo)
    SessionStorage.list_sessions_from_store(store, directory, limit, offset)
  end

  def self.get_session_info_from_store(
    store : SessionStore,
    session_id : String,
    directory : String? = nil,
  ) : SDKSessionInfo?
    SessionStorage.get_session_info_from_store(store, session_id, directory)
  end

  def self.get_session_messages_from_store(
    store : SessionStore,
    session_id : String,
    directory : String? = nil,
    limit : Int32? = nil,
    offset : Int32 = 0,
    include_system_messages : Bool = false,
  ) : Array(SessionMessage)
    SessionStorage.get_session_messages_from_store(
      store, session_id, directory, limit, offset, include_system_messages
    )
  end

  def self.rename_session_via_store(
    store : SessionStore,
    session_id : String,
    title : String,
    directory : String? = nil,
  ) : Nil
    SessionStorage.rename_session_via_store(store, session_id, title, directory)
  end

  def self.tag_session_via_store(
    store : SessionStore,
    session_id : String,
    tag : String?,
    directory : String? = nil,
  ) : Nil
    SessionStorage.tag_session_via_store(store, session_id, tag, directory)
  end

  def self.delete_session_via_store(
    store : SessionStore,
    session_id : String,
    directory : String? = nil,
  ) : Nil
    SessionStorage.delete_session_via_store(store, session_id, directory)
  end

  def self.fork_session_via_store(
    store : SessionStore,
    session_id : String,
    directory : String? = nil,
    up_to_message_id : String? = nil,
    title : String? = nil,
  ) : ForkSessionResult
    SessionStorage.fork_session_via_store(
      store, session_id, directory, up_to_message_id, title
    )
  end

  def self.list_subagents_from_store(
    store : SessionStore,
    session_id : String,
    directory : String? = nil,
  ) : Array(String)
    SessionStorage.list_subagents_from_store(store, session_id, directory)
  end

  def self.get_subagent_messages_from_store(
    store : SessionStore,
    session_id : String,
    agent_id : String,
    directory : String? = nil,
    limit : Int32? = nil,
    offset : Int32 = 0,
  ) : Array(SessionMessage)
    SessionStorage.get_subagent_messages_from_store(
      store, session_id, agent_id, directory, limit, offset
    )
  end
end
