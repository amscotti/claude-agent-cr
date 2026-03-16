require "json"
require "set"

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

    def initialize(
      @type : String,
      @uuid : String,
      @session_id : String,
      @message : Hash(String, JSON::Any),
      @parent_tool_use_id : String? = nil,
    )
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

    def get_session_messages(
      session_id : String,
      directory : String? = nil,
      limit : Int32? = nil,
      offset : Int32 = 0,
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
        next unless visible_message?(entry)
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

    private def visible_message?(entry : TranscriptEntry) : Bool
      type = string_field(entry, "type")
      return false unless {"user", "assistant"}.includes?(type)
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

    # ameba:disable Metrics/CyclomaticComplexity
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
        if project_dir && appendable_session_file?(path = File.join(project_dir, file_name))
          return path
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
  ) : Array(SessionMessage)
    SessionStorage.get_session_messages(session_id, directory, limit, offset)
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
end
