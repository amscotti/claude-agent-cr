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

  module SessionStorage
    extend self

    private alias TranscriptEntry = Hash(String, JSON::Any)

    MAX_SANITIZED_LENGTH = 200
    UUID_REGEX           = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    COMMAND_NAME_REGEX   = /<command-name>(.*?)<\/command-name>/
    SKIP_FIRST_PROMPT    = /^(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|\[Request interrupted by user[^\]]*\]|\s*<ide_opened_file>[\s\S]*<\/ide_opened_file>\s*$|\s*<ide_selection>[\s\S]*<\/ide_selection>\s*$)/

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
      return nil unless valid_uuid?(session_id)

      file_path = resolve_session_file_path(session_id, directory)
      return nil unless file_path

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
                      else
                        nil
                      end

      append_to_session(
        session_id,
        %({"type":"tag","tag":#{(sanitized_tag || "").to_json},"sessionId":#{session_id.to_json}}\n),
        directory,
      )
    end

    # Delete a session by removing its JSONL file and sibling subagent
    # transcript directory (if any). Raises File::NotFoundError if the
    # session cannot be located.
    def delete_session(session_id : String, directory : String? = nil) : Nil
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)

      file_path = resolve_session_file_path(session_id, directory)
      unless file_path
        missing = directory ? File.join(directory, "#{session_id}.jsonl") : "#{session_id}.jsonl"
        raise File::NotFoundError.new("Session #{session_id} not found", file: missing)
      end

      File.delete(file_path)

      subagent_dir = Path[file_path].parent.to_s
      subagent_dir = File.join(subagent_dir, session_id)
      if Dir.exists?(subagent_dir)
        begin
          FileUtils.rm_rf(subagent_dir)
        rescue File::Error
        end
      end
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
      chain = build_subagent_chain(entries)

      messages = chain.compact_map do |entry|
        next unless {"user", "assistant"}.includes?(string_field(entry, "type"))
        to_session_message(entry)
      end

      start = Math.max(offset, 0)
      return [] of SessionMessage if start >= messages.size

      if limit && limit > 0
        messages[start, limit]? || [] of SessionMessage
      else
        messages[start..] || [] of SessionMessage
      end
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

      transcript, content_replacements = prepare_fork_transcript(content, session_id, up_to_message_id)
      uuid_mapping = build_fork_uuid_mapping(transcript)
      writable = transcript.reject { |entry| string_field(entry, "type") == "progress" }
      raise ArgumentError.new("Session #{session_id} has no messages to fork") if writable.empty?

      by_uuid = index_transcript(transcript)
      forked_session_id = UUID.random.to_s

      lines = build_fork_lines(
        writable,
        by_uuid,
        uuid_mapping,
        forked_session_id,
        session_id,
      )
      append_fork_footer(lines, forked_session_id, content, content_replacements, title)

      fork_path = File.join(project_dir, "#{forked_session_id}.jsonl")
      File.open(fork_path, "w") do |file|
        lines.each { |line| file << line << "\n" }
      end

      ForkSessionResult.new(forked_session_id)
    end

    private def validate_fork_inputs!(session_id : String, up_to_message_id : String?)
      raise ArgumentError.new("Invalid session_id: #{session_id}") unless valid_uuid?(session_id)
      if up_to_message_id && !valid_uuid?(up_to_message_id)
        raise ArgumentError.new("Invalid up_to_message_id: #{up_to_message_id}")
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
        cutoff = transcript.index { |entry| string_field(entry, "uuid") == up_to_message_id }
        unless cutoff
          raise ArgumentError.new("Message #{up_to_message_id} not found in session #{session_id}")
        end
        transcript = transcript[0..cutoff]
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
      %w[teamName agentName slug sourceToolAssistantUUID].each { |key| forked.delete(key) }
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

      entries = parse_transcript_entries(content)
      chain = build_conversation_chain(entries)
      messages = chain.compact_map do |entry|
        next unless visible_message?(entry, include_system_messages)
        to_session_message(entry)
      end

      start = Math.max(offset, 0)
      return [] of SessionMessage if start >= messages.size

      if limit && limit > 0
        messages[start, limit]? || [] of SessionMessage
      else
        messages[start..] || [] of SessionMessage
      end
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
      return nil unless file_path

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
      parse_jsonl_entries(content).select do |entry|
        type = string_field(entry, "type")
        uuid = string_field(entry, "uuid")
        uuid && type && {"user", "assistant", "progress", "system", "attachment"}.includes?(type)
      end
    end

    private def build_conversation_chain(entries : Array(TranscriptEntry)) : Array(TranscriptEntry)
      return [] of TranscriptEntry if entries.empty?

      by_uuid, entry_index = index_entries(entries)
      leaves = collect_leaf_candidates(terminal_entries(entries), by_uuid)

      return [] of TranscriptEntry if leaves.empty?

      main_leaves = leaves.reject do |leaf|
        bool_field(leaf, "isSidechain") || bool_field(leaf, "isMeta") || !string_field(leaf, "teamName").nil?
      end

      leaf = pick_best_leaf(main_leaves.empty? ? leaves : main_leaves, entry_index)
      return [] of TranscriptEntry unless leaf

      build_chain_from_leaf(leaf, by_uuid)
    end

    private def index_entries(entries : Array(TranscriptEntry)) : Tuple(Hash(String, TranscriptEntry), Hash(String, Int32))
      by_uuid = {} of String => TranscriptEntry
      entry_index = {} of String => Int32

      entries.each_with_index do |entry, index|
        uuid = string_field(entry, "uuid")
        next unless uuid
        by_uuid[uuid] = entry
        entry_index[uuid] = index
      end

      {by_uuid, entry_index}
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
        return nil unless uuid
        return nil if seen.includes?(uuid)
        seen.add(uuid)

        case string_field(current, "type")
        when "user", "assistant"
          return current
        end

        parent = string_field(current, "parentUuid")
        return nil unless parent

        next_entry = by_uuid[parent]?
        return nil unless next_entry
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
      chain
    end

    private def pick_best_leaf(
      leaves : Array(TranscriptEntry),
      entry_index : Hash(String, Int32),
    ) : TranscriptEntry?
      return nil if leaves.empty?

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
      return false if bool_field(entry, "isMeta")
      return false if bool_field(entry, "isSidechain")

      string_field(entry, "teamName").nil?
    end

    private def to_session_message(entry : TranscriptEntry) : SessionMessage?
      type = string_field(entry, "type")
      uuid = string_field(entry, "uuid")
      session_id = string_field(entry, "sessionId") || string_field(entry, "session_id")
      message = hash_field(entry, "message")
      return nil unless type && uuid && session_id && message

      SessionMessage.new(
        type: type,
        uuid: uuid,
        session_id: session_id,
        message: message,
        parent_tool_use_id: string_field(entry, "parentToolUseId") || string_field(entry, "parent_tool_use_id"),
        parent_agent_id: string_field(entry, "parentAgentId") || string_field(entry, "parent_agent_id"),
      )
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
      return nil if content.empty?

      first_entry = first_json_entry(content)
      return nil if first_entry && bool_field(first_entry, "isSidechain")

      entries = parse_jsonl_entries(content)
      return nil if entries.empty?

      custom_title = last_string_field(entries, "customTitle")
      first_prompt = extract_first_prompt(entries)
      summary = custom_title || last_string_field(entries, "summary") || first_prompt
      return nil unless summary

      info = File.info(file_path)
      git_branch = last_string_field(entries, "gitBranch") || first_string_field(entries, "gitBranch")
      session_cwd = first_string_field(entries, "cwd") || project_path
      tag = last_string_field(entries, "tag")
      tag = nil if tag == ""

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
      )
    rescue File::Error
      nil
    end

    # ameba:enable Metrics/CyclomaticComplexity

    private def resolve_session_file_path(session_id : String, directory : String?) : String?
      file_name = "#{session_id}.jsonl"

      if directory
        canonical_dir = canonicalize_path(directory)
        search_paths = Set{canonical_dir}
        worktree_paths(canonical_dir).each { |path| search_paths.add(path) }

        search_paths.each do |path|
          project_dir = find_project_dir(path)
          next unless project_dir

          file_path = File.join(project_dir, file_name)
          return file_path if File.exists?(file_path)
        end

        return nil
      end

      projects_dir = projects_dir_path
      return nil unless Dir.exists?(projects_dir)

      Dir.children(projects_dir).each do |entry|
        project_dir = File.join(projects_dir, entry)
        next unless Dir.exists?(project_dir)

        file_path = File.join(project_dir, file_name)
        return file_path if File.exists?(file_path)
      end

      nil
    rescue File::Error
      nil
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

        return nil
      end

      projects_dir = projects_dir_path
      return nil unless Dir.exists?(projects_dir)

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
          return nil
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
      return nil unless timestamp

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
      return nil if sanitized.size <= MAX_SANITIZED_LENGTH
      return nil unless Dir.exists?(projects_dir_path)

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
      return nil unless file_path

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

        return nil
      end

      projects_dir = projects_dir_path
      return nil unless Dir.exists?(projects_dir)

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

        begin
          meta = JSON.parse(File.read(meta_path)).as_h.dup
          meta["type"] = JSON::Any.new("agent_metadata")
          store.append(sub_key, [SessionStoreEntry.from_hash(meta)])
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
      return nil unless valid_uuid?(session_id)

      project_key = project_key_for_directory(directory)
      key = SessionKey.new(project_key, session_id)
      entries = store.load(key)
      return nil if entries.nil? || entries.empty?

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

      transcript = filter_transcript_entries(entries)
      chain = build_conversation_chain(transcript)
      messages = chain.compact_map do |entry|
        next unless visible_message?(entry, include_system_messages)
        to_session_message(entry)
      end

      start = Math.max(offset, 0)
      return [] of SessionMessage if start >= messages.size

      if limit && limit > 0
        messages[start, limit]? || [] of SessionMessage
      else
        messages[start..] || [] of SessionMessage
      end
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
                      else
                        nil
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
      transcript, content_replacements = prepare_fork_transcript(content, session_id, up_to_message_id)
      uuid_mapping = build_fork_uuid_mapping(transcript)
      writable = transcript.reject { |entry| string_field(entry, "type") == "progress" }
      raise ArgumentError.new("Session #{session_id} has no messages to fork") if writable.empty?

      by_uuid = index_transcript(transcript)
      forked_session_id = UUID.random.to_s

      lines = build_fork_lines(
        writable,
        by_uuid,
        uuid_mapping,
        forked_session_id,
        session_id,
      )
      append_fork_footer(lines, forked_session_id, content, content_replacements, title)

      forked_entries = lines.compact_map do |line|
        begin
          SessionStoreEntry.from_hash(JSON.parse(line).as_h)
        rescue
          nil
        end
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
      transcript = entries.reject { |e| e.type == "agent_metadata" }.map(&.to_h)
      chain = build_subagent_chain(filter_transcript_hashes(transcript))
      chain.compact_map do |entry|
        next unless {"user", "assistant"}.includes?(string_field(entry, "type"))
        to_session_message(entry)
      end
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
      return nil if data["is_sidechain"]?.try(&.as_bool?) == true

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
      return nil unless summary

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
      return nil if entries.first.bool_field("isSidechain")

      hashes = entries.map(&.to_h)
      custom_title = last_string_field(hashes, "customTitle")
      first_prompt = extract_first_prompt(hashes)
      summary = custom_title || last_string_field(hashes, "summary") || first_prompt
      return nil unless summary

      mtime = entries.reverse_each.compact_map { |entry|
        iso_timestamp_ms(entry.timestamp)
      }.first? || Time.utc.to_unix_ms

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
      return nil unless ts
      Time::Format::ISO_8601_DATE_TIME.parse(ts, Time::Location::UTC).to_unix_ms
    rescue Time::Format::Error
      nil
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
