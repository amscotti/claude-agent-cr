require "file_utils"
require "json"
require "mutex"

module ClaudeAgent
  # Durable filesystem SessionStore.
  #
  # Layout (under `root`):
  #   {project_key}/{session_id}.jsonl              — main transcript
  #   {project_key}/{session_id}/{subpath}.jsonl    — subagent / subkey transcripts
  #
  # Zero external dependencies. Suitable as a production local adapter or as a
  # reference for Redis/Postgres/S3 implementations (see examples/session_stores/).
  class FileSessionStore < SessionStore
    getter root : String

    def initialize(@root : String)
      Dir.mkdir_p(@root)
      @mutex = Mutex.new
    end

    def append(key : SessionKey, entries : Array(SessionStoreEntry)) : Nil
      return if entries.empty?

      @mutex.synchronize do
        path = entry_path(key)
        Dir.mkdir_p(File.dirname(path))
        File.open(path, "a") do |io|
          entries.each do |entry|
            io.puts(entry.to_h.to_json)
          end
        end
      end
    end

    def load(key : SessionKey) : Array(SessionStoreEntry)?
      @mutex.synchronize do
        path = entry_path(key)
        return nil unless File.file?(path)

        entries = [] of SessionStoreEntry
        File.each_line(path) do |line|
          next if line.blank?
          begin
            data = JSON.parse(line).as_h?
            next unless data
            entries << SessionStoreEntry.from_hash(data)
          rescue JSON::ParseException | ArgumentError
            # Skip malformed lines (parity with TS S3/Redis adapters)
          end
        end
        entries.empty? ? nil : entries
      end
    end

    def list_sessions(project_key : String) : Array(SessionStoreListEntry)
      @mutex.synchronize do
        dir = File.join(@root, sanitize(project_key))
        return [] of SessionStoreListEntry unless Dir.exists?(dir)

        results = [] of SessionStoreListEntry
        Dir.children(dir).each do |name|
          next unless name.ends_with?(".jsonl")
          session_id = name.rchop(".jsonl")
          path = File.join(dir, name)
          next unless File.file?(path)
          mtime_ms = (File.info(path).modification_time.to_unix_ms)
          results << SessionStoreListEntry.new(session_id, mtime_ms)
        end
        results
      end
    end

    def delete(key : SessionKey) : Nil
      @mutex.synchronize do
        if key.subpath
          path = entry_path(key)
          File.delete(path) if File.file?(path)
          # Best-effort remove empty parents under session dir
          session_dir = File.join(@root, sanitize(key.project_key), sanitize(key.session_id))
          cleanup_empty_dirs(session_dir)
        else
          main = entry_path(key)
          File.delete(main) if File.file?(main)
          session_dir = File.join(@root, sanitize(key.project_key), sanitize(key.session_id))
          FileUtils.rm_rf(session_dir) if Dir.exists?(session_dir)
        end
      end
    end

    def list_subkeys(key : SessionListSubkeysKey) : Array(String)
      @mutex.synchronize do
        session_dir = File.join(@root, sanitize(key.project_key), sanitize(key.session_id))
        return [] of String unless Dir.exists?(session_dir)

        collect_jsonl_subpaths(session_dir, session_dir)
      end
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

    private def entry_path(key : SessionKey) : String
      base = File.join(@root, sanitize(key.project_key))
      if sub = key.subpath
        File.join(base, sanitize(key.session_id), "#{sanitize_path_components(sub)}.jsonl")
      else
        File.join(base, "#{sanitize(key.session_id)}.jsonl")
      end
    end

    private def sanitize(component : String) : String
      # Keep path component safe: reject traversal.
      raise ArgumentError.new("empty path component") if component.empty?
      raise ArgumentError.new("invalid path component: #{component}") if component.includes?("..") || component.includes?('/') || component.includes?('\\')
      component
    end

    private def sanitize_path_components(subpath : String) : String
      parts = subpath.split('/').reject(&.empty?)
      raise ArgumentError.new("empty subpath") if parts.empty?
      parts.each { |part| sanitize(part) }
      parts.join("/")
    end

    private def collect_jsonl_subpaths(root_dir : String, current : String) : Array(String)
      results = [] of String
      return results unless Dir.exists?(current)

      Dir.children(current).each do |name|
        path = File.join(current, name)
        if File.directory?(path)
          results.concat(collect_jsonl_subpaths(root_dir, path))
        elsif name.ends_with?(".jsonl") && File.file?(path)
          rel = Path[path].relative_to(root_dir).to_s
          results << rel.rchop(".jsonl")
        end
      end
      results
    end

    private def cleanup_empty_dirs(dir : String) : Nil
      return unless Dir.exists?(dir)
      return unless Dir.children(dir).empty?

      Dir.delete(dir)
      parent = File.dirname(dir)
      cleanup_empty_dirs(parent) if parent.starts_with?(@root) && parent != @root
    rescue
    end
  end
end
