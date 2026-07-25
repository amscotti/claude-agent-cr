require "json"
require "uuid"

module ClaudeAgent
  # Behavioral conformance suite for SessionStore adapters.
  #
  # Any adapter that passes these checks satisfies the contract the SDK relies
  # on for transcript mirroring and resume. Mirrors the TypeScript examples'
  # `runSessionStoreConformance` suite (13 behaviors).
  #
  # Usage:
  # ```
  # ClaudeAgent::SessionStoreConformance.run(ClaudeAgent::InMemorySessionStore.new)
  # ClaudeAgent::SessionStoreConformance.run(ClaudeAgent::FileSessionStore.new(root: dir))
  # ```
  #
  # Raises `SessionStoreConformance::Failure` on the first failed check.
  # Returns the number of checks executed (optional methods may skip some).
  module SessionStoreConformance
    class Failure < Error
      getter check_name : String

      def initialize(@check_name : String, message : String)
        super("SessionStore conformance [#{check_name}]: #{message}")
      end
    end

    # Run the suite against a fresh store. The store must be empty / isolated.
    def self.run(store : SessionStore) : Int32
      count = 0
      count += 1
      check_append_then_load(store)
      count += 1
      check_load_unknown(store)
      count += 1
      check_multiple_appends(store)
      count += 1
      check_empty_append(store)
      count += 1
      check_subpath_independence(store)
      count += 1
      check_project_isolation(store)

      if store.supports_list_sessions?
        count += 1
        check_list_sessions(store)
        count += 1
        check_list_sessions_excludes_subpaths(store)
      end

      if store.supports_delete?
        count += 1
        check_delete_main(store)
        count += 1
        check_delete_cascade(store)
        count += 1
        check_delete_subpath_only(store)
      end

      if store.supports_list_subkeys?
        count += 1
        check_list_subkeys(store)
        count += 1
        check_list_subkeys_excludes_main(store)
      end

      count
    end

    private def self.e(type : String, extra : Hash(String, JSON::Any) = {} of String => JSON::Any) : SessionStoreEntry
      hash = {"type" => JSON::Any.new(type)} of String => JSON::Any
      extra.each { |k, v| hash[k] = v }
      SessionStoreEntry.from_hash(hash)
    end

    private def self.key(project = "proj", session = "sess", subpath : String? = nil) : SessionKey
      SessionKey.new(project, session, subpath)
    end

    private def self.expect_entries(actual : Array(SessionStoreEntry)?, expected : Array(SessionStoreEntry), name : String) : Nil
      raise Failure.new(name, "expected entries, got nil") if actual.nil?
      unless actual.size == expected.size
        raise Failure.new(name, "size #{actual.size} != #{expected.size}")
      end
      actual.zip(expected) do |got, want|
        unless canon(got.to_h) == canon(want.to_h)
          raise Failure.new(name, "entry mismatch: #{got.to_h} vs #{want.to_h}")
        end
      end
    end

    # Sorted-key stringify so deep-equal ignores object-key order.
    private def self.canon(value : JSON::Any) : String
      raw = value.raw
      case raw
      when Hash
        sorted = raw.keys.sort!.each_with_object({} of String => JSON::Any) do |k, acc|
          acc[k] = JSON::Any.new(JSON.parse(canon(raw[k])).raw)
        end
        sorted.to_json
      when Array
        raw.map { |v| JSON.parse(canon(v)) }.to_json
      else
        value.to_json
      end
    end

    private def self.canon(hash : Hash(String, JSON::Any)) : String
      canon(JSON::Any.new(hash))
    end

    private def self.check_append_then_load(store : SessionStore) : Nil
      entries = [
        e("a", {"n" => JSON::Any.new(1_i64), "nested" => JSON::Any.new({"x" => JSON::Any.new([JSON::Any.new(1_i64), JSON::Any.new(2_i64)])})}),
        e("b", {"n" => JSON::Any.new(2_i64)}),
      ]
      store.append(key, entries)
      expect_entries(store.load(key), entries, "append_then_load")
    end

    private def self.check_load_unknown(store : SessionStore) : Nil
      k = key("unknown", "never-#{UUID.random}")
      raise Failure.new("load_unknown", "expected nil") unless store.load(k).nil?
      raise Failure.new("load_unknown_sub", "expected nil") unless store.load(key("unknown", "never", "subagents/a")).nil?
    end

    private def self.check_multiple_appends(store : SessionStore) : Nil
      k = key("multi", "s1")
      store.append(k, [e("a")])
      store.append(k, [e("b"), e("c")])
      store.append(k, [e("d")])
      expect_entries(store.load(k), [e("a"), e("b"), e("c"), e("d")], "multiple_appends")
    end

    private def self.check_empty_append(store : SessionStore) : Nil
      k = key("empty", "s1")
      store.append(k, [] of SessionStoreEntry)
      raise Failure.new("empty_append_nil", "expected nil") unless store.load(k).nil?
      store.append(k, [e("a")])
      store.append(k, [] of SessionStoreEntry)
      expect_entries(store.load(k), [e("a")], "empty_append_preserve")
    end

    private def self.check_subpath_independence(store : SessionStore) : Nil
      k = key("sub", "s1")
      store.append(k, [e("main")])
      store.append(SessionKey.new("sub", "s1", "subagents/x"), [e("sub")])
      expect_entries(store.load(k), [e("main")], "subpath_main")
      expect_entries(store.load(SessionKey.new("sub", "s1", "subagents/x")), [e("sub")], "subpath_sub")
    end

    private def self.check_project_isolation(store : SessionStore) : Nil
      a = key("A", "s")
      b = key("B", "s")
      store.append(a, [e("a")])
      store.append(b, [e("b")])
      expect_entries(store.load(a), [e("a")], "project_A")
      expect_entries(store.load(b), [e("b")], "project_B")
    end

    private def self.check_list_sessions(store : SessionStore) : Nil
      store.append(key("P", "s1"), [e("a")])
      store.append(key("P", "s2"), [e("b")])
      store.append(key("Q", "s3"), [e("c")])
      ids = store.list_sessions("P").map(&.session_id).sort!
      raise Failure.new("list_sessions_ids", "got #{ids}") unless ids == ["s1", "s2"]
      listed = store.list_sessions("P")
      unless listed.all? { |entry| entry.mtime > 1_000_000_000_000_i64 }
        # Allow lower mtimes for file stores that use seconds*1000 or synthetic clocks
        unless listed.all? { |entry| entry.mtime > 0 }
          raise Failure.new("list_sessions_mtime", "mtime should be positive")
        end
      end
      empty = store.list_sessions("never-seen-#{UUID.random}")
      raise Failure.new("list_sessions_empty", "expected []") unless empty.empty?
    end

    private def self.check_list_sessions_excludes_subpaths(store : SessionStore) : Nil
      pk = "P-sub-#{UUID.random}"
      store.append(SessionKey.new(pk, "s1", "subagents/x"), [e("sub")])
      ids = store.list_sessions(pk).map(&.session_id)
      if ids.includes?("s1")
        raise Failure.new("list_sessions_excludes_subpaths", "subpath-only session listed")
      end
    end

    private def self.check_delete_main(store : SessionStore) : Nil
      k = key("del", "s1")
      store.append(k, [e("a")])
      store.delete(k)
      raise Failure.new("delete_main", "expected nil after delete") unless store.load(k).nil?
      store.delete(key("x", "never")) # must not raise
    end

    private def self.check_delete_cascade(store : SessionStore) : Nil
      k = key("casc", "sess")
      store.append(k, [e("main")])
      store.append(SessionKey.new("casc", "sess", "subagents/a"), [e("sa")])
      store.append(SessionKey.new("casc", "sess", "subagents/b"), [e("sb")])
      store.append(key("casc", "other"), [e("o")])
      store.append(key("casc2", "sess"), [e("p2")])
      store.delete(k)
      raise Failure.new("cascade_main", "main") unless store.load(k).nil?
      raise Failure.new("cascade_a", "a") unless store.load(SessionKey.new("casc", "sess", "subagents/a")).nil?
      raise Failure.new("cascade_b", "b") unless store.load(SessionKey.new("casc", "sess", "subagents/b")).nil?
      expect_entries(store.load(key("casc", "other")), [e("o")], "cascade_other")
      expect_entries(store.load(key("casc2", "sess")), [e("p2")], "cascade_other_proj")
      if store.supports_list_subkeys?
        subs = store.list_subkeys(SessionListSubkeysKey.new("casc", "sess"))
        raise Failure.new("cascade_subkeys", "expected []") unless subs.empty?
      end
    end

    private def self.check_delete_subpath_only(store : SessionStore) : Nil
      k = key("dsub", "sess")
      store.append(k, [e("main")])
      store.append(SessionKey.new("dsub", "sess", "subagents/a"), [e("sa")])
      store.append(SessionKey.new("dsub", "sess", "subagents/b"), [e("sb")])
      store.delete(SessionKey.new("dsub", "sess", "subagents/a"))
      expect_entries(store.load(k), [e("main")], "dsub_main")
      raise Failure.new("dsub_a", "a") unless store.load(SessionKey.new("dsub", "sess", "subagents/a")).nil?
      expect_entries(store.load(SessionKey.new("dsub", "sess", "subagents/b")), [e("sb")], "dsub_b")
    end

    private def self.check_list_subkeys(store : SessionStore) : Nil
      store.append(SessionKey.new("lsk", "sess", "subagents/a"), [e("sa")])
      store.append(SessionKey.new("lsk", "sess", "subagents/b"), [e("sb")])
      store.append(SessionKey.new("lsk", "other", "subagents/c"), [e("sc")])
      subs = store.list_subkeys(SessionListSubkeysKey.new("lsk", "sess")).sort!
      raise Failure.new("list_subkeys", "got #{subs}") unless subs == ["subagents/a", "subagents/b"]
    end

    private def self.check_list_subkeys_excludes_main(store : SessionStore) : Nil
      k = key("lskm", "sess")
      store.append(k, [e("main")])
      subs = store.list_subkeys(SessionListSubkeysKey.new("lskm", "sess"))
      raise Failure.new("list_subkeys_main", "expected []") unless subs.empty?
      empty = store.list_subkeys(SessionListSubkeysKey.new("x", "never"))
      raise Failure.new("list_subkeys_never", "expected []") unless empty.empty?
    end
  end
end
