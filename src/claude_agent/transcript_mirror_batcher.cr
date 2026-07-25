require "json"
require "mutex"

module ClaudeAgent
  # Batching layer between CLI `transcript_mirror` stdout frames and a
  # SessionStore. Matches Python's TranscriptMirrorBatcher:
  # - enqueue is fire-and-forget
  # - flush is synchronous and serialized
  # - eager background flush when pending thresholds are exceeded
  # - adapter failures are retried (3 attempts); never raise into the reader
  class TranscriptMirrorBatcher
    MAX_PENDING_ENTRIES = 500
    MAX_PENDING_BYTES   = 1 << 20 # 1 MiB
    MAX_ATTEMPTS        = 3
    BACKOFF             = {0.2.seconds, 0.8.seconds}

    private struct PendingFrame
      getter file_path : String
      getter entries : Array(SessionStoreEntry)
      getter bytes : Int32

      def initialize(@file_path : String, @entries : Array(SessionStoreEntry), @bytes : Int32)
      end
    end

    @store : SessionStore
    @projects_dir : String
    @on_error : Proc(SessionKey?, String, Nil)
    @max_pending_entries : Int32
    @max_pending_bytes : Int32
    @mutex = Mutex.new
    @flush_mutex = Mutex.new
    @pending = [] of PendingFrame
    @pending_entries = 0
    @pending_bytes = 0
    @closed = false

    def initialize(
      @store : SessionStore,
      @projects_dir : String,
      @on_error : Proc(SessionKey?, String, Nil),
      @max_pending_entries : Int32 = MAX_PENDING_ENTRIES,
      @max_pending_bytes : Int32 = MAX_PENDING_BYTES,
    )
    end

    # Buffer a mirror frame. Schedules a background flush when thresholds
    # are exceeded (or immediately when max thresholds are 0 = eager).
    def enqueue(file_path : String, entries : Array(SessionStoreEntry)) : Nil
      return if entries.empty?

      size = approximate_size(entries)
      should_flush = false

      @mutex.synchronize do
        return if @closed

        @pending << PendingFrame.new(file_path, entries, size)
        @pending_entries += entries.size
        @pending_bytes += size
        should_flush =
          @pending_entries > @max_pending_entries ||
            @pending_bytes > @max_pending_bytes
      end

      spawn { flush } if should_flush
    end

    # Flush all pending entries. Never raises.
    def flush : Nil
      items = detach_pending
      return if items.empty?

      errors = [] of {SessionKey?, String}
      @flush_mutex.synchronize do
        do_flush(items, errors)
      end

      errors.each do |key, message|
        begin
          @on_error.call(key, message)
        rescue
          # Defensive: never let on_error crash the reader fiber.
        end
      end
    end

    # Final flush before teardown. Never raises.
    def close : Nil
      @mutex.synchronize { @closed = true }
      flush
    end

    private def detach_pending : Array(PendingFrame)
      @mutex.synchronize do
        items = @pending
        @pending = [] of PendingFrame
        @pending_entries = 0
        @pending_bytes = 0
        items
      end
    end

    private def do_flush(items : Array(PendingFrame), errors : Array({SessionKey?, String})) : Nil
      by_path = {} of String => Array(SessionStoreEntry)
      items.each do |item|
        bucket = by_path[item.file_path] ||= [] of SessionStoreEntry
        bucket.concat(item.entries)
      end

      by_path.each do |file_path, entries|
        next if entries.empty?

        key = ClaudeAgent.file_path_to_session_key(file_path, @projects_dir)
        unless key
          # Subprocess CLAUDE_CONFIG_DIR may differ from parent projects_dir.
          errors << {nil, "transcript_mirror filePath not under projects_dir: #{file_path}"}
          next
        end

        last_error : String? = nil
        succeeded = false
        MAX_ATTEMPTS.times do |attempt|
          sleep BACKOFF[attempt - 1] if attempt > 0
          begin
            @store.append(key, entries)
            succeeded = true
            break
          rescue ex
            last_error = ex.message || ex.class.to_s
          end
        end

        unless succeeded
          errors << {key, last_error || "SessionStore#append failed"}
        end
      end
    end

    private def approximate_size(entries : Array(SessionStoreEntry)) : Int32
      # Cheap estimate: stringify once per frame via entry hashes.
      total = 0
      entries.each { |entry| total += entry.to_h.to_json.bytesize }
      total
    end
  end
end
