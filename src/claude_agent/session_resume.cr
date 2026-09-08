require "file_utils"
require "json"
require "uuid"

module ClaudeAgent
  # Pre-flight validation and resume materialization for SessionStore-backed
  # sessions. Mirrors Python's session_store_validation + session_resume.

  # Result of materializing a store-backed resume into a temp CLAUDE_CONFIG_DIR.
  class MaterializedResume
    getter config_dir : String
    getter resume_session_id : String

    def initialize(@config_dir : String, @resume_session_id : String)
    end

    # Best-effort removal of the temp config directory (retries on lock).
    def cleanup : Nil
      ClaudeAgent.rmtree_with_retry(@config_dir)
    end
  end

  # Raise ConfigurationError for invalid session_store option combinations.
  def self.validate_session_store_options!(options : AgentOptions) : Nil
    store = options.session_store
    return unless store

    if options.continue_conversation? && options.resume.nil? && !store.supports_list_sessions?
      raise ConfigurationError.new(
        "continue_conversation with session_store requires the store to " \
        "implement list_sessions()"
      )
    end

    if options.enable_file_checkpointing?
      raise ConfigurationError.new(
        "session_store cannot be combined with enable_file_checkpointing " \
        "(checkpoints are local-disk only and would diverge from the " \
        "mirrored transcript)"
      )
    end

    begin
      SessionStoreFlushMode.parse(options.session_store_flush)
    rescue ArgumentError
      raise ConfigurationError.new(
        "session_store_flush must be \"batched\" or \"eager\", got " \
        "#{options.session_store_flush.inspect}"
      )
    end
  end

  # Effective projects directory for filePath → SessionKey resolution.
  def self.effective_projects_dir(env : Hash(String, String)? = nil) : String
    config = env.try(&.["CLAUDE_CONFIG_DIR"]?) ||
             ENV["CLAUDE_CONFIG_DIR"]? ||
             File.join(ENV["HOME"]? || ".", ".claude")
    File.join(config, "projects")
  end

  # Build a TranscriptMirrorBatcher for the given store and flush mode.
  def self.build_mirror_batcher(
    store : SessionStore,
    *,
    projects_dir : String,
    flush_mode : String = "batched",
    on_error : Proc(SessionKey?, String, Nil),
  ) : TranscriptMirrorBatcher
    mode = SessionStoreFlushMode.parse(flush_mode)
    eager = mode.eager?
    TranscriptMirrorBatcher.new(
      store: store,
      projects_dir: projects_dir,
      on_error: on_error,
      max_pending_entries: eager ? 0 : TranscriptMirrorBatcher::MAX_PENDING_ENTRIES,
      max_pending_bytes: eager ? 0 : TranscriptMirrorBatcher::MAX_PENDING_BYTES,
    )
  end

  # Load a session from options.session_store into a temp CLAUDE_CONFIG_DIR
  # when resume/continue is set. Returns nil when materialization is not
  # needed (no store, no resume/continue, missing entries, or invalid id).
  def self.materialize_resume_session(options : AgentOptions) : MaterializedResume?
    store = options.session_store
    return unless store
    return if options.resume.nil? && !options.continue_conversation?

    project_key = project_key_for_directory(options.cwd)
    timeout_ms = options.load_timeout_ms

    resolved = if resume_id = options.resume
                 return unless resume_uuid?(resume_id)
                 load_candidate(store, project_key, resume_id, timeout_ms)
               else
                 resolve_continue_candidate(store, project_key, timeout_ms)
               end
    return unless resolved

    session_id, entries = resolved
    tmp_base = File.tempname("claude-resume-")
    Dir.mkdir_p(tmp_base)

    begin
      project_dir = File.join(tmp_base, "projects", project_key)
      Dir.mkdir_p(project_dir)
      write_jsonl(File.join(project_dir, "#{session_id}.jsonl"), entries)
      materialize_subkeys(store, project_dir, project_key, session_id)
      # Copy redacted credentials / .claude.json so the subprocess can auth
      # under the redirected CLAUDE_CONFIG_DIR (Python session_resume parity).
      copy_auth_files(tmp_base, options.env)
      MaterializedResume.new(tmp_base, session_id)
    rescue ex
      rmtree_with_retry(tmp_base)
      raise Error.new("Failed to materialize session_store resume: #{ex.message}")
    end
  end

  # Return a copy of AgentOptions repointed at the materialized temp config
  # dir. AgentOptions is a struct, so callers must assign the return value
  # (and update CLIClient) — in-place mutation would not propagate.
  def self.apply_materialized_options(
    options : AgentOptions,
    materialized : MaterializedResume,
  ) : AgentOptions
    env = options.env.try(&.dup) || {} of String => String
    env["CLAUDE_CONFIG_DIR"] = materialized.config_dir
    options.env = env
    options.resume = materialized.resume_session_id
    options.continue_conversation = false
    options
  end

  private def self.resume_uuid?(id : String) : Bool
    !!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.match(id)
  end

  private def self.load_candidate(
    store : SessionStore,
    project_key : String,
    session_id : String,
    _timeout_ms : Int32,
  ) : {String, Array(SessionStoreEntry)}?
    key = SessionKey.new(project_key, session_id)
    entries = store.load(key)
    return if entries.nil? || entries.empty?

    {session_id, entries}
  end

  private def self.resolve_continue_candidate(
    store : SessionStore,
    project_key : String,
    timeout_ms : Int32,
  ) : {String, Array(SessionStoreEntry)}?
    return unless store.supports_list_sessions?

    listed = store.list_sessions(project_key)
    # Prefer most recently modified session (highest mtime first).
    candidates = listed.sort_by { |entry| -entry.mtime }
    candidates.each do |entry|
      if resolved = load_candidate(store, project_key, entry.session_id, timeout_ms)
        return resolved
      end
    end
    nil
  end

  private def self.write_jsonl(path : String, entries : Array(SessionStoreEntry)) : Nil
    Dir.mkdir_p(File.dirname(path))
    File.open(path, "w") do |io|
      entries.each do |entry|
        io.puts(entry.to_h.to_json)
      end
    end
    begin
      File.chmod(path, 0o600)
    rescue
    end
  end

  private def self.materialize_subkeys(
    store : SessionStore,
    project_dir : String,
    project_key : String,
    session_id : String,
  ) : Nil
    return unless store.supports_list_subkeys?

    list_key = SessionListSubkeysKey.new(project_key, session_id)
    store.list_subkeys(list_key).each do |subpath|
      next if subpath.empty? || subpath.includes?("..")

      entries = store.load(SessionKey.new(project_key, session_id, subpath))
      next if entries.nil? || entries.empty?

      # Partition: agent_metadata entries describe the .meta.json sidecar
      # (last one wins — it is rewritten on resume); everything else is
      # a transcript line. Mirrors Python's `_materialize_subkeys`
      # (0.2.140): resumed subagents keep their agentType/worktreePath.
      metadata = nil.as(SessionStoreEntry?)
      transcript = [] of SessionStoreEntry
      entries.each do |entry|
        if entry.type == "agent_metadata"
          metadata = entry
        else
          transcript << entry
        end
      end

      # subpath like "subagents/agent-xyz" → session_dir/subagents/agent-xyz.jsonl
      target = File.join(project_dir, session_id, "#{subpath}.jsonl")
      Dir.mkdir_p(File.dirname(target))
      write_jsonl(target, transcript) unless transcript.empty?

      if meta = metadata
        # Strip the synthetic `type` discriminator before persisting.
        meta_content = meta.to_h.reject { |key, _| key == "type" }
        meta_file = agent_metadata_sidecar_path(target)
        File.write(meta_file, meta_content.to_json)
        begin
          File.chmod(meta_file, 0o600)
        rescue
        end
      end
    end
  rescue SessionStoreNotImplementedError
    # optional API
  end

  # Seed `tmp_base` with the caller's auth and user config:
  # `.credentials.json` (refreshToken redacted), `.claude.json`, and user
  # `settings.json` / `cowork_settings.json` (plugin declarations
  # stripped). Mirrors Python's `_copy_auth_files` (0.2.137).
  private def self.copy_auth_files(tmp_base : String, opt_env : Hash(String, String)?) : Nil
    caller_config = opt_env.try(&.["CLAUDE_CONFIG_DIR"]?) || ENV["CLAUDE_CONFIG_DIR"]?
    source_config = if caller_config
                      caller_config
                    else
                      File.join(ENV["HOME"]? || ".", ".claude")
                    end

    creds_path = File.join(source_config, ".credentials.json")
    if File.file?(creds_path)
      write_redacted_credentials(File.read(creds_path), File.join(tmp_base, ".credentials.json"))
    end

    claude_json_src = if caller_config
                        File.join(caller_config, ".claude.json")
                      else
                        File.join(ENV["HOME"]? || ".", ".claude.json")
                      end
    copy_if_present(claude_json_src, File.join(tmp_base, ".claude.json"))

    # User settings carry `apiKeyHelper` (a fourth auth mechanism
    # alongside .credentials.json / Keychain / env) plus env/hooks/
    # permissions. Without them the resumed subprocess sees no user
    # settings at all, and an apiKeyHelper-only host fails with
    # "Not logged in". `cowork_settings.json` is the alternate filename
    # the CLI reads in cowork-plugins mode. Both pass through
    # `strip_settings_for_resume` so plugin declarations don't reconcile
    # against the empty tmp plugin cache.
    ["settings.json", "cowork_settings.json"].each do |name|
      copy_if_present(
        File.join(source_config, name),
        File.join(tmp_base, name),
        ->strip_settings_for_resume(String),
      )
    end
  end

  # User-settings keys that only misbehave under the redirected
  # CLAUDE_CONFIG_DIR: plugin declarations reconcile against the
  # always-empty tmp plugins cache and would network-install each
  # declared marketplace on every resume.
  RESUME_SETTINGS_STRIPPED_KEYS = {"enabledPlugins", "extraKnownMarketplaces"}

  # Drop settings keys that misbehave under a redirected config dir:
  # `RESUME_SETTINGS_STRIPPED_KEYS` and `env.CLAUDE_CONFIG_DIR` (which
  # would point the subprocess's config reads away from `tmp_base`).
  # Content that doesn't parse as a JSON object is returned untouched so
  # the subprocess sees exactly what the CLI would have read.
  # Mirrors Python's `_strip_settings_for_resume` (0.2.137).
  def self.strip_settings_for_resume(content : String) : String
    parsed = begin
      # lchop mirrors the CLI's BOM-tolerant settings reader:
      # PowerShell writes settings.json with a UTF-8 BOM, which a plain
      # parse rejects.
      JSON.parse(content.lchop('\uFEFF')).as_h?
    rescue JSON::ParseException
      return content
    end
    return content unless parsed

    stripped = false
    RESUME_SETTINGS_STRIPPED_KEYS.each do |key|
      if parsed.has_key?(key)
        parsed.delete(key)
        stripped = true
      end
    end
    if env_block = parsed["env"]?.try(&.as_h?)
      if env_block.has_key?("CLAUDE_CONFIG_DIR")
        env_block.delete("CLAUDE_CONFIG_DIR")
        stripped = true
      end
    end
    return content unless stripped

    parsed.to_json
  rescue
    content
  end

  private def self.write_redacted_credentials(creds_json : String, dst : String) : Nil
    payload = creds_json
    begin
      data = JSON.parse(creds_json).as_h?
      if data
        oauth = data["claudeAiOauth"]?.try(&.as_h?)
        if oauth && oauth.has_key?("refreshToken")
          # Avoid single-use refresh token being consumed under redirected CONFIG_DIR.
          redacted = oauth.dup
          redacted.delete("refreshToken")
          rewritten = data.dup
          rewritten["claudeAiOauth"] = JSON::Any.new(redacted)
          payload = rewritten.to_json
        end
      end
    rescue JSON::ParseException
      # Write through unparseable content; subprocess will fail the same way.
    end
    File.write(dst, payload)
    begin
      File.chmod(dst, 0o600)
    rescue
    end
  end

  # Copy `src` to `dst` (mode 0o600) when it exists, through an
  # optional `transform`. Best-effort enrichment of the temp config dir:
  # a missing source is skipped silently; anything else unreadable (a
  # directory or FIFO where a file was expected, permissions, ...) is
  # skipped rather than aborting — or, for a FIFO, hanging — the resume.
  # A failed write never leaves a truncated `dst` behind for the
  # subprocess to misparse. Mirrors Python's `_read_if_present` /
  # `_copy_if_present` (0.2.137).
  private def self.copy_if_present(
    src : String,
    dst : String,
    transform : (String -> String)? = nil,
  ) : Nil
    content = read_if_present(src)
    return unless content

    begin
      File.write(dst, transform ? transform.call(content) : content)
      begin
        File.chmod(dst, 0o600)
      rescue
      end
    rescue
      begin
        File.delete(dst)
      rescue
      end
    end
  end

  private def self.read_if_present(src : String) : String?
    info = File.info?(src)
    return unless info && info.file?

    File.read(src)
  rescue
    nil
  end

  # Best-effort rmtree with short retries for transient locks (AV/indexer).
  def self.rmtree_with_retry(path : String, *, retries : Int32 = 4) : Nil
    return unless Dir.exists?(path) || File.exists?(path)

    retries.times do |i|
      return if try_rmtree(path)
      sleep(0.1.seconds) if i + 1 < retries
    end
    try_rmtree(path)
  end

  # Single rmtree attempt. A failed attempt must not abort the retry
  # loop (or the final best-effort sweep).
  private def self.try_rmtree(path : String) : Bool
    FileUtils.rm_rf(path)
    true
  rescue
    false
  end
end
