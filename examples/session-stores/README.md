# SessionStore adapters

The Crystal SDK defines `ClaudeAgent::SessionStore` plus:

| Adapter | Location | Dependencies |
|---------|----------|--------------|
| `InMemorySessionStore` | `src/claude_agent/session_store.cr` | none |
| `FileSessionStore` | `src/claude_agent/file_session_store.cr` | none |
| Redis reference | `examples/session-stores/redis_session_store.cr` | optional `redis` shard |
| Postgres reference | `examples/session-stores/postgres_session_store.cr` | optional `pg` shard |

## Conformance

Any adapter should pass the shared suite:

```crystal
ClaudeAgent::SessionStoreConformance.run(my_store)
```

This is what `spec/session_store_conformance_spec.cr` runs against InMemory and File stores. Mirror the TypeScript examples' `runSessionStoreConformance` checklist (append/load order, project isolation, cascade delete, list_subkeys, etc.).

## Live mirroring

```crystal
store = ClaudeAgent::FileSessionStore.new("/var/lib/claude-sessions")

options = ClaudeAgent::AgentOptions.new(
  session_store: store,
  session_store_flush: "batched", # or "eager"
)

ClaudeAgent::AgentClient.open(options) do |client|
  client.query("…")
  client.each_response { |msg| … }
end
```

See also `examples/44_session_store.cr` and `examples/session-stores/file_demo.cr`.
