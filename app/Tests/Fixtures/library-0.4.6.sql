-- The structure of a library as the 0.4.6 release leaves it on a device that
-- has been updated since 0.4.2, for LibrarySchemaUpgradeTests: every table,
-- index and trigger, in the order the library holds them, and no rows. It
-- has the tables named companion_* that 0.4.6 never reads, tables still
-- declared as an earlier release created them, the number an earlier release
-- left in the file, and the built-in agent's own tables (wm_pi_*). SQLite's
-- own tables and the search index's shadow tables are created by SQLite.
PRAGMA auto_vacuum=INCREMENTAL;
PRAGMA user_version=3;
CREATE TABLE surface_profiles (
  id TEXT PRIMARY KEY, device_id TEXT, theme TEXT NOT NULL DEFAULT 'green',
  sidebar_style TEXT NOT NULL DEFAULT 'split',
  single_sidebar_side TEXT NOT NULL DEFAULT 'left',
  left_rail_visible INTEGER NOT NULL DEFAULT 1,
  right_rail_visible INTEGER NOT NULL DEFAULT 1,
  single_rail_visible INTEGER NOT NULL DEFAULT 1,
  chat_width_percent REAL NOT NULL DEFAULT 58,
  note_on_left INTEGER NOT NULL DEFAULT 0,
  workspace_mode TEXT NOT NULL DEFAULT 'chats',
  agent_order_json TEXT NOT NULL DEFAULT '[]',
  revision INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE folders (
  id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
  icon TEXT NOT NULL DEFAULT 'folder', position INTEGER NOT NULL DEFAULT 0,
  is_pinned INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE notes (
  id TEXT PRIMARY KEY, folder_id TEXT,
  title TEXT NOT NULL DEFAULT 'Untitled Note', content TEXT NOT NULL DEFAULT '',
  snippet TEXT, is_pinned INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT, original_folder_id TEXT, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE "conversations" (
  id TEXT PRIMARY KEY, agent_id TEXT, agent_codename TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT 'New conversation',
  unread INTEGER NOT NULL DEFAULT 0, last_message_preview TEXT,
  is_archived INTEGER NOT NULL DEFAULT 0, last_message_at TEXT NOT NULL DEFAULT '', folder_id TEXT, original_folder_id TEXT,
  is_pinned INTEGER NOT NULL DEFAULT 0, deleted_at TEXT, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');
CREATE TABLE "messages" (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '', client_message_id TEXT,
  run_id TEXT, role TEXT NOT NULL DEFAULT 'assistant',
  content TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'completed', created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
  "sequence" INTEGER, "position" INTEGER, "attachment_references" TEXT);
CREATE TABLE "message_attachments" (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
  message_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'file',
  file_name TEXT NOT NULL DEFAULT '', mime_type TEXT NOT NULL DEFAULT '',
  size_bytes INTEGER NOT NULL DEFAULT 0, content_hash TEXT, created_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE "message_references" (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
  message_id TEXT NOT NULL DEFAULT '', resource_type TEXT NOT NULL DEFAULT 'note', resource_id TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'attached', title_snapshot TEXT NOT NULL DEFAULT '',
  content_snapshot TEXT NOT NULL DEFAULT '',
  folder_id_snapshot TEXT, folder_title_snapshot TEXT, agent_codename_snapshot TEXT,
  revision_snapshot TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE "run_visible_notes" (
  run_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '', note_id TEXT NOT NULL DEFAULT '', revision_snapshot TEXT NOT NULL DEFAULT '');
CREATE TABLE "remote_note_edits" (
  run_id TEXT PRIMARY KEY, assistant_message_id TEXT NOT NULL,
  note_id TEXT NOT NULL, expected_revision TEXT NOT NULL,
  nonce TEXT NOT NULL, note_kind TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending', error TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE "run_activities" (
  id TEXT PRIMARY KEY, run_id TEXT NOT NULL DEFAULT '',
  conversation_id TEXT NOT NULL DEFAULT '', event_type TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT ''
, "position" INTEGER, "sequence" INTEGER, "title" TEXT, "detail" TEXT, "status" TEXT, "details_record_id" TEXT, "is_transient" INTEGER, "completed_at" TEXT);
CREATE TABLE "harness_sessions" (
  conversation_id TEXT PRIMARY KEY, agent_id TEXT,
  runtime_kind TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  "native_session_id" TEXT, model TEXT, thinking TEXT,
  remote_workspace_id TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
, permission TEXT);
CREATE TABLE "calendar_items" (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '', description TEXT, starts_at TEXT NOT NULL DEFAULT '',
  ends_at TEXT, all_day INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'scheduled',
  source TEXT NOT NULL DEFAULT 'user', created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
, calendar_json TEXT, deleted_at TEXT);
CREATE TABLE "workspace_revision" (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  revision INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE usage_sources (
  source_id TEXT PRIMARY KEY,
  source_name TEXT NOT NULL,
  source_location TEXT NOT NULL,
  provider TEXT NOT NULL,
  harness TEXT,
  fingerprint TEXT NOT NULL,
  imported_at REAL NOT NULL
, source_kind TEXT NOT NULL DEFAULT 'local-history', installation_id TEXT, indexed_after REAL);
CREATE TABLE usage_events (
  event_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES usage_sources(source_id) ON DELETE CASCADE,
  source_event_id TEXT NOT NULL,
  dedupe_key TEXT,
  provider TEXT NOT NULL,
  billing_provider TEXT NOT NULL,
  billing_route TEXT NOT NULL,
  model_raw TEXT NOT NULL,
  model_canonical TEXT NOT NULL,
  model_family TEXT NOT NULL,
  model_publisher TEXT NOT NULL,
  model_identity_confidence TEXT NOT NULL,
  timestamp REAL NOT NULL,
  session_id TEXT NOT NULL,
  reasoning_level TEXT,
  harness TEXT NOT NULL,
  application TEXT NOT NULL,
  agent TEXT,
  workspace TEXT,
  request_count INTEGER NOT NULL DEFAULT 1,
  input_tokens INTEGER NOT NULL,
  cached_input_tokens INTEGER NOT NULL,
  cache_creation_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  reasoning_tokens INTEGER NOT NULL,
  reported_total_tokens INTEGER,
  cost_usd REAL,
  attribution_confidence TEXT NOT NULL,
  granularity TEXT NOT NULL,
  imported_at REAL NOT NULL,
  UNIQUE(source_id, source_event_id)
);
CREATE TABLE usage_metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE usage_runtime_cursors (
  endpoint TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  cursor TEXT NOT NULL,
  synced_at REAL NOT NULL,
  status TEXT NOT NULL,
  detail TEXT NOT NULL
);
CREATE TABLE "opencode_sessions" (
  conversation_id TEXT PRIMARY KEY REFERENCES "conversations"(id),
  connection_id TEXT NOT NULL, session_id TEXT NOT NULL, snapshot_json TEXT NOT NULL,
  UNIQUE(connection_id, session_id)
);
CREATE TABLE "opencode_submissions" (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL
);
CREATE TABLE "session_imports" (
  conversation_id TEXT PRIMARY KEY REFERENCES "conversations"(id) ON DELETE CASCADE,
  imported_at TEXT NOT NULL
);
CREATE TABLE "session_deliveries"(
  id TEXT PRIMARY KEY,source_id TEXT NOT NULL,target_id TEXT NOT NULL,content TEXT NOT NULL,
  status TEXT NOT NULL,message_id TEXT UNIQUE,source_agent TEXT,source_title TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
, kind TEXT NOT NULL DEFAULT 'message', purpose TEXT, target_title TEXT, target_harness TEXT, target_model TEXT, event_key TEXT, transport_started INTEGER NOT NULL DEFAULT 1, retry_after REAL, native_command TEXT, failure_code TEXT, failure_reason TEXT);
CREATE TABLE "history_events"(
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
  conversation_id TEXT, run_id TEXT, agent_id TEXT, harness TEXT NOT NULL,
  kind TEXT NOT NULL, payload TEXT NOT NULL, completeness TEXT NOT NULL DEFAULT 'observed',
  recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
, native_session_id TEXT, source_connection_id TEXT, source_id TEXT, native_record_id TEXT, native_revision_id TEXT, content_mode TEXT, text_content TEXT, projection_json TEXT);
CREATE TABLE note_asset_versions(
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
  note_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL,
  revision TEXT NOT NULL, source TEXT NOT NULL, bytes INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE "tool_mutations"(
  source_id TEXT NOT NULL REFERENCES "conversations"(id), request_id TEXT NOT NULL,
  operation TEXT NOT NULL, input_digest TEXT NOT NULL, result_json TEXT NOT NULL,
  PRIMARY KEY(source_id,request_id));
CREATE TABLE "tool_settings"(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
CREATE TABLE "opencode_input_contexts"(
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, visible_text TEXT NOT NULL, delivery_id TEXT);
CREATE TABLE "session_grants"(
  source_id TEXT NOT NULL REFERENCES "conversations"(id),
  target_id TEXT NOT NULL REFERENCES "conversations"(id),
  kind TEXT NOT NULL CHECK(kind IN ('attachment','approved')),
  PRIMARY KEY(source_id,target_id,kind));
CREATE TABLE "session_relationships"(
  session_id TEXT PRIMARY KEY REFERENCES "conversations"(id),
  created_by TEXT REFERENCES "conversations"(id),
  coordinator_id TEXT REFERENCES "conversations"(id),
  purpose TEXT, notifications_enabled INTEGER NOT NULL DEFAULT 1, coordination_epoch TEXT, coordination_since TEXT,
  CHECK(session_id != created_by), CHECK(session_id != coordinator_id));
CREATE TABLE "session_timers"(
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES "conversations"(id),
  instruction TEXT NOT NULL, next_fire_at REAL NOT NULL, interval_seconds REAL,
  is_paused INTEGER NOT NULL DEFAULT 0, pending_delivery_id TEXT);
CREATE TABLE "coordination_access_requests"(
  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES "conversations"(id),
  target_id TEXT NOT NULL REFERENCES "conversations"(id), purpose TEXT NOT NULL,
  notifications INTEGER NOT NULL, state TEXT NOT NULL, error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), coordination_epoch TEXT);
CREATE TABLE "session_creations"(
  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES "conversations"(id),
  target_id TEXT NOT NULL UNIQUE, arguments_json TEXT NOT NULL,
  purpose TEXT NOT NULL, managed INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'planned', configuration_json TEXT, configuration_applied INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "coordination_observations"(
  epoch TEXT NOT NULL, event_key TEXT NOT NULL, PRIMARY KEY(epoch,event_key));
CREATE TABLE "calendar_runs"(
  id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES "calendar_items"(id),
  scheduled_at TEXT NOT NULL, occurrence_index INTEGER NOT NULL, session_id TEXT NOT NULL,
  task_json TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
  error TEXT, retry_after REAL, coalesced_through REAL NOT NULL, hidden_at TEXT,
  UNIQUE(event_id,scheduled_at));
CREATE TABLE "calendar_task_sessions"(id TEXT PRIMARY KEY, configuration_json TEXT NOT NULL);
CREATE TABLE library_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE library_messages(
  message_id TEXT PRIMARY KEY REFERENCES "messages"(id) ON DELETE CASCADE,
  dirty INTEGER NOT NULL DEFAULT 1);
CREATE TABLE library_items(
  id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES library_messages(message_id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL, kind TEXT NOT NULL,title TEXT NOT NULL,source TEXT NOT NULL,
  content_hash TEXT,mime_type TEXT,size_bytes INTEGER,storage TEXT NOT NULL,error TEXT,
  retry_at TEXT, UNIQUE(message_id,source));
CREATE TABLE library_locations(
  conversation_id TEXT PRIMARY KEY, workspace_name TEXT NOT NULL,root TEXT NOT NULL);
CREATE TABLE "calendar_remote_ownership"(
  workspace_id TEXT PRIMARY KEY, state TEXT NOT NULL CHECK(state IN ('pending','remote')));
CREATE TABLE "calendar_remote_receipts"(
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, session_id TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE "conversation_titles" (
  conversation_id TEXT PRIMARY KEY REFERENCES "conversations"(id) ON DELETE CASCADE,
  title TEXT NOT NULL
);
CREATE TABLE "session_executor_profiles"(
  session_id TEXT PRIMARY KEY REFERENCES "conversations"(id), profiles_json TEXT NOT NULL);
CREATE TABLE "input_contexts"(
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES "conversations"(id),
  note_id TEXT, created_at TEXT NOT NULL);
CREATE TABLE "activity_revision" (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
CREATE TABLE "activity_summaries" (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, run_id TEXT NOT NULL,
  revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  summary TEXT);
CREATE TABLE "message_revisions" (
  id TEXT PRIMARY KEY, revision INTEGER NOT NULL);
CREATE TABLE "opencode_hidden_messages" (
  message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL);
CREATE TABLE "run_program_statuses" (
  run_id TEXT NOT NULL REFERENCES "runs"(id) ON DELETE CASCADE,
  source TEXT NOT NULL, records_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(run_id, source)
);
CREATE TABLE companion_library_identity (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1), host_device_id TEXT NOT NULL
);
CREATE TABLE companion_execution_workspaces (
  id TEXT PRIMARY KEY, owner_device_id TEXT NOT NULL, revision INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL
);
CREATE TABLE companion_workspace_publishers (
  workspace_id TEXT PRIMARY KEY, digest BLOB NOT NULL UNIQUE, payload BLOB NOT NULL
);
CREATE TABLE companion_execution_journal (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
  workspace_id TEXT NOT NULL, origin_sequence INTEGER NOT NULL,
  fingerprint BLOB NOT NULL, payload BLOB NOT NULL,
  UNIQUE(workspace_id, origin_sequence)
);
CREATE TABLE companion_retained_settlements (
  event_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, fingerprint BLOB NOT NULL
);
CREATE TABLE companion_execution_conversations (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  conversation BLOB NOT NULL, transcript BLOB
);
CREATE TABLE companion_execution_adoptions (
  conversation_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, payload BLOB NOT NULL
);
CREATE TABLE companion_execution_runs (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, conversation_id TEXT NOT NULL
);
CREATE TABLE companion_execution_receipts (
  workspace_id TEXT NOT NULL, command_id TEXT NOT NULL, device_id TEXT NOT NULL,
  payload BLOB NOT NULL, PRIMARY KEY(workspace_id, command_id)
);
CREATE TABLE companion_native_history (
  workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
  run_id TEXT, format TEXT NOT NULL, part_count INTEGER NOT NULL, byte_count INTEGER NOT NULL,
  sha256 TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(workspace_id, record_id)
);
CREATE TABLE companion_native_history_parts (
  workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, part_index INTEGER NOT NULL, bytes BLOB NOT NULL,
  PRIMARY KEY(workspace_id, record_id, part_index)
);
CREATE TABLE companion_saved_artifacts (
  id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest BLOB NOT NULL
);
CREATE TABLE companion_artifact_uploads (
  id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest BLOB NOT NULL,
  next_offset INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE companion_artifact_chunks (
  artifact_id TEXT NOT NULL, revision INTEGER NOT NULL, offset INTEGER NOT NULL,
  bytes BLOB NOT NULL, PRIMARY KEY(artifact_id, revision, offset)
);
CREATE TABLE companion_tool_receipts (
  device_id TEXT NOT NULL, request_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
  fingerprint BLOB NOT NULL, response BLOB, PRIMARY KEY(device_id,request_id)
);
CREATE TABLE companion_workspace (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1), workspace_id TEXT NOT NULL
);
CREATE TABLE companion_versions (
  kind TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind, resource_id)
);
CREATE TABLE companion_changes (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
  resource_id TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE companion_mutation_receipts (
  device_id TEXT NOT NULL, operation_id TEXT NOT NULL, request BLOB NOT NULL,
  response BLOB NOT NULL, PRIMARY KEY(device_id, operation_id)
);
CREATE TABLE companion_command_receipts (
  device_id TEXT NOT NULL, command_id TEXT NOT NULL, request BLOB NOT NULL,
  response BLOB NOT NULL, PRIMARY KEY(device_id, command_id)
);
CREATE TABLE companion_draft_receipts (
  operation_id TEXT PRIMARY KEY, note_id TEXT NOT NULL, title TEXT NOT NULL,
  content TEXT NOT NULL, revision TEXT NOT NULL
);
CREATE TABLE companion_calendar_execution_conflicts(event_id TEXT PRIMARY KEY);
CREATE TABLE companion_calendar_execution_context(singleton INTEGER PRIMARY KEY CHECK(singleton=1), library_id TEXT NOT NULL, workspace_id TEXT NOT NULL);
CREATE TABLE companion_calendar_owners(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, tools_json TEXT);
CREATE TABLE companion_calendar_run_owners(event_id TEXT NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(event_id,device_id));
CREATE TABLE companion_calendar_runs(id TEXT PRIMARY KEY, event_id TEXT NOT NULL, device_id TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE companion_calendar_receipts(device_id TEXT NOT NULL, mutation_id TEXT NOT NULL,
  input_json TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(device_id,mutation_id));
CREATE TABLE folder_execution_roots (
  folder_id TEXT PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL, root_path TEXT NOT NULL,
  managed INTEGER NOT NULL, reference_paths TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE session_scratch_directories (
  session_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
  workspace_root TEXT NOT NULL, root_path TEXT NOT NULL,
  UNIQUE(workspace_id, root_path)
);
CREATE TABLE execution_workspace_defaults (workspace_id TEXT PRIMARY KEY, default_path TEXT NOT NULL);
CREATE TABLE session_execution_roots (
  conversation_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
  root_path TEXT NOT NULL, folder_locked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE "automation_requests"(
  source_id TEXT NOT NULL REFERENCES "conversations"(id), request_id TEXT NOT NULL,
  input_digest TEXT NOT NULL, PRIMARY KEY(source_id,request_id));
CREATE TABLE "automation_cancellations"(
  source_id TEXT NOT NULL REFERENCES "conversations"(id), request_id TEXT NOT NULL,
  PRIMARY KEY(source_id,request_id));
CREATE TABLE "session_goals"(
  session_id TEXT PRIMARY KEY REFERENCES "conversations"(id) ON DELETE CASCADE, value TEXT NOT NULL);
CREATE TABLE "goal_runs"(
  goal_id TEXT NOT NULL, run_id TEXT NOT NULL, PRIMARY KEY(goal_id,run_id));
CREATE TABLE "goal_usage"(
  goal_id TEXT NOT NULL, run_id TEXT NOT NULL, tokens INTEGER NOT NULL,
  PRIMARY KEY(goal_id,run_id));
CREATE TABLE product_analytics_events(id TEXT PRIMARY KEY, created REAL NOT NULL);
CREATE TABLE product_analytics_limits(name TEXT PRIMARY KEY, last_attempt REAL NOT NULL);
CREATE TABLE retained_execution_history (
  conversation_id TEXT PRIMARY KEY REFERENCES "conversations"(id) ON DELETE CASCADE
);
CREATE TABLE companion_message_provenance (
  message_id TEXT PRIMARY KEY, source_id TEXT NOT NULL,
  source_title TEXT, source_agent TEXT, kind TEXT NOT NULL
);
CREATE TABLE companion_workspace_mcp_grants (
  workspace_id TEXT PRIMARY KEY, digest BLOB NOT NULL UNIQUE, payload BLOB NOT NULL
);
CREATE TABLE companion_scheduled_mcp_callers (
  run_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
  event_id TEXT NOT NULL, scheduled_at TEXT NOT NULL, native_session_id TEXT,
  UNIQUE(event_id,scheduled_at)
);
CREATE TABLE dictation_history (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
  created_at REAL NOT NULL, payload_json TEXT NOT NULL
);
CREATE TABLE wm_pi_runtime_stores (store_id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, schema_prefix TEXT NOT NULL UNIQUE, format INTEGER NOT NULL, activated_at TEXT NOT NULL);
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_durable_schema (
			singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
			version INTEGER NOT NULL CHECK (version >= 0)
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_durable_metadata (
			singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
			next_id TEXT NOT NULL,
			next_seq INTEGER NOT NULL
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_record_ids (
			id INTEGER PRIMARY KEY,
			record_type TEXT NOT NULL CHECK (record_type IN ('conversation', 'entry', 'task', 'submission', 'document'))
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_conversations (
			id INTEGER PRIMARY KEY,
			owner_conversation_id INTEGER,
			owner_task_id INTEGER,
			record TEXT NOT NULL CHECK (json_valid(record))
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_entries (
			id INTEGER PRIMARY KEY,
			conversation_id INTEGER NOT NULL,
			head INTEGER,
			commit_seq INTEGER NOT NULL,
			record TEXT NOT NULL CHECK (json_valid(record))
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_submissions (
			id INTEGER PRIMARY KEY,
			conversation_id INTEGER NOT NULL,
			request_id TEXT,
			status TEXT NOT NULL CHECK (status IN ('queued', 'placed', 'done', 'unanswered')),
			record TEXT NOT NULL CHECK (json_valid(record))
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_documents (
			id INTEGER PRIMARY KEY,
			kind TEXT NOT NULL,
			family INTEGER NOT NULL CHECK (family IN (0, 1)),
			key_value TEXT NOT NULL,
			scope_kind TEXT NOT NULL CHECK (scope_kind IN ('session', 'conversation', 'task')),
			owner_id INTEGER NOT NULL,
			created_at INTEGER NOT NULL,
			retired_at INTEGER,
			record TEXT NOT NULL CHECK (json_valid(record))
		) STRICT;
CREATE TABLE wm_pi_0123456789abcdef0123456789abcdef_document_revisions (
			document_id INTEGER NOT NULL,
			seq INTEGER NOT NULL,
			kind TEXT NOT NULL CHECK (kind IN ('base', 'delta')),
			version INTEGER NOT NULL,
			content TEXT NOT NULL CHECK (json_valid(content)),
			PRIMARY KEY (document_id, seq)
		) STRICT;
CREATE TABLE "wm_pi_0123456789abcdef0123456789abcdef_tasks" (
			id INTEGER PRIMARY KEY,
			conversation_id INTEGER NOT NULL,
			kind TEXT NOT NULL,
			status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'waiting', 'sleeping', 'completing', 'terminal')),
			abort_requested INTEGER NOT NULL CHECK (abort_requested IN (0, 1)),
			background INTEGER NOT NULL CHECK (background IN (0, 1)),
			record TEXT NOT NULL CHECK (json_valid(record))
		) STRICT;
CREATE TABLE calendar_schedules(
  item_id TEXT PRIMARY KEY, next_fire_at REAL, task_session_id TEXT, item_definition TEXT NOT NULL DEFAULT '');
CREATE TABLE "product_analytics_preference"(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload TEXT NOT NULL);
CREATE TABLE "agents" (
  id TEXT PRIMARY KEY, codename TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT 'bot',
  execution_location TEXT NOT NULL DEFAULT 'local', owner_device_id TEXT,
  runtime_kind TEXT NOT NULL, runtime_device_id TEXT, platform_codename TEXT,
  status TEXT NOT NULL DEFAULT 'offline', revision INTEGER NOT NULL DEFAULT 1,
  deleted_at TEXT, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE "session_tools" (
  session_id TEXT PRIMARY KEY REFERENCES conversations(id), enabled_json TEXT NOT NULL,
  defaults_applied INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "runs" (
  ordinal INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
  conversation_id TEXT NOT NULL DEFAULT '', agent_id TEXT,
  agent_codename TEXT NOT NULL DEFAULT '',
  native_session_id TEXT NOT NULL DEFAULT '', user_message_id TEXT,
  assistant_message_id TEXT, status TEXT NOT NULL DEFAULT 'queued', error TEXT,
  started_at TEXT, completed_at TEXT,
  created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
  position INTEGER
);
CREATE TABLE github_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload TEXT NOT NULL);
CREATE TABLE github_identity_recipients(device_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
CREATE TABLE library_identity (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1), host_device_id TEXT NOT NULL, library_id TEXT NOT NULL
);
CREATE TABLE execution_workspaces (
  id TEXT PRIMARY KEY, owner_device_id TEXT NOT NULL, revision INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0, payload TEXT NOT NULL
);
CREATE TABLE execution_journal (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
  workspace_id TEXT NOT NULL, origin_sequence INTEGER NOT NULL,
  fingerprint BLOB NOT NULL, payload TEXT NOT NULL,
  UNIQUE(workspace_id, origin_sequence)
);
CREATE TABLE execution_retained_settlements (
  event_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, fingerprint BLOB NOT NULL
);
CREATE TABLE execution_conversations (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  conversation TEXT NOT NULL, active_run_id TEXT
);
CREATE TABLE execution_adoptions (
  conversation_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, payload TEXT NOT NULL
);
CREATE TABLE message_provenance (
  message_id TEXT PRIMARY KEY, source_id TEXT NOT NULL,
  source_title TEXT, source_agent TEXT, kind TEXT NOT NULL
);
CREATE TABLE execution_runs (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, conversation_id TEXT NOT NULL
);
CREATE TABLE execution_receipts (
  workspace_id TEXT NOT NULL, command_id TEXT NOT NULL, device_id TEXT NOT NULL,
  payload TEXT NOT NULL, PRIMARY KEY(workspace_id, command_id)
);
CREATE TABLE execution_native_history (
  workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
  run_id TEXT, format TEXT NOT NULL, part_count INTEGER NOT NULL, byte_count INTEGER NOT NULL,
  sha256 TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(workspace_id, record_id)
);
CREATE TABLE execution_native_history_parts (
  workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, part_index INTEGER NOT NULL,
  sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
  PRIMARY KEY(workspace_id, record_id, part_index)
);
CREATE TABLE saved_artifacts (
  id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest TEXT NOT NULL
);
CREATE TABLE artifact_uploads (
  id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest TEXT NOT NULL,
  next_offset INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE artifact_chunks (
  artifact_id TEXT NOT NULL, revision INTEGER NOT NULL, offset INTEGER NOT NULL,
  sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL, PRIMARY KEY(artifact_id, revision, offset)
);
CREATE TABLE device_tool_receipts (
  device_id TEXT NOT NULL, request_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
  fingerprint BLOB NOT NULL, response TEXT, PRIMARY KEY(device_id,request_id)
);
CREATE TABLE device_scheduled_mcp_callers (
  run_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
  event_id TEXT NOT NULL, scheduled_at TEXT NOT NULL, native_session_id TEXT,
  UNIQUE(event_id,scheduled_at)
);
CREATE TABLE device_sync_revisions (
  kind TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind, resource_id)
);
CREATE TABLE device_sync_changes (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
  resource_id TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE device_mutation_receipts (
  device_id TEXT NOT NULL, operation_id TEXT NOT NULL, request BLOB NOT NULL,
  response TEXT NOT NULL, PRIMARY KEY(device_id, operation_id)
);
CREATE TABLE device_command_receipts (
  device_id TEXT NOT NULL, command_id TEXT NOT NULL, request BLOB NOT NULL,
  response TEXT NOT NULL, PRIMARY KEY(device_id, command_id)
);
CREATE TABLE device_draft_receipts (
  operation_id TEXT PRIMARY KEY, note_id TEXT NOT NULL, title TEXT NOT NULL,
  content TEXT NOT NULL, revision TEXT NOT NULL
);
CREATE TABLE mcp_callers(id TEXT PRIMARY KEY, display_name TEXT, machine_id TEXT,
  revoked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE mcp_bot_machines(machine_id TEXT PRIMARY KEY, active INTEGER NOT NULL);
CREATE TABLE calendar_task_executors(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, tools_json TEXT);
CREATE TABLE calendar_run_publishers(event_id TEXT NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(event_id,device_id));
CREATE TABLE calendar_published_runs(id TEXT PRIMARY KEY, event_id TEXT NOT NULL, device_id TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE device_calendar_receipts(device_id TEXT NOT NULL, mutation_id TEXT NOT NULL,
  input_json TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(device_id,mutation_id));
CREATE TABLE library_members(device_id TEXT NOT NULL, added_by TEXT NOT NULL, added_at INTEGER NOT NULL,
  payload TEXT NOT NULL, PRIMARY KEY(device_id, added_by));
CREATE TABLE library_member_revocations(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, payload TEXT NOT NULL);
CREATE TABLE library_member_anchors(device_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
CREATE TABLE library_member_pin_candidates(device_id TEXT PRIMARY KEY, payload TEXT NOT NULL, first_seen INTEGER NOT NULL);
CREATE TABLE member_tool_sessions(id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, workspace_id TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE member_session_watch(id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
  workspace_name TEXT, title TEXT, harness TEXT, state TEXT NOT NULL, run_id TEXT, questions TEXT, updated_at TEXT NOT NULL);
CREATE TABLE member_session_wakeups(id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
  kind TEXT NOT NULL, key TEXT NOT NULL, title TEXT, workspace_name TEXT, harness TEXT, question TEXT,
  attempt INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
CREATE TABLE member_session_wakeup_counts(caller_id TEXT PRIMARY KEY, count INTEGER NOT NULL);
CREATE TABLE bot_conversations(
  id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, bot_id TEXT NOT NULL, bot_name TEXT NOT NULL,
  runtime_conversation_id INTEGER NOT NULL, kind TEXT NOT NULL, parent_runtime_conversation_id INTEGER, forked_at_entry_id INTEGER,
  title TEXT, is_pinned INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
CREATE TABLE bot_conversation_entries(
  id TEXT PRIMARY KEY, bot_conversation_id TEXT NOT NULL, entry_id INTEGER NOT NULL,
  role TEXT NOT NULL, text TEXT NOT NULL, error TEXT, stopped INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
CREATE TABLE peer_sync_clock(singleton INTEGER PRIMARY KEY CHECK(singleton=1), device_id TEXT NOT NULL, tick INTEGER NOT NULL DEFAULT 0, vector TEXT NOT NULL DEFAULT '{}', applying INTEGER NOT NULL DEFAULT 0);
CREATE TABLE peer_sync_versions(cursor INTEGER PRIMARY KEY AUTOINCREMENT,table_name TEXT NOT NULL,record_key TEXT NOT NULL,
  origin TEXT NOT NULL,clock INTEGER NOT NULL,pending_peer TEXT,waits_for_update INTEGER NOT NULL DEFAULT 0,payload TEXT NOT NULL,
  UNIQUE(table_name,record_key,origin,clock));
CREATE TABLE peer_sync_conflicts(id TEXT PRIMARY KEY,table_name TEXT NOT NULL,record_key TEXT NOT NULL,origin TEXT NOT NULL,clock INTEGER NOT NULL,payload TEXT NOT NULL);
CREATE TABLE peer_sync_quarantine(id TEXT PRIMARY KEY,peer_id TEXT NOT NULL,table_name TEXT NOT NULL,record_key TEXT NOT NULL,origin TEXT NOT NULL,clock INTEGER NOT NULL,payload TEXT NOT NULL,error TEXT NOT NULL);
CREATE TABLE peer_sync_cursors(peer_id TEXT PRIMARY KEY,pulled INTEGER NOT NULL DEFAULT 0,pushed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE peer_sync_state(name TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE peer_sync_file_cursors(peer_id TEXT PRIMARY KEY,cursor TEXT NOT NULL);
CREATE TABLE peer_sync_seeded(table_name TEXT PRIMARY KEY);
CREATE TABLE peer_sync_reassert(table_name TEXT NOT NULL,record_key TEXT NOT NULL,PRIMARY KEY(table_name,record_key));
CREATE TABLE mac_routes(device_id TEXT PRIMARY KEY,library_id TEXT NOT NULL,endpoint TEXT NOT NULL,name TEXT NOT NULL);
CREATE TABLE remote_workspace_configurations(id TEXT PRIMARY KEY,owner_device_id TEXT NOT NULL,configuration TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE agent_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
CREATE TABLE conversation_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
CREATE TABLE calendar_item_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
CREATE TABLE execution_stream_changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL,
  entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL
);
CREATE INDEX dictation_history_date ON dictation_history(created_at DESC, id DESC);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_conversations_by_owner_conversation ON wm_pi_0123456789abcdef0123456789abcdef_conversations (owner_conversation_id, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_conversations_by_owner_task ON wm_pi_0123456789abcdef0123456789abcdef_conversations (owner_task_id, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_entries_by_conversation ON wm_pi_0123456789abcdef0123456789abcdef_entries (conversation_id, id DESC);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_entry_heads_by_conversation ON wm_pi_0123456789abcdef0123456789abcdef_entries (conversation_id, id DESC) WHERE head IS NOT NULL;
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_submissions_by_request ON wm_pi_0123456789abcdef0123456789abcdef_submissions (conversation_id, request_id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_submissions_by_conversation ON wm_pi_0123456789abcdef0123456789abcdef_submissions (conversation_id, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_submissions_by_status ON wm_pi_0123456789abcdef0123456789abcdef_submissions (status, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_documents_by_address
			ON wm_pi_0123456789abcdef0123456789abcdef_documents (kind, scope_kind, owner_id, family, key_value, created_at DESC, retired_at);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_documents_by_scope ON wm_pi_0123456789abcdef0123456789abcdef_documents (scope_kind, owner_id, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_documents_by_scope_kind ON wm_pi_0123456789abcdef0123456789abcdef_documents (scope_kind, owner_id, kind, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_document_revisions_by_kind ON wm_pi_0123456789abcdef0123456789abcdef_document_revisions (document_id, kind, seq DESC);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_tasks_by_status ON wm_pi_0123456789abcdef0123456789abcdef_tasks (status, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_tasks_by_conversation ON wm_pi_0123456789abcdef0123456789abcdef_tasks (conversation_id, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_tasks_by_kind ON wm_pi_0123456789abcdef0123456789abcdef_tasks (kind, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_tasks_by_abort_requested ON wm_pi_0123456789abcdef0123456789abcdef_tasks (abort_requested, id);
CREATE INDEX wm_pi_0123456789abcdef0123456789abcdef_tasks_by_background ON wm_pi_0123456789abcdef0123456789abcdef_tasks (background, id);
CREATE INDEX usage_events_timestamp
  ON usage_events(timestamp, event_id);
CREATE INDEX usage_events_source
  ON usage_events(source_id, timestamp);
CREATE INDEX conversations_recent
  ON conversations(is_archived, deleted_at, last_message_at DESC);
CREATE INDEX conversations_folder
  ON conversations(folder_id) WHERE folder_id IS NOT NULL;
CREATE INDEX messages_conversation_created
  ON messages(conversation_id, created_at, id);
CREATE INDEX messages_conversation_position
  ON messages(conversation_id, position) WHERE position IS NOT NULL;
CREATE INDEX message_attachments_message_created
  ON message_attachments(message_id, created_at, id);
CREATE INDEX message_attachments_content_hash
  ON message_attachments(content_hash, created_at, id) WHERE content_hash IS NOT NULL;
CREATE INDEX message_references_message_created
  ON message_references(message_id, created_at, id);
CREATE INDEX run_activities_run_created
  ON run_activities(run_id, created_at, id);
CREATE INDEX run_activities_conversation_created
  ON run_activities(conversation_id, created_at, id);
CREATE INDEX run_activities_conversation_position
  ON run_activities(conversation_id, position) WHERE position IS NOT NULL;
CREATE INDEX runs_conversation_user_message
  ON runs(conversation_id, user_message_id);
CREATE INDEX runs_conversation_assistant_message
  ON runs(conversation_id, assistant_message_id);
CREATE INDEX runs_conversation_status
  ON runs(conversation_id, status, created_at DESC, id DESC);
CREATE INDEX notes_recent
  ON notes(deleted_at, updated_at DESC);
CREATE INDEX notes_folder
  ON notes(folder_id) WHERE folder_id IS NOT NULL;
CREATE INDEX opencode_submissions_conversation
  ON opencode_submissions(conversation_id, status);
CREATE INDEX session_deliveries_source ON session_deliveries(source_id,created_at);
CREATE INDEX session_deliveries_target ON session_deliveries(target_id,status);
CREATE INDEX session_deliveries_queued ON session_deliveries(status) WHERE status='queued';
CREATE INDEX history_events_conversation ON history_events(conversation_id,sequence);
CREATE INDEX history_events_run ON history_events(run_id,sequence);
CREATE INDEX history_events_harness ON history_events(harness,sequence);
CREATE INDEX history_events_native_session ON history_events(harness,source_connection_id,agent_id,native_session_id)
  WHERE conversation_id IS NULL;
CREATE INDEX history_events_native_record ON history_events(harness,source_id,native_session_id,native_record_id,sequence);
CREATE INDEX history_events_cli ON history_events(sequence) WHERE kind LIKE 'cli.%';
CREATE INDEX note_asset_versions_note ON note_asset_versions(note_id,created_at DESC,id DESC,bytes);
CREATE INDEX note_asset_versions_created ON note_asset_versions(created_at DESC,id DESC,bytes);
CREATE INDEX session_relationships_coordinator ON session_relationships(coordinator_id);
CREATE INDEX session_timers_due ON session_timers(is_paused,next_fire_at);
CREATE INDEX session_timers_session ON session_timers(session_id);
CREATE INDEX coordination_access_requests_state ON coordination_access_requests(state,created_at);
CREATE UNIQUE INDEX session_deliveries_event ON session_deliveries(event_key) WHERE event_key IS NOT NULL;
CREATE INDEX tool_mutations_request_case ON tool_mutations(source_id,request_id COLLATE NOCASE);
CREATE INDEX session_deliveries_request_case ON session_deliveries(id COLLATE NOCASE);
CREATE INDEX session_creations_request_case ON session_creations(id COLLATE NOCASE);
CREATE INDEX coordination_access_requests_request_case ON coordination_access_requests(id COLLATE NOCASE);
CREATE INDEX calendar_schedules_due ON calendar_schedules(next_fire_at) WHERE next_fire_at IS NOT NULL;
CREATE INDEX calendar_runs_visible ON calendar_runs(scheduled_at,id) WHERE hidden_at IS NULL;
CREATE INDEX calendar_runs_pending ON calendar_runs(status) WHERE status='pending';
CREATE INDEX library_messages_dirty ON library_messages(message_id) WHERE dirty=1;
CREATE INDEX library_items_conversation ON library_items(conversation_id);
CREATE INDEX library_items_pending ON library_items(storage,retry_at);
CREATE INDEX activity_summaries_conversation_revision
  ON activity_summaries(conversation_id,revision);
CREATE INDEX activity_summaries_run ON activity_summaries(run_id);
CREATE INDEX member_tool_sessions_caller ON member_tool_sessions(caller_id, created_at);
CREATE INDEX member_session_wakeups_caller ON member_session_wakeups(caller_id, created_at);
CREATE INDEX bot_conversation_entries_conversation ON bot_conversation_entries(bot_conversation_id, entry_id);
CREATE INDEX bot_conversations_machine ON bot_conversations(machine_id, bot_id);
CREATE INDEX peer_sync_versions_pending ON peer_sync_versions(cursor) WHERE pending_peer IS NOT NULL;
CREATE INDEX peer_sync_versions_waiting ON peer_sync_versions(cursor) WHERE waits_for_update=1;
CREATE VIRTUAL TABLE "history_search" USING fts5(payload,content='')
/* history_search(payload) */;
CREATE TRIGGER folders_workspace_revision_insert
AFTER INSERT ON folders
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER folders_workspace_revision_update
AFTER UPDATE ON folders
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER folders_workspace_revision_delete
AFTER DELETE ON folders
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER folder_execution_roots_workspace_revision_insert
AFTER INSERT ON folder_execution_roots
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER folder_execution_roots_workspace_revision_update
AFTER UPDATE ON folder_execution_roots
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER folder_execution_roots_workspace_revision_delete
AFTER DELETE ON folder_execution_roots
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER session_execution_roots_workspace_revision_insert
AFTER INSERT ON session_execution_roots
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER session_execution_roots_workspace_revision_update
AFTER UPDATE ON session_execution_roots
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER session_execution_roots_workspace_revision_delete
AFTER DELETE ON session_execution_roots
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER retained_execution_history_workspace_revision_insert
AFTER INSERT ON retained_execution_history
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER retained_execution_history_workspace_revision_update
AFTER UPDATE ON retained_execution_history
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER retained_execution_history_workspace_revision_delete
AFTER DELETE ON retained_execution_history
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER surface_profiles_workspace_revision_insert
AFTER INSERT ON surface_profiles
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER surface_profiles_workspace_revision_update
AFTER UPDATE ON surface_profiles
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER surface_profiles_workspace_revision_delete
AFTER DELETE ON surface_profiles
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER agents_workspace_revision_insert
AFTER INSERT ON agents
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER agents_workspace_revision_update
AFTER UPDATE ON agents
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER agents_workspace_revision_delete
AFTER DELETE ON agents
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER conversations_workspace_revision_insert
AFTER INSERT ON conversations
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER conversations_workspace_revision_update
AFTER UPDATE ON conversations
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER conversations_workspace_revision_delete
AFTER DELETE ON conversations
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER messages_workspace_revision_insert
AFTER INSERT ON messages
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER messages_workspace_revision_update
AFTER UPDATE ON messages
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER messages_workspace_revision_delete
AFTER DELETE ON messages
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER notes_workspace_revision_insert
AFTER INSERT ON notes
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER notes_workspace_revision_update
AFTER UPDATE ON notes
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER notes_workspace_revision_delete
AFTER DELETE ON notes
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER runs_workspace_revision_insert
AFTER INSERT ON runs
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER runs_workspace_revision_update
AFTER UPDATE ON runs
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER runs_workspace_revision_delete
AFTER DELETE ON runs
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER run_program_statuses_workspace_revision_insert
AFTER INSERT ON run_program_statuses
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER run_program_statuses_workspace_revision_update
AFTER UPDATE ON run_program_statuses
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER run_program_statuses_workspace_revision_delete
AFTER DELETE ON run_program_statuses
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER calendar_items_workspace_revision_insert
AFTER INSERT ON calendar_items
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER calendar_items_workspace_revision_update
AFTER UPDATE ON calendar_items
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER calendar_items_workspace_revision_delete
AFTER DELETE ON calendar_items
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER harness_sessions_workspace_revision_insert
AFTER INSERT ON harness_sessions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER harness_sessions_workspace_revision_update
AFTER UPDATE ON harness_sessions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER harness_sessions_workspace_revision_delete
AFTER DELETE ON harness_sessions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER opencode_sessions_workspace_revision_insert
AFTER INSERT ON opencode_sessions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER opencode_sessions_workspace_revision_update
AFTER UPDATE ON opencode_sessions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER opencode_sessions_workspace_revision_delete
AFTER DELETE ON opencode_sessions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER opencode_submissions_workspace_revision_insert
AFTER INSERT ON opencode_submissions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER opencode_submissions_workspace_revision_update
AFTER UPDATE ON opencode_submissions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER opencode_submissions_workspace_revision_delete
AFTER DELETE ON opencode_submissions
BEGIN
  UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
END;
CREATE TRIGGER folders_device_sync_insert
AFTER INSERT ON folders
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('folder', NEW.id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'folder' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER folders_device_sync_update
AFTER UPDATE ON folders
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('folder', NEW.id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'folder' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER folders_device_sync_delete
AFTER DELETE ON folders
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('folder', OLD.id, 1, 1)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'folder' AND resource_id = OLD.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER notes_device_sync_insert
AFTER INSERT ON notes
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('note', NEW.id, 1, CASE WHEN NEW.deleted_at IS NULL THEN 0 ELSE 1 END)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'note' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER notes_device_sync_update
AFTER UPDATE ON notes
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('note', NEW.id, 1, CASE WHEN NEW.deleted_at IS NULL THEN 0 ELSE 1 END)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + CASE WHEN NEW.title IS NOT OLD.title OR NEW.content IS NOT OLD.content OR NEW.folder_id IS NOT OLD.folder_id OR NEW.deleted_at IS NOT OLD.deleted_at OR NEW.updated_at IS NOT OLD.updated_at THEN 1 ELSE 0 END, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'note' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER notes_device_sync_delete
AFTER DELETE ON notes
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('note', OLD.id, 1, 1)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'note' AND resource_id = OLD.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER conversations_device_sync_insert
AFTER INSERT ON conversations
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('conversation', NEW.id, 1, CASE WHEN NEW.deleted_at IS NULL AND NEW.is_archived = 0 THEN 0 ELSE 1 END)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'conversation' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER conversations_device_sync_update
AFTER UPDATE ON conversations
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('conversation', NEW.id, 1, CASE WHEN NEW.deleted_at IS NULL AND NEW.is_archived = 0 THEN 0 ELSE 1 END)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'conversation' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER conversations_device_sync_delete
AFTER DELETE ON conversations
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('conversation', OLD.id, 1, 1)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'conversation' AND resource_id = OLD.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER messages_device_sync_insert
AFTER INSERT ON messages
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER messages_device_sync_update
AFTER UPDATE ON messages
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER messages_device_sync_delete
AFTER DELETE ON messages
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', OLD.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = OLD.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER runs_device_sync_insert
AFTER INSERT ON runs
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER runs_device_sync_update
AFTER UPDATE ON runs
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER runs_device_sync_delete
AFTER DELETE ON runs
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', OLD.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = OLD.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER run_activities_device_sync_insert
AFTER INSERT ON run_activities
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER run_activities_device_sync_update
AFTER UPDATE ON run_activities
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER run_activities_device_sync_delete
AFTER DELETE ON run_activities
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', OLD.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = OLD.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER message_attachments_device_sync_insert
AFTER INSERT ON message_attachments
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER message_attachments_device_sync_update
AFTER UPDATE ON message_attachments
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER message_attachments_device_sync_delete
AFTER DELETE ON message_attachments
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', OLD.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = OLD.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER message_references_device_sync_insert
AFTER INSERT ON message_references
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER message_references_device_sync_update
AFTER UPDATE ON message_references
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', NEW.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = NEW.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER message_references_device_sync_delete
AFTER DELETE ON message_references
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('transcript', OLD.conversation_id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'transcript' AND resource_id = OLD.conversation_id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER agents_device_sync_insert
AFTER INSERT ON agents
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('providers', NEW.id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'providers' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER agents_device_sync_update
AFTER UPDATE ON agents
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('providers', NEW.id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'providers' AND resource_id = NEW.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER agents_device_sync_delete
AFTER DELETE ON agents
BEGIN
  INSERT INTO device_sync_revisions(kind, resource_id, revision, deleted)
  VALUES ('providers', OLD.id, 1, 0)
  ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + 1, deleted = excluded.deleted;
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  SELECT kind, resource_id, revision, deleted FROM device_sync_revisions
  WHERE kind = 'providers' AND resource_id = OLD.id;
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER folders_detach_contents_delete BEFORE DELETE ON folders
BEGIN
  UPDATE notes SET folder_id = NULL WHERE folder_id = OLD.id;
  UPDATE conversations SET folder_id = NULL WHERE folder_id = OLD.id
    AND NOT EXISTS(SELECT 1 FROM session_execution_roots WHERE conversation_id = conversations.id);
END;
CREATE TRIGGER history_events_search_insert AFTER INSERT ON history_events
  WHEN new.kind NOT LIKE 'cli.%' BEGIN
  INSERT INTO history_search(rowid,payload)
    VALUES(new.sequence,new.payload||' '||coalesce(new.text_content,'')||' '||coalesce(new.projection_json,''));
END;
CREATE TRIGGER history_events_search_delete AFTER DELETE ON history_events
  WHEN old.kind NOT LIKE 'cli.%' BEGIN
  INSERT INTO history_search(history_search,rowid,payload)
    VALUES('delete',old.sequence,old.payload||' '||coalesce(old.text_content,'')||' '||coalesce(old.projection_json,''));
END;
CREATE TRIGGER conversations_session_tools_insert AFTER INSERT ON conversations BEGIN
  INSERT OR IGNORE INTO session_tools(session_id,enabled_json,defaults_applied)
    VALUES(new.id,(SELECT json_extract(value,'$.enabledByDefault') FROM tool_settings WHERE id=1),0);
  INSERT OR IGNORE INTO session_executor_profiles(session_id,profiles_json)
    VALUES(new.id,COALESCE((SELECT json_extract(value,'$.executor.defaultProfiles') FROM tool_settings WHERE id=1),'[]'));
END;
CREATE TRIGGER conversations_mcp_caller_insert AFTER INSERT ON conversations BEGIN
  INSERT OR IGNORE INTO mcp_callers(id) VALUES(new.id);
END;
CREATE TRIGGER session_relationships_created_by_bot_insert BEFORE INSERT ON session_relationships
WHEN NEW.created_by LIKE 'woven:bot:%'
BEGIN INSERT INTO mcp_callers(id) SELECT NEW.created_by WHERE NOT EXISTS (SELECT 1 FROM mcp_callers WHERE id=NEW.created_by); END;
CREATE TRIGGER session_relationships_created_by_bot_update BEFORE UPDATE OF created_by ON session_relationships
WHEN NEW.created_by LIKE 'woven:bot:%'
BEGIN INSERT INTO mcp_callers(id) SELECT NEW.created_by WHERE NOT EXISTS (SELECT 1 FROM mcp_callers WHERE id=NEW.created_by); END;
CREATE TRIGGER session_relationships_coordinator_id_bot_insert BEFORE INSERT ON session_relationships
WHEN NEW.coordinator_id LIKE 'woven:bot:%'
BEGIN INSERT INTO mcp_callers(id) SELECT NEW.coordinator_id WHERE NOT EXISTS (SELECT 1 FROM mcp_callers WHERE id=NEW.coordinator_id); END;
CREATE TRIGGER session_relationships_coordinator_id_bot_update BEFORE UPDATE OF coordinator_id ON session_relationships
WHEN NEW.coordinator_id LIKE 'woven:bot:%'
BEGIN INSERT INTO mcp_callers(id) SELECT NEW.coordinator_id WHERE NOT EXISTS (SELECT 1 FROM mcp_callers WHERE id=NEW.coordinator_id); END;
CREATE TRIGGER session_grants_source_id_bot_insert BEFORE INSERT ON session_grants
WHEN NEW.source_id LIKE 'woven:bot:%'
BEGIN INSERT INTO mcp_callers(id) SELECT NEW.source_id WHERE NOT EXISTS (SELECT 1 FROM mcp_callers WHERE id=NEW.source_id); END;
CREATE TRIGGER session_grants_source_id_bot_update BEFORE UPDATE OF source_id ON session_grants
WHEN NEW.source_id LIKE 'woven:bot:%'
BEGIN INSERT INTO mcp_callers(id) SELECT NEW.source_id WHERE NOT EXISTS (SELECT 1 FROM mcp_callers WHERE id=NEW.source_id); END;
CREATE TRIGGER session_goals_cleanup_delete BEFORE DELETE ON session_goals BEGIN
  DELETE FROM goal_runs WHERE goal_id=json_extract(old.value,'$.id');
  DELETE FROM goal_usage WHERE goal_id=json_extract(old.value,'$.id');
END;
CREATE TRIGGER calendar_runs_workspace_revision_insert
AFTER INSERT ON calendar_runs BEGIN
  UPDATE workspace_revision SET revision=revision+1 WHERE singleton=1;
END;
CREATE TRIGGER calendar_runs_workspace_revision_update
AFTER UPDATE ON calendar_runs BEGIN
  UPDATE workspace_revision SET revision=revision+1 WHERE singleton=1;
END;
CREATE TRIGGER calendar_runs_workspace_revision_delete
AFTER DELETE ON calendar_runs BEGIN
  UPDATE workspace_revision SET revision=revision+1 WHERE singleton=1;
END;
CREATE TRIGGER messages_library_delete AFTER DELETE ON messages
BEGIN DELETE FROM library_messages WHERE message_id=OLD.id; END;
CREATE TRIGGER conversations_library_delete AFTER DELETE ON conversations
BEGIN
  DELETE FROM library_messages WHERE message_id IN (SELECT message_id FROM library_items WHERE conversation_id=OLD.id)
    OR message_id IN (SELECT id FROM messages WHERE conversation_id=OLD.id);
  DELETE FROM library_locations WHERE conversation_id=OLD.id;
END;
CREATE TRIGGER conversations_library_trash_update AFTER UPDATE OF deleted_at ON conversations
WHEN NEW.deleted_at IS NOT OLD.deleted_at
BEGIN
  UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision';
END;
CREATE TRIGGER library_locations_revision_insert AFTER INSERT ON library_locations
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER library_locations_revision_update AFTER UPDATE ON library_locations
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER library_locations_revision_delete AFTER DELETE ON library_locations
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER conversations_library_metadata_update AFTER UPDATE OF title,agent_id,agent_codename ON conversations
WHEN EXISTS(SELECT 1 FROM library_items WHERE conversation_id=NEW.id)
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER agents_library_metadata_update AFTER UPDATE OF display_name ON agents
WHEN NEW.display_name != OLD.display_name
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER harness_sessions_library_revision_insert AFTER INSERT ON harness_sessions
WHEN EXISTS(SELECT 1 FROM library_items WHERE conversation_id=NEW.conversation_id)
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER session_deliveries_library_revision_insert AFTER INSERT ON session_deliveries
WHEN EXISTS(SELECT 1 FROM library_items WHERE message_id=NEW.message_id)
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER harness_sessions_library_revision_update AFTER UPDATE OF runtime_kind,remote_workspace_id ON harness_sessions
WHEN EXISTS(SELECT 1 FROM library_items WHERE conversation_id=NEW.conversation_id)
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER session_deliveries_library_revision_update AFTER UPDATE OF message_id ON session_deliveries
WHEN EXISTS(SELECT 1 FROM library_items WHERE message_id IN (OLD.message_id,NEW.message_id))
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER harness_sessions_library_revision_delete AFTER DELETE ON harness_sessions
WHEN EXISTS(SELECT 1 FROM library_items WHERE conversation_id=OLD.conversation_id)
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER session_deliveries_library_revision_delete AFTER DELETE ON session_deliveries
WHEN EXISTS(SELECT 1 FROM library_items WHERE message_id=OLD.message_id)
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER library_items_revision_insert AFTER INSERT ON library_items
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER library_items_revision_update AFTER UPDATE ON library_items
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER library_items_revision_delete AFTER DELETE ON library_items
BEGIN UPDATE library_settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'; END;
CREATE TRIGGER messages_revision_insert
AFTER INSERT ON messages BEGIN
  UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
  INSERT INTO message_revisions(id,revision)
    VALUES(new.id,(SELECT revision FROM activity_revision WHERE singleton=1))
    ON CONFLICT(id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER messages_revision_update
AFTER UPDATE ON messages BEGIN
  UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
  INSERT INTO message_revisions(id,revision)
    VALUES(new.id,(SELECT revision FROM activity_revision WHERE singleton=1))
    ON CONFLICT(id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER messages_revision_delete
AFTER DELETE ON messages BEGIN
  UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
  INSERT INTO message_revisions(id,revision)
    VALUES(old.id,(SELECT revision FROM activity_revision WHERE singleton=1))
    ON CONFLICT(id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER run_activities_summary_insert AFTER INSERT ON run_activities  BEGIN
  UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
  INSERT INTO activity_summaries(id,conversation_id,run_id,revision,deleted)
    VALUES(new.id,new.conversation_id,new.run_id,
      (SELECT revision FROM activity_revision WHERE singleton=1),0)
  ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,run_id=excluded.run_id,
    revision=excluded.revision,deleted=excluded.deleted,summary=NULL;
END;
CREATE TRIGGER run_activities_summary_update AFTER UPDATE ON run_activities WHEN old.content IS NOT new.content OR old.event_type IS NOT new.event_type OR old.run_id IS NOT new.run_id OR old.conversation_id IS NOT new.conversation_id OR old.created_at IS NOT new.created_at BEGIN
  UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
  INSERT INTO activity_summaries(id,conversation_id,run_id,revision,deleted)
    VALUES(new.id,new.conversation_id,new.run_id,
      (SELECT revision FROM activity_revision WHERE singleton=1),0)
  ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,run_id=excluded.run_id,
    revision=excluded.revision,deleted=excluded.deleted,summary=NULL;
END;
CREATE TRIGGER run_activities_summary_delete AFTER DELETE ON run_activities BEGIN
  UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
  UPDATE activity_summaries SET deleted=1,summary=NULL,
    revision=(SELECT revision FROM activity_revision WHERE singleton=1)
    WHERE id=old.id;
END;
CREATE TRIGGER agents_owner_insert AFTER INSERT ON agents
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 BEGIN
  INSERT OR IGNORE INTO agent_owners VALUES(NEW.id,(SELECT device_id FROM peer_sync_clock WHERE singleton=1));
END;
CREATE TRIGGER calendar_items_owner_insert AFTER INSERT ON calendar_items
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 BEGIN
  INSERT OR IGNORE INTO calendar_item_owners VALUES(NEW.id,(SELECT device_id FROM peer_sync_clock WHERE singleton=1));
END;
CREATE TRIGGER opencode_sessions_history_insert AFTER INSERT ON opencode_sessions  WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  UPDATE history_events SET conversation_id=new.conversation_id
  WHERE conversation_id IS NULL AND harness='opencode'
    AND source_connection_id=new.connection_id AND native_session_id=new.session_id;
END;
CREATE TRIGGER messages_history_insert AFTER INSERT ON messages 
 WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload)
  VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=new.conversation_id),'unknown'),
    'message.insert',json_object('id',new.id,'role',new.role,'content',new.content,'contentMode','snapshot','status',new.status));
END;
CREATE TRIGGER runs_history_insert AFTER INSERT ON runs
 WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,agent_id,harness,kind,payload)
  VALUES(lower(hex(randomblob(16))),new.conversation_id,new.id,new.agent_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=new.conversation_id),'unknown'),
    'run.insert',json_object('id',new.id,'status',new.status,'error',new.error,'nativeSession',new.native_session_id));
END;
CREATE TRIGGER messages_history_update AFTER UPDATE ON messages  WHEN (SELECT applying FROM peer_sync_clock)=0 AND (new.status != 'streaming') BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload)
  VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=new.conversation_id),'unknown'),
    'message.update',json_object('id',new.id,'role',new.role,'content',new.content,'contentMode','snapshot','status',new.status));
END;
CREATE TRIGGER runs_history_update AFTER UPDATE ON runs
 WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,agent_id,harness,kind,payload)
  VALUES(lower(hex(randomblob(16))),new.conversation_id,new.id,new.agent_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=new.conversation_id),'unknown'),
    'run.update',json_object('id',new.id,'status',new.status,'error',new.error,'nativeSession',new.native_session_id));
END;
CREATE TRIGGER messages_library_insert AFTER INSERT ON messages
 WHEN (SELECT applying FROM peer_sync_clock)=0 AND (NEW.role IN ('user','assistant') AND julianday(NEW.created_at) >=
  (SELECT julianday(value) FROM library_settings WHERE key='activated_at')) BEGIN INSERT OR IGNORE INTO library_messages(message_id) VALUES(NEW.id); END;
CREATE TRIGGER messages_library_update AFTER UPDATE OF content,status ON messages
 WHEN (SELECT applying FROM peer_sync_clock)=0 AND (NEW.content != OLD.content OR NEW.status != OLD.status) BEGIN UPDATE library_messages SET dirty=1 WHERE message_id=NEW.id; END;
CREATE TRIGGER message_attachments_library_insert AFTER INSERT ON message_attachments
 WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN UPDATE library_messages SET dirty=1 WHERE message_id=NEW.message_id; END;
CREATE TRIGGER message_attachments_history_insert AFTER INSERT ON message_attachments   WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content)
  VALUES(lower(hex(randomblob(16))),coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),(SELECT run_id FROM messages WHERE id=new.message_id),
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id))),'unknown'),
    'attachment.snapshot',woven_history_redact(json_object('content_hash',new."content_hash",'conversation_id',new."conversation_id",'created_at',new."created_at",'file_name',new."file_name",'id',new."id",'kind',new."kind",'message_id',new."message_id",'mime_type',new."mime_type",'size_bytes',new."size_bytes")),'woven:attachment',coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),new.id,'snapshot',woven_history_redact(new.file_name));
END;
CREATE TRIGGER message_attachments_history_update AFTER UPDATE ON message_attachments  WHEN (SELECT applying FROM peer_sync_clock)=0 AND (json_object('content_hash',old."content_hash",'conversation_id',old."conversation_id",'created_at',old."created_at",'file_name',old."file_name",'id',old."id",'kind',old."kind",'message_id',old."message_id",'mime_type',old."mime_type",'size_bytes',old."size_bytes") IS NOT json_object('content_hash',new."content_hash",'conversation_id',new."conversation_id",'created_at',new."created_at",'file_name',new."file_name",'id',new."id",'kind',new."kind",'message_id',new."message_id",'mime_type',new."mime_type",'size_bytes',new."size_bytes")) BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content)
  VALUES(lower(hex(randomblob(16))),coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),(SELECT run_id FROM messages WHERE id=new.message_id),
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id))),'unknown'),
    'attachment.snapshot',woven_history_redact(json_object('content_hash',new."content_hash",'conversation_id',new."conversation_id",'created_at',new."created_at",'file_name',new."file_name",'id',new."id",'kind',new."kind",'message_id',new."message_id",'mime_type',new."mime_type",'size_bytes',new."size_bytes")),'woven:attachment',coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),new.id,'snapshot',woven_history_redact(new.file_name));
END;
CREATE TRIGGER message_references_history_insert AFTER INSERT ON message_references   WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content)
  VALUES(lower(hex(randomblob(16))),coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),(SELECT run_id FROM messages WHERE id=new.message_id),
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id))),'unknown'),
    'reference.snapshot',woven_history_redact(json_object('agent_codename_snapshot',new."agent_codename_snapshot",'content_snapshot',new."content_snapshot",'conversation_id',new."conversation_id",'created_at',new."created_at",'folder_id_snapshot',new."folder_id_snapshot",'folder_title_snapshot',new."folder_title_snapshot",'id',new."id",'message_id',new."message_id",'resource_id',new."resource_id",'resource_type',new."resource_type",'revision_snapshot',new."revision_snapshot",'source',new."source",'title_snapshot',new."title_snapshot")),'woven:reference',coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),new.id,'snapshot',woven_history_redact(new.title_snapshot));
END;
CREATE TRIGGER message_references_history_update AFTER UPDATE ON message_references  WHEN (SELECT applying FROM peer_sync_clock)=0 AND (json_object('agent_codename_snapshot',old."agent_codename_snapshot",'content_snapshot',old."content_snapshot",'conversation_id',old."conversation_id",'created_at',old."created_at",'folder_id_snapshot',old."folder_id_snapshot",'folder_title_snapshot',old."folder_title_snapshot",'id',old."id",'message_id',old."message_id",'resource_id',old."resource_id",'resource_type',old."resource_type",'revision_snapshot',old."revision_snapshot",'source',old."source",'title_snapshot',old."title_snapshot") IS NOT json_object('agent_codename_snapshot',new."agent_codename_snapshot",'content_snapshot',new."content_snapshot",'conversation_id',new."conversation_id",'created_at',new."created_at",'folder_id_snapshot',new."folder_id_snapshot",'folder_title_snapshot',new."folder_title_snapshot",'id',new."id",'message_id',new."message_id",'resource_id',new."resource_id",'resource_type',new."resource_type",'revision_snapshot',new."revision_snapshot",'source',new."source",'title_snapshot',new."title_snapshot")) BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content)
  VALUES(lower(hex(randomblob(16))),coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),(SELECT run_id FROM messages WHERE id=new.message_id),
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id))),'unknown'),
    'reference.snapshot',woven_history_redact(json_object('agent_codename_snapshot',new."agent_codename_snapshot",'content_snapshot',new."content_snapshot",'conversation_id',new."conversation_id",'created_at',new."created_at",'folder_id_snapshot',new."folder_id_snapshot",'folder_title_snapshot',new."folder_title_snapshot",'id',new."id",'message_id',new."message_id",'resource_id',new."resource_id",'resource_type',new."resource_type",'revision_snapshot',new."revision_snapshot",'source',new."source",'title_snapshot',new."title_snapshot")),'woven:reference',coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM messages WHERE id=new.message_id)),new.id,'snapshot',woven_history_redact(new.title_snapshot));
END;
CREATE TRIGGER run_activities_history_insert AFTER INSERT ON run_activities   WHEN (SELECT applying FROM peer_sync_clock)=0 BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content,projection_json)
  VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=new.conversation_id),'unknown'),
    CASE WHEN 0 THEN 'activity.delta' ELSE 'activity.snapshot' END,
    woven_history_redact(CASE WHEN 0 THEN json_set(new.content,'$.content',NULL) ELSE new.content END),'woven:activity',new.conversation_id,new.id,
    CASE WHEN 0 THEN 'delta' ELSE 'snapshot' END,
    CASE WHEN 0 THEN woven_history_redact(NULL) WHEN json_valid(new.content) THEN woven_history_redact(json_extract(new.content,'$.content')) ELSE woven_history_redact(new.content) END,
    woven_history_redact(CASE WHEN 0 THEN json_set(new.content,'$.content',NULL) ELSE new.content END));
END;
CREATE TRIGGER run_activities_history_update AFTER UPDATE ON run_activities  WHEN (SELECT applying FROM peer_sync_clock)=0 AND (old.content IS NOT new.content OR old.event_type IS NOT new.event_type) BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content,projection_json)
  VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=new.conversation_id),'unknown'),
    CASE WHEN CASE WHEN json_valid(new.content) AND json_valid(old.content) THEN
  json_extract(new.content,'$.contentIsDelta')=1
    AND json_type(new.content,'$.content')='text' AND json_type(old.content,'$.content')='text'
    AND woven_text_substr(json_extract(new.content,'$.content'),1,woven_text_length(json_extract(old.content,'$.content')))=json_extract(old.content,'$.content')
  ELSE 0 END THEN 'activity.delta' ELSE 'activity.snapshot' END,
    woven_history_redact(CASE WHEN CASE WHEN json_valid(new.content) AND json_valid(old.content) THEN
  json_extract(new.content,'$.contentIsDelta')=1
    AND json_type(new.content,'$.content')='text' AND json_type(old.content,'$.content')='text'
    AND woven_text_substr(json_extract(new.content,'$.content'),1,woven_text_length(json_extract(old.content,'$.content')))=json_extract(old.content,'$.content')
  ELSE 0 END THEN json_set(new.content,'$.content',woven_text_substr(json_extract(new.content,'$.content'),woven_text_length(json_extract(old.content,'$.content'))+1)) ELSE new.content END),'woven:activity',new.conversation_id,new.id,
    CASE WHEN CASE WHEN json_valid(new.content) AND json_valid(old.content) THEN
  json_extract(new.content,'$.contentIsDelta')=1
    AND json_type(new.content,'$.content')='text' AND json_type(old.content,'$.content')='text'
    AND woven_text_substr(json_extract(new.content,'$.content'),1,woven_text_length(json_extract(old.content,'$.content')))=json_extract(old.content,'$.content')
  ELSE 0 END THEN 'delta' ELSE 'snapshot' END,
    CASE WHEN CASE WHEN json_valid(new.content) AND json_valid(old.content) THEN
  json_extract(new.content,'$.contentIsDelta')=1
    AND json_type(new.content,'$.content')='text' AND json_type(old.content,'$.content')='text'
    AND woven_text_substr(json_extract(new.content,'$.content'),1,woven_text_length(json_extract(old.content,'$.content')))=json_extract(old.content,'$.content')
  ELSE 0 END THEN woven_history_redact(woven_text_substr(json_extract(new.content,'$.content'),woven_text_length(json_extract(old.content,'$.content'))+1)) WHEN json_valid(new.content) THEN woven_history_redact(json_extract(new.content,'$.content')) ELSE woven_history_redact(new.content) END,
    woven_history_redact(CASE WHEN CASE WHEN json_valid(new.content) AND json_valid(old.content) THEN
  json_extract(new.content,'$.contentIsDelta')=1
    AND json_type(new.content,'$.content')='text' AND json_type(old.content,'$.content')='text'
    AND woven_text_substr(json_extract(new.content,'$.content'),1,woven_text_length(json_extract(old.content,'$.content')))=json_extract(old.content,'$.content')
  ELSE 0 END THEN json_set(new.content,'$.content',woven_text_substr(json_extract(new.content,'$.content'),woven_text_length(json_extract(old.content,'$.content'))+1)) ELSE new.content END));
END;
CREATE TRIGGER runs_final_activity_history_update AFTER UPDATE ON runs
   WHEN (SELECT applying FROM peer_sync_clock)=0 AND (new.status IN ('completed','failed','cancelled','interrupted') AND old.status IS NOT new.status) BEGIN
  INSERT INTO history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content,projection_json)
  SELECT lower(hex(randomblob(16))),e.conversation_id,e.run_id,
    coalesce((SELECT runtime_kind FROM harness_sessions WHERE conversation_id=e.conversation_id),'unknown'),
    'activity.final',woven_history_redact(e.content),'woven:activity',e.conversation_id,e.id,'snapshot',
    woven_history_redact(json_extract(e.content,'$.content')),woven_history_redact(e.content)
  FROM run_activities e WHERE e.run_id=new.id
    AND CASE WHEN json_valid(e.content) THEN json_extract(e.content,'$.contentIsDelta')=1 ELSE 0 END;
END;
CREATE TRIGGER surface_profiles_peer_sync_insert AFTER INSERT ON "surface_profiles"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'surface_profiles',i.peer_key,c.device_id,c.tick,json_object('table','surface_profiles','key',i.peer_key,'row',json_object('agent_order_json',json_object('type',typeof(NEW."agent_order_json"),'value',CASE typeof(NEW."agent_order_json") WHEN 'blob' THEN hex(NEW."agent_order_json") WHEN 'real' THEN printf('%!.17g',NEW."agent_order_json") ELSE CAST(NEW."agent_order_json" AS TEXT) || '' END),'chat_width_percent',json_object('type',typeof(NEW."chat_width_percent"),'value',CASE typeof(NEW."chat_width_percent") WHEN 'blob' THEN hex(NEW."chat_width_percent") WHEN 'real' THEN printf('%!.17g',NEW."chat_width_percent") ELSE CAST(NEW."chat_width_percent" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'left_rail_visible',json_object('type',typeof(NEW."left_rail_visible"),'value',CASE typeof(NEW."left_rail_visible") WHEN 'blob' THEN hex(NEW."left_rail_visible") WHEN 'real' THEN printf('%!.17g',NEW."left_rail_visible") ELSE CAST(NEW."left_rail_visible" AS TEXT) || '' END),'note_on_left',json_object('type',typeof(NEW."note_on_left"),'value',CASE typeof(NEW."note_on_left") WHEN 'blob' THEN hex(NEW."note_on_left") WHEN 'real' THEN printf('%!.17g',NEW."note_on_left") ELSE CAST(NEW."note_on_left" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'right_rail_visible',json_object('type',typeof(NEW."right_rail_visible"),'value',CASE typeof(NEW."right_rail_visible") WHEN 'blob' THEN hex(NEW."right_rail_visible") WHEN 'real' THEN printf('%!.17g',NEW."right_rail_visible") ELSE CAST(NEW."right_rail_visible" AS TEXT) || '' END),'sidebar_style',json_object('type',typeof(NEW."sidebar_style"),'value',CASE typeof(NEW."sidebar_style") WHEN 'blob' THEN hex(NEW."sidebar_style") WHEN 'real' THEN printf('%!.17g',NEW."sidebar_style") ELSE CAST(NEW."sidebar_style" AS TEXT) || '' END),'single_rail_visible',json_object('type',typeof(NEW."single_rail_visible"),'value',CASE typeof(NEW."single_rail_visible") WHEN 'blob' THEN hex(NEW."single_rail_visible") WHEN 'real' THEN printf('%!.17g',NEW."single_rail_visible") ELSE CAST(NEW."single_rail_visible" AS TEXT) || '' END),'single_sidebar_side',json_object('type',typeof(NEW."single_sidebar_side"),'value',CASE typeof(NEW."single_sidebar_side") WHEN 'blob' THEN hex(NEW."single_sidebar_side") WHEN 'real' THEN printf('%!.17g',NEW."single_sidebar_side") ELSE CAST(NEW."single_sidebar_side" AS TEXT) || '' END),'theme',json_object('type',typeof(NEW."theme"),'value',CASE typeof(NEW."theme") WHEN 'blob' THEN hex(NEW."theme") WHEN 'real' THEN printf('%!.17g',NEW."theme") ELSE CAST(NEW."theme" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END),'workspace_mode',json_object('type',typeof(NEW."workspace_mode"),'value',CASE typeof(NEW."workspace_mode") WHEN 'blob' THEN hex(NEW."workspace_mode") WHEN 'real' THEN printf('%!.17g',NEW."workspace_mode") ELSE CAST(NEW."workspace_mode" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='surface_profiles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='surface_profiles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='surface_profiles' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='surface_profiles' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER surface_profiles_peer_sync_update AFTER UPDATE ON "surface_profiles"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."agent_order_json" IS NOT NEW."agent_order_json" OR OLD."chat_width_percent" IS NOT NEW."chat_width_percent" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."device_id" IS NOT NEW."device_id" OR OLD."id" IS NOT NEW."id" OR OLD."left_rail_visible" IS NOT NEW."left_rail_visible" OR OLD."note_on_left" IS NOT NEW."note_on_left" OR OLD."revision" IS NOT NEW."revision" OR OLD."right_rail_visible" IS NOT NEW."right_rail_visible" OR OLD."sidebar_style" IS NOT NEW."sidebar_style" OR OLD."single_rail_visible" IS NOT NEW."single_rail_visible" OR OLD."single_sidebar_side" IS NOT NEW."single_sidebar_side" OR OLD."theme" IS NOT NEW."theme" OR OLD."updated_at" IS NOT NEW."updated_at" OR OLD."workspace_mode" IS NOT NEW."workspace_mode")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'surface_profiles',i.peer_key,c.device_id,c.tick,json_object('table','surface_profiles','key',i.peer_key,'row',json_object('agent_order_json',json_object('type',typeof(NEW."agent_order_json"),'value',CASE typeof(NEW."agent_order_json") WHEN 'blob' THEN hex(NEW."agent_order_json") WHEN 'real' THEN printf('%!.17g',NEW."agent_order_json") ELSE CAST(NEW."agent_order_json" AS TEXT) || '' END),'chat_width_percent',json_object('type',typeof(NEW."chat_width_percent"),'value',CASE typeof(NEW."chat_width_percent") WHEN 'blob' THEN hex(NEW."chat_width_percent") WHEN 'real' THEN printf('%!.17g',NEW."chat_width_percent") ELSE CAST(NEW."chat_width_percent" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'left_rail_visible',json_object('type',typeof(NEW."left_rail_visible"),'value',CASE typeof(NEW."left_rail_visible") WHEN 'blob' THEN hex(NEW."left_rail_visible") WHEN 'real' THEN printf('%!.17g',NEW."left_rail_visible") ELSE CAST(NEW."left_rail_visible" AS TEXT) || '' END),'note_on_left',json_object('type',typeof(NEW."note_on_left"),'value',CASE typeof(NEW."note_on_left") WHEN 'blob' THEN hex(NEW."note_on_left") WHEN 'real' THEN printf('%!.17g',NEW."note_on_left") ELSE CAST(NEW."note_on_left" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'right_rail_visible',json_object('type',typeof(NEW."right_rail_visible"),'value',CASE typeof(NEW."right_rail_visible") WHEN 'blob' THEN hex(NEW."right_rail_visible") WHEN 'real' THEN printf('%!.17g',NEW."right_rail_visible") ELSE CAST(NEW."right_rail_visible" AS TEXT) || '' END),'sidebar_style',json_object('type',typeof(NEW."sidebar_style"),'value',CASE typeof(NEW."sidebar_style") WHEN 'blob' THEN hex(NEW."sidebar_style") WHEN 'real' THEN printf('%!.17g',NEW."sidebar_style") ELSE CAST(NEW."sidebar_style" AS TEXT) || '' END),'single_rail_visible',json_object('type',typeof(NEW."single_rail_visible"),'value',CASE typeof(NEW."single_rail_visible") WHEN 'blob' THEN hex(NEW."single_rail_visible") WHEN 'real' THEN printf('%!.17g',NEW."single_rail_visible") ELSE CAST(NEW."single_rail_visible" AS TEXT) || '' END),'single_sidebar_side',json_object('type',typeof(NEW."single_sidebar_side"),'value',CASE typeof(NEW."single_sidebar_side") WHEN 'blob' THEN hex(NEW."single_sidebar_side") WHEN 'real' THEN printf('%!.17g',NEW."single_sidebar_side") ELSE CAST(NEW."single_sidebar_side" AS TEXT) || '' END),'theme',json_object('type',typeof(NEW."theme"),'value',CASE typeof(NEW."theme") WHEN 'blob' THEN hex(NEW."theme") WHEN 'real' THEN printf('%!.17g',NEW."theme") ELSE CAST(NEW."theme" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END),'workspace_mode',json_object('type',typeof(NEW."workspace_mode"),'value',CASE typeof(NEW."workspace_mode") WHEN 'blob' THEN hex(NEW."workspace_mode") WHEN 'real' THEN printf('%!.17g',NEW."workspace_mode") ELSE CAST(NEW."workspace_mode" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='surface_profiles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='surface_profiles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='surface_profiles' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='surface_profiles' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER surface_profiles_peer_sync_delete AFTER DELETE ON "surface_profiles"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'surface_profiles',i.peer_key,c.device_id,c.tick,json_object('table','surface_profiles','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='surface_profiles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='surface_profiles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='surface_profiles' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='surface_profiles' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER folders_peer_sync_insert AFTER INSERT ON "folders"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'folders',i.peer_key,c.device_id,c.tick,json_object('table','folders','key',i.peer_key,'row',json_object('created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'icon',json_object('type',typeof(NEW."icon"),'value',CASE typeof(NEW."icon") WHEN 'blob' THEN hex(NEW."icon") WHEN 'real' THEN printf('%!.17g',NEW."icon") ELSE CAST(NEW."icon" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'name',json_object('type',typeof(NEW."name"),'value',CASE typeof(NEW."name") WHEN 'blob' THEN hex(NEW."name") WHEN 'real' THEN printf('%!.17g',NEW."name") ELSE CAST(NEW."name" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='folders' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='folders' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='folders' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='folders' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER folders_peer_sync_update AFTER UPDATE ON "folders"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."created_at" IS NOT NEW."created_at" OR OLD."icon" IS NOT NEW."icon" OR OLD."id" IS NOT NEW."id" OR OLD."is_pinned" IS NOT NEW."is_pinned" OR OLD."name" IS NOT NEW."name" OR OLD."position" IS NOT NEW."position" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'folders',i.peer_key,c.device_id,c.tick,json_object('table','folders','key',i.peer_key,'row',json_object('created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'icon',json_object('type',typeof(NEW."icon"),'value',CASE typeof(NEW."icon") WHEN 'blob' THEN hex(NEW."icon") WHEN 'real' THEN printf('%!.17g',NEW."icon") ELSE CAST(NEW."icon" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'name',json_object('type',typeof(NEW."name"),'value',CASE typeof(NEW."name") WHEN 'blob' THEN hex(NEW."name") WHEN 'real' THEN printf('%!.17g',NEW."name") ELSE CAST(NEW."name" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='folders' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='folders' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='folders' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='folders' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER folders_peer_sync_delete AFTER DELETE ON "folders"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'folders',i.peer_key,c.device_id,c.tick,json_object('table','folders','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='folders' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='folders' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='folders' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='folders' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER folder_execution_roots_peer_sync_insert AFTER INSERT ON "folder_execution_roots"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'folder_execution_roots',i.peer_key,c.device_id,c.tick,json_object('table','folder_execution_roots','key',i.peer_key,'row',json_object('folder_id',json_object('type',typeof(NEW."folder_id"),'value',CASE typeof(NEW."folder_id") WHEN 'blob' THEN hex(NEW."folder_id") WHEN 'real' THEN printf('%!.17g',NEW."folder_id") ELSE CAST(NEW."folder_id" AS TEXT) || '' END),'managed',json_object('type',typeof(NEW."managed"),'value',CASE typeof(NEW."managed") WHEN 'blob' THEN hex(NEW."managed") WHEN 'real' THEN printf('%!.17g',NEW."managed") ELSE CAST(NEW."managed" AS TEXT) || '' END),'reference_paths',json_object('type',typeof(NEW."reference_paths"),'value',CASE typeof(NEW."reference_paths") WHEN 'blob' THEN hex(NEW."reference_paths") WHEN 'real' THEN printf('%!.17g',NEW."reference_paths") ELSE CAST(NEW."reference_paths" AS TEXT) || '' END),'root_path',json_object('type',typeof(NEW."root_path"),'value',CASE typeof(NEW."root_path") WHEN 'blob' THEN hex(NEW."root_path") WHEN 'real' THEN printf('%!.17g',NEW."root_path") ELSE CAST(NEW."root_path" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='folder_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='folder_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='folder_execution_roots' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."folder_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='folder_execution_roots' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."folder_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER folder_execution_roots_peer_sync_update AFTER UPDATE ON "folder_execution_roots"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."folder_id" IS NOT NEW."folder_id" OR OLD."managed" IS NOT NEW."managed" OR OLD."reference_paths" IS NOT NEW."reference_paths" OR OLD."root_path" IS NOT NEW."root_path" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'folder_execution_roots',i.peer_key,c.device_id,c.tick,json_object('table','folder_execution_roots','key',i.peer_key,'row',json_object('folder_id',json_object('type',typeof(NEW."folder_id"),'value',CASE typeof(NEW."folder_id") WHEN 'blob' THEN hex(NEW."folder_id") WHEN 'real' THEN printf('%!.17g',NEW."folder_id") ELSE CAST(NEW."folder_id" AS TEXT) || '' END),'managed',json_object('type',typeof(NEW."managed"),'value',CASE typeof(NEW."managed") WHEN 'blob' THEN hex(NEW."managed") WHEN 'real' THEN printf('%!.17g',NEW."managed") ELSE CAST(NEW."managed" AS TEXT) || '' END),'reference_paths',json_object('type',typeof(NEW."reference_paths"),'value',CASE typeof(NEW."reference_paths") WHEN 'blob' THEN hex(NEW."reference_paths") WHEN 'real' THEN printf('%!.17g',NEW."reference_paths") ELSE CAST(NEW."reference_paths" AS TEXT) || '' END),'root_path',json_object('type',typeof(NEW."root_path"),'value',CASE typeof(NEW."root_path") WHEN 'blob' THEN hex(NEW."root_path") WHEN 'real' THEN printf('%!.17g',NEW."root_path") ELSE CAST(NEW."root_path" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='folder_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='folder_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='folder_execution_roots' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."folder_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='folder_execution_roots' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."folder_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER folder_execution_roots_peer_sync_delete AFTER DELETE ON "folder_execution_roots"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'folder_execution_roots',i.peer_key,c.device_id,c.tick,json_object('table','folder_execution_roots','key',i.peer_key,'row',json_object('folder_id',json_object('type',typeof(OLD."folder_id"),'value',CASE typeof(OLD."folder_id") WHEN 'blob' THEN hex(OLD."folder_id") WHEN 'real' THEN printf('%!.17g',OLD."folder_id") ELSE CAST(OLD."folder_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='folder_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='folder_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='folder_execution_roots' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."folder_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='folder_execution_roots' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."folder_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER notes_peer_sync_insert AFTER INSERT ON "notes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'notes',i.peer_key,c.device_id,c.tick,json_object('table','notes','key',i.peer_key,'row',json_object('content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'folder_id',json_object('type',typeof(NEW."folder_id"),'value',CASE typeof(NEW."folder_id") WHEN 'blob' THEN hex(NEW."folder_id") WHEN 'real' THEN printf('%!.17g',NEW."folder_id") ELSE CAST(NEW."folder_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'original_folder_id',json_object('type',typeof(NEW."original_folder_id"),'value',CASE typeof(NEW."original_folder_id") WHEN 'blob' THEN hex(NEW."original_folder_id") WHEN 'real' THEN printf('%!.17g',NEW."original_folder_id") ELSE CAST(NEW."original_folder_id" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'snippet',json_object('type',typeof(NEW."snippet"),'value',CASE typeof(NEW."snippet") WHEN 'blob' THEN hex(NEW."snippet") WHEN 'real' THEN printf('%!.17g',NEW."snippet") ELSE CAST(NEW."snippet" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='notes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='notes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER notes_peer_sync_update AFTER UPDATE ON "notes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."content" IS NOT NEW."content" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."deleted_at" IS NOT NEW."deleted_at" OR OLD."folder_id" IS NOT NEW."folder_id" OR OLD."id" IS NOT NEW."id" OR OLD."is_pinned" IS NOT NEW."is_pinned" OR OLD."original_folder_id" IS NOT NEW."original_folder_id" OR OLD."position" IS NOT NEW."position" OR OLD."snippet" IS NOT NEW."snippet" OR OLD."title" IS NOT NEW."title" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'notes',i.peer_key,c.device_id,c.tick,json_object('table','notes','key',i.peer_key,'row',json_object('content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'folder_id',json_object('type',typeof(NEW."folder_id"),'value',CASE typeof(NEW."folder_id") WHEN 'blob' THEN hex(NEW."folder_id") WHEN 'real' THEN printf('%!.17g',NEW."folder_id") ELSE CAST(NEW."folder_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'original_folder_id',json_object('type',typeof(NEW."original_folder_id"),'value',CASE typeof(NEW."original_folder_id") WHEN 'blob' THEN hex(NEW."original_folder_id") WHEN 'real' THEN printf('%!.17g',NEW."original_folder_id") ELSE CAST(NEW."original_folder_id" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'snippet',json_object('type',typeof(NEW."snippet"),'value',CASE typeof(NEW."snippet") WHEN 'blob' THEN hex(NEW."snippet") WHEN 'real' THEN printf('%!.17g',NEW."snippet") ELSE CAST(NEW."snippet" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='notes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='notes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER notes_peer_sync_delete AFTER DELETE ON "notes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'notes',i.peer_key,c.device_id,c.tick,json_object('table','notes','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='notes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='notes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER dictation_history_peer_sync_insert AFTER INSERT ON "dictation_history"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'dictation_history',i.peer_key,c.device_id,c.tick,json_object('table','dictation_history','key',i.peer_key,'row',json_object('created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'payload_json',json_object('type',typeof(NEW."payload_json"),'value',CASE typeof(NEW."payload_json") WHEN 'blob' THEN hex(NEW."payload_json") WHEN 'real' THEN printf('%!.17g',NEW."payload_json") ELSE CAST(NEW."payload_json" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='dictation_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='dictation_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='dictation_history' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='dictation_history' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER dictation_history_peer_sync_update AFTER UPDATE ON "dictation_history"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."created_at" IS NOT NEW."created_at" OR OLD."id" IS NOT NEW."id" OR OLD."payload_json" IS NOT NEW."payload_json")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'dictation_history',i.peer_key,c.device_id,c.tick,json_object('table','dictation_history','key',i.peer_key,'row',json_object('created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'payload_json',json_object('type',typeof(NEW."payload_json"),'value',CASE typeof(NEW."payload_json") WHEN 'blob' THEN hex(NEW."payload_json") WHEN 'real' THEN printf('%!.17g',NEW."payload_json") ELSE CAST(NEW."payload_json" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='dictation_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='dictation_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='dictation_history' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='dictation_history' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER dictation_history_peer_sync_delete AFTER DELETE ON "dictation_history"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'dictation_history',i.peer_key,c.device_id,c.tick,json_object('table','dictation_history','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='dictation_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='dictation_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='dictation_history' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='dictation_history' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER agent_owners_peer_sync_insert AFTER INSERT ON "agent_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'agent_owners',i.peer_key,c.device_id,c.tick,json_object('table','agent_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='agent_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='agent_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='agent_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='agent_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER agent_owners_peer_sync_update AFTER UPDATE ON "agent_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."id" IS NOT NEW."id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'agent_owners',i.peer_key,c.device_id,c.tick,json_object('table','agent_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='agent_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='agent_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='agent_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='agent_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER agent_owners_peer_sync_delete AFTER DELETE ON "agent_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'agent_owners',i.peer_key,c.device_id,c.tick,json_object('table','agent_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='agent_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='agent_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='agent_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='agent_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversation_owners_peer_sync_insert AFTER INSERT ON "conversation_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversation_owners',i.peer_key,c.device_id,c.tick,json_object('table','conversation_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversation_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversation_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversation_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversation_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversation_owners_peer_sync_update AFTER UPDATE ON "conversation_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."id" IS NOT NEW."id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversation_owners',i.peer_key,c.device_id,c.tick,json_object('table','conversation_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversation_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversation_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversation_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversation_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversation_owners_peer_sync_delete AFTER DELETE ON "conversation_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversation_owners',i.peer_key,c.device_id,c.tick,json_object('table','conversation_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversation_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversation_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversation_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversation_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER agents_peer_sync_insert AFTER INSERT ON "agents"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'agents',i.peer_key,c.device_id,c.tick,json_object('table','agents','key',i.peer_key,'row',json_object('codename',json_object('type',typeof(NEW."codename"),'value',CASE typeof(NEW."codename") WHEN 'blob' THEN hex(NEW."codename") WHEN 'real' THEN printf('%!.17g',NEW."codename") ELSE CAST(NEW."codename" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'display_name',json_object('type',typeof(NEW."display_name"),'value',CASE typeof(NEW."display_name") WHEN 'blob' THEN hex(NEW."display_name") WHEN 'real' THEN printf('%!.17g',NEW."display_name") ELSE CAST(NEW."display_name" AS TEXT) || '' END),'execution_location',json_object('type',typeof(NEW."execution_location"),'value',CASE typeof(NEW."execution_location") WHEN 'blob' THEN hex(NEW."execution_location") WHEN 'real' THEN printf('%!.17g',NEW."execution_location") ELSE CAST(NEW."execution_location" AS TEXT) || '' END),'icon',json_object('type',typeof(NEW."icon"),'value',CASE typeof(NEW."icon") WHEN 'blob' THEN hex(NEW."icon") WHEN 'real' THEN printf('%!.17g',NEW."icon") ELSE CAST(NEW."icon" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(NEW."owner_device_id"),'value',CASE typeof(NEW."owner_device_id") WHEN 'blob' THEN hex(NEW."owner_device_id") WHEN 'real' THEN printf('%!.17g',NEW."owner_device_id") ELSE CAST(NEW."owner_device_id" AS TEXT) || '' END),'platform_codename',json_object('type',typeof(NEW."platform_codename"),'value',CASE typeof(NEW."platform_codename") WHEN 'blob' THEN hex(NEW."platform_codename") WHEN 'real' THEN printf('%!.17g',NEW."platform_codename") ELSE CAST(NEW."platform_codename" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'runtime_device_id',json_object('type',typeof(NEW."runtime_device_id"),'value',CASE typeof(NEW."runtime_device_id") WHEN 'blob' THEN hex(NEW."runtime_device_id") WHEN 'real' THEN printf('%!.17g',NEW."runtime_device_id") ELSE CAST(NEW."runtime_device_id" AS TEXT) || '' END),'runtime_kind',json_object('type',typeof(NEW."runtime_kind"),'value',CASE typeof(NEW."runtime_kind") WHEN 'blob' THEN hex(NEW."runtime_kind") WHEN 'real' THEN printf('%!.17g',NEW."runtime_kind") ELSE CAST(NEW."runtime_kind" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='agents' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='agents' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='agents' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='agents' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER agents_peer_sync_update AFTER UPDATE ON "agents"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."codename" IS NOT NEW."codename" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."deleted_at" IS NOT NEW."deleted_at" OR OLD."display_name" IS NOT NEW."display_name" OR OLD."execution_location" IS NOT NEW."execution_location" OR OLD."icon" IS NOT NEW."icon" OR OLD."id" IS NOT NEW."id" OR OLD."owner_device_id" IS NOT NEW."owner_device_id" OR OLD."platform_codename" IS NOT NEW."platform_codename" OR OLD."revision" IS NOT NEW."revision" OR OLD."runtime_device_id" IS NOT NEW."runtime_device_id" OR OLD."runtime_kind" IS NOT NEW."runtime_kind" OR OLD."status" IS NOT NEW."status" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'agents',i.peer_key,c.device_id,c.tick,json_object('table','agents','key',i.peer_key,'row',json_object('codename',json_object('type',typeof(NEW."codename"),'value',CASE typeof(NEW."codename") WHEN 'blob' THEN hex(NEW."codename") WHEN 'real' THEN printf('%!.17g',NEW."codename") ELSE CAST(NEW."codename" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'display_name',json_object('type',typeof(NEW."display_name"),'value',CASE typeof(NEW."display_name") WHEN 'blob' THEN hex(NEW."display_name") WHEN 'real' THEN printf('%!.17g',NEW."display_name") ELSE CAST(NEW."display_name" AS TEXT) || '' END),'execution_location',json_object('type',typeof(NEW."execution_location"),'value',CASE typeof(NEW."execution_location") WHEN 'blob' THEN hex(NEW."execution_location") WHEN 'real' THEN printf('%!.17g',NEW."execution_location") ELSE CAST(NEW."execution_location" AS TEXT) || '' END),'icon',json_object('type',typeof(NEW."icon"),'value',CASE typeof(NEW."icon") WHEN 'blob' THEN hex(NEW."icon") WHEN 'real' THEN printf('%!.17g',NEW."icon") ELSE CAST(NEW."icon" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(NEW."owner_device_id"),'value',CASE typeof(NEW."owner_device_id") WHEN 'blob' THEN hex(NEW."owner_device_id") WHEN 'real' THEN printf('%!.17g',NEW."owner_device_id") ELSE CAST(NEW."owner_device_id" AS TEXT) || '' END),'platform_codename',json_object('type',typeof(NEW."platform_codename"),'value',CASE typeof(NEW."platform_codename") WHEN 'blob' THEN hex(NEW."platform_codename") WHEN 'real' THEN printf('%!.17g',NEW."platform_codename") ELSE CAST(NEW."platform_codename" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'runtime_device_id',json_object('type',typeof(NEW."runtime_device_id"),'value',CASE typeof(NEW."runtime_device_id") WHEN 'blob' THEN hex(NEW."runtime_device_id") WHEN 'real' THEN printf('%!.17g',NEW."runtime_device_id") ELSE CAST(NEW."runtime_device_id" AS TEXT) || '' END),'runtime_kind',json_object('type',typeof(NEW."runtime_kind"),'value',CASE typeof(NEW."runtime_kind") WHEN 'blob' THEN hex(NEW."runtime_kind") WHEN 'real' THEN printf('%!.17g',NEW."runtime_kind") ELSE CAST(NEW."runtime_kind" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='agents' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='agents' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='agents' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='agents' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER agents_peer_sync_delete AFTER DELETE ON "agents"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'agents',i.peer_key,c.device_id,c.tick,json_object('table','agents','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(OLD."owner_device_id"),'value',CASE typeof(OLD."owner_device_id") WHEN 'blob' THEN hex(OLD."owner_device_id") WHEN 'real' THEN printf('%!.17g',OLD."owner_device_id") ELSE CAST(OLD."owner_device_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='agents' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='agents' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='agents' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='agents' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversations_peer_sync_insert AFTER INSERT ON "conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversations',i.peer_key,c.device_id,c.tick,json_object('table','conversations','key',i.peer_key,'row',json_object('agent_codename',json_object('type',typeof(NEW."agent_codename"),'value',CASE typeof(NEW."agent_codename") WHEN 'blob' THEN hex(NEW."agent_codename") WHEN 'real' THEN printf('%!.17g',NEW."agent_codename") ELSE CAST(NEW."agent_codename" AS TEXT) || '' END),'agent_id',json_object('type',typeof(NEW."agent_id"),'value',CASE typeof(NEW."agent_id") WHEN 'blob' THEN hex(NEW."agent_id") WHEN 'real' THEN printf('%!.17g',NEW."agent_id") ELSE CAST(NEW."agent_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'folder_id',json_object('type',typeof(NEW."folder_id"),'value',CASE typeof(NEW."folder_id") WHEN 'blob' THEN hex(NEW."folder_id") WHEN 'real' THEN printf('%!.17g',NEW."folder_id") ELSE CAST(NEW."folder_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_archived',json_object('type',typeof(NEW."is_archived"),'value',CASE typeof(NEW."is_archived") WHEN 'blob' THEN hex(NEW."is_archived") WHEN 'real' THEN printf('%!.17g',NEW."is_archived") ELSE CAST(NEW."is_archived" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'last_message_at',json_object('type',typeof(NEW."last_message_at"),'value',CASE typeof(NEW."last_message_at") WHEN 'blob' THEN hex(NEW."last_message_at") WHEN 'real' THEN printf('%!.17g',NEW."last_message_at") ELSE CAST(NEW."last_message_at" AS TEXT) || '' END),'last_message_preview',json_object('type',typeof(NEW."last_message_preview"),'value',CASE typeof(NEW."last_message_preview") WHEN 'blob' THEN hex(NEW."last_message_preview") WHEN 'real' THEN printf('%!.17g',NEW."last_message_preview") ELSE CAST(NEW."last_message_preview" AS TEXT) || '' END),'original_folder_id',json_object('type',typeof(NEW."original_folder_id"),'value',CASE typeof(NEW."original_folder_id") WHEN 'blob' THEN hex(NEW."original_folder_id") WHEN 'real' THEN printf('%!.17g',NEW."original_folder_id") ELSE CAST(NEW."original_folder_id" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'unread',json_object('type',typeof(NEW."unread"),'value',CASE typeof(NEW."unread") WHEN 'blob' THEN hex(NEW."unread") WHEN 'real' THEN printf('%!.17g',NEW."unread") ELSE CAST(NEW."unread" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversations_peer_sync_update AFTER UPDATE ON "conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."agent_codename" IS NOT NEW."agent_codename" OR OLD."agent_id" IS NOT NEW."agent_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."deleted_at" IS NOT NEW."deleted_at" OR OLD."folder_id" IS NOT NEW."folder_id" OR OLD."id" IS NOT NEW."id" OR OLD."is_archived" IS NOT NEW."is_archived" OR OLD."is_pinned" IS NOT NEW."is_pinned" OR OLD."last_message_at" IS NOT NEW."last_message_at" OR OLD."last_message_preview" IS NOT NEW."last_message_preview" OR OLD."original_folder_id" IS NOT NEW."original_folder_id" OR OLD."title" IS NOT NEW."title" OR OLD."unread" IS NOT NEW."unread" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversations',i.peer_key,c.device_id,c.tick,json_object('table','conversations','key',i.peer_key,'row',json_object('agent_codename',json_object('type',typeof(NEW."agent_codename"),'value',CASE typeof(NEW."agent_codename") WHEN 'blob' THEN hex(NEW."agent_codename") WHEN 'real' THEN printf('%!.17g',NEW."agent_codename") ELSE CAST(NEW."agent_codename" AS TEXT) || '' END),'agent_id',json_object('type',typeof(NEW."agent_id"),'value',CASE typeof(NEW."agent_id") WHEN 'blob' THEN hex(NEW."agent_id") WHEN 'real' THEN printf('%!.17g',NEW."agent_id") ELSE CAST(NEW."agent_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'folder_id',json_object('type',typeof(NEW."folder_id"),'value',CASE typeof(NEW."folder_id") WHEN 'blob' THEN hex(NEW."folder_id") WHEN 'real' THEN printf('%!.17g',NEW."folder_id") ELSE CAST(NEW."folder_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_archived',json_object('type',typeof(NEW."is_archived"),'value',CASE typeof(NEW."is_archived") WHEN 'blob' THEN hex(NEW."is_archived") WHEN 'real' THEN printf('%!.17g',NEW."is_archived") ELSE CAST(NEW."is_archived" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'last_message_at',json_object('type',typeof(NEW."last_message_at"),'value',CASE typeof(NEW."last_message_at") WHEN 'blob' THEN hex(NEW."last_message_at") WHEN 'real' THEN printf('%!.17g',NEW."last_message_at") ELSE CAST(NEW."last_message_at" AS TEXT) || '' END),'last_message_preview',json_object('type',typeof(NEW."last_message_preview"),'value',CASE typeof(NEW."last_message_preview") WHEN 'blob' THEN hex(NEW."last_message_preview") WHEN 'real' THEN printf('%!.17g',NEW."last_message_preview") ELSE CAST(NEW."last_message_preview" AS TEXT) || '' END),'original_folder_id',json_object('type',typeof(NEW."original_folder_id"),'value',CASE typeof(NEW."original_folder_id") WHEN 'blob' THEN hex(NEW."original_folder_id") WHEN 'real' THEN printf('%!.17g',NEW."original_folder_id") ELSE CAST(NEW."original_folder_id" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'unread',json_object('type',typeof(NEW."unread"),'value',CASE typeof(NEW."unread") WHEN 'blob' THEN hex(NEW."unread") WHEN 'real' THEN printf('%!.17g',NEW."unread") ELSE CAST(NEW."unread" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversations_peer_sync_delete AFTER DELETE ON "conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversations',i.peer_key,c.device_id,c.tick,json_object('table','conversations','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversation_titles_peer_sync_insert AFTER INSERT ON "conversation_titles"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversation_titles',i.peer_key,c.device_id,c.tick,json_object('table','conversation_titles','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversation_titles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversation_titles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversation_titles' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversation_titles' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversation_titles_peer_sync_update AFTER UPDATE ON "conversation_titles"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."title" IS NOT NEW."title")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversation_titles',i.peer_key,c.device_id,c.tick,json_object('table','conversation_titles','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversation_titles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversation_titles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversation_titles' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversation_titles' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversation_titles_peer_sync_delete AFTER DELETE ON "conversation_titles"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'conversation_titles',i.peer_key,c.device_id,c.tick,json_object('table','conversation_titles','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='conversation_titles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='conversation_titles' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='conversation_titles' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='conversation_titles' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_execution_roots_peer_sync_insert AFTER INSERT ON "session_execution_roots"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_execution_roots',i.peer_key,c.device_id,c.tick,json_object('table','session_execution_roots','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'folder_locked',json_object('type',typeof(NEW."folder_locked"),'value',CASE typeof(NEW."folder_locked") WHEN 'blob' THEN hex(NEW."folder_locked") WHEN 'real' THEN printf('%!.17g',NEW."folder_locked") ELSE CAST(NEW."folder_locked" AS TEXT) || '' END),'root_path',json_object('type',typeof(NEW."root_path"),'value',CASE typeof(NEW."root_path") WHEN 'blob' THEN hex(NEW."root_path") WHEN 'real' THEN printf('%!.17g',NEW."root_path") ELSE CAST(NEW."root_path" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_execution_roots' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_execution_roots' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_execution_roots_peer_sync_update AFTER UPDATE ON "session_execution_roots"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."folder_locked" IS NOT NEW."folder_locked" OR OLD."root_path" IS NOT NEW."root_path" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_execution_roots',i.peer_key,c.device_id,c.tick,json_object('table','session_execution_roots','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'folder_locked',json_object('type',typeof(NEW."folder_locked"),'value',CASE typeof(NEW."folder_locked") WHEN 'blob' THEN hex(NEW."folder_locked") WHEN 'real' THEN printf('%!.17g',NEW."folder_locked") ELSE CAST(NEW."folder_locked" AS TEXT) || '' END),'root_path',json_object('type',typeof(NEW."root_path"),'value',CASE typeof(NEW."root_path") WHEN 'blob' THEN hex(NEW."root_path") WHEN 'real' THEN printf('%!.17g',NEW."root_path") ELSE CAST(NEW."root_path" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_execution_roots' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_execution_roots' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_execution_roots_peer_sync_delete AFTER DELETE ON "session_execution_roots"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_execution_roots',i.peer_key,c.device_id,c.tick,json_object('table','session_execution_roots','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_execution_roots' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_execution_roots' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_execution_roots' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER messages_peer_sync_insert AFTER INSERT ON "messages"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'messages',i.peer_key,c.device_id,c.tick,json_object('table','messages','key',i.peer_key,'row',json_object('attachment_references',json_object('type',typeof(NEW."attachment_references"),'value',CASE typeof(NEW."attachment_references") WHEN 'blob' THEN hex(NEW."attachment_references") WHEN 'real' THEN printf('%!.17g',NEW."attachment_references") ELSE CAST(NEW."attachment_references" AS TEXT) || '' END),'client_message_id',json_object('type',typeof(NEW."client_message_id"),'value',CASE typeof(NEW."client_message_id") WHEN 'blob' THEN hex(NEW."client_message_id") WHEN 'real' THEN printf('%!.17g',NEW."client_message_id") ELSE CAST(NEW."client_message_id" AS TEXT) || '' END),'content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'role',json_object('type',typeof(NEW."role"),'value',CASE typeof(NEW."role") WHEN 'blob' THEN hex(NEW."role") WHEN 'real' THEN printf('%!.17g',NEW."role") ELSE CAST(NEW."role" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'sequence',json_object('type',typeof(NEW."sequence"),'value',CASE typeof(NEW."sequence") WHEN 'blob' THEN hex(NEW."sequence") WHEN 'real' THEN printf('%!.17g',NEW."sequence") ELSE CAST(NEW."sequence" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='messages' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='messages' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER messages_peer_sync_update AFTER UPDATE ON "messages"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."attachment_references" IS NOT NEW."attachment_references" OR OLD."client_message_id" IS NOT NEW."client_message_id" OR OLD."content" IS NOT NEW."content" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."id" IS NOT NEW."id" OR OLD."position" IS NOT NEW."position" OR OLD."role" IS NOT NEW."role" OR OLD."run_id" IS NOT NEW."run_id" OR OLD."sequence" IS NOT NEW."sequence" OR OLD."status" IS NOT NEW."status" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'messages',i.peer_key,c.device_id,c.tick,json_object('table','messages','key',i.peer_key,'row',json_object('attachment_references',json_object('type',typeof(NEW."attachment_references"),'value',CASE typeof(NEW."attachment_references") WHEN 'blob' THEN hex(NEW."attachment_references") WHEN 'real' THEN printf('%!.17g',NEW."attachment_references") ELSE CAST(NEW."attachment_references" AS TEXT) || '' END),'client_message_id',json_object('type',typeof(NEW."client_message_id"),'value',CASE typeof(NEW."client_message_id") WHEN 'blob' THEN hex(NEW."client_message_id") WHEN 'real' THEN printf('%!.17g',NEW."client_message_id") ELSE CAST(NEW."client_message_id" AS TEXT) || '' END),'content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'role',json_object('type',typeof(NEW."role"),'value',CASE typeof(NEW."role") WHEN 'blob' THEN hex(NEW."role") WHEN 'real' THEN printf('%!.17g',NEW."role") ELSE CAST(NEW."role" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'sequence',json_object('type',typeof(NEW."sequence"),'value',CASE typeof(NEW."sequence") WHEN 'blob' THEN hex(NEW."sequence") WHEN 'real' THEN printf('%!.17g',NEW."sequence") ELSE CAST(NEW."sequence" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='messages' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='messages' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER messages_peer_sync_delete AFTER DELETE ON "messages"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'messages',i.peer_key,c.device_id,c.tick,json_object('table','messages','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='messages' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='messages' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_attachments_peer_sync_insert AFTER INSERT ON "message_attachments"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_attachments',i.peer_key,c.device_id,c.tick,json_object('table','message_attachments','key',i.peer_key,'row',json_object('content_hash',json_object('type',typeof(NEW."content_hash"),'value',CASE typeof(NEW."content_hash") WHEN 'blob' THEN hex(NEW."content_hash") WHEN 'real' THEN printf('%!.17g',NEW."content_hash") ELSE CAST(NEW."content_hash" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'file_name',json_object('type',typeof(NEW."file_name"),'value',CASE typeof(NEW."file_name") WHEN 'blob' THEN hex(NEW."file_name") WHEN 'real' THEN printf('%!.17g',NEW."file_name") ELSE CAST(NEW."file_name" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'mime_type',json_object('type',typeof(NEW."mime_type"),'value',CASE typeof(NEW."mime_type") WHEN 'blob' THEN hex(NEW."mime_type") WHEN 'real' THEN printf('%!.17g',NEW."mime_type") ELSE CAST(NEW."mime_type" AS TEXT) || '' END),'size_bytes',json_object('type',typeof(NEW."size_bytes"),'value',CASE typeof(NEW."size_bytes") WHEN 'blob' THEN hex(NEW."size_bytes") WHEN 'real' THEN printf('%!.17g',NEW."size_bytes") ELSE CAST(NEW."size_bytes" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_attachments' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_attachments' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_attachments' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_attachments' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_attachments_peer_sync_update AFTER UPDATE ON "message_attachments"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."content_hash" IS NOT NEW."content_hash" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."file_name" IS NOT NEW."file_name" OR OLD."id" IS NOT NEW."id" OR OLD."kind" IS NOT NEW."kind" OR OLD."message_id" IS NOT NEW."message_id" OR OLD."mime_type" IS NOT NEW."mime_type" OR OLD."size_bytes" IS NOT NEW."size_bytes")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_attachments',i.peer_key,c.device_id,c.tick,json_object('table','message_attachments','key',i.peer_key,'row',json_object('content_hash',json_object('type',typeof(NEW."content_hash"),'value',CASE typeof(NEW."content_hash") WHEN 'blob' THEN hex(NEW."content_hash") WHEN 'real' THEN printf('%!.17g',NEW."content_hash") ELSE CAST(NEW."content_hash" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'file_name',json_object('type',typeof(NEW."file_name"),'value',CASE typeof(NEW."file_name") WHEN 'blob' THEN hex(NEW."file_name") WHEN 'real' THEN printf('%!.17g',NEW."file_name") ELSE CAST(NEW."file_name" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'mime_type',json_object('type',typeof(NEW."mime_type"),'value',CASE typeof(NEW."mime_type") WHEN 'blob' THEN hex(NEW."mime_type") WHEN 'real' THEN printf('%!.17g',NEW."mime_type") ELSE CAST(NEW."mime_type" AS TEXT) || '' END),'size_bytes',json_object('type',typeof(NEW."size_bytes"),'value',CASE typeof(NEW."size_bytes") WHEN 'blob' THEN hex(NEW."size_bytes") WHEN 'real' THEN printf('%!.17g',NEW."size_bytes") ELSE CAST(NEW."size_bytes" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_attachments' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_attachments' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_attachments' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_attachments' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_attachments_peer_sync_delete AFTER DELETE ON "message_attachments"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_attachments',i.peer_key,c.device_id,c.tick,json_object('table','message_attachments','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_attachments' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_attachments' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_attachments' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_attachments' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_references_peer_sync_insert AFTER INSERT ON "message_references"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_references',i.peer_key,c.device_id,c.tick,json_object('table','message_references','key',i.peer_key,'row',json_object('agent_codename_snapshot',json_object('type',typeof(NEW."agent_codename_snapshot"),'value',CASE typeof(NEW."agent_codename_snapshot") WHEN 'blob' THEN hex(NEW."agent_codename_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."agent_codename_snapshot") ELSE CAST(NEW."agent_codename_snapshot" AS TEXT) || '' END),'content_snapshot',json_object('type',typeof(NEW."content_snapshot"),'value',CASE typeof(NEW."content_snapshot") WHEN 'blob' THEN hex(NEW."content_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."content_snapshot") ELSE CAST(NEW."content_snapshot" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'folder_id_snapshot',json_object('type',typeof(NEW."folder_id_snapshot"),'value',CASE typeof(NEW."folder_id_snapshot") WHEN 'blob' THEN hex(NEW."folder_id_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."folder_id_snapshot") ELSE CAST(NEW."folder_id_snapshot" AS TEXT) || '' END),'folder_title_snapshot',json_object('type',typeof(NEW."folder_title_snapshot"),'value',CASE typeof(NEW."folder_title_snapshot") WHEN 'blob' THEN hex(NEW."folder_title_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."folder_title_snapshot") ELSE CAST(NEW."folder_title_snapshot" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'resource_id',json_object('type',typeof(NEW."resource_id"),'value',CASE typeof(NEW."resource_id") WHEN 'blob' THEN hex(NEW."resource_id") WHEN 'real' THEN printf('%!.17g',NEW."resource_id") ELSE CAST(NEW."resource_id" AS TEXT) || '' END),'resource_type',json_object('type',typeof(NEW."resource_type"),'value',CASE typeof(NEW."resource_type") WHEN 'blob' THEN hex(NEW."resource_type") WHEN 'real' THEN printf('%!.17g',NEW."resource_type") ELSE CAST(NEW."resource_type" AS TEXT) || '' END),'revision_snapshot',json_object('type',typeof(NEW."revision_snapshot"),'value',CASE typeof(NEW."revision_snapshot") WHEN 'blob' THEN hex(NEW."revision_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."revision_snapshot") ELSE CAST(NEW."revision_snapshot" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'title_snapshot',json_object('type',typeof(NEW."title_snapshot"),'value',CASE typeof(NEW."title_snapshot") WHEN 'blob' THEN hex(NEW."title_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."title_snapshot") ELSE CAST(NEW."title_snapshot" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_references' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_references' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_references' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_references' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_references_peer_sync_update AFTER UPDATE ON "message_references"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."agent_codename_snapshot" IS NOT NEW."agent_codename_snapshot" OR OLD."content_snapshot" IS NOT NEW."content_snapshot" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."folder_id_snapshot" IS NOT NEW."folder_id_snapshot" OR OLD."folder_title_snapshot" IS NOT NEW."folder_title_snapshot" OR OLD."id" IS NOT NEW."id" OR OLD."message_id" IS NOT NEW."message_id" OR OLD."resource_id" IS NOT NEW."resource_id" OR OLD."resource_type" IS NOT NEW."resource_type" OR OLD."revision_snapshot" IS NOT NEW."revision_snapshot" OR OLD."source" IS NOT NEW."source" OR OLD."title_snapshot" IS NOT NEW."title_snapshot")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_references',i.peer_key,c.device_id,c.tick,json_object('table','message_references','key',i.peer_key,'row',json_object('agent_codename_snapshot',json_object('type',typeof(NEW."agent_codename_snapshot"),'value',CASE typeof(NEW."agent_codename_snapshot") WHEN 'blob' THEN hex(NEW."agent_codename_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."agent_codename_snapshot") ELSE CAST(NEW."agent_codename_snapshot" AS TEXT) || '' END),'content_snapshot',json_object('type',typeof(NEW."content_snapshot"),'value',CASE typeof(NEW."content_snapshot") WHEN 'blob' THEN hex(NEW."content_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."content_snapshot") ELSE CAST(NEW."content_snapshot" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'folder_id_snapshot',json_object('type',typeof(NEW."folder_id_snapshot"),'value',CASE typeof(NEW."folder_id_snapshot") WHEN 'blob' THEN hex(NEW."folder_id_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."folder_id_snapshot") ELSE CAST(NEW."folder_id_snapshot" AS TEXT) || '' END),'folder_title_snapshot',json_object('type',typeof(NEW."folder_title_snapshot"),'value',CASE typeof(NEW."folder_title_snapshot") WHEN 'blob' THEN hex(NEW."folder_title_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."folder_title_snapshot") ELSE CAST(NEW."folder_title_snapshot" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'resource_id',json_object('type',typeof(NEW."resource_id"),'value',CASE typeof(NEW."resource_id") WHEN 'blob' THEN hex(NEW."resource_id") WHEN 'real' THEN printf('%!.17g',NEW."resource_id") ELSE CAST(NEW."resource_id" AS TEXT) || '' END),'resource_type',json_object('type',typeof(NEW."resource_type"),'value',CASE typeof(NEW."resource_type") WHEN 'blob' THEN hex(NEW."resource_type") WHEN 'real' THEN printf('%!.17g',NEW."resource_type") ELSE CAST(NEW."resource_type" AS TEXT) || '' END),'revision_snapshot',json_object('type',typeof(NEW."revision_snapshot"),'value',CASE typeof(NEW."revision_snapshot") WHEN 'blob' THEN hex(NEW."revision_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."revision_snapshot") ELSE CAST(NEW."revision_snapshot" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'title_snapshot',json_object('type',typeof(NEW."title_snapshot"),'value',CASE typeof(NEW."title_snapshot") WHEN 'blob' THEN hex(NEW."title_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."title_snapshot") ELSE CAST(NEW."title_snapshot" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_references' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_references' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_references' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_references' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_references_peer_sync_delete AFTER DELETE ON "message_references"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_references',i.peer_key,c.device_id,c.tick,json_object('table','message_references','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_references' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_references' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_references' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_references' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER runs_peer_sync_insert AFTER INSERT ON "runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'runs',i.peer_key,c.device_id,c.tick,json_object('table','runs','key',i.peer_key,'row',json_object('agent_codename',json_object('type',typeof(NEW."agent_codename"),'value',CASE typeof(NEW."agent_codename") WHEN 'blob' THEN hex(NEW."agent_codename") WHEN 'real' THEN printf('%!.17g',NEW."agent_codename") ELSE CAST(NEW."agent_codename" AS TEXT) || '' END),'agent_id',json_object('type',typeof(NEW."agent_id"),'value',CASE typeof(NEW."agent_id") WHEN 'blob' THEN hex(NEW."agent_id") WHEN 'real' THEN printf('%!.17g',NEW."agent_id") ELSE CAST(NEW."agent_id" AS TEXT) || '' END),'assistant_message_id',json_object('type',typeof(NEW."assistant_message_id"),'value',CASE typeof(NEW."assistant_message_id") WHEN 'blob' THEN hex(NEW."assistant_message_id") WHEN 'real' THEN printf('%!.17g',NEW."assistant_message_id") ELSE CAST(NEW."assistant_message_id" AS TEXT) || '' END),'completed_at',json_object('type',typeof(NEW."completed_at"),'value',CASE typeof(NEW."completed_at") WHEN 'blob' THEN hex(NEW."completed_at") WHEN 'real' THEN printf('%!.17g',NEW."completed_at") ELSE CAST(NEW."completed_at" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'error',json_object('type',typeof(NEW."error"),'value',CASE typeof(NEW."error") WHEN 'blob' THEN hex(NEW."error") WHEN 'real' THEN printf('%!.17g',NEW."error") ELSE CAST(NEW."error" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'native_session_id',json_object('type',typeof(NEW."native_session_id"),'value',CASE typeof(NEW."native_session_id") WHEN 'blob' THEN hex(NEW."native_session_id") WHEN 'real' THEN printf('%!.17g',NEW."native_session_id") ELSE CAST(NEW."native_session_id" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'started_at',json_object('type',typeof(NEW."started_at"),'value',CASE typeof(NEW."started_at") WHEN 'blob' THEN hex(NEW."started_at") WHEN 'real' THEN printf('%!.17g',NEW."started_at") ELSE CAST(NEW."started_at" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END),'user_message_id',json_object('type',typeof(NEW."user_message_id"),'value',CASE typeof(NEW."user_message_id") WHEN 'blob' THEN hex(NEW."user_message_id") WHEN 'real' THEN printf('%!.17g',NEW."user_message_id") ELSE CAST(NEW."user_message_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER runs_peer_sync_update AFTER UPDATE ON "runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."agent_codename" IS NOT NEW."agent_codename" OR OLD."agent_id" IS NOT NEW."agent_id" OR OLD."assistant_message_id" IS NOT NEW."assistant_message_id" OR OLD."completed_at" IS NOT NEW."completed_at" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."error" IS NOT NEW."error" OR OLD."id" IS NOT NEW."id" OR OLD."native_session_id" IS NOT NEW."native_session_id" OR OLD."position" IS NOT NEW."position" OR OLD."started_at" IS NOT NEW."started_at" OR OLD."status" IS NOT NEW."status" OR OLD."updated_at" IS NOT NEW."updated_at" OR OLD."user_message_id" IS NOT NEW."user_message_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'runs',i.peer_key,c.device_id,c.tick,json_object('table','runs','key',i.peer_key,'row',json_object('agent_codename',json_object('type',typeof(NEW."agent_codename"),'value',CASE typeof(NEW."agent_codename") WHEN 'blob' THEN hex(NEW."agent_codename") WHEN 'real' THEN printf('%!.17g',NEW."agent_codename") ELSE CAST(NEW."agent_codename" AS TEXT) || '' END),'agent_id',json_object('type',typeof(NEW."agent_id"),'value',CASE typeof(NEW."agent_id") WHEN 'blob' THEN hex(NEW."agent_id") WHEN 'real' THEN printf('%!.17g',NEW."agent_id") ELSE CAST(NEW."agent_id" AS TEXT) || '' END),'assistant_message_id',json_object('type',typeof(NEW."assistant_message_id"),'value',CASE typeof(NEW."assistant_message_id") WHEN 'blob' THEN hex(NEW."assistant_message_id") WHEN 'real' THEN printf('%!.17g',NEW."assistant_message_id") ELSE CAST(NEW."assistant_message_id" AS TEXT) || '' END),'completed_at',json_object('type',typeof(NEW."completed_at"),'value',CASE typeof(NEW."completed_at") WHEN 'blob' THEN hex(NEW."completed_at") WHEN 'real' THEN printf('%!.17g',NEW."completed_at") ELSE CAST(NEW."completed_at" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'error',json_object('type',typeof(NEW."error"),'value',CASE typeof(NEW."error") WHEN 'blob' THEN hex(NEW."error") WHEN 'real' THEN printf('%!.17g',NEW."error") ELSE CAST(NEW."error" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'native_session_id',json_object('type',typeof(NEW."native_session_id"),'value',CASE typeof(NEW."native_session_id") WHEN 'blob' THEN hex(NEW."native_session_id") WHEN 'real' THEN printf('%!.17g',NEW."native_session_id") ELSE CAST(NEW."native_session_id" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'started_at',json_object('type',typeof(NEW."started_at"),'value',CASE typeof(NEW."started_at") WHEN 'blob' THEN hex(NEW."started_at") WHEN 'real' THEN printf('%!.17g',NEW."started_at") ELSE CAST(NEW."started_at" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END),'user_message_id',json_object('type',typeof(NEW."user_message_id"),'value',CASE typeof(NEW."user_message_id") WHEN 'blob' THEN hex(NEW."user_message_id") WHEN 'real' THEN printf('%!.17g',NEW."user_message_id") ELSE CAST(NEW."user_message_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER runs_peer_sync_delete AFTER DELETE ON "runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'runs',i.peer_key,c.device_id,c.tick,json_object('table','runs','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER run_visible_notes_peer_sync_insert AFTER INSERT ON "run_visible_notes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'run_visible_notes',i.peer_key,c.device_id,c.tick,json_object('table','run_visible_notes','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'note_id',json_object('type',typeof(NEW."note_id"),'value',CASE typeof(NEW."note_id") WHEN 'blob' THEN hex(NEW."note_id") WHEN 'real' THEN printf('%!.17g',NEW."note_id") ELSE CAST(NEW."note_id" AS TEXT) || '' END),'revision_snapshot',json_object('type',typeof(NEW."revision_snapshot"),'value',CASE typeof(NEW."revision_snapshot") WHEN 'blob' THEN hex(NEW."revision_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."revision_snapshot") ELSE CAST(NEW."revision_snapshot" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='run_visible_notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='run_visible_notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='run_visible_notes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='run_visible_notes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER run_visible_notes_peer_sync_update AFTER UPDATE ON "run_visible_notes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."note_id" IS NOT NEW."note_id" OR OLD."revision_snapshot" IS NOT NEW."revision_snapshot" OR OLD."run_id" IS NOT NEW."run_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'run_visible_notes',i.peer_key,c.device_id,c.tick,json_object('table','run_visible_notes','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'note_id',json_object('type',typeof(NEW."note_id"),'value',CASE typeof(NEW."note_id") WHEN 'blob' THEN hex(NEW."note_id") WHEN 'real' THEN printf('%!.17g',NEW."note_id") ELSE CAST(NEW."note_id" AS TEXT) || '' END),'revision_snapshot',json_object('type',typeof(NEW."revision_snapshot"),'value',CASE typeof(NEW."revision_snapshot") WHEN 'blob' THEN hex(NEW."revision_snapshot") WHEN 'real' THEN printf('%!.17g',NEW."revision_snapshot") ELSE CAST(NEW."revision_snapshot" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='run_visible_notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='run_visible_notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='run_visible_notes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='run_visible_notes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER run_visible_notes_peer_sync_delete AFTER DELETE ON "run_visible_notes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'run_visible_notes',i.peer_key,c.device_id,c.tick,json_object('table','run_visible_notes','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(OLD."run_id"),'value',CASE typeof(OLD."run_id") WHEN 'blob' THEN hex(OLD."run_id") WHEN 'real' THEN printf('%!.17g',OLD."run_id") ELSE CAST(OLD."run_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='run_visible_notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='run_visible_notes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='run_visible_notes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='run_visible_notes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER run_activities_peer_sync_insert AFTER INSERT ON "run_activities"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'run_activities',i.peer_key,c.device_id,c.tick,json_object('table','run_activities','key',i.peer_key,'row',json_object('completed_at',json_object('type',typeof(NEW."completed_at"),'value',CASE typeof(NEW."completed_at") WHEN 'blob' THEN hex(NEW."completed_at") WHEN 'real' THEN printf('%!.17g',NEW."completed_at") ELSE CAST(NEW."completed_at" AS TEXT) || '' END),'content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'detail',json_object('type',typeof(NEW."detail"),'value',CASE typeof(NEW."detail") WHEN 'blob' THEN hex(NEW."detail") WHEN 'real' THEN printf('%!.17g',NEW."detail") ELSE CAST(NEW."detail" AS TEXT) || '' END),'details_record_id',json_object('type',typeof(NEW."details_record_id"),'value',CASE typeof(NEW."details_record_id") WHEN 'blob' THEN hex(NEW."details_record_id") WHEN 'real' THEN printf('%!.17g',NEW."details_record_id") ELSE CAST(NEW."details_record_id" AS TEXT) || '' END),'event_type',json_object('type',typeof(NEW."event_type"),'value',CASE typeof(NEW."event_type") WHEN 'blob' THEN hex(NEW."event_type") WHEN 'real' THEN printf('%!.17g',NEW."event_type") ELSE CAST(NEW."event_type" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_transient',json_object('type',typeof(NEW."is_transient"),'value',CASE typeof(NEW."is_transient") WHEN 'blob' THEN hex(NEW."is_transient") WHEN 'real' THEN printf('%!.17g',NEW."is_transient") ELSE CAST(NEW."is_transient" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'sequence',json_object('type',typeof(NEW."sequence"),'value',CASE typeof(NEW."sequence") WHEN 'blob' THEN hex(NEW."sequence") WHEN 'real' THEN printf('%!.17g',NEW."sequence") ELSE CAST(NEW."sequence" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='run_activities' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='run_activities' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='run_activities' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='run_activities' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER run_activities_peer_sync_update AFTER UPDATE ON "run_activities"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."completed_at" IS NOT NEW."completed_at" OR OLD."content" IS NOT NEW."content" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."detail" IS NOT NEW."detail" OR OLD."details_record_id" IS NOT NEW."details_record_id" OR OLD."event_type" IS NOT NEW."event_type" OR OLD."id" IS NOT NEW."id" OR OLD."is_transient" IS NOT NEW."is_transient" OR OLD."position" IS NOT NEW."position" OR OLD."run_id" IS NOT NEW."run_id" OR OLD."sequence" IS NOT NEW."sequence" OR OLD."status" IS NOT NEW."status" OR OLD."title" IS NOT NEW."title")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'run_activities',i.peer_key,c.device_id,c.tick,json_object('table','run_activities','key',i.peer_key,'row',json_object('completed_at',json_object('type',typeof(NEW."completed_at"),'value',CASE typeof(NEW."completed_at") WHEN 'blob' THEN hex(NEW."completed_at") WHEN 'real' THEN printf('%!.17g',NEW."completed_at") ELSE CAST(NEW."completed_at" AS TEXT) || '' END),'content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'detail',json_object('type',typeof(NEW."detail"),'value',CASE typeof(NEW."detail") WHEN 'blob' THEN hex(NEW."detail") WHEN 'real' THEN printf('%!.17g',NEW."detail") ELSE CAST(NEW."detail" AS TEXT) || '' END),'details_record_id',json_object('type',typeof(NEW."details_record_id"),'value',CASE typeof(NEW."details_record_id") WHEN 'blob' THEN hex(NEW."details_record_id") WHEN 'real' THEN printf('%!.17g',NEW."details_record_id") ELSE CAST(NEW."details_record_id" AS TEXT) || '' END),'event_type',json_object('type',typeof(NEW."event_type"),'value',CASE typeof(NEW."event_type") WHEN 'blob' THEN hex(NEW."event_type") WHEN 'real' THEN printf('%!.17g',NEW."event_type") ELSE CAST(NEW."event_type" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_transient',json_object('type',typeof(NEW."is_transient"),'value',CASE typeof(NEW."is_transient") WHEN 'blob' THEN hex(NEW."is_transient") WHEN 'real' THEN printf('%!.17g',NEW."is_transient") ELSE CAST(NEW."is_transient" AS TEXT) || '' END),'position',json_object('type',typeof(NEW."position"),'value',CASE typeof(NEW."position") WHEN 'blob' THEN hex(NEW."position") WHEN 'real' THEN printf('%!.17g',NEW."position") ELSE CAST(NEW."position" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'sequence',json_object('type',typeof(NEW."sequence"),'value',CASE typeof(NEW."sequence") WHEN 'blob' THEN hex(NEW."sequence") WHEN 'real' THEN printf('%!.17g',NEW."sequence") ELSE CAST(NEW."sequence" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='run_activities' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='run_activities' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='run_activities' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='run_activities' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER run_activities_peer_sync_delete AFTER DELETE ON "run_activities"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'run_activities',i.peer_key,c.device_id,c.tick,json_object('table','run_activities','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='run_activities' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='run_activities' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='run_activities' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='run_activities' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER history_events_peer_sync_insert AFTER INSERT ON "history_events"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'history_events',i.peer_key,c.device_id,c.tick,json_object('table','history_events','key',i.peer_key,'row',json_object('agent_id',json_object('type',typeof(NEW."agent_id"),'value',CASE typeof(NEW."agent_id") WHEN 'blob' THEN hex(NEW."agent_id") WHEN 'real' THEN printf('%!.17g',NEW."agent_id") ELSE CAST(NEW."agent_id" AS TEXT) || '' END),'completeness',json_object('type',typeof(NEW."completeness"),'value',CASE typeof(NEW."completeness") WHEN 'blob' THEN hex(NEW."completeness") WHEN 'real' THEN printf('%!.17g',NEW."completeness") ELSE CAST(NEW."completeness" AS TEXT) || '' END),'content_mode',json_object('type',typeof(NEW."content_mode"),'value',CASE typeof(NEW."content_mode") WHEN 'blob' THEN hex(NEW."content_mode") WHEN 'real' THEN printf('%!.17g',NEW."content_mode") ELSE CAST(NEW."content_mode" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'harness',json_object('type',typeof(NEW."harness"),'value',CASE typeof(NEW."harness") WHEN 'blob' THEN hex(NEW."harness") WHEN 'real' THEN printf('%!.17g',NEW."harness") ELSE CAST(NEW."harness" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'native_record_id',json_object('type',typeof(NEW."native_record_id"),'value',CASE typeof(NEW."native_record_id") WHEN 'blob' THEN hex(NEW."native_record_id") WHEN 'real' THEN printf('%!.17g',NEW."native_record_id") ELSE CAST(NEW."native_record_id" AS TEXT) || '' END),'native_revision_id',json_object('type',typeof(NEW."native_revision_id"),'value',CASE typeof(NEW."native_revision_id") WHEN 'blob' THEN hex(NEW."native_revision_id") WHEN 'real' THEN printf('%!.17g',NEW."native_revision_id") ELSE CAST(NEW."native_revision_id" AS TEXT) || '' END),'native_session_id',json_object('type',typeof(NEW."native_session_id"),'value',CASE typeof(NEW."native_session_id") WHEN 'blob' THEN hex(NEW."native_session_id") WHEN 'real' THEN printf('%!.17g',NEW."native_session_id") ELSE CAST(NEW."native_session_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'projection_json',json_object('type',typeof(NEW."projection_json"),'value',CASE typeof(NEW."projection_json") WHEN 'blob' THEN hex(NEW."projection_json") WHEN 'real' THEN printf('%!.17g',NEW."projection_json") ELSE CAST(NEW."projection_json" AS TEXT) || '' END),'recorded_at',json_object('type',typeof(NEW."recorded_at"),'value',CASE typeof(NEW."recorded_at") WHEN 'blob' THEN hex(NEW."recorded_at") WHEN 'real' THEN printf('%!.17g',NEW."recorded_at") ELSE CAST(NEW."recorded_at" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'source_connection_id',json_object('type',typeof(NEW."source_connection_id"),'value',CASE typeof(NEW."source_connection_id") WHEN 'blob' THEN hex(NEW."source_connection_id") WHEN 'real' THEN printf('%!.17g',NEW."source_connection_id") ELSE CAST(NEW."source_connection_id" AS TEXT) || '' END),'source_id',json_object('type',typeof(NEW."source_id"),'value',CASE typeof(NEW."source_id") WHEN 'blob' THEN hex(NEW."source_id") WHEN 'real' THEN printf('%!.17g',NEW."source_id") ELSE CAST(NEW."source_id" AS TEXT) || '' END),'text_content',json_object('type',typeof(NEW."text_content"),'value',CASE typeof(NEW."text_content") WHEN 'blob' THEN hex(NEW."text_content") WHEN 'real' THEN printf('%!.17g',NEW."text_content") ELSE CAST(NEW."text_content" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='history_events' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='history_events' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='history_events' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='history_events' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER history_events_peer_sync_update AFTER UPDATE ON "history_events"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."agent_id" IS NOT NEW."agent_id" OR OLD."completeness" IS NOT NEW."completeness" OR OLD."content_mode" IS NOT NEW."content_mode" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."harness" IS NOT NEW."harness" OR OLD."id" IS NOT NEW."id" OR OLD."kind" IS NOT NEW."kind" OR OLD."native_record_id" IS NOT NEW."native_record_id" OR OLD."native_revision_id" IS NOT NEW."native_revision_id" OR OLD."native_session_id" IS NOT NEW."native_session_id" OR OLD."payload" IS NOT NEW."payload" OR OLD."projection_json" IS NOT NEW."projection_json" OR OLD."recorded_at" IS NOT NEW."recorded_at" OR OLD."run_id" IS NOT NEW."run_id" OR OLD."source_connection_id" IS NOT NEW."source_connection_id" OR OLD."source_id" IS NOT NEW."source_id" OR OLD."text_content" IS NOT NEW."text_content")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'history_events',i.peer_key,c.device_id,c.tick,json_object('table','history_events','key',i.peer_key,'row',json_object('agent_id',json_object('type',typeof(NEW."agent_id"),'value',CASE typeof(NEW."agent_id") WHEN 'blob' THEN hex(NEW."agent_id") WHEN 'real' THEN printf('%!.17g',NEW."agent_id") ELSE CAST(NEW."agent_id" AS TEXT) || '' END),'completeness',json_object('type',typeof(NEW."completeness"),'value',CASE typeof(NEW."completeness") WHEN 'blob' THEN hex(NEW."completeness") WHEN 'real' THEN printf('%!.17g',NEW."completeness") ELSE CAST(NEW."completeness" AS TEXT) || '' END),'content_mode',json_object('type',typeof(NEW."content_mode"),'value',CASE typeof(NEW."content_mode") WHEN 'blob' THEN hex(NEW."content_mode") WHEN 'real' THEN printf('%!.17g',NEW."content_mode") ELSE CAST(NEW."content_mode" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'harness',json_object('type',typeof(NEW."harness"),'value',CASE typeof(NEW."harness") WHEN 'blob' THEN hex(NEW."harness") WHEN 'real' THEN printf('%!.17g',NEW."harness") ELSE CAST(NEW."harness" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'native_record_id',json_object('type',typeof(NEW."native_record_id"),'value',CASE typeof(NEW."native_record_id") WHEN 'blob' THEN hex(NEW."native_record_id") WHEN 'real' THEN printf('%!.17g',NEW."native_record_id") ELSE CAST(NEW."native_record_id" AS TEXT) || '' END),'native_revision_id',json_object('type',typeof(NEW."native_revision_id"),'value',CASE typeof(NEW."native_revision_id") WHEN 'blob' THEN hex(NEW."native_revision_id") WHEN 'real' THEN printf('%!.17g',NEW."native_revision_id") ELSE CAST(NEW."native_revision_id" AS TEXT) || '' END),'native_session_id',json_object('type',typeof(NEW."native_session_id"),'value',CASE typeof(NEW."native_session_id") WHEN 'blob' THEN hex(NEW."native_session_id") WHEN 'real' THEN printf('%!.17g',NEW."native_session_id") ELSE CAST(NEW."native_session_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'projection_json',json_object('type',typeof(NEW."projection_json"),'value',CASE typeof(NEW."projection_json") WHEN 'blob' THEN hex(NEW."projection_json") WHEN 'real' THEN printf('%!.17g',NEW."projection_json") ELSE CAST(NEW."projection_json" AS TEXT) || '' END),'recorded_at',json_object('type',typeof(NEW."recorded_at"),'value',CASE typeof(NEW."recorded_at") WHEN 'blob' THEN hex(NEW."recorded_at") WHEN 'real' THEN printf('%!.17g',NEW."recorded_at") ELSE CAST(NEW."recorded_at" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'source_connection_id',json_object('type',typeof(NEW."source_connection_id"),'value',CASE typeof(NEW."source_connection_id") WHEN 'blob' THEN hex(NEW."source_connection_id") WHEN 'real' THEN printf('%!.17g',NEW."source_connection_id") ELSE CAST(NEW."source_connection_id" AS TEXT) || '' END),'source_id',json_object('type',typeof(NEW."source_id"),'value',CASE typeof(NEW."source_id") WHEN 'blob' THEN hex(NEW."source_id") WHEN 'real' THEN printf('%!.17g',NEW."source_id") ELSE CAST(NEW."source_id" AS TEXT) || '' END),'text_content',json_object('type',typeof(NEW."text_content"),'value',CASE typeof(NEW."text_content") WHEN 'blob' THEN hex(NEW."text_content") WHEN 'real' THEN printf('%!.17g',NEW."text_content") ELSE CAST(NEW."text_content" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='history_events' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='history_events' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='history_events' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='history_events' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER history_events_peer_sync_delete AFTER DELETE ON "history_events"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'history_events',i.peer_key,c.device_id,c.tick,json_object('table','history_events','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='history_events' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='history_events' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='history_events' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='history_events' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER note_asset_versions_peer_sync_insert AFTER INSERT ON "note_asset_versions"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'note_asset_versions',i.peer_key,c.device_id,c.tick,json_object('table','note_asset_versions','key',i.peer_key,'row',json_object('bytes',json_object('type',typeof(NEW."bytes"),'value',CASE typeof(NEW."bytes") WHEN 'blob' THEN hex(NEW."bytes") WHEN 'real' THEN printf('%!.17g',NEW."bytes") ELSE CAST(NEW."bytes" AS TEXT) || '' END),'content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'note_id',json_object('type',typeof(NEW."note_id"),'value',CASE typeof(NEW."note_id") WHEN 'blob' THEN hex(NEW."note_id") WHEN 'real' THEN printf('%!.17g',NEW."note_id") ELSE CAST(NEW."note_id" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='note_asset_versions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='note_asset_versions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='note_asset_versions' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='note_asset_versions' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER note_asset_versions_peer_sync_update AFTER UPDATE ON "note_asset_versions"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."bytes" IS NOT NEW."bytes" OR OLD."content" IS NOT NEW."content" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."id" IS NOT NEW."id" OR OLD."note_id" IS NOT NEW."note_id" OR OLD."revision" IS NOT NEW."revision" OR OLD."source" IS NOT NEW."source" OR OLD."title" IS NOT NEW."title")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'note_asset_versions',i.peer_key,c.device_id,c.tick,json_object('table','note_asset_versions','key',i.peer_key,'row',json_object('bytes',json_object('type',typeof(NEW."bytes"),'value',CASE typeof(NEW."bytes") WHEN 'blob' THEN hex(NEW."bytes") WHEN 'real' THEN printf('%!.17g',NEW."bytes") ELSE CAST(NEW."bytes" AS TEXT) || '' END),'content',json_object('type',typeof(NEW."content"),'value',CASE typeof(NEW."content") WHEN 'blob' THEN hex(NEW."content") WHEN 'real' THEN printf('%!.17g',NEW."content") ELSE CAST(NEW."content" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'note_id',json_object('type',typeof(NEW."note_id"),'value',CASE typeof(NEW."note_id") WHEN 'blob' THEN hex(NEW."note_id") WHEN 'real' THEN printf('%!.17g',NEW."note_id") ELSE CAST(NEW."note_id" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='note_asset_versions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='note_asset_versions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='note_asset_versions' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='note_asset_versions' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER note_asset_versions_peer_sync_delete AFTER DELETE ON "note_asset_versions"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'note_asset_versions',i.peer_key,c.device_id,c.tick,json_object('table','note_asset_versions','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='note_asset_versions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='note_asset_versions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='note_asset_versions' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='note_asset_versions' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER tool_settings_peer_sync_insert AFTER INSERT ON "tool_settings"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'tool_settings',i.peer_key,c.device_id,c.tick,json_object('table','tool_settings','key',i.peer_key,'row',json_object('id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'value',json_object('type',typeof(NEW."value"),'value',CASE typeof(NEW."value") WHEN 'blob' THEN hex(NEW."value") WHEN 'real' THEN printf('%!.17g',NEW."value") ELSE CAST(NEW."value" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='tool_settings' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='tool_settings' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='tool_settings' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='tool_settings' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER tool_settings_peer_sync_update AFTER UPDATE ON "tool_settings"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."id" IS NOT NEW."id" OR OLD."value" IS NOT NEW."value")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'tool_settings',i.peer_key,c.device_id,c.tick,json_object('table','tool_settings','key',i.peer_key,'row',json_object('id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'value',json_object('type',typeof(NEW."value"),'value',CASE typeof(NEW."value") WHEN 'blob' THEN hex(NEW."value") WHEN 'real' THEN printf('%!.17g',NEW."value") ELSE CAST(NEW."value" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='tool_settings' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='tool_settings' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='tool_settings' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='tool_settings' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER tool_settings_peer_sync_delete AFTER DELETE ON "tool_settings"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'tool_settings',i.peer_key,c.device_id,c.tick,json_object('table','tool_settings','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='tool_settings' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='tool_settings' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='tool_settings' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='tool_settings' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_tools_peer_sync_insert AFTER INSERT ON "session_tools"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_tools',i.peer_key,c.device_id,c.tick,json_object('table','session_tools','key',i.peer_key,'row',json_object('defaults_applied',json_object('type',typeof(NEW."defaults_applied"),'value',CASE typeof(NEW."defaults_applied") WHEN 'blob' THEN hex(NEW."defaults_applied") WHEN 'real' THEN printf('%!.17g',NEW."defaults_applied") ELSE CAST(NEW."defaults_applied" AS TEXT) || '' END),'enabled_json',json_object('type',typeof(NEW."enabled_json"),'value',CASE typeof(NEW."enabled_json") WHEN 'blob' THEN hex(NEW."enabled_json") WHEN 'real' THEN printf('%!.17g',NEW."enabled_json") ELSE CAST(NEW."enabled_json" AS TEXT) || '' END),'session_id',json_object('type',typeof(NEW."session_id"),'value',CASE typeof(NEW."session_id") WHEN 'blob' THEN hex(NEW."session_id") WHEN 'real' THEN printf('%!.17g',NEW."session_id") ELSE CAST(NEW."session_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_tools' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_tools' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_tools' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_tools' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_tools_peer_sync_update AFTER UPDATE ON "session_tools"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."defaults_applied" IS NOT NEW."defaults_applied" OR OLD."enabled_json" IS NOT NEW."enabled_json" OR OLD."session_id" IS NOT NEW."session_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_tools',i.peer_key,c.device_id,c.tick,json_object('table','session_tools','key',i.peer_key,'row',json_object('defaults_applied',json_object('type',typeof(NEW."defaults_applied"),'value',CASE typeof(NEW."defaults_applied") WHEN 'blob' THEN hex(NEW."defaults_applied") WHEN 'real' THEN printf('%!.17g',NEW."defaults_applied") ELSE CAST(NEW."defaults_applied" AS TEXT) || '' END),'enabled_json',json_object('type',typeof(NEW."enabled_json"),'value',CASE typeof(NEW."enabled_json") WHEN 'blob' THEN hex(NEW."enabled_json") WHEN 'real' THEN printf('%!.17g',NEW."enabled_json") ELSE CAST(NEW."enabled_json" AS TEXT) || '' END),'session_id',json_object('type',typeof(NEW."session_id"),'value',CASE typeof(NEW."session_id") WHEN 'blob' THEN hex(NEW."session_id") WHEN 'real' THEN printf('%!.17g',NEW."session_id") ELSE CAST(NEW."session_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_tools' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_tools' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_tools' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_tools' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_tools_peer_sync_delete AFTER DELETE ON "session_tools"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_tools',i.peer_key,c.device_id,c.tick,json_object('table','session_tools','key',i.peer_key,'row',json_object('session_id',json_object('type',typeof(OLD."session_id"),'value',CASE typeof(OLD."session_id") WHEN 'blob' THEN hex(OLD."session_id") WHEN 'real' THEN printf('%!.17g',OLD."session_id") ELSE CAST(OLD."session_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_tools' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_tools' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_tools' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_tools' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_relationships_peer_sync_insert AFTER INSERT ON "session_relationships"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_relationships',i.peer_key,c.device_id,c.tick,json_object('table','session_relationships','key',i.peer_key,'row',json_object('coordination_epoch',json_object('type',typeof(NEW."coordination_epoch"),'value',CASE typeof(NEW."coordination_epoch") WHEN 'blob' THEN hex(NEW."coordination_epoch") WHEN 'real' THEN printf('%!.17g',NEW."coordination_epoch") ELSE CAST(NEW."coordination_epoch" AS TEXT) || '' END),'coordination_since',json_object('type',typeof(NEW."coordination_since"),'value',CASE typeof(NEW."coordination_since") WHEN 'blob' THEN hex(NEW."coordination_since") WHEN 'real' THEN printf('%!.17g',NEW."coordination_since") ELSE CAST(NEW."coordination_since" AS TEXT) || '' END),'coordinator_id',json_object('type',typeof(NEW."coordinator_id"),'value',CASE typeof(NEW."coordinator_id") WHEN 'blob' THEN hex(NEW."coordinator_id") WHEN 'real' THEN printf('%!.17g',NEW."coordinator_id") ELSE CAST(NEW."coordinator_id" AS TEXT) || '' END),'created_by',json_object('type',typeof(NEW."created_by"),'value',CASE typeof(NEW."created_by") WHEN 'blob' THEN hex(NEW."created_by") WHEN 'real' THEN printf('%!.17g',NEW."created_by") ELSE CAST(NEW."created_by" AS TEXT) || '' END),'notifications_enabled',json_object('type',typeof(NEW."notifications_enabled"),'value',CASE typeof(NEW."notifications_enabled") WHEN 'blob' THEN hex(NEW."notifications_enabled") WHEN 'real' THEN printf('%!.17g',NEW."notifications_enabled") ELSE CAST(NEW."notifications_enabled" AS TEXT) || '' END),'purpose',json_object('type',typeof(NEW."purpose"),'value',CASE typeof(NEW."purpose") WHEN 'blob' THEN hex(NEW."purpose") WHEN 'real' THEN printf('%!.17g',NEW."purpose") ELSE CAST(NEW."purpose" AS TEXT) || '' END),'session_id',json_object('type',typeof(NEW."session_id"),'value',CASE typeof(NEW."session_id") WHEN 'blob' THEN hex(NEW."session_id") WHEN 'real' THEN printf('%!.17g',NEW."session_id") ELSE CAST(NEW."session_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_relationships' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_relationships' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_relationships' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_relationships' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_relationships_peer_sync_update AFTER UPDATE ON "session_relationships"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."coordination_epoch" IS NOT NEW."coordination_epoch" OR OLD."coordination_since" IS NOT NEW."coordination_since" OR OLD."coordinator_id" IS NOT NEW."coordinator_id" OR OLD."created_by" IS NOT NEW."created_by" OR OLD."notifications_enabled" IS NOT NEW."notifications_enabled" OR OLD."purpose" IS NOT NEW."purpose" OR OLD."session_id" IS NOT NEW."session_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_relationships',i.peer_key,c.device_id,c.tick,json_object('table','session_relationships','key',i.peer_key,'row',json_object('coordination_epoch',json_object('type',typeof(NEW."coordination_epoch"),'value',CASE typeof(NEW."coordination_epoch") WHEN 'blob' THEN hex(NEW."coordination_epoch") WHEN 'real' THEN printf('%!.17g',NEW."coordination_epoch") ELSE CAST(NEW."coordination_epoch" AS TEXT) || '' END),'coordination_since',json_object('type',typeof(NEW."coordination_since"),'value',CASE typeof(NEW."coordination_since") WHEN 'blob' THEN hex(NEW."coordination_since") WHEN 'real' THEN printf('%!.17g',NEW."coordination_since") ELSE CAST(NEW."coordination_since" AS TEXT) || '' END),'coordinator_id',json_object('type',typeof(NEW."coordinator_id"),'value',CASE typeof(NEW."coordinator_id") WHEN 'blob' THEN hex(NEW."coordinator_id") WHEN 'real' THEN printf('%!.17g',NEW."coordinator_id") ELSE CAST(NEW."coordinator_id" AS TEXT) || '' END),'created_by',json_object('type',typeof(NEW."created_by"),'value',CASE typeof(NEW."created_by") WHEN 'blob' THEN hex(NEW."created_by") WHEN 'real' THEN printf('%!.17g',NEW."created_by") ELSE CAST(NEW."created_by" AS TEXT) || '' END),'notifications_enabled',json_object('type',typeof(NEW."notifications_enabled"),'value',CASE typeof(NEW."notifications_enabled") WHEN 'blob' THEN hex(NEW."notifications_enabled") WHEN 'real' THEN printf('%!.17g',NEW."notifications_enabled") ELSE CAST(NEW."notifications_enabled" AS TEXT) || '' END),'purpose',json_object('type',typeof(NEW."purpose"),'value',CASE typeof(NEW."purpose") WHEN 'blob' THEN hex(NEW."purpose") WHEN 'real' THEN printf('%!.17g',NEW."purpose") ELSE CAST(NEW."purpose" AS TEXT) || '' END),'session_id',json_object('type',typeof(NEW."session_id"),'value',CASE typeof(NEW."session_id") WHEN 'blob' THEN hex(NEW."session_id") WHEN 'real' THEN printf('%!.17g',NEW."session_id") ELSE CAST(NEW."session_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_relationships' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_relationships' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_relationships' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_relationships' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_relationships_peer_sync_delete AFTER DELETE ON "session_relationships"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_relationships',i.peer_key,c.device_id,c.tick,json_object('table','session_relationships','key',i.peer_key,'row',json_object('session_id',json_object('type',typeof(OLD."session_id"),'value',CASE typeof(OLD."session_id") WHEN 'blob' THEN hex(OLD."session_id") WHEN 'real' THEN printf('%!.17g',OLD."session_id") ELSE CAST(OLD."session_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_relationships' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_relationships' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_relationships' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_relationships' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_grants_peer_sync_insert AFTER INSERT ON "session_grants"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_grants',i.peer_key,c.device_id,c.tick,json_object('table','session_grants','key',i.peer_key,'row',json_object('kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'source_id',json_object('type',typeof(NEW."source_id"),'value',CASE typeof(NEW."source_id") WHEN 'blob' THEN hex(NEW."source_id") WHEN 'real' THEN printf('%!.17g',NEW."source_id") ELSE CAST(NEW."source_id" AS TEXT) || '' END),'target_id',json_object('type',typeof(NEW."target_id"),'value',CASE typeof(NEW."target_id") WHEN 'blob' THEN hex(NEW."target_id") WHEN 'real' THEN printf('%!.17g',NEW."target_id") ELSE CAST(NEW."target_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_grants' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_grants' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_grants' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."source_id",NEW."target_id",NEW."kind")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_grants' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."source_id",NEW."target_id",NEW."kind")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_grants_peer_sync_update AFTER UPDATE ON "session_grants"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."kind" IS NOT NEW."kind" OR OLD."source_id" IS NOT NEW."source_id" OR OLD."target_id" IS NOT NEW."target_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_grants',i.peer_key,c.device_id,c.tick,json_object('table','session_grants','key',i.peer_key,'row',json_object('kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'source_id',json_object('type',typeof(NEW."source_id"),'value',CASE typeof(NEW."source_id") WHEN 'blob' THEN hex(NEW."source_id") WHEN 'real' THEN printf('%!.17g',NEW."source_id") ELSE CAST(NEW."source_id" AS TEXT) || '' END),'target_id',json_object('type',typeof(NEW."target_id"),'value',CASE typeof(NEW."target_id") WHEN 'blob' THEN hex(NEW."target_id") WHEN 'real' THEN printf('%!.17g',NEW."target_id") ELSE CAST(NEW."target_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_grants' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_grants' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_grants' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."source_id",NEW."target_id",NEW."kind")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_grants' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."source_id",NEW."target_id",NEW."kind")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_grants_peer_sync_delete AFTER DELETE ON "session_grants"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_grants',i.peer_key,c.device_id,c.tick,json_object('table','session_grants','key',i.peer_key,'row',json_object('kind',json_object('type',typeof(OLD."kind"),'value',CASE typeof(OLD."kind") WHEN 'blob' THEN hex(OLD."kind") WHEN 'real' THEN printf('%!.17g',OLD."kind") ELSE CAST(OLD."kind" AS TEXT) || '' END),'source_id',json_object('type',typeof(OLD."source_id"),'value',CASE typeof(OLD."source_id") WHEN 'blob' THEN hex(OLD."source_id") WHEN 'real' THEN printf('%!.17g',OLD."source_id") ELSE CAST(OLD."source_id" AS TEXT) || '' END),'target_id',json_object('type',typeof(OLD."target_id"),'value',CASE typeof(OLD."target_id") WHEN 'blob' THEN hex(OLD."target_id") WHEN 'real' THEN printf('%!.17g',OLD."target_id") ELSE CAST(OLD."target_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_grants' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_grants' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_grants' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."source_id",OLD."target_id",OLD."kind")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_grants' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."source_id",OLD."target_id",OLD."kind")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_goals_peer_sync_insert AFTER INSERT ON "session_goals"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_goals',i.peer_key,c.device_id,c.tick,json_object('table','session_goals','key',i.peer_key,'row',json_object('session_id',json_object('type',typeof(NEW."session_id"),'value',CASE typeof(NEW."session_id") WHEN 'blob' THEN hex(NEW."session_id") WHEN 'real' THEN printf('%!.17g',NEW."session_id") ELSE CAST(NEW."session_id" AS TEXT) || '' END),'value',json_object('type',typeof(NEW."value"),'value',CASE typeof(NEW."value") WHEN 'blob' THEN hex(NEW."value") WHEN 'real' THEN printf('%!.17g',NEW."value") ELSE CAST(NEW."value" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_goals' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_goals' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_goals' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_goals' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_goals_peer_sync_update AFTER UPDATE ON "session_goals"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."session_id" IS NOT NEW."session_id" OR OLD."value" IS NOT NEW."value")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_goals',i.peer_key,c.device_id,c.tick,json_object('table','session_goals','key',i.peer_key,'row',json_object('session_id',json_object('type',typeof(NEW."session_id"),'value',CASE typeof(NEW."session_id") WHEN 'blob' THEN hex(NEW."session_id") WHEN 'real' THEN printf('%!.17g',NEW."session_id") ELSE CAST(NEW."session_id" AS TEXT) || '' END),'value',json_object('type',typeof(NEW."value"),'value',CASE typeof(NEW."value") WHEN 'blob' THEN hex(NEW."value") WHEN 'real' THEN printf('%!.17g',NEW."value") ELSE CAST(NEW."value" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_goals' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_goals' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_goals' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_goals' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER session_goals_peer_sync_delete AFTER DELETE ON "session_goals"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'session_goals',i.peer_key,c.device_id,c.tick,json_object('table','session_goals','key',i.peer_key,'row',json_object('session_id',json_object('type',typeof(OLD."session_id"),'value',CASE typeof(OLD."session_id") WHEN 'blob' THEN hex(OLD."session_id") WHEN 'real' THEN printf('%!.17g',OLD."session_id") ELSE CAST(OLD."session_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='session_goals' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='session_goals' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='session_goals' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."session_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='session_goals' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."session_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER goal_runs_peer_sync_insert AFTER INSERT ON "goal_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'goal_runs',i.peer_key,c.device_id,c.tick,json_object('table','goal_runs','key',i.peer_key,'row',json_object('goal_id',json_object('type',typeof(NEW."goal_id"),'value',CASE typeof(NEW."goal_id") WHEN 'blob' THEN hex(NEW."goal_id") WHEN 'real' THEN printf('%!.17g',NEW."goal_id") ELSE CAST(NEW."goal_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='goal_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='goal_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='goal_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='goal_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER goal_runs_peer_sync_update AFTER UPDATE ON "goal_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."goal_id" IS NOT NEW."goal_id" OR OLD."run_id" IS NOT NEW."run_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'goal_runs',i.peer_key,c.device_id,c.tick,json_object('table','goal_runs','key',i.peer_key,'row',json_object('goal_id',json_object('type',typeof(NEW."goal_id"),'value',CASE typeof(NEW."goal_id") WHEN 'blob' THEN hex(NEW."goal_id") WHEN 'real' THEN printf('%!.17g',NEW."goal_id") ELSE CAST(NEW."goal_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='goal_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='goal_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='goal_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='goal_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER goal_runs_peer_sync_delete AFTER DELETE ON "goal_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'goal_runs',i.peer_key,c.device_id,c.tick,json_object('table','goal_runs','key',i.peer_key,'row',json_object('goal_id',json_object('type',typeof(OLD."goal_id"),'value',CASE typeof(OLD."goal_id") WHEN 'blob' THEN hex(OLD."goal_id") WHEN 'real' THEN printf('%!.17g',OLD."goal_id") ELSE CAST(OLD."goal_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(OLD."run_id"),'value',CASE typeof(OLD."run_id") WHEN 'blob' THEN hex(OLD."run_id") WHEN 'real' THEN printf('%!.17g',OLD."run_id") ELSE CAST(OLD."run_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='goal_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='goal_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='goal_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."goal_id",OLD."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='goal_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."goal_id",OLD."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER goal_usage_peer_sync_insert AFTER INSERT ON "goal_usage"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'goal_usage',i.peer_key,c.device_id,c.tick,json_object('table','goal_usage','key',i.peer_key,'row',json_object('goal_id',json_object('type',typeof(NEW."goal_id"),'value',CASE typeof(NEW."goal_id") WHEN 'blob' THEN hex(NEW."goal_id") WHEN 'real' THEN printf('%!.17g',NEW."goal_id") ELSE CAST(NEW."goal_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'tokens',json_object('type',typeof(NEW."tokens"),'value',CASE typeof(NEW."tokens") WHEN 'blob' THEN hex(NEW."tokens") WHEN 'real' THEN printf('%!.17g',NEW."tokens") ELSE CAST(NEW."tokens" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='goal_usage' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='goal_usage' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='goal_usage' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='goal_usage' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER goal_usage_peer_sync_update AFTER UPDATE ON "goal_usage"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."goal_id" IS NOT NEW."goal_id" OR OLD."run_id" IS NOT NEW."run_id" OR OLD."tokens" IS NOT NEW."tokens")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'goal_usage',i.peer_key,c.device_id,c.tick,json_object('table','goal_usage','key',i.peer_key,'row',json_object('goal_id',json_object('type',typeof(NEW."goal_id"),'value',CASE typeof(NEW."goal_id") WHEN 'blob' THEN hex(NEW."goal_id") WHEN 'real' THEN printf('%!.17g',NEW."goal_id") ELSE CAST(NEW."goal_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'tokens',json_object('type',typeof(NEW."tokens"),'value',CASE typeof(NEW."tokens") WHEN 'blob' THEN hex(NEW."tokens") WHEN 'real' THEN printf('%!.17g',NEW."tokens") ELSE CAST(NEW."tokens" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='goal_usage' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='goal_usage' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='goal_usage' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='goal_usage' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."goal_id",NEW."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER goal_usage_peer_sync_delete AFTER DELETE ON "goal_usage"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'goal_usage',i.peer_key,c.device_id,c.tick,json_object('table','goal_usage','key',i.peer_key,'row',json_object('goal_id',json_object('type',typeof(OLD."goal_id"),'value',CASE typeof(OLD."goal_id") WHEN 'blob' THEN hex(OLD."goal_id") WHEN 'real' THEN printf('%!.17g',OLD."goal_id") ELSE CAST(OLD."goal_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(OLD."run_id"),'value',CASE typeof(OLD."run_id") WHEN 'blob' THEN hex(OLD."run_id") WHEN 'real' THEN printf('%!.17g',OLD."run_id") ELSE CAST(OLD."run_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='goal_usage' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='goal_usage' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='goal_usage' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."goal_id",OLD."run_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='goal_usage' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."goal_id",OLD."run_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_item_owners_peer_sync_insert AFTER INSERT ON "calendar_item_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_item_owners',i.peer_key,c.device_id,c.tick,json_object('table','calendar_item_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_item_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_item_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_item_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_item_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_item_owners_peer_sync_update AFTER UPDATE ON "calendar_item_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."id" IS NOT NEW."id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_item_owners',i.peer_key,c.device_id,c.tick,json_object('table','calendar_item_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_item_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_item_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_item_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_item_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_item_owners_peer_sync_delete AFTER DELETE ON "calendar_item_owners"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_item_owners',i.peer_key,c.device_id,c.tick,json_object('table','calendar_item_owners','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_item_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_item_owners' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_item_owners' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_item_owners' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_items_peer_sync_insert AFTER INSERT ON "calendar_items"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_items',i.peer_key,c.device_id,c.tick,json_object('table','calendar_items','key',i.peer_key,'row',json_object('all_day',json_object('type',typeof(NEW."all_day"),'value',CASE typeof(NEW."all_day") WHEN 'blob' THEN hex(NEW."all_day") WHEN 'real' THEN printf('%!.17g',NEW."all_day") ELSE CAST(NEW."all_day" AS TEXT) || '' END),'calendar_json',json_object('type',typeof(NEW."calendar_json"),'value',CASE typeof(NEW."calendar_json") WHEN 'blob' THEN hex(NEW."calendar_json") WHEN 'real' THEN printf('%!.17g',NEW."calendar_json") ELSE CAST(NEW."calendar_json" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'description',json_object('type',typeof(NEW."description"),'value',CASE typeof(NEW."description") WHEN 'blob' THEN hex(NEW."description") WHEN 'real' THEN printf('%!.17g',NEW."description") ELSE CAST(NEW."description" AS TEXT) || '' END),'ends_at',json_object('type',typeof(NEW."ends_at"),'value',CASE typeof(NEW."ends_at") WHEN 'blob' THEN hex(NEW."ends_at") WHEN 'real' THEN printf('%!.17g',NEW."ends_at") ELSE CAST(NEW."ends_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'starts_at',json_object('type',typeof(NEW."starts_at"),'value',CASE typeof(NEW."starts_at") WHEN 'blob' THEN hex(NEW."starts_at") WHEN 'real' THEN printf('%!.17g',NEW."starts_at") ELSE CAST(NEW."starts_at" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_items' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_items' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_items_peer_sync_update AFTER UPDATE ON "calendar_items"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."all_day" IS NOT NEW."all_day" OR OLD."calendar_json" IS NOT NEW."calendar_json" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."deleted_at" IS NOT NEW."deleted_at" OR OLD."description" IS NOT NEW."description" OR OLD."ends_at" IS NOT NEW."ends_at" OR OLD."id" IS NOT NEW."id" OR OLD."kind" IS NOT NEW."kind" OR OLD."source" IS NOT NEW."source" OR OLD."starts_at" IS NOT NEW."starts_at" OR OLD."status" IS NOT NEW."status" OR OLD."title" IS NOT NEW."title" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_items',i.peer_key,c.device_id,c.tick,json_object('table','calendar_items','key',i.peer_key,'row',json_object('all_day',json_object('type',typeof(NEW."all_day"),'value',CASE typeof(NEW."all_day") WHEN 'blob' THEN hex(NEW."all_day") WHEN 'real' THEN printf('%!.17g',NEW."all_day") ELSE CAST(NEW."all_day" AS TEXT) || '' END),'calendar_json',json_object('type',typeof(NEW."calendar_json"),'value',CASE typeof(NEW."calendar_json") WHEN 'blob' THEN hex(NEW."calendar_json") WHEN 'real' THEN printf('%!.17g',NEW."calendar_json") ELSE CAST(NEW."calendar_json" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'description',json_object('type',typeof(NEW."description"),'value',CASE typeof(NEW."description") WHEN 'blob' THEN hex(NEW."description") WHEN 'real' THEN printf('%!.17g',NEW."description") ELSE CAST(NEW."description" AS TEXT) || '' END),'ends_at',json_object('type',typeof(NEW."ends_at"),'value',CASE typeof(NEW."ends_at") WHEN 'blob' THEN hex(NEW."ends_at") WHEN 'real' THEN printf('%!.17g',NEW."ends_at") ELSE CAST(NEW."ends_at" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'starts_at',json_object('type',typeof(NEW."starts_at"),'value',CASE typeof(NEW."starts_at") WHEN 'blob' THEN hex(NEW."starts_at") WHEN 'real' THEN printf('%!.17g',NEW."starts_at") ELSE CAST(NEW."starts_at" AS TEXT) || '' END),'status',json_object('type',typeof(NEW."status"),'value',CASE typeof(NEW."status") WHEN 'blob' THEN hex(NEW."status") WHEN 'real' THEN printf('%!.17g',NEW."status") ELSE CAST(NEW."status" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_items' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_items' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_items_peer_sync_delete AFTER DELETE ON "calendar_items"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_items',i.peer_key,c.device_id,c.tick,json_object('table','calendar_items','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_items' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_items' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_task_executors_peer_sync_insert AFTER INSERT ON "calendar_task_executors"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_task_executors',i.peer_key,c.device_id,c.tick,json_object('table','calendar_task_executors','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'tools_json',json_object('type',typeof(NEW."tools_json"),'value',CASE typeof(NEW."tools_json") WHEN 'blob' THEN hex(NEW."tools_json") WHEN 'real' THEN printf('%!.17g',NEW."tools_json") ELSE CAST(NEW."tools_json" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_task_executors' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_task_executors' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_task_executors' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_task_executors' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_task_executors_peer_sync_update AFTER UPDATE ON "calendar_task_executors"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."event_id" IS NOT NEW."event_id" OR OLD."tools_json" IS NOT NEW."tools_json")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_task_executors',i.peer_key,c.device_id,c.tick,json_object('table','calendar_task_executors','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'tools_json',json_object('type',typeof(NEW."tools_json"),'value',CASE typeof(NEW."tools_json") WHEN 'blob' THEN hex(NEW."tools_json") WHEN 'real' THEN printf('%!.17g',NEW."tools_json") ELSE CAST(NEW."tools_json" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_task_executors' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_task_executors' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_task_executors' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_task_executors' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_task_executors_peer_sync_delete AFTER DELETE ON "calendar_task_executors"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_task_executors',i.peer_key,c.device_id,c.tick,json_object('table','calendar_task_executors','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(OLD."event_id"),'value',CASE typeof(OLD."event_id") WHEN 'blob' THEN hex(OLD."event_id") WHEN 'real' THEN printf('%!.17g',OLD."event_id") ELSE CAST(OLD."event_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_task_executors' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_task_executors' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_task_executors' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_task_executors' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_run_publishers_peer_sync_insert AFTER INSERT ON "calendar_run_publishers"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_run_publishers',i.peer_key,c.device_id,c.tick,json_object('table','calendar_run_publishers','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_run_publishers' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_run_publishers' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_run_publishers' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id",NEW."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_run_publishers' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id",NEW."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_run_publishers_peer_sync_update AFTER UPDATE ON "calendar_run_publishers"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."event_id" IS NOT NEW."event_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_run_publishers',i.peer_key,c.device_id,c.tick,json_object('table','calendar_run_publishers','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_run_publishers' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_run_publishers' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_run_publishers' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id",NEW."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_run_publishers' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id",NEW."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_run_publishers_peer_sync_delete AFTER DELETE ON "calendar_run_publishers"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_run_publishers',i.peer_key,c.device_id,c.tick,json_object('table','calendar_run_publishers','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(OLD."event_id"),'value',CASE typeof(OLD."event_id") WHEN 'blob' THEN hex(OLD."event_id") WHEN 'real' THEN printf('%!.17g',OLD."event_id") ELSE CAST(OLD."event_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_run_publishers' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_run_publishers' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_run_publishers' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."event_id",OLD."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_run_publishers' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."event_id",OLD."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_published_runs_peer_sync_insert AFTER INSERT ON "calendar_published_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_published_runs',i.peer_key,c.device_id,c.tick,json_object('table','calendar_published_runs','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'payload_json',json_object('type',typeof(NEW."payload_json"),'value',CASE typeof(NEW."payload_json") WHEN 'blob' THEN hex(NEW."payload_json") WHEN 'real' THEN printf('%!.17g',NEW."payload_json") ELSE CAST(NEW."payload_json" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_published_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_published_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_published_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_published_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_published_runs_peer_sync_update AFTER UPDATE ON "calendar_published_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."event_id" IS NOT NEW."event_id" OR OLD."id" IS NOT NEW."id" OR OLD."payload_json" IS NOT NEW."payload_json")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_published_runs',i.peer_key,c.device_id,c.tick,json_object('table','calendar_published_runs','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'payload_json',json_object('type',typeof(NEW."payload_json"),'value',CASE typeof(NEW."payload_json") WHEN 'blob' THEN hex(NEW."payload_json") WHEN 'real' THEN printf('%!.17g',NEW."payload_json") ELSE CAST(NEW."payload_json" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_published_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_published_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_published_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_published_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER calendar_published_runs_peer_sync_delete AFTER DELETE ON "calendar_published_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'calendar_published_runs',i.peer_key,c.device_id,c.tick,json_object('table','calendar_published_runs','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='calendar_published_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='calendar_published_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='calendar_published_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='calendar_published_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_workspaces_peer_sync_insert AFTER INSERT ON "execution_workspaces"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_workspaces',i.peer_key,c.device_id,c.tick,json_object('table','execution_workspaces','key',i.peer_key,'row',json_object('deleted',json_object('type',typeof(NEW."deleted"),'value',CASE typeof(NEW."deleted") WHEN 'blob' THEN hex(NEW."deleted") WHEN 'real' THEN printf('%!.17g',NEW."deleted") ELSE CAST(NEW."deleted" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(NEW."owner_device_id"),'value',CASE typeof(NEW."owner_device_id") WHEN 'blob' THEN hex(NEW."owner_device_id") WHEN 'real' THEN printf('%!.17g',NEW."owner_device_id") ELSE CAST(NEW."owner_device_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted"<>0 THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_workspaces' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_workspaces' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_workspaces' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_workspaces' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_workspaces_peer_sync_update AFTER UPDATE ON "execution_workspaces"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."deleted" IS NOT NEW."deleted" OR OLD."id" IS NOT NEW."id" OR OLD."owner_device_id" IS NOT NEW."owner_device_id" OR OLD."payload" IS NOT NEW."payload" OR OLD."revision" IS NOT NEW."revision")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_workspaces',i.peer_key,c.device_id,c.tick,json_object('table','execution_workspaces','key',i.peer_key,'row',json_object('deleted',json_object('type',typeof(NEW."deleted"),'value',CASE typeof(NEW."deleted") WHEN 'blob' THEN hex(NEW."deleted") WHEN 'real' THEN printf('%!.17g',NEW."deleted") ELSE CAST(NEW."deleted" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(NEW."owner_device_id"),'value',CASE typeof(NEW."owner_device_id") WHEN 'blob' THEN hex(NEW."owner_device_id") WHEN 'real' THEN printf('%!.17g',NEW."owner_device_id") ELSE CAST(NEW."owner_device_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted"<>0 THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_workspaces' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_workspaces' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_workspaces' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_workspaces' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_workspaces_peer_sync_delete AFTER DELETE ON "execution_workspaces"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_workspaces',i.peer_key,c.device_id,c.tick,json_object('table','execution_workspaces','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(OLD."owner_device_id"),'value',CASE typeof(OLD."owner_device_id") WHEN 'blob' THEN hex(OLD."owner_device_id") WHEN 'real' THEN printf('%!.17g',OLD."owner_device_id") ELSE CAST(OLD."owner_device_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_workspaces' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_workspaces' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_workspaces' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_workspaces' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_journal_peer_sync_insert AFTER INSERT ON "execution_journal"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_journal',i.peer_key,c.device_id,c.tick,json_object('table','execution_journal','key',i.peer_key,'row',json_object('event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'fingerprint',json_object('type',typeof(NEW."fingerprint"),'value',CASE typeof(NEW."fingerprint") WHEN 'blob' THEN hex(NEW."fingerprint") WHEN 'real' THEN printf('%!.17g',NEW."fingerprint") ELSE CAST(NEW."fingerprint" AS TEXT) || '' END),'origin_sequence',json_object('type',typeof(NEW."origin_sequence"),'value',CASE typeof(NEW."origin_sequence") WHEN 'blob' THEN hex(NEW."origin_sequence") WHEN 'real' THEN printf('%!.17g',NEW."origin_sequence") ELSE CAST(NEW."origin_sequence" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_journal' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_journal' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_journal' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_journal' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_journal_peer_sync_update AFTER UPDATE ON "execution_journal"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."event_id" IS NOT NEW."event_id" OR OLD."fingerprint" IS NOT NEW."fingerprint" OR OLD."origin_sequence" IS NOT NEW."origin_sequence" OR OLD."payload" IS NOT NEW."payload" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_journal',i.peer_key,c.device_id,c.tick,json_object('table','execution_journal','key',i.peer_key,'row',json_object('event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'fingerprint',json_object('type',typeof(NEW."fingerprint"),'value',CASE typeof(NEW."fingerprint") WHEN 'blob' THEN hex(NEW."fingerprint") WHEN 'real' THEN printf('%!.17g',NEW."fingerprint") ELSE CAST(NEW."fingerprint" AS TEXT) || '' END),'origin_sequence',json_object('type',typeof(NEW."origin_sequence"),'value',CASE typeof(NEW."origin_sequence") WHEN 'blob' THEN hex(NEW."origin_sequence") WHEN 'real' THEN printf('%!.17g',NEW."origin_sequence") ELSE CAST(NEW."origin_sequence" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_journal' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_journal' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_journal' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_journal' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_journal_peer_sync_delete AFTER DELETE ON "execution_journal"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_journal',i.peer_key,c.device_id,c.tick,json_object('table','execution_journal','key',i.peer_key,'row',json_object('event_id',json_object('type',typeof(OLD."event_id"),'value',CASE typeof(OLD."event_id") WHEN 'blob' THEN hex(OLD."event_id") WHEN 'real' THEN printf('%!.17g',OLD."event_id") ELSE CAST(OLD."event_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_journal' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_journal' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_journal' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_journal' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_retained_settlements_peer_sync_insert AFTER INSERT ON "execution_retained_settlements"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_retained_settlements',i.peer_key,c.device_id,c.tick,json_object('table','execution_retained_settlements','key',i.peer_key,'row',json_object('event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'fingerprint',json_object('type',typeof(NEW."fingerprint"),'value',CASE typeof(NEW."fingerprint") WHEN 'blob' THEN hex(NEW."fingerprint") WHEN 'real' THEN printf('%!.17g',NEW."fingerprint") ELSE CAST(NEW."fingerprint" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_retained_settlements' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_retained_settlements' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_retained_settlements' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_retained_settlements' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_retained_settlements_peer_sync_update AFTER UPDATE ON "execution_retained_settlements"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."event_id" IS NOT NEW."event_id" OR OLD."fingerprint" IS NOT NEW."fingerprint" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_retained_settlements',i.peer_key,c.device_id,c.tick,json_object('table','execution_retained_settlements','key',i.peer_key,'row',json_object('event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'fingerprint',json_object('type',typeof(NEW."fingerprint"),'value',CASE typeof(NEW."fingerprint") WHEN 'blob' THEN hex(NEW."fingerprint") WHEN 'real' THEN printf('%!.17g',NEW."fingerprint") ELSE CAST(NEW."fingerprint" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_retained_settlements' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_retained_settlements' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_retained_settlements' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_retained_settlements' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_retained_settlements_peer_sync_delete AFTER DELETE ON "execution_retained_settlements"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_retained_settlements',i.peer_key,c.device_id,c.tick,json_object('table','execution_retained_settlements','key',i.peer_key,'row',json_object('event_id',json_object('type',typeof(OLD."event_id"),'value',CASE typeof(OLD."event_id") WHEN 'blob' THEN hex(OLD."event_id") WHEN 'real' THEN printf('%!.17g',OLD."event_id") ELSE CAST(OLD."event_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_retained_settlements' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_retained_settlements' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_retained_settlements' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_retained_settlements' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_conversations_peer_sync_insert AFTER INSERT ON "execution_conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_conversations',i.peer_key,c.device_id,c.tick,json_object('table','execution_conversations','key',i.peer_key,'row',json_object('active_run_id',json_object('type',typeof(NEW."active_run_id"),'value',CASE typeof(NEW."active_run_id") WHEN 'blob' THEN hex(NEW."active_run_id") WHEN 'real' THEN printf('%!.17g',NEW."active_run_id") ELSE CAST(NEW."active_run_id" AS TEXT) || '' END),'conversation',json_object('type',typeof(NEW."conversation"),'value',CASE typeof(NEW."conversation") WHEN 'blob' THEN hex(NEW."conversation") WHEN 'real' THEN printf('%!.17g',NEW."conversation") ELSE CAST(NEW."conversation" AS TEXT) || '' END),'deleted',json_object('type',typeof(NEW."deleted"),'value',CASE typeof(NEW."deleted") WHEN 'blob' THEN hex(NEW."deleted") WHEN 'real' THEN printf('%!.17g',NEW."deleted") ELSE CAST(NEW."deleted" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted"<>0 THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_conversations_peer_sync_update AFTER UPDATE ON "execution_conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."active_run_id" IS NOT NEW."active_run_id" OR OLD."conversation" IS NOT NEW."conversation" OR OLD."deleted" IS NOT NEW."deleted" OR OLD."id" IS NOT NEW."id" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_conversations',i.peer_key,c.device_id,c.tick,json_object('table','execution_conversations','key',i.peer_key,'row',json_object('active_run_id',json_object('type',typeof(NEW."active_run_id"),'value',CASE typeof(NEW."active_run_id") WHEN 'blob' THEN hex(NEW."active_run_id") WHEN 'real' THEN printf('%!.17g',NEW."active_run_id") ELSE CAST(NEW."active_run_id" AS TEXT) || '' END),'conversation',json_object('type',typeof(NEW."conversation"),'value',CASE typeof(NEW."conversation") WHEN 'blob' THEN hex(NEW."conversation") WHEN 'real' THEN printf('%!.17g',NEW."conversation") ELSE CAST(NEW."conversation" AS TEXT) || '' END),'deleted',json_object('type',typeof(NEW."deleted"),'value',CASE typeof(NEW."deleted") WHEN 'blob' THEN hex(NEW."deleted") WHEN 'real' THEN printf('%!.17g',NEW."deleted") ELSE CAST(NEW."deleted" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted"<>0 THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_conversations_peer_sync_delete AFTER DELETE ON "execution_conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_conversations',i.peer_key,c.device_id,c.tick,json_object('table','execution_conversations','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_adoptions_peer_sync_insert AFTER INSERT ON "execution_adoptions"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_adoptions',i.peer_key,c.device_id,c.tick,json_object('table','execution_adoptions','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_adoptions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_adoptions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_adoptions' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_adoptions' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_adoptions_peer_sync_update AFTER UPDATE ON "execution_adoptions"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."payload" IS NOT NEW."payload" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_adoptions',i.peer_key,c.device_id,c.tick,json_object('table','execution_adoptions','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_adoptions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_adoptions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_adoptions' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_adoptions' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_adoptions_peer_sync_delete AFTER DELETE ON "execution_adoptions"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_adoptions',i.peer_key,c.device_id,c.tick,json_object('table','execution_adoptions','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_adoptions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_adoptions' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_adoptions' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_adoptions' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_provenance_peer_sync_insert AFTER INSERT ON "message_provenance"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_provenance',i.peer_key,c.device_id,c.tick,json_object('table','message_provenance','key',i.peer_key,'row',json_object('kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'source_agent',json_object('type',typeof(NEW."source_agent"),'value',CASE typeof(NEW."source_agent") WHEN 'blob' THEN hex(NEW."source_agent") WHEN 'real' THEN printf('%!.17g',NEW."source_agent") ELSE CAST(NEW."source_agent" AS TEXT) || '' END),'source_id',json_object('type',typeof(NEW."source_id"),'value',CASE typeof(NEW."source_id") WHEN 'blob' THEN hex(NEW."source_id") WHEN 'real' THEN printf('%!.17g',NEW."source_id") ELSE CAST(NEW."source_id" AS TEXT) || '' END),'source_title',json_object('type',typeof(NEW."source_title"),'value',CASE typeof(NEW."source_title") WHEN 'blob' THEN hex(NEW."source_title") WHEN 'real' THEN printf('%!.17g',NEW."source_title") ELSE CAST(NEW."source_title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_provenance' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_provenance' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_provenance' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_provenance' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_provenance_peer_sync_update AFTER UPDATE ON "message_provenance"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."kind" IS NOT NEW."kind" OR OLD."message_id" IS NOT NEW."message_id" OR OLD."source_agent" IS NOT NEW."source_agent" OR OLD."source_id" IS NOT NEW."source_id" OR OLD."source_title" IS NOT NEW."source_title")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_provenance',i.peer_key,c.device_id,c.tick,json_object('table','message_provenance','key',i.peer_key,'row',json_object('kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'source_agent',json_object('type',typeof(NEW."source_agent"),'value',CASE typeof(NEW."source_agent") WHEN 'blob' THEN hex(NEW."source_agent") WHEN 'real' THEN printf('%!.17g',NEW."source_agent") ELSE CAST(NEW."source_agent" AS TEXT) || '' END),'source_id',json_object('type',typeof(NEW."source_id"),'value',CASE typeof(NEW."source_id") WHEN 'blob' THEN hex(NEW."source_id") WHEN 'real' THEN printf('%!.17g',NEW."source_id") ELSE CAST(NEW."source_id" AS TEXT) || '' END),'source_title',json_object('type',typeof(NEW."source_title"),'value',CASE typeof(NEW."source_title") WHEN 'blob' THEN hex(NEW."source_title") WHEN 'real' THEN printf('%!.17g',NEW."source_title") ELSE CAST(NEW."source_title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_provenance' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_provenance' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_provenance' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_provenance' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER message_provenance_peer_sync_delete AFTER DELETE ON "message_provenance"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'message_provenance',i.peer_key,c.device_id,c.tick,json_object('table','message_provenance','key',i.peer_key,'row',json_object('message_id',json_object('type',typeof(OLD."message_id"),'value',CASE typeof(OLD."message_id") WHEN 'blob' THEN hex(OLD."message_id") WHEN 'real' THEN printf('%!.17g',OLD."message_id") ELSE CAST(OLD."message_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='message_provenance' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='message_provenance' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='message_provenance' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."message_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='message_provenance' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."message_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_runs_peer_sync_insert AFTER INSERT ON "execution_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_runs',i.peer_key,c.device_id,c.tick,json_object('table','execution_runs','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_runs_peer_sync_update AFTER UPDATE ON "execution_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."id" IS NOT NEW."id" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_runs',i.peer_key,c.device_id,c.tick,json_object('table','execution_runs','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_runs_peer_sync_delete AFTER DELETE ON "execution_runs"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_runs',i.peer_key,c.device_id,c.tick,json_object('table','execution_runs','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_runs' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_runs' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_runs' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_native_history_peer_sync_insert AFTER INSERT ON "execution_native_history"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_native_history',i.peer_key,c.device_id,c.tick,json_object('table','execution_native_history','key',i.peer_key,'row',json_object('byte_count',json_object('type',typeof(NEW."byte_count"),'value',CASE typeof(NEW."byte_count") WHEN 'blob' THEN hex(NEW."byte_count") WHEN 'real' THEN printf('%!.17g',NEW."byte_count") ELSE CAST(NEW."byte_count" AS TEXT) || '' END),'complete',json_object('type',typeof(NEW."complete"),'value',CASE typeof(NEW."complete") WHEN 'blob' THEN hex(NEW."complete") WHEN 'real' THEN printf('%!.17g',NEW."complete") ELSE CAST(NEW."complete" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'format',json_object('type',typeof(NEW."format"),'value',CASE typeof(NEW."format") WHEN 'blob' THEN hex(NEW."format") WHEN 'real' THEN printf('%!.17g',NEW."format") ELSE CAST(NEW."format" AS TEXT) || '' END),'part_count',json_object('type',typeof(NEW."part_count"),'value',CASE typeof(NEW."part_count") WHEN 'blob' THEN hex(NEW."part_count") WHEN 'real' THEN printf('%!.17g',NEW."part_count") ELSE CAST(NEW."part_count" AS TEXT) || '' END),'record_id',json_object('type',typeof(NEW."record_id"),'value',CASE typeof(NEW."record_id") WHEN 'blob' THEN hex(NEW."record_id") WHEN 'real' THEN printf('%!.17g',NEW."record_id") ELSE CAST(NEW."record_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'sha256',json_object('type',typeof(NEW."sha256"),'value',CASE typeof(NEW."sha256") WHEN 'blob' THEN hex(NEW."sha256") WHEN 'real' THEN printf('%!.17g',NEW."sha256") ELSE CAST(NEW."sha256" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_native_history' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_native_history' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_native_history_peer_sync_update AFTER UPDATE ON "execution_native_history"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."byte_count" IS NOT NEW."byte_count" OR OLD."complete" IS NOT NEW."complete" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."format" IS NOT NEW."format" OR OLD."part_count" IS NOT NEW."part_count" OR OLD."record_id" IS NOT NEW."record_id" OR OLD."run_id" IS NOT NEW."run_id" OR OLD."sha256" IS NOT NEW."sha256" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_native_history',i.peer_key,c.device_id,c.tick,json_object('table','execution_native_history','key',i.peer_key,'row',json_object('byte_count',json_object('type',typeof(NEW."byte_count"),'value',CASE typeof(NEW."byte_count") WHEN 'blob' THEN hex(NEW."byte_count") WHEN 'real' THEN printf('%!.17g',NEW."byte_count") ELSE CAST(NEW."byte_count" AS TEXT) || '' END),'complete',json_object('type',typeof(NEW."complete"),'value',CASE typeof(NEW."complete") WHEN 'blob' THEN hex(NEW."complete") WHEN 'real' THEN printf('%!.17g',NEW."complete") ELSE CAST(NEW."complete" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'format',json_object('type',typeof(NEW."format"),'value',CASE typeof(NEW."format") WHEN 'blob' THEN hex(NEW."format") WHEN 'real' THEN printf('%!.17g',NEW."format") ELSE CAST(NEW."format" AS TEXT) || '' END),'part_count',json_object('type',typeof(NEW."part_count"),'value',CASE typeof(NEW."part_count") WHEN 'blob' THEN hex(NEW."part_count") WHEN 'real' THEN printf('%!.17g',NEW."part_count") ELSE CAST(NEW."part_count" AS TEXT) || '' END),'record_id',json_object('type',typeof(NEW."record_id"),'value',CASE typeof(NEW."record_id") WHEN 'blob' THEN hex(NEW."record_id") WHEN 'real' THEN printf('%!.17g',NEW."record_id") ELSE CAST(NEW."record_id" AS TEXT) || '' END),'run_id',json_object('type',typeof(NEW."run_id"),'value',CASE typeof(NEW."run_id") WHEN 'blob' THEN hex(NEW."run_id") WHEN 'real' THEN printf('%!.17g',NEW."run_id") ELSE CAST(NEW."run_id" AS TEXT) || '' END),'sha256',json_object('type',typeof(NEW."sha256"),'value',CASE typeof(NEW."sha256") WHEN 'blob' THEN hex(NEW."sha256") WHEN 'real' THEN printf('%!.17g',NEW."sha256") ELSE CAST(NEW."sha256" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_native_history' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_native_history' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_native_history_peer_sync_delete AFTER DELETE ON "execution_native_history"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_native_history',i.peer_key,c.device_id,c.tick,json_object('table','execution_native_history','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'record_id',json_object('type',typeof(OLD."record_id"),'value',CASE typeof(OLD."record_id") WHEN 'blob' THEN hex(OLD."record_id") WHEN 'real' THEN printf('%!.17g',OLD."record_id") ELSE CAST(OLD."record_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_native_history' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."workspace_id",OLD."record_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_native_history' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."workspace_id",OLD."record_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_native_history_parts_peer_sync_insert AFTER INSERT ON "execution_native_history_parts"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_native_history_parts',i.peer_key,c.device_id,c.tick,json_object('table','execution_native_history_parts','key',i.peer_key,'row',json_object('byte_count',json_object('type',typeof(NEW."byte_count"),'value',CASE typeof(NEW."byte_count") WHEN 'blob' THEN hex(NEW."byte_count") WHEN 'real' THEN printf('%!.17g',NEW."byte_count") ELSE CAST(NEW."byte_count" AS TEXT) || '' END),'part_index',json_object('type',typeof(NEW."part_index"),'value',CASE typeof(NEW."part_index") WHEN 'blob' THEN hex(NEW."part_index") WHEN 'real' THEN printf('%!.17g',NEW."part_index") ELSE CAST(NEW."part_index" AS TEXT) || '' END),'record_id',json_object('type',typeof(NEW."record_id"),'value',CASE typeof(NEW."record_id") WHEN 'blob' THEN hex(NEW."record_id") WHEN 'real' THEN printf('%!.17g',NEW."record_id") ELSE CAST(NEW."record_id" AS TEXT) || '' END),'sha256',json_object('type',typeof(NEW."sha256"),'value',CASE typeof(NEW."sha256") WHEN 'blob' THEN hex(NEW."sha256") WHEN 'real' THEN printf('%!.17g',NEW."sha256") ELSE CAST(NEW."sha256" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history_parts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history_parts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_native_history_parts' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id",NEW."part_index")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_native_history_parts' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id",NEW."part_index")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_native_history_parts_peer_sync_update AFTER UPDATE ON "execution_native_history_parts"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."byte_count" IS NOT NEW."byte_count" OR OLD."part_index" IS NOT NEW."part_index" OR OLD."record_id" IS NOT NEW."record_id" OR OLD."sha256" IS NOT NEW."sha256" OR OLD."workspace_id" IS NOT NEW."workspace_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_native_history_parts',i.peer_key,c.device_id,c.tick,json_object('table','execution_native_history_parts','key',i.peer_key,'row',json_object('byte_count',json_object('type',typeof(NEW."byte_count"),'value',CASE typeof(NEW."byte_count") WHEN 'blob' THEN hex(NEW."byte_count") WHEN 'real' THEN printf('%!.17g',NEW."byte_count") ELSE CAST(NEW."byte_count" AS TEXT) || '' END),'part_index',json_object('type',typeof(NEW."part_index"),'value',CASE typeof(NEW."part_index") WHEN 'blob' THEN hex(NEW."part_index") WHEN 'real' THEN printf('%!.17g',NEW."part_index") ELSE CAST(NEW."part_index" AS TEXT) || '' END),'record_id',json_object('type',typeof(NEW."record_id"),'value',CASE typeof(NEW."record_id") WHEN 'blob' THEN hex(NEW."record_id") WHEN 'real' THEN printf('%!.17g',NEW."record_id") ELSE CAST(NEW."record_id" AS TEXT) || '' END),'sha256',json_object('type',typeof(NEW."sha256"),'value',CASE typeof(NEW."sha256") WHEN 'blob' THEN hex(NEW."sha256") WHEN 'real' THEN printf('%!.17g',NEW."sha256") ELSE CAST(NEW."sha256" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(NEW."workspace_id"),'value',CASE typeof(NEW."workspace_id") WHEN 'blob' THEN hex(NEW."workspace_id") WHEN 'real' THEN printf('%!.17g',NEW."workspace_id") ELSE CAST(NEW."workspace_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history_parts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history_parts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_native_history_parts' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id",NEW."part_index")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_native_history_parts' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."workspace_id",NEW."record_id",NEW."part_index")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER execution_native_history_parts_peer_sync_delete AFTER DELETE ON "execution_native_history_parts"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'execution_native_history_parts',i.peer_key,c.device_id,c.tick,json_object('table','execution_native_history_parts','key',i.peer_key,'row',json_object('part_index',json_object('type',typeof(OLD."part_index"),'value',CASE typeof(OLD."part_index") WHEN 'blob' THEN hex(OLD."part_index") WHEN 'real' THEN printf('%!.17g',OLD."part_index") ELSE CAST(OLD."part_index" AS TEXT) || '' END),'record_id',json_object('type',typeof(OLD."record_id"),'value',CASE typeof(OLD."record_id") WHEN 'blob' THEN hex(OLD."record_id") WHEN 'real' THEN printf('%!.17g',OLD."record_id") ELSE CAST(OLD."record_id" AS TEXT) || '' END),'workspace_id',json_object('type',typeof(OLD."workspace_id"),'value',CASE typeof(OLD."workspace_id") WHEN 'blob' THEN hex(OLD."workspace_id") WHEN 'real' THEN printf('%!.17g',OLD."workspace_id") ELSE CAST(OLD."workspace_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history_parts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='execution_native_history_parts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='execution_native_history_parts' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."workspace_id",OLD."record_id",OLD."part_index")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='execution_native_history_parts' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."workspace_id",OLD."record_id",OLD."part_index")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER saved_artifacts_peer_sync_insert AFTER INSERT ON "saved_artifacts"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'saved_artifacts',i.peer_key,c.device_id,c.tick,json_object('table','saved_artifacts','key',i.peer_key,'row',json_object('id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'manifest',json_object('type',typeof(NEW."manifest"),'value',CASE typeof(NEW."manifest") WHEN 'blob' THEN hex(NEW."manifest") WHEN 'real' THEN printf('%!.17g',NEW."manifest") ELSE CAST(NEW."manifest" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='saved_artifacts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='saved_artifacts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='saved_artifacts' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='saved_artifacts' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER saved_artifacts_peer_sync_update AFTER UPDATE ON "saved_artifacts"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."id" IS NOT NEW."id" OR OLD."manifest" IS NOT NEW."manifest" OR OLD."revision" IS NOT NEW."revision")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'saved_artifacts',i.peer_key,c.device_id,c.tick,json_object('table','saved_artifacts','key',i.peer_key,'row',json_object('id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'manifest',json_object('type',typeof(NEW."manifest"),'value',CASE typeof(NEW."manifest") WHEN 'blob' THEN hex(NEW."manifest") WHEN 'real' THEN printf('%!.17g',NEW."manifest") ELSE CAST(NEW."manifest" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='saved_artifacts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='saved_artifacts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='saved_artifacts' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='saved_artifacts' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER saved_artifacts_peer_sync_delete AFTER DELETE ON "saved_artifacts"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'saved_artifacts',i.peer_key,c.device_id,c.tick,json_object('table','saved_artifacts','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='saved_artifacts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='saved_artifacts' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='saved_artifacts' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='saved_artifacts' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER artifact_uploads_peer_sync_insert AFTER INSERT ON "artifact_uploads"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'artifact_uploads',i.peer_key,c.device_id,c.tick,json_object('table','artifact_uploads','key',i.peer_key,'row',json_object('id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'manifest',json_object('type',typeof(NEW."manifest"),'value',CASE typeof(NEW."manifest") WHEN 'blob' THEN hex(NEW."manifest") WHEN 'real' THEN printf('%!.17g',NEW."manifest") ELSE CAST(NEW."manifest" AS TEXT) || '' END),'next_offset',json_object('type',typeof(NEW."next_offset"),'value',CASE typeof(NEW."next_offset") WHEN 'blob' THEN hex(NEW."next_offset") WHEN 'real' THEN printf('%!.17g',NEW."next_offset") ELSE CAST(NEW."next_offset" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='artifact_uploads' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='artifact_uploads' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='artifact_uploads' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='artifact_uploads' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER artifact_uploads_peer_sync_update AFTER UPDATE ON "artifact_uploads"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."id" IS NOT NEW."id" OR OLD."manifest" IS NOT NEW."manifest" OR OLD."next_offset" IS NOT NEW."next_offset" OR OLD."revision" IS NOT NEW."revision")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'artifact_uploads',i.peer_key,c.device_id,c.tick,json_object('table','artifact_uploads','key',i.peer_key,'row',json_object('id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'manifest',json_object('type',typeof(NEW."manifest"),'value',CASE typeof(NEW."manifest") WHEN 'blob' THEN hex(NEW."manifest") WHEN 'real' THEN printf('%!.17g',NEW."manifest") ELSE CAST(NEW."manifest" AS TEXT) || '' END),'next_offset',json_object('type',typeof(NEW."next_offset"),'value',CASE typeof(NEW."next_offset") WHEN 'blob' THEN hex(NEW."next_offset") WHEN 'real' THEN printf('%!.17g',NEW."next_offset") ELSE CAST(NEW."next_offset" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='artifact_uploads' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='artifact_uploads' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='artifact_uploads' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='artifact_uploads' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER artifact_uploads_peer_sync_delete AFTER DELETE ON "artifact_uploads"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'artifact_uploads',i.peer_key,c.device_id,c.tick,json_object('table','artifact_uploads','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='artifact_uploads' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='artifact_uploads' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='artifact_uploads' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='artifact_uploads' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER artifact_chunks_peer_sync_insert AFTER INSERT ON "artifact_chunks"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'artifact_chunks',i.peer_key,c.device_id,c.tick,json_object('table','artifact_chunks','key',i.peer_key,'row',json_object('artifact_id',json_object('type',typeof(NEW."artifact_id"),'value',CASE typeof(NEW."artifact_id") WHEN 'blob' THEN hex(NEW."artifact_id") WHEN 'real' THEN printf('%!.17g',NEW."artifact_id") ELSE CAST(NEW."artifact_id" AS TEXT) || '' END),'byte_count',json_object('type',typeof(NEW."byte_count"),'value',CASE typeof(NEW."byte_count") WHEN 'blob' THEN hex(NEW."byte_count") WHEN 'real' THEN printf('%!.17g',NEW."byte_count") ELSE CAST(NEW."byte_count" AS TEXT) || '' END),'offset',json_object('type',typeof(NEW."offset"),'value',CASE typeof(NEW."offset") WHEN 'blob' THEN hex(NEW."offset") WHEN 'real' THEN printf('%!.17g',NEW."offset") ELSE CAST(NEW."offset" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'sha256',json_object('type',typeof(NEW."sha256"),'value',CASE typeof(NEW."sha256") WHEN 'blob' THEN hex(NEW."sha256") WHEN 'real' THEN printf('%!.17g',NEW."sha256") ELSE CAST(NEW."sha256" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='artifact_chunks' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='artifact_chunks' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='artifact_chunks' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."artifact_id",NEW."revision",NEW."offset")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='artifact_chunks' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."artifact_id",NEW."revision",NEW."offset")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER artifact_chunks_peer_sync_update AFTER UPDATE ON "artifact_chunks"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."artifact_id" IS NOT NEW."artifact_id" OR OLD."byte_count" IS NOT NEW."byte_count" OR OLD."offset" IS NOT NEW."offset" OR OLD."revision" IS NOT NEW."revision" OR OLD."sha256" IS NOT NEW."sha256")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'artifact_chunks',i.peer_key,c.device_id,c.tick,json_object('table','artifact_chunks','key',i.peer_key,'row',json_object('artifact_id',json_object('type',typeof(NEW."artifact_id"),'value',CASE typeof(NEW."artifact_id") WHEN 'blob' THEN hex(NEW."artifact_id") WHEN 'real' THEN printf('%!.17g',NEW."artifact_id") ELSE CAST(NEW."artifact_id" AS TEXT) || '' END),'byte_count',json_object('type',typeof(NEW."byte_count"),'value',CASE typeof(NEW."byte_count") WHEN 'blob' THEN hex(NEW."byte_count") WHEN 'real' THEN printf('%!.17g',NEW."byte_count") ELSE CAST(NEW."byte_count" AS TEXT) || '' END),'offset',json_object('type',typeof(NEW."offset"),'value',CASE typeof(NEW."offset") WHEN 'blob' THEN hex(NEW."offset") WHEN 'real' THEN printf('%!.17g',NEW."offset") ELSE CAST(NEW."offset" AS TEXT) || '' END),'revision',json_object('type',typeof(NEW."revision"),'value',CASE typeof(NEW."revision") WHEN 'blob' THEN hex(NEW."revision") WHEN 'real' THEN printf('%!.17g',NEW."revision") ELSE CAST(NEW."revision" AS TEXT) || '' END),'sha256',json_object('type',typeof(NEW."sha256"),'value',CASE typeof(NEW."sha256") WHEN 'blob' THEN hex(NEW."sha256") WHEN 'real' THEN printf('%!.17g',NEW."sha256") ELSE CAST(NEW."sha256" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='artifact_chunks' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='artifact_chunks' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='artifact_chunks' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."artifact_id",NEW."revision",NEW."offset")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='artifact_chunks' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."artifact_id",NEW."revision",NEW."offset")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER artifact_chunks_peer_sync_delete AFTER DELETE ON "artifact_chunks"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'artifact_chunks',i.peer_key,c.device_id,c.tick,json_object('table','artifact_chunks','key',i.peer_key,'row',json_object('artifact_id',json_object('type',typeof(OLD."artifact_id"),'value',CASE typeof(OLD."artifact_id") WHEN 'blob' THEN hex(OLD."artifact_id") WHEN 'real' THEN printf('%!.17g',OLD."artifact_id") ELSE CAST(OLD."artifact_id" AS TEXT) || '' END),'offset',json_object('type',typeof(OLD."offset"),'value',CASE typeof(OLD."offset") WHEN 'blob' THEN hex(OLD."offset") WHEN 'real' THEN printf('%!.17g',OLD."offset") ELSE CAST(OLD."offset" AS TEXT) || '' END),'revision',json_object('type',typeof(OLD."revision"),'value',CASE typeof(OLD."revision") WHEN 'blob' THEN hex(OLD."revision") WHEN 'real' THEN printf('%!.17g',OLD."revision") ELSE CAST(OLD."revision" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='artifact_chunks' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='artifact_chunks' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='artifact_chunks' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."artifact_id",OLD."revision",OLD."offset")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='artifact_chunks' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."artifact_id",OLD."revision",OLD."offset")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_messages_peer_sync_insert AFTER INSERT ON "library_messages"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_messages',i.peer_key,c.device_id,c.tick,json_object('table','library_messages','key',i.peer_key,'row',json_object('dirty',json_object('type',typeof(NEW."dirty"),'value',CASE typeof(NEW."dirty") WHEN 'blob' THEN hex(NEW."dirty") WHEN 'real' THEN printf('%!.17g',NEW."dirty") ELSE CAST(NEW."dirty" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_messages' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_messages' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_messages_peer_sync_update AFTER UPDATE ON "library_messages"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."dirty" IS NOT NEW."dirty" OR OLD."message_id" IS NOT NEW."message_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_messages',i.peer_key,c.device_id,c.tick,json_object('table','library_messages','key',i.peer_key,'row',json_object('dirty',json_object('type',typeof(NEW."dirty"),'value',CASE typeof(NEW."dirty") WHEN 'blob' THEN hex(NEW."dirty") WHEN 'real' THEN printf('%!.17g',NEW."dirty") ELSE CAST(NEW."dirty" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_messages' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_messages' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."message_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_messages_peer_sync_delete AFTER DELETE ON "library_messages"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_messages',i.peer_key,c.device_id,c.tick,json_object('table','library_messages','key',i.peer_key,'row',json_object('message_id',json_object('type',typeof(OLD."message_id"),'value',CASE typeof(OLD."message_id") WHEN 'blob' THEN hex(OLD."message_id") WHEN 'real' THEN printf('%!.17g',OLD."message_id") ELSE CAST(OLD."message_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_messages' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_messages' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."message_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_messages' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."message_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_items_peer_sync_insert AFTER INSERT ON "library_items"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_items',i.peer_key,c.device_id,c.tick,json_object('table','library_items','key',i.peer_key,'row',json_object('content_hash',json_object('type',typeof(NEW."content_hash"),'value',CASE typeof(NEW."content_hash") WHEN 'blob' THEN hex(NEW."content_hash") WHEN 'real' THEN printf('%!.17g',NEW."content_hash") ELSE CAST(NEW."content_hash" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'error',json_object('type',typeof(NEW."error"),'value',CASE typeof(NEW."error") WHEN 'blob' THEN hex(NEW."error") WHEN 'real' THEN printf('%!.17g',NEW."error") ELSE CAST(NEW."error" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'mime_type',json_object('type',typeof(NEW."mime_type"),'value',CASE typeof(NEW."mime_type") WHEN 'blob' THEN hex(NEW."mime_type") WHEN 'real' THEN printf('%!.17g',NEW."mime_type") ELSE CAST(NEW."mime_type" AS TEXT) || '' END),'retry_at',json_object('type',typeof(NEW."retry_at"),'value',CASE typeof(NEW."retry_at") WHEN 'blob' THEN hex(NEW."retry_at") WHEN 'real' THEN printf('%!.17g',NEW."retry_at") ELSE CAST(NEW."retry_at" AS TEXT) || '' END),'size_bytes',json_object('type',typeof(NEW."size_bytes"),'value',CASE typeof(NEW."size_bytes") WHEN 'blob' THEN hex(NEW."size_bytes") WHEN 'real' THEN printf('%!.17g',NEW."size_bytes") ELSE CAST(NEW."size_bytes" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'storage',json_object('type',typeof(NEW."storage"),'value',CASE typeof(NEW."storage") WHEN 'blob' THEN hex(NEW."storage") WHEN 'real' THEN printf('%!.17g',NEW."storage") ELSE CAST(NEW."storage" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_items' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_items' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_items_peer_sync_update AFTER UPDATE ON "library_items"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."content_hash" IS NOT NEW."content_hash" OR OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."error" IS NOT NEW."error" OR OLD."id" IS NOT NEW."id" OR OLD."kind" IS NOT NEW."kind" OR OLD."message_id" IS NOT NEW."message_id" OR OLD."mime_type" IS NOT NEW."mime_type" OR OLD."retry_at" IS NOT NEW."retry_at" OR OLD."size_bytes" IS NOT NEW."size_bytes" OR OLD."source" IS NOT NEW."source" OR OLD."storage" IS NOT NEW."storage" OR OLD."title" IS NOT NEW."title")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_items',i.peer_key,c.device_id,c.tick,json_object('table','library_items','key',i.peer_key,'row',json_object('content_hash',json_object('type',typeof(NEW."content_hash"),'value',CASE typeof(NEW."content_hash") WHEN 'blob' THEN hex(NEW."content_hash") WHEN 'real' THEN printf('%!.17g',NEW."content_hash") ELSE CAST(NEW."content_hash" AS TEXT) || '' END),'conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'error',json_object('type',typeof(NEW."error"),'value',CASE typeof(NEW."error") WHEN 'blob' THEN hex(NEW."error") WHEN 'real' THEN printf('%!.17g',NEW."error") ELSE CAST(NEW."error" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'message_id',json_object('type',typeof(NEW."message_id"),'value',CASE typeof(NEW."message_id") WHEN 'blob' THEN hex(NEW."message_id") WHEN 'real' THEN printf('%!.17g',NEW."message_id") ELSE CAST(NEW."message_id" AS TEXT) || '' END),'mime_type',json_object('type',typeof(NEW."mime_type"),'value',CASE typeof(NEW."mime_type") WHEN 'blob' THEN hex(NEW."mime_type") WHEN 'real' THEN printf('%!.17g',NEW."mime_type") ELSE CAST(NEW."mime_type" AS TEXT) || '' END),'retry_at',json_object('type',typeof(NEW."retry_at"),'value',CASE typeof(NEW."retry_at") WHEN 'blob' THEN hex(NEW."retry_at") WHEN 'real' THEN printf('%!.17g',NEW."retry_at") ELSE CAST(NEW."retry_at" AS TEXT) || '' END),'size_bytes',json_object('type',typeof(NEW."size_bytes"),'value',CASE typeof(NEW."size_bytes") WHEN 'blob' THEN hex(NEW."size_bytes") WHEN 'real' THEN printf('%!.17g',NEW."size_bytes") ELSE CAST(NEW."size_bytes" AS TEXT) || '' END),'source',json_object('type',typeof(NEW."source"),'value',CASE typeof(NEW."source") WHEN 'blob' THEN hex(NEW."source") WHEN 'real' THEN printf('%!.17g',NEW."source") ELSE CAST(NEW."source" AS TEXT) || '' END),'storage',json_object('type',typeof(NEW."storage"),'value',CASE typeof(NEW."storage") WHEN 'blob' THEN hex(NEW."storage") WHEN 'real' THEN printf('%!.17g',NEW."storage") ELSE CAST(NEW."storage" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_items' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_items' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_items_peer_sync_delete AFTER DELETE ON "library_items"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_items',i.peer_key,c.device_id,c.tick,json_object('table','library_items','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END),'id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_items' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_items' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_items' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_locations_peer_sync_insert AFTER INSERT ON "library_locations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_locations',i.peer_key,c.device_id,c.tick,json_object('table','library_locations','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'root',json_object('type',typeof(NEW."root"),'value',CASE typeof(NEW."root") WHEN 'blob' THEN hex(NEW."root") WHEN 'real' THEN printf('%!.17g',NEW."root") ELSE CAST(NEW."root" AS TEXT) || '' END),'workspace_name',json_object('type',typeof(NEW."workspace_name"),'value',CASE typeof(NEW."workspace_name") WHEN 'blob' THEN hex(NEW."workspace_name") WHEN 'real' THEN printf('%!.17g',NEW."workspace_name") ELSE CAST(NEW."workspace_name" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_locations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_locations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_locations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_locations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_locations_peer_sync_update AFTER UPDATE ON "library_locations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."conversation_id" IS NOT NEW."conversation_id" OR OLD."root" IS NOT NEW."root" OR OLD."workspace_name" IS NOT NEW."workspace_name")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_locations',i.peer_key,c.device_id,c.tick,json_object('table','library_locations','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(NEW."conversation_id"),'value',CASE typeof(NEW."conversation_id") WHEN 'blob' THEN hex(NEW."conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."conversation_id") ELSE CAST(NEW."conversation_id" AS TEXT) || '' END),'root',json_object('type',typeof(NEW."root"),'value',CASE typeof(NEW."root") WHEN 'blob' THEN hex(NEW."root") WHEN 'real' THEN printf('%!.17g',NEW."root") ELSE CAST(NEW."root" AS TEXT) || '' END),'workspace_name',json_object('type',typeof(NEW."workspace_name"),'value',CASE typeof(NEW."workspace_name") WHEN 'blob' THEN hex(NEW."workspace_name") WHEN 'real' THEN printf('%!.17g',NEW."workspace_name") ELSE CAST(NEW."workspace_name" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_locations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_locations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_locations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_locations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_locations_peer_sync_delete AFTER DELETE ON "library_locations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_locations',i.peer_key,c.device_id,c.tick,json_object('table','library_locations','key',i.peer_key,'row',json_object('conversation_id',json_object('type',typeof(OLD."conversation_id"),'value',CASE typeof(OLD."conversation_id") WHEN 'blob' THEN hex(OLD."conversation_id") WHEN 'real' THEN printf('%!.17g',OLD."conversation_id") ELSE CAST(OLD."conversation_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_locations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_locations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_locations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_locations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."conversation_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER mac_routes_peer_sync_insert AFTER INSERT ON "mac_routes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'mac_routes',i.peer_key,c.device_id,c.tick,json_object('table','mac_routes','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'endpoint',json_object('type',typeof(NEW."endpoint"),'value',CASE typeof(NEW."endpoint") WHEN 'blob' THEN hex(NEW."endpoint") WHEN 'real' THEN printf('%!.17g',NEW."endpoint") ELSE CAST(NEW."endpoint" AS TEXT) || '' END),'library_id',json_object('type',typeof(NEW."library_id"),'value',CASE typeof(NEW."library_id") WHEN 'blob' THEN hex(NEW."library_id") WHEN 'real' THEN printf('%!.17g',NEW."library_id") ELSE CAST(NEW."library_id" AS TEXT) || '' END),'name',json_object('type',typeof(NEW."name"),'value',CASE typeof(NEW."name") WHEN 'blob' THEN hex(NEW."name") WHEN 'real' THEN printf('%!.17g',NEW."name") ELSE CAST(NEW."name" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='mac_routes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='mac_routes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='mac_routes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='mac_routes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER mac_routes_peer_sync_update AFTER UPDATE ON "mac_routes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."endpoint" IS NOT NEW."endpoint" OR OLD."library_id" IS NOT NEW."library_id" OR OLD."name" IS NOT NEW."name")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'mac_routes',i.peer_key,c.device_id,c.tick,json_object('table','mac_routes','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'endpoint',json_object('type',typeof(NEW."endpoint"),'value',CASE typeof(NEW."endpoint") WHEN 'blob' THEN hex(NEW."endpoint") WHEN 'real' THEN printf('%!.17g',NEW."endpoint") ELSE CAST(NEW."endpoint" AS TEXT) || '' END),'library_id',json_object('type',typeof(NEW."library_id"),'value',CASE typeof(NEW."library_id") WHEN 'blob' THEN hex(NEW."library_id") WHEN 'real' THEN printf('%!.17g',NEW."library_id") ELSE CAST(NEW."library_id" AS TEXT) || '' END),'name',json_object('type',typeof(NEW."name"),'value',CASE typeof(NEW."name") WHEN 'blob' THEN hex(NEW."name") WHEN 'real' THEN printf('%!.17g',NEW."name") ELSE CAST(NEW."name" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='mac_routes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='mac_routes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='mac_routes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='mac_routes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER mac_routes_peer_sync_delete AFTER DELETE ON "mac_routes"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'mac_routes',i.peer_key,c.device_id,c.tick,json_object('table','mac_routes','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='mac_routes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='mac_routes' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='mac_routes' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='mac_routes' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER remote_workspace_configurations_peer_sync_insert AFTER INSERT ON "remote_workspace_configurations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'remote_workspace_configurations',i.peer_key,c.device_id,c.tick,json_object('table','remote_workspace_configurations','key',i.peer_key,'row',json_object('configuration',json_object('type',typeof(NEW."configuration"),'value',CASE typeof(NEW."configuration") WHEN 'blob' THEN hex(NEW."configuration") WHEN 'real' THEN printf('%!.17g',NEW."configuration") ELSE CAST(NEW."configuration" AS TEXT) || '' END),'deleted',json_object('type',typeof(NEW."deleted"),'value',CASE typeof(NEW."deleted") WHEN 'blob' THEN hex(NEW."deleted") WHEN 'real' THEN printf('%!.17g',NEW."deleted") ELSE CAST(NEW."deleted" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(NEW."owner_device_id"),'value',CASE typeof(NEW."owner_device_id") WHEN 'blob' THEN hex(NEW."owner_device_id") WHEN 'real' THEN printf('%!.17g',NEW."owner_device_id") ELSE CAST(NEW."owner_device_id" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted"<>0 THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='remote_workspace_configurations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='remote_workspace_configurations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='remote_workspace_configurations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='remote_workspace_configurations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER remote_workspace_configurations_peer_sync_update AFTER UPDATE ON "remote_workspace_configurations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."configuration" IS NOT NEW."configuration" OR OLD."deleted" IS NOT NEW."deleted" OR OLD."id" IS NOT NEW."id" OR OLD."owner_device_id" IS NOT NEW."owner_device_id")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'remote_workspace_configurations',i.peer_key,c.device_id,c.tick,json_object('table','remote_workspace_configurations','key',i.peer_key,'row',json_object('configuration',json_object('type',typeof(NEW."configuration"),'value',CASE typeof(NEW."configuration") WHEN 'blob' THEN hex(NEW."configuration") WHEN 'real' THEN printf('%!.17g',NEW."configuration") ELSE CAST(NEW."configuration" AS TEXT) || '' END),'deleted',json_object('type',typeof(NEW."deleted"),'value',CASE typeof(NEW."deleted") WHEN 'blob' THEN hex(NEW."deleted") WHEN 'real' THEN printf('%!.17g',NEW."deleted") ELSE CAST(NEW."deleted" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(NEW."owner_device_id"),'value',CASE typeof(NEW."owner_device_id") WHEN 'blob' THEN hex(NEW."owner_device_id") WHEN 'real' THEN printf('%!.17g',NEW."owner_device_id") ELSE CAST(NEW."owner_device_id" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted"<>0 THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='remote_workspace_configurations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='remote_workspace_configurations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='remote_workspace_configurations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='remote_workspace_configurations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER remote_workspace_configurations_peer_sync_delete AFTER DELETE ON "remote_workspace_configurations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'remote_workspace_configurations',i.peer_key,c.device_id,c.tick,json_object('table','remote_workspace_configurations','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END),'owner_device_id',json_object('type',typeof(OLD."owner_device_id"),'value',CASE typeof(OLD."owner_device_id") WHEN 'blob' THEN hex(OLD."owner_device_id") WHEN 'real' THEN printf('%!.17g',OLD."owner_device_id") ELSE CAST(OLD."owner_device_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='remote_workspace_configurations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='remote_workspace_configurations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='remote_workspace_configurations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='remote_workspace_configurations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_members_peer_sync_insert AFTER INSERT ON "library_members"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_members',i.peer_key,c.device_id,c.tick,json_object('table','library_members','key',i.peer_key,'row',json_object('added_at',json_object('type',typeof(NEW."added_at"),'value',CASE typeof(NEW."added_at") WHEN 'blob' THEN hex(NEW."added_at") WHEN 'real' THEN printf('%!.17g',NEW."added_at") ELSE CAST(NEW."added_at" AS TEXT) || '' END),'added_by',json_object('type',typeof(NEW."added_by"),'value',CASE typeof(NEW."added_by") WHEN 'blob' THEN hex(NEW."added_by") WHEN 'real' THEN printf('%!.17g',NEW."added_by") ELSE CAST(NEW."added_by" AS TEXT) || '' END),'device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_members' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_members' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_members' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."device_id",NEW."added_by")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_members' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."device_id",NEW."added_by")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_members_peer_sync_update AFTER UPDATE ON "library_members"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."added_at" IS NOT NEW."added_at" OR OLD."added_by" IS NOT NEW."added_by" OR OLD."device_id" IS NOT NEW."device_id" OR OLD."payload" IS NOT NEW."payload")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_members',i.peer_key,c.device_id,c.tick,json_object('table','library_members','key',i.peer_key,'row',json_object('added_at',json_object('type',typeof(NEW."added_at"),'value',CASE typeof(NEW."added_at") WHEN 'blob' THEN hex(NEW."added_at") WHEN 'real' THEN printf('%!.17g',NEW."added_at") ELSE CAST(NEW."added_at" AS TEXT) || '' END),'added_by',json_object('type',typeof(NEW."added_by"),'value',CASE typeof(NEW."added_by") WHEN 'blob' THEN hex(NEW."added_by") WHEN 'real' THEN printf('%!.17g',NEW."added_by") ELSE CAST(NEW."added_by" AS TEXT) || '' END),'device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_members' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_members' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_members' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."device_id",NEW."added_by")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_members' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."device_id",NEW."added_by")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_members_peer_sync_delete AFTER DELETE ON "library_members"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_members',i.peer_key,c.device_id,c.tick,json_object('table','library_members','key',i.peer_key,'row',json_object('added_by',json_object('type',typeof(OLD."added_by"),'value',CASE typeof(OLD."added_by") WHEN 'blob' THEN hex(OLD."added_by") WHEN 'real' THEN printf('%!.17g',OLD."added_by") ELSE CAST(OLD."added_by" AS TEXT) || '' END),'device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_members' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_members' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_members' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."device_id",OLD."added_by")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_members' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."device_id",OLD."added_by")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_member_revocations_peer_sync_insert AFTER INSERT ON "library_member_revocations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_member_revocations',i.peer_key,c.device_id,c.tick,json_object('table','library_member_revocations','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_member_revocations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_member_revocations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_member_revocations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_member_revocations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_member_revocations_peer_sync_update AFTER UPDATE ON "library_member_revocations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."event_id" IS NOT NEW."event_id" OR OLD."payload" IS NOT NEW."payload")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_member_revocations',i.peer_key,c.device_id,c.tick,json_object('table','library_member_revocations','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(NEW."event_id"),'value',CASE typeof(NEW."event_id") WHEN 'blob' THEN hex(NEW."event_id") WHEN 'real' THEN printf('%!.17g',NEW."event_id") ELSE CAST(NEW."event_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_member_revocations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_member_revocations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_member_revocations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_member_revocations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER library_member_revocations_peer_sync_delete AFTER DELETE ON "library_member_revocations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'library_member_revocations',i.peer_key,c.device_id,c.tick,json_object('table','library_member_revocations','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END),'event_id',json_object('type',typeof(OLD."event_id"),'value',CASE typeof(OLD."event_id") WHEN 'blob' THEN hex(OLD."event_id") WHEN 'real' THEN printf('%!.17g',OLD."event_id") ELSE CAST(OLD."event_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='library_member_revocations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='library_member_revocations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='library_member_revocations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='library_member_revocations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."event_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER bot_conversations_peer_sync_insert AFTER INSERT ON "bot_conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'bot_conversations',i.peer_key,c.device_id,c.tick,json_object('table','bot_conversations','key',i.peer_key,'row',json_object('bot_id',json_object('type',typeof(NEW."bot_id"),'value',CASE typeof(NEW."bot_id") WHEN 'blob' THEN hex(NEW."bot_id") WHEN 'real' THEN printf('%!.17g',NEW."bot_id") ELSE CAST(NEW."bot_id" AS TEXT) || '' END),'bot_name',json_object('type',typeof(NEW."bot_name"),'value',CASE typeof(NEW."bot_name") WHEN 'blob' THEN hex(NEW."bot_name") WHEN 'real' THEN printf('%!.17g',NEW."bot_name") ELSE CAST(NEW."bot_name" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'forked_at_entry_id',json_object('type',typeof(NEW."forked_at_entry_id"),'value',CASE typeof(NEW."forked_at_entry_id") WHEN 'blob' THEN hex(NEW."forked_at_entry_id") WHEN 'real' THEN printf('%!.17g',NEW."forked_at_entry_id") ELSE CAST(NEW."forked_at_entry_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'machine_id',json_object('type',typeof(NEW."machine_id"),'value',CASE typeof(NEW."machine_id") WHEN 'blob' THEN hex(NEW."machine_id") WHEN 'real' THEN printf('%!.17g',NEW."machine_id") ELSE CAST(NEW."machine_id" AS TEXT) || '' END),'parent_runtime_conversation_id',json_object('type',typeof(NEW."parent_runtime_conversation_id"),'value',CASE typeof(NEW."parent_runtime_conversation_id") WHEN 'blob' THEN hex(NEW."parent_runtime_conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."parent_runtime_conversation_id") ELSE CAST(NEW."parent_runtime_conversation_id" AS TEXT) || '' END),'runtime_conversation_id',json_object('type',typeof(NEW."runtime_conversation_id"),'value',CASE typeof(NEW."runtime_conversation_id") WHEN 'blob' THEN hex(NEW."runtime_conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."runtime_conversation_id") ELSE CAST(NEW."runtime_conversation_id" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='bot_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='bot_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='bot_conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='bot_conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER bot_conversations_peer_sync_update AFTER UPDATE ON "bot_conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."bot_id" IS NOT NEW."bot_id" OR OLD."bot_name" IS NOT NEW."bot_name" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."deleted_at" IS NOT NEW."deleted_at" OR OLD."forked_at_entry_id" IS NOT NEW."forked_at_entry_id" OR OLD."id" IS NOT NEW."id" OR OLD."is_pinned" IS NOT NEW."is_pinned" OR OLD."kind" IS NOT NEW."kind" OR OLD."machine_id" IS NOT NEW."machine_id" OR OLD."parent_runtime_conversation_id" IS NOT NEW."parent_runtime_conversation_id" OR OLD."runtime_conversation_id" IS NOT NEW."runtime_conversation_id" OR OLD."title" IS NOT NEW."title" OR OLD."updated_at" IS NOT NEW."updated_at")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'bot_conversations',i.peer_key,c.device_id,c.tick,json_object('table','bot_conversations','key',i.peer_key,'row',json_object('bot_id',json_object('type',typeof(NEW."bot_id"),'value',CASE typeof(NEW."bot_id") WHEN 'blob' THEN hex(NEW."bot_id") WHEN 'real' THEN printf('%!.17g',NEW."bot_id") ELSE CAST(NEW."bot_id" AS TEXT) || '' END),'bot_name',json_object('type',typeof(NEW."bot_name"),'value',CASE typeof(NEW."bot_name") WHEN 'blob' THEN hex(NEW."bot_name") WHEN 'real' THEN printf('%!.17g',NEW."bot_name") ELSE CAST(NEW."bot_name" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'deleted_at',json_object('type',typeof(NEW."deleted_at"),'value',CASE typeof(NEW."deleted_at") WHEN 'blob' THEN hex(NEW."deleted_at") WHEN 'real' THEN printf('%!.17g',NEW."deleted_at") ELSE CAST(NEW."deleted_at" AS TEXT) || '' END),'forked_at_entry_id',json_object('type',typeof(NEW."forked_at_entry_id"),'value',CASE typeof(NEW."forked_at_entry_id") WHEN 'blob' THEN hex(NEW."forked_at_entry_id") WHEN 'real' THEN printf('%!.17g',NEW."forked_at_entry_id") ELSE CAST(NEW."forked_at_entry_id" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'is_pinned',json_object('type',typeof(NEW."is_pinned"),'value',CASE typeof(NEW."is_pinned") WHEN 'blob' THEN hex(NEW."is_pinned") WHEN 'real' THEN printf('%!.17g',NEW."is_pinned") ELSE CAST(NEW."is_pinned" AS TEXT) || '' END),'kind',json_object('type',typeof(NEW."kind"),'value',CASE typeof(NEW."kind") WHEN 'blob' THEN hex(NEW."kind") WHEN 'real' THEN printf('%!.17g',NEW."kind") ELSE CAST(NEW."kind" AS TEXT) || '' END),'machine_id',json_object('type',typeof(NEW."machine_id"),'value',CASE typeof(NEW."machine_id") WHEN 'blob' THEN hex(NEW."machine_id") WHEN 'real' THEN printf('%!.17g',NEW."machine_id") ELSE CAST(NEW."machine_id" AS TEXT) || '' END),'parent_runtime_conversation_id',json_object('type',typeof(NEW."parent_runtime_conversation_id"),'value',CASE typeof(NEW."parent_runtime_conversation_id") WHEN 'blob' THEN hex(NEW."parent_runtime_conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."parent_runtime_conversation_id") ELSE CAST(NEW."parent_runtime_conversation_id" AS TEXT) || '' END),'runtime_conversation_id',json_object('type',typeof(NEW."runtime_conversation_id"),'value',CASE typeof(NEW."runtime_conversation_id") WHEN 'blob' THEN hex(NEW."runtime_conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."runtime_conversation_id") ELSE CAST(NEW."runtime_conversation_id" AS TEXT) || '' END),'title',json_object('type',typeof(NEW."title"),'value',CASE typeof(NEW."title") WHEN 'blob' THEN hex(NEW."title") WHEN 'real' THEN printf('%!.17g',NEW."title") ELSE CAST(NEW."title" AS TEXT) || '' END),'updated_at',json_object('type',typeof(NEW."updated_at"),'value',CASE typeof(NEW."updated_at") WHEN 'blob' THEN hex(NEW."updated_at") WHEN 'real' THEN printf('%!.17g',NEW."updated_at") ELSE CAST(NEW."updated_at" AS TEXT) || '' END)),'deleted',json(CASE WHEN NEW."deleted_at" IS NOT NULL THEN 'true' ELSE 'false' END),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='bot_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='bot_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='bot_conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='bot_conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER bot_conversations_peer_sync_delete AFTER DELETE ON "bot_conversations"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'bot_conversations',i.peer_key,c.device_id,c.tick,json_object('table','bot_conversations','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='bot_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='bot_conversations' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='bot_conversations' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='bot_conversations' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER bot_conversation_entries_peer_sync_insert AFTER INSERT ON "bot_conversation_entries"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'bot_conversation_entries',i.peer_key,c.device_id,c.tick,json_object('table','bot_conversation_entries','key',i.peer_key,'row',json_object('bot_conversation_id',json_object('type',typeof(NEW."bot_conversation_id"),'value',CASE typeof(NEW."bot_conversation_id") WHEN 'blob' THEN hex(NEW."bot_conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."bot_conversation_id") ELSE CAST(NEW."bot_conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'entry_id',json_object('type',typeof(NEW."entry_id"),'value',CASE typeof(NEW."entry_id") WHEN 'blob' THEN hex(NEW."entry_id") WHEN 'real' THEN printf('%!.17g',NEW."entry_id") ELSE CAST(NEW."entry_id" AS TEXT) || '' END),'error',json_object('type',typeof(NEW."error"),'value',CASE typeof(NEW."error") WHEN 'blob' THEN hex(NEW."error") WHEN 'real' THEN printf('%!.17g',NEW."error") ELSE CAST(NEW."error" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'role',json_object('type',typeof(NEW."role"),'value',CASE typeof(NEW."role") WHEN 'blob' THEN hex(NEW."role") WHEN 'real' THEN printf('%!.17g',NEW."role") ELSE CAST(NEW."role" AS TEXT) || '' END),'stopped',json_object('type',typeof(NEW."stopped"),'value',CASE typeof(NEW."stopped") WHEN 'blob' THEN hex(NEW."stopped") WHEN 'real' THEN printf('%!.17g',NEW."stopped") ELSE CAST(NEW."stopped" AS TEXT) || '' END),'text',json_object('type',typeof(NEW."text"),'value',CASE typeof(NEW."text") WHEN 'blob' THEN hex(NEW."text") WHEN 'real' THEN printf('%!.17g',NEW."text") ELSE CAST(NEW."text" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='bot_conversation_entries' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='bot_conversation_entries' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='bot_conversation_entries' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='bot_conversation_entries' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER bot_conversation_entries_peer_sync_update AFTER UPDATE ON "bot_conversation_entries"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."bot_conversation_id" IS NOT NEW."bot_conversation_id" OR OLD."created_at" IS NOT NEW."created_at" OR OLD."entry_id" IS NOT NEW."entry_id" OR OLD."error" IS NOT NEW."error" OR OLD."id" IS NOT NEW."id" OR OLD."role" IS NOT NEW."role" OR OLD."stopped" IS NOT NEW."stopped" OR OLD."text" IS NOT NEW."text")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'bot_conversation_entries',i.peer_key,c.device_id,c.tick,json_object('table','bot_conversation_entries','key',i.peer_key,'row',json_object('bot_conversation_id',json_object('type',typeof(NEW."bot_conversation_id"),'value',CASE typeof(NEW."bot_conversation_id") WHEN 'blob' THEN hex(NEW."bot_conversation_id") WHEN 'real' THEN printf('%!.17g',NEW."bot_conversation_id") ELSE CAST(NEW."bot_conversation_id" AS TEXT) || '' END),'created_at',json_object('type',typeof(NEW."created_at"),'value',CASE typeof(NEW."created_at") WHEN 'blob' THEN hex(NEW."created_at") WHEN 'real' THEN printf('%!.17g',NEW."created_at") ELSE CAST(NEW."created_at" AS TEXT) || '' END),'entry_id',json_object('type',typeof(NEW."entry_id"),'value',CASE typeof(NEW."entry_id") WHEN 'blob' THEN hex(NEW."entry_id") WHEN 'real' THEN printf('%!.17g',NEW."entry_id") ELSE CAST(NEW."entry_id" AS TEXT) || '' END),'error',json_object('type',typeof(NEW."error"),'value',CASE typeof(NEW."error") WHEN 'blob' THEN hex(NEW."error") WHEN 'real' THEN printf('%!.17g',NEW."error") ELSE CAST(NEW."error" AS TEXT) || '' END),'id',json_object('type',typeof(NEW."id"),'value',CASE typeof(NEW."id") WHEN 'blob' THEN hex(NEW."id") WHEN 'real' THEN printf('%!.17g',NEW."id") ELSE CAST(NEW."id" AS TEXT) || '' END),'role',json_object('type',typeof(NEW."role"),'value',CASE typeof(NEW."role") WHEN 'blob' THEN hex(NEW."role") WHEN 'real' THEN printf('%!.17g',NEW."role") ELSE CAST(NEW."role" AS TEXT) || '' END),'stopped',json_object('type',typeof(NEW."stopped"),'value',CASE typeof(NEW."stopped") WHEN 'blob' THEN hex(NEW."stopped") WHEN 'real' THEN printf('%!.17g',NEW."stopped") ELSE CAST(NEW."stopped" AS TEXT) || '' END),'text',json_object('type',typeof(NEW."text"),'value',CASE typeof(NEW."text") WHEN 'blob' THEN hex(NEW."text") WHEN 'real' THEN printf('%!.17g',NEW."text") ELSE CAST(NEW."text" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='bot_conversation_entries' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='bot_conversation_entries' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='bot_conversation_entries' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='bot_conversation_entries' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER bot_conversation_entries_peer_sync_delete AFTER DELETE ON "bot_conversation_entries"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'bot_conversation_entries',i.peer_key,c.device_id,c.tick,json_object('table','bot_conversation_entries','key',i.peer_key,'row',json_object('id',json_object('type',typeof(OLD."id"),'value',CASE typeof(OLD."id") WHEN 'blob' THEN hex(OLD."id") WHEN 'real' THEN printf('%!.17g',OLD."id") ELSE CAST(OLD."id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='bot_conversation_entries' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='bot_conversation_entries' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='bot_conversation_entries' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='bot_conversation_entries' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER product_analytics_preference_peer_sync_insert AFTER INSERT ON "product_analytics_preference"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'product_analytics_preference',i.peer_key,c.device_id,c.tick,json_object('table','product_analytics_preference','key',i.peer_key,'row',json_object('payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'singleton',json_object('type',typeof(NEW."singleton"),'value',CASE typeof(NEW."singleton") WHEN 'blob' THEN hex(NEW."singleton") WHEN 'real' THEN printf('%!.17g',NEW."singleton") ELSE CAST(NEW."singleton" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='product_analytics_preference' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='product_analytics_preference' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='product_analytics_preference' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='product_analytics_preference' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER product_analytics_preference_peer_sync_update AFTER UPDATE ON "product_analytics_preference"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."payload" IS NOT NEW."payload" OR OLD."singleton" IS NOT NEW."singleton")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'product_analytics_preference',i.peer_key,c.device_id,c.tick,json_object('table','product_analytics_preference','key',i.peer_key,'row',json_object('payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'singleton',json_object('type',typeof(NEW."singleton"),'value',CASE typeof(NEW."singleton") WHEN 'blob' THEN hex(NEW."singleton") WHEN 'real' THEN printf('%!.17g',NEW."singleton") ELSE CAST(NEW."singleton" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='product_analytics_preference' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='product_analytics_preference' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='product_analytics_preference' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='product_analytics_preference' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER product_analytics_preference_peer_sync_delete AFTER DELETE ON "product_analytics_preference"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'product_analytics_preference',i.peer_key,c.device_id,c.tick,json_object('table','product_analytics_preference','key',i.peer_key,'row',json_object('singleton',json_object('type',typeof(OLD."singleton"),'value',CASE typeof(OLD."singleton") WHEN 'blob' THEN hex(OLD."singleton") WHEN 'real' THEN printf('%!.17g',OLD."singleton") ELSE CAST(OLD."singleton" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='product_analytics_preference' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='product_analytics_preference' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='product_analytics_preference' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."singleton")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='product_analytics_preference' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."singleton")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER github_identity_peer_sync_insert AFTER INSERT ON "github_identity"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'github_identity',i.peer_key,c.device_id,c.tick,json_object('table','github_identity','key',i.peer_key,'row',json_object('payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'singleton',json_object('type',typeof(NEW."singleton"),'value',CASE typeof(NEW."singleton") WHEN 'blob' THEN hex(NEW."singleton") WHEN 'real' THEN printf('%!.17g',NEW."singleton") ELSE CAST(NEW."singleton" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='github_identity' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='github_identity' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='github_identity' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='github_identity' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER github_identity_peer_sync_update AFTER UPDATE ON "github_identity"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."payload" IS NOT NEW."payload" OR OLD."singleton" IS NOT NEW."singleton")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'github_identity',i.peer_key,c.device_id,c.tick,json_object('table','github_identity','key',i.peer_key,'row',json_object('payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END),'singleton',json_object('type',typeof(NEW."singleton"),'value',CASE typeof(NEW."singleton") WHEN 'blob' THEN hex(NEW."singleton") WHEN 'real' THEN printf('%!.17g',NEW."singleton") ELSE CAST(NEW."singleton" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='github_identity' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='github_identity' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='github_identity' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='github_identity' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."singleton")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER github_identity_peer_sync_delete AFTER DELETE ON "github_identity"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'github_identity',i.peer_key,c.device_id,c.tick,json_object('table','github_identity','key',i.peer_key,'row',json_object('singleton',json_object('type',typeof(OLD."singleton"),'value',CASE typeof(OLD."singleton") WHEN 'blob' THEN hex(OLD."singleton") WHEN 'real' THEN printf('%!.17g',OLD."singleton") ELSE CAST(OLD."singleton" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='github_identity' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='github_identity' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='github_identity' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."singleton")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='github_identity' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."singleton")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER github_identity_recipients_peer_sync_insert AFTER INSERT ON "github_identity_recipients"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'github_identity_recipients',i.peer_key,c.device_id,c.tick,json_object('table','github_identity_recipients','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='github_identity_recipients' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='github_identity_recipients' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='github_identity_recipients' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='github_identity_recipients' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER github_identity_recipients_peer_sync_update AFTER UPDATE ON "github_identity_recipients"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 AND (OLD."device_id" IS NOT NEW."device_id" OR OLD."payload" IS NOT NEW."payload")
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'github_identity_recipients',i.peer_key,c.device_id,c.tick,json_object('table','github_identity_recipients','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(NEW."device_id"),'value',CASE typeof(NEW."device_id") WHEN 'blob' THEN hex(NEW."device_id") WHEN 'real' THEN printf('%!.17g',NEW."device_id") ELSE CAST(NEW."device_id" AS TEXT) || '' END),'payload',json_object('type',typeof(NEW."payload"),'value',CASE typeof(NEW."payload") WHEN 'blob' THEN hex(NEW."payload") WHEN 'real' THEN printf('%!.17g',NEW."payload") ELSE CAST(NEW."payload" AS TEXT) || '' END)),'deleted',json('false'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='github_identity_recipients' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='github_identity_recipients' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='github_identity_recipients' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='github_identity_recipients' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(NEW."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER github_identity_recipients_peer_sync_delete AFTER DELETE ON "github_identity_recipients"
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
BEGIN
  UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
  INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
SELECT 'github_identity_recipients',i.peer_key,c.device_id,c.tick,json_object('table','github_identity_recipients','key',i.peer_key,'row',json_object('device_id',json_object('type',typeof(OLD."device_id"),'value',CASE typeof(OLD."device_id") WHEN 'blob' THEN hex(OLD."device_id") WHEN 'real' THEN printf('%!.17g',OLD."device_id") ELSE CAST(OLD."device_id" AS TEXT) || '' END)),'deleted',json('true'),'clock',c.tick,'origin',c.device_id,'vector',json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE w.table_name='github_identity_recipients' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL) THEN c.vector
  ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE((SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE w.table_name='github_identity_recipients' AND w.record_key=i.peer_key AND w.pending_peer IS NOT NULL AND w.origin=v.key AND w.clock>(SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
  WHERE a.table_name='github_identity_recipients' AND a.record_key=i.peer_key AND a.pending_peer IS NULL)),v.value)) AS value
    FROM json_each(c.vector) v) WHERE value>0) END)) FROM peer_sync_clock c,(SELECT printf('%s',json_array(OLD."device_id")) AS peer_key) i;
  DELETE FROM peer_sync_versions WHERE table_name='github_identity_recipients' AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM (SELECT printf('%s',json_array(OLD."device_id")) AS peer_key) i)
  AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock));
END;
CREATE TRIGGER conversations_execution_stream_insert AFTER INSERT ON conversations
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.id, 'conversation', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER conversations_execution_stream_update AFTER UPDATE ON conversations
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.id, 'conversation', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER conversations_execution_stream_delete AFTER DELETE ON conversations
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = OLD.id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.id, 'conversation', OLD.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER harness_sessions_execution_stream_insert AFTER INSERT ON harness_sessions
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'conversation', NEW.conversation_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER harness_sessions_execution_stream_update AFTER UPDATE ON harness_sessions
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'conversation', NEW.conversation_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER harness_sessions_execution_stream_delete AFTER DELETE ON harness_sessions
WHEN OLD.remote_workspace_id IS NULL AND NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), ''))
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.conversation_id, 'conversation', OLD.conversation_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER messages_execution_stream_insert AFTER INSERT ON messages
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'message', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER messages_execution_stream_update AFTER UPDATE ON messages
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'message', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER messages_execution_stream_delete AFTER DELETE ON messages
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = OLD.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.conversation_id, 'message', OLD.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER runs_execution_stream_insert AFTER INSERT ON runs
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'run', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER runs_execution_stream_update AFTER UPDATE ON runs
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'run', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER runs_execution_stream_delete AFTER DELETE ON runs
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = OLD.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.conversation_id, 'run', OLD.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER run_activities_execution_stream_insert AFTER INSERT ON run_activities
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'run_event', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER run_activities_execution_stream_update AFTER UPDATE ON run_activities
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.conversation_id, 'run_event', NEW.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER run_activities_execution_stream_delete AFTER DELETE ON run_activities
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.conversation_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.conversation_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = OLD.conversation_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.conversation_id, 'run_event', OLD.id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER session_goals_execution_stream_insert AFTER INSERT ON session_goals
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.session_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.session_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.session_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.session_id, 'session', NEW.session_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER session_goals_execution_stream_update AFTER UPDATE ON session_goals
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.session_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.session_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.session_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.session_id, 'session', NEW.session_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER session_goals_execution_stream_delete AFTER DELETE ON session_goals
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.session_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.session_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = OLD.session_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.session_id, 'session', OLD.session_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER session_tools_execution_stream_insert AFTER INSERT ON session_tools
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.session_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.session_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.session_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.session_id, 'session', NEW.session_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER session_tools_execution_stream_update AFTER UPDATE ON session_tools
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = NEW.session_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = NEW.session_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = NEW.session_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (NEW.session_id, 'session', NEW.session_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER session_tools_execution_stream_delete AFTER DELETE ON session_tools
WHEN NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = OLD.session_id AND f.deleted = 0) AND NOT EXISTS (SELECT 1 FROM conversation_owners o WHERE o.id = OLD.session_id AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), '')) AND EXISTS (SELECT 1 FROM harness_sessions s WHERE s.conversation_id = OLD.session_id AND s.remote_workspace_id IS NULL)
BEGIN
  INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
  VALUES (OLD.session_id, 'session', OLD.session_id);
  DELETE FROM execution_stream_changes WHERE sequence <=
    (SELECT MAX(sequence) FROM execution_stream_changes) - 10000;
END;
CREATE TRIGGER calendar_items_device_sync_wake_insert
AFTER INSERT ON calendar_items
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_items_device_sync_wake_update
AFTER UPDATE ON calendar_items
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_items_device_sync_wake_delete
AFTER DELETE ON calendar_items
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(OLD.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_task_executors_device_sync_wake_insert
AFTER INSERT ON calendar_task_executors
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(NEW.event_id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_task_executors_device_sync_wake_update
AFTER UPDATE ON calendar_task_executors
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(NEW.event_id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_task_executors_device_sync_wake_delete
AFTER DELETE ON calendar_task_executors
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(OLD.event_id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_published_runs_device_sync_wake_insert
AFTER INSERT ON calendar_published_runs
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_published_runs_device_sync_wake_update
AFTER UPDATE ON calendar_published_runs
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER calendar_published_runs_device_sync_wake_delete
AFTER DELETE ON calendar_published_runs
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('calendar', CAST(OLD.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER dictation_history_device_sync_wake_insert
AFTER INSERT ON dictation_history
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('dictation', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER dictation_history_device_sync_wake_update
AFTER UPDATE ON dictation_history
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('dictation', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER dictation_history_device_sync_wake_delete
AFTER DELETE ON dictation_history
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('dictation', CAST(OLD.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER execution_workspaces_device_sync_wake_insert
AFTER INSERT ON execution_workspaces
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('registry', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER execution_workspaces_device_sync_wake_update
AFTER UPDATE ON execution_workspaces
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('registry', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER execution_workspaces_device_sync_wake_delete
AFTER DELETE ON execution_workspaces
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('registry', CAST(OLD.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER saved_artifacts_device_sync_wake_insert
AFTER INSERT ON saved_artifacts
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('artifacts', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER saved_artifacts_device_sync_wake_update
AFTER UPDATE ON saved_artifacts
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('artifacts', CAST(NEW.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER saved_artifacts_device_sync_wake_delete
AFTER DELETE ON saved_artifacts
BEGIN
  INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
  VALUES ('artifacts', CAST(OLD.id AS TEXT), 0, 0);
  DELETE FROM device_sync_changes WHERE cursor <=
    (SELECT COALESCE(MAX(cursor), 0) - 10000 FROM device_sync_changes);
END;
CREATE TRIGGER conversations_owner_insert AFTER INSERT ON conversations
WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
  AND NOT EXISTS(SELECT 1 FROM execution_conversations c WHERE c.id=NEW.id) BEGIN
  INSERT OR IGNORE INTO conversation_owners VALUES(NEW.id,(SELECT device_id FROM peer_sync_clock WHERE singleton=1));
END;
