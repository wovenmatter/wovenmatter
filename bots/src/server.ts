import { chmod, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ConversationView, ConversationWatch, LiveState } from "@earendil-works/pi-durable";
import { type RawData, WebSocket, WebSocketServer } from "ws";
import type { BotManager, ModelStatus } from "./bots.ts";
import { NotFoundError } from "./bots.ts";
import type { Forum } from "./forum.ts";
import type { HostChannel } from "./host/channel.ts";
import { entryId as toEntryId } from "./ids.ts";
import { editFacts, type MemoryEdit } from "./memory.ts";
import { describeProfile, type ProfileStore } from "./profiles.ts";
import {
  type BotSummary,
  type ConversationSnapshot,
  type ForumPost,
  type HostReply,
  type OnboardingStatus,
  type ProfilesList,
  type Replies,
  type Request,
  type RequestType,
  requestSchema,
  type ServerMessage,
  type StreamEvent,
  type ThreadSummary,
} from "./protocol.ts";
import type { RuntimeOperations } from "./operations.ts";
import type { SettingsService } from "./settings/service.ts";
import type { BotRecord, ThreadRecord } from "./storage/registry.ts";
import { ACCOUNT_NOTES } from "./tools.ts";
import { assistantText, type DisplayEntry, displayEntry } from "./transcript.ts";

const ctx = BACKGROUND_CONTEXT;
const HISTORY_LIMIT = 200;

export type BotServerOptions = {
  /** Where bots' tools run: `none`, `linux-dockerd` or `mac-vm`. */
  readonly environment?: string;
  /** The Unix socket to listen on; its directory keeps others out. */
  readonly socket: string;
  /** The host interface, carried on the server's connection. */
  readonly host: HostChannel;
  readonly operations?: RuntimeOperations;
  /** A client used a bot (opened its chat, sent a message): restart its idle clock. */
  readonly onActivity?: (botId: string) => void;
  readonly manager: BotManager;
  readonly log?: (message: string) => void;
  /** Settings backend; without it the settings requests fail. */
  readonly settings?: SettingsService;
  /** The Forum; without it the `forum.*` requests fail. */
  readonly forum?: Forum;
  /** What bots call the user ("" for none); without it the `user.*` requests fail. */
  readonly user?: { name(): Promise<string>; setName(name: string): Promise<string> };
};

export type BotServer = {
  readonly socket: string;
  /** Tell every client the bot list changed. */
  botsChanged(): void;
  groupsChanged(): void;
  /** Tell every client a bot's thread list changed (a thread was titled). */
  threadsChanged(botId: string): void;
  /** Tell every client a bot's memory changed (an extraction added facts). */
  memoryChanged(botId: string): void;
  broadcast(message: ServerMessage): void;
  /** Tell the clients that have the post's Forum room open about a new or changed post. */
  forumPost(post: ForumPost): void;
  /** Tell the clients that have a Forum room open which bots are working there. */
  forumThinking(roomId: number, botIds: string[]): void;
  /** Whether any client has one of the bot's conversations open now. */
  viewing(botId: string): boolean;
  close(): Promise<void>;
};

/** How clients see a bot: its profile's name, and model names only in a usage-limit status. */
const botSummary = (
  record: BotRecord,
  profiles: ProfileStore | undefined,
  status?: ModelStatus,
): BotSummary => {
  const profile = profiles?.resolve(record.profile);
  return {
    id: record.id,
    name: record.name,
    createdAt: record.createdAt,
    kind: record.kind,
    manager: record.manager,
    ...(record.managerId ? { managerId: record.managerId } : {}),
    orchestrator: record.orchestrator,
    ...(record.groupId ? { groupId: record.groupId } : {}),
    profileId: profile?.id ?? record.profile ?? "",
    profileName: profile?.name ?? "",
    defaultProfile: !record.profile || !profiles?.get(record.profile),
    ...(status
      ? {
          modelStatus: {
            kind: status.kind,
            at: status.at,
            primary: status.primary,
            active: status.active,
            limits: status.limits.map((limit) => ({
              model: limit.model,
              account: limit.account,
              kind: limit.kind,
              ...(limit.resetsAt !== undefined ? { resetsAt: limit.resetsAt } : {}),
              retryAt: limit.retryAt,
            })),
          },
        }
      : {}),
  };
};

const thread = (record: ThreadRecord): ThreadSummary => ({
  conversationId: record.conversationId,
  parentConversationId: record.parentConversationId,
  forkedAt: record.forkedAt,
  ...(record.title ? { title: record.title } : {}),
  createdAt: record.createdAt,
  ...(record.pinned ? { pinned: true as const } : {}),
});

/** Translate conversation revisions into the existing client protocol. */
export function streamEvents(
  previous: Pick<ConversationView, "entries" | "docs">,
  current: Pick<ConversationView, "entries" | "docs">,
): StreamEvent[] {
  const before = previous.docs["pi.live"] as LiveState | undefined;
  const live = current.docs["pi.live"] as LiveState | undefined;
  const out: StreamEvent[] = [];
  if (live?.run && !before?.run) out.push({ kind: "run", state: "start" });
  const oldEntries = new Map(previous.entries.map((entry) => [entry.id, entry]));
  for (const entry of current.entries) {
    if (JSON.stringify(oldEntries.get(entry.id)) === JSON.stringify(entry)) continue;
    const display = displayEntry(entry);
    if (display) out.push({ kind: "entry", entry: display });
  }
  const finishedAssistant = out.some(
    (event) => event.kind === "entry" && event.entry.role === "assistant",
  );
  const sameGeneration =
    !finishedAssistant &&
    live?.run?.taskId === before?.run?.taskId &&
    live?.generation?.attempt === before?.generation?.attempt;
  const text = assistantText(live?.generation?.message);
  const oldText = assistantText(before?.generation?.message);
  if (live?.generation && (text !== oldText || !before?.generation || !sameGeneration)) {
    if (before?.generation && sameGeneration && text.startsWith(oldText)) {
      out.push({ kind: "delta", text: text.slice(oldText.length) });
    } else out.push({ kind: "assistant_start", text });
  }
  if (
    live?.generation?.retry &&
    JSON.stringify(live.generation.retry) !== JSON.stringify(before?.generation?.retry)
  ) {
    out.push({ kind: "error", message: `retrying: ${live.generation.retry.error}` });
  }
  if (live?.runFailure && JSON.stringify(live.runFailure) !== JSON.stringify(before?.runFailure)) {
    out.push({ kind: "error", message: live.runFailure.detail ?? live.runFailure.reason });
  }
  if (!live?.run) out.push({ kind: "run", state: "end" });
  return out;
}

type SubscriptionId = string | number;

/**
 * One server connection. The server multiplexes its clients onto it, so a conversation or Forum
 * room may be open for several subscriptions at once: it stays open until the last one closes.
 */
class Connection {
  readonly #socket: WebSocket;
  readonly #server: Server;
  /** `<botId>:<conversationId>` → its watch and the subscriptions that have it open. */
  readonly #subscriptions = new Map<string, { stream: ConversationWatch; ids: Set<SubscriptionId> }>();
  /** Forum rooms this connection has open, with the subscriptions that opened each. */
  readonly #forumRooms = new Map<number, Set<SubscriptionId>>();
  readonly #detachHost: () => void;

  constructor(socket: WebSocket, server: Server) {
    this.#socket = socket;
    this.#server = server;
    socket.on("message", (data, isBinary) => void this.#onMessage(data, isBinary));
    socket.on("close", () => void this.dispose());
    this.#detachHost = server.host.attach((request) => this.send(request));
  }

  send(message: ServerMessage): void {
    if (this.#socket.readyState === WebSocket.OPEN) this.#socket.send(JSON.stringify(message));
  }

  async dispose(): Promise<void> {
    this.#detachHost();
    const streams = [...this.#subscriptions.values()];
    this.#subscriptions.clear();
    this.#forumRooms.clear();
    this.#server.connections.delete(this);
    await Promise.all(streams.map(({ stream }) => stream.stop().catch(() => {})));
  }

  /** Whether this connection has one of the bot's conversations open. */
  watching(botId: string): boolean {
    for (const key of this.#subscriptions.keys()) if (key.startsWith(`${botId}:`)) return true;
    return false;
  }

  /** Whether this client has the Forum room open. */
  inForumRoom(roomId: number): boolean {
    return this.#forumRooms.has(roomId);
  }

  async unsubscribeBot(botId: string): Promise<void> {
    for (const [key, { stream }] of this.#subscriptions) {
      if (!key.startsWith(`${botId}:`)) continue;
      this.#subscriptions.delete(key);
      await stream.stop().catch(() => {});
    }
  }

  async #onMessage(data: RawData, isBinary: boolean): Promise<void> {
    let id: string | number | undefined;
    try {
      if (isBinary) throw new Error("binary frames are not supported");
      const json: unknown = JSON.parse(data.toString());
      if (isHostReply(json)) {
        this.#server.host.deliver(json);
        return;
      }
      if (json && typeof json === "object" && "id" in json) {
        const candidate = (json as { id: unknown }).id;
        if (typeof candidate === "string" || typeof candidate === "number") id = candidate;
      }
      const parsed = requestSchema.safeParse(json);
      if (!parsed.success) {
        throw new Error(`invalid request: ${parsed.error.issues[0]?.message ?? "malformed"}`);
      }
      const afterReply: (() => void)[] = [];
      const result = await this.#handle(parsed.data, afterReply);
      this.send({ type: "result", id: parsed.data.id, data: result });
      for (const start of afterReply) start();
    } catch (error) {
      const message =
        error instanceof NotFoundError || error instanceof Error ? error.message : String(error);
      this.send({ type: "error", ...(id === undefined ? {} : { id }), message });
    }
  }

  #operations(): RuntimeOperations {
    const operations = this.#server.operations;
    if (!operations) throw new Error("bot environments are not available on this server");
    return operations;
  }

  #settings(): SettingsService {
    const settings = this.#server.settings;
    if (!settings) throw new Error("settings are not available on this server");
    return settings;
  }

  #user(): NonNullable<BotServerOptions["user"]> {
    const user = this.#server.user;
    if (!user) throw new Error("the user's name is not available on this server");
    return user;
  }

  #forum(): Forum {
    const forum = this.#server.forum;
    if (!forum) throw new Error("the Forum is not available on this server");
    return forum;
  }

  async #handle(request: Request, afterReply: (() => void)[]): Promise<Replies[RequestType]> {
    const manager = this.#server.manager;
    const bot = (record: BotRecord) =>
      botSummary(record, manager.profiles, manager.modelStatus(record.id));
    const profiles = () => {
      const store = manager.profiles;
      if (!store) throw new Error("model profiles are not available on this server");
      return store;
    };
    const listProfiles = (): ProfilesList => {
      const store = profiles();
      return {
        defaultId: store.defaultId,
        profiles: store.list().map((profile) => describeProfile(profile, store.defaultId)),
      };
    };
    switch (request.type) {
      case "groups.list":
        return { groups: await manager.listGroups() };
      case "groups.create":
        return { group: await manager.createGroup(request.name) };
      case "groups.rename":
        return { group: await manager.renameGroup(request.groupId, request.name) };
      case "groups.delete":
        await manager.deleteGroup(request.groupId);
        return { deleted: true };
      case "groups.reorder":
        return { groups: await manager.reorderGroups(request.groupIds) };
      case "bots.setGroup":
        return { bot: bot(await manager.setGroup(request.botId, request.groupId)) };

      case "bots.list":
        return { bots: (await manager.list()).map(bot) };
      case "bots.create":
        return {
          bot: bot(
            await manager.create(
              request.name,
              request.managerId ? { managerId: request.managerId } : {},
            ),
          ),
        };
      case "bots.delete": {
        if ((await manager.record(request.botId)).kind === "admin")
          throw new Error("the Admin Bot cannot be deleted");
        for (const connection of this.#server.connections) {
          await connection.unsubscribeBot(request.botId);
        }
        return { deleted: await manager.delete(request.botId) };
      }
      case "bots.listDeleted":
        return {
          bots: (await manager.listDeleted()).map((record) => ({
            ...bot(record),
            deletedAt: record.deletedAt,
          })),
        };
      case "bots.restore": {
        const restored = await manager.restore(request.botId);
        return restored ? { restored: true, bot: bot(restored) } : { restored: false };
      }
      case "bots.purge":
        return { purged: true, ...(await manager.purge(request.botId)) };
      case "bots.rename":
        return { bot: bot(await manager.rename(request.botId, request.name)) };
      case "bots.setManager":
        return { bot: bot(await manager.setManager(request.botId, request.manager)) };
      case "bots.setTeam":
        return { bot: bot(await manager.setTeam(request.botId, request.managerId ?? undefined)) };
      case "bots.replaceManager":
        return { bot: bot(await manager.replaceManager(request.managerId, request.newManagerId)) };
      case "bots.setOrchestrator": {
        const orchestrator = await manager.setOrchestrator(request.botId ?? undefined);
        return { bot: orchestrator ? bot(orchestrator) : null };
      }
      case "onboarding.status": {
        const admin = await manager.admin();
        if (!admin) throw new Error("this server has no Admin Bot");
        const settings = this.#settings();
        const signedIn = await settings.signedIn();
        const profile = profiles().resolve(manager.assignedProfile(admin.id));
        const mainModelAvailable = profile.main ? await settings.modelAvailable(profile.main) : false;
        const status: OnboardingStatus = {
          adminId: admin.id,
          profileId: profile.id,
          mainModel: profile.main ?? "",
          mainModelAvailable,
          signedIn,
          needed: !signedIn || !mainModelAvailable,
        };
        return status;
      }
      case "onboarding.setMainModel": {
        const admin = await manager.admin();
        if (!admin) throw new Error("this server has no Admin Bot");
        this.#settings().checkModel(request.model);
        const store = profiles();
        const profile = store.resolve(manager.assignedProfile(admin.id));
        const saved = await store.save({ ...profile, main: request.model });
        // Saving waits for the model to reach Admin Bot, so its greeting runs on it. Best-effort:
        // the model is saved either way, and the user can still write first.
        await (await manager.get(admin.id))
          .greet()
          .catch((error: unknown) => this.#server.log(`Admin Bot greeting: ${String(error)}`));
        return { profile: describeProfile(saved, store.defaultId) };
      }
      case "profiles.list":
        return listProfiles();
      case "profiles.save": {
        const store = profiles();
        const { profile, create } = request;
        await store.save(
          {
            id: profile.id,
            name: profile.name,
            main: profile.main,
            ...(profile.fallbacks ? { fallbacks: profile.fallbacks } : {}),
            ...(profile.memoryModel ? { memoryModel: profile.memoryModel } : {}),
            pool: profile.pool,
            ...(profile.guidance !== undefined ? { guidance: profile.guidance } : {}),
          },
          { create: create === true },
        );
        return listProfiles();
      }
      case "profiles.delete":
        await profiles().remove(request.profileId);
        return listProfiles();
      case "profiles.setDefault":
        await profiles().setDefault(request.profileId);
        return listProfiles();
      case "bots.setProfile":
        return {
          bot: bot(await manager.setProfile(request.botId, request.profileId ?? undefined)),
        };
      case "memory.list":
        await manager.record(request.botId);
        return { facts: [...(await manager.registry.memory(request.botId)).facts] };
      case "memory.add":
      case "memory.update":
      case "memory.delete": {
        await manager.record(request.botId);
        const edit: MemoryEdit =
          request.type === "memory.add"
            ? { kind: "add", text: request.text }
            : request.type === "memory.update"
              ? { kind: "update", fact: request.fact, text: request.text }
              : { kind: "delete", fact: request.fact };
        const saved = await manager.registry.updateMemory(request.botId, (memory) => ({
          facts: editFacts(memory.facts, edit),
          checkpoint: memory.checkpoint,
        }));
        this.#server.memoryChanged(request.botId);
        return { facts: [...saved.facts] };
      }
      case "account.notes": {
        const note = await manager.registry.note(ACCOUNT_NOTES);
        return note ? { notes: note.text, updatedAt: note.updatedAt } : { notes: "" };
      }
      case "account.setNotes":
        await manager.registry.setNote(ACCOUNT_NOTES, request.notes);
        return { saved: true };
      case "settings.accounts":
        return this.#settings().accounts();
      case "models.catalog":
        return this.#settings().modelCatalog();
      case "models.setRoles": {
        const { id: _id, type: _type, ...roles } = request;
        return { roles: await this.#settings().setRoles(roles), restartRequired: false };
      }
      case "bots.environment":
        return { environment: await this.#operations().environment(request.botId) };
      case "bots.rebuild":
        await this.#operations().rebuild(request.botId);
        return { rebuilt: true };
      case "bots.stop":
        await this.#operations().stop(request.botId);
        return { stopped: true };
      case "runtime.update": {
        const operations = this.#operations();
        // The update runs past this reply; progress arrives as `runtime.update` pushes.
        afterReply.push(() => {
          void operations.update(request.botIds).catch((error: unknown) =>
            this.#server.broadcast({
              type: "runtime.update",
              phase: "done",
              error: error instanceof Error ? error.message : String(error),
            }),
          );
        });
        return { started: true };
      }
      case "runtime.status": {
        const image = await this.#operations().imageStatus();
        return {
          environment: this.#server.environment,
          bots: (await manager.list()).length,
          ...(image
            ? {
                image: {
                  tag: image.tag,
                  ...image.tools,
                  staleBots: image.staleBots.length,
                  outdatedBots: image.outdatedBots.length,
                },
              }
            : {}),
        };
      }
      case "threads.list": {
        const target = await manager.get(request.botId);
        return { threads: (await target.threads(request.query)).map(thread) };
      }
      case "thread.fork": {
        const target = await manager.get(request.botId);
        const record = await target.fork({
          ...(request.conversationId === undefined
            ? {}
            : { fromConversationId: request.conversationId }),
          entryId: request.entryId,
        });
        this.#server.threadsChanged(request.botId);
        return { thread: thread(record) };
      }
      case "thread.setTitle": {
        await manager.get(request.botId);
        const record = await manager.registry.setThreadTitle(request.botId, request.conversationId, request.title);
        this.#server.threadsChanged(request.botId);
        return { thread: thread(record) };
      }
      case "thread.setPinned": {
        await manager.get(request.botId);
        const record = await manager.registry.setThreadPinned(
          request.botId,
          request.conversationId,
          request.pinned,
        );
        this.#server.threadsChanged(request.botId);
        return { thread: thread(record) };
      }
      case "thread.delete": {
        const target = await manager.get(request.botId);
        await target.deleteThread(request.conversationId);
        this.#server.threadsChanged(request.botId);
        return { deleted: true };
      }
      case "message.send": {
        const target = await manager.get(request.botId);
        this.#server.onActivity?.(request.botId);
        if (request.newThread && request.conversationId !== undefined) {
          throw new Error("invalid request: newThread cannot name a conversation");
        }
        const submit = async () => {
          const started = request.newThread ? await target.startThread() : undefined;
          if (started) this.#server.threadsChanged(request.botId);
          const { conversation, submission } = await target.send(
            request.text,
            started?.conversationId ?? request.conversationId,
            0,
            request.context,
            request.from ? { from: request.from } : {},
          );
          return { conversationId: conversation.id, submissionId: submission.id };
        };
        return request.deliveryId ? this.#server.delivery(request.deliveryId, submit) : submit();
      }
      case "conversation.abort": {
        const target = await manager.get(request.botId);
        const conversation = await target.abort(request.conversationId);
        return { conversationId: conversation.id, stopped: true };
      }
      case "conversation.close": {
        const key = `${request.botId}:${request.conversationId}`;
        const open = this.#subscriptions.get(key);
        if (!open) return { closed: false };
        if (request.subscriptionId !== undefined) {
          if (!open.ids.delete(request.subscriptionId)) return { closed: false };
          if (open.ids.size) return { closed: true };
        }
        this.#subscriptions.delete(key);
        await open.stream.stop();
        return { closed: true };
      }
      case "conversation.open":
        return this.#open(request.botId, request.conversationId, afterReply, request.id);

      case "forum.get":
        return this.#forum().state();
      case "forum.open": {
        const forum = this.#forum();
        const roomId = request.roomId ?? (await forum.store.mainRoom()).id;
        // Subscribed before the snapshot is read: a post made meanwhile arrives as a push, and
        // clients merge posts by id.
        const ids = this.#forumRooms.get(roomId) ?? new Set<SubscriptionId>();
        const added = !ids.has(request.id);
        ids.add(request.id);
        this.#forumRooms.set(roomId, ids);
        try {
          return { ...(await forum.snapshot(roomId)), subscriptionId: request.id };
        } catch (error) {
          if (added) ids.delete(request.id);
          if (!ids.size) this.#forumRooms.delete(roomId);
          throw error;
        }
      }
      case "forum.abort":
        return { roomId: request.roomId, stopped: await this.#forum().stopRoom(request.roomId) };
      case "forum.close": {
        const ids = this.#forumRooms.get(request.roomId);
        if (!ids) return { closed: false };
        if (request.subscriptionId !== undefined) {
          if (!ids.delete(request.subscriptionId)) return { closed: false };
          if (ids.size) return { closed: true };
        }
        this.#forumRooms.delete(request.roomId);
        return { closed: true };
      }
      case "forum.posts":
        return this.#forum().posts(request.roomId, request.before, request.limit);
      case "forum.post": {
        const forum = this.#forum();
        const submit = async () => ({
          post: await forum.postAsUser({
            ...(request.roomId !== undefined ? { roomId: request.roomId } : {}),
            text: request.text,
            ...(request.mentions ? { mentions: request.mentions } : {}),
            ...(request.everyone ? { everyone: true } : {}),
            ...(request.context ? { context: request.context } : {}),
          }),
        });
        return request.deliveryId ? this.#server.delivery(request.deliveryId, submit) : submit();
      }
      case "forum.thread.create":
        return { thread: await this.#forum().createThread(request.postId) };
      case "forum.thread.setTitle":
        return { thread: await this.#forum().setThreadTitle(request.roomId, request.title) };
      case "forum.thread.setPinned":
        return { thread: await this.#forum().setThreadPinned(request.roomId, request.pinned) };
      case "forum.thread.delete":
        await this.#forum().deleteThread(request.roomId);
        return { deleted: true };
      case "forum.setPaused":
        return this.#forum().setPaused(request.paused);
      case "forum.setBotActive":
        return this.#forum().setBotActive(request.botId, request.active);
      case "forum.schedules.list":
        return { schedules: await this.#forum().schedules() };
      case "forum.schedules.save": {
        const { schedule } = request;
        return {
          schedules: await this.#forum().saveSchedule({
            ...(schedule.id !== undefined ? { id: schedule.id } : {}),
            text: schedule.text,
            ...(schedule.mentions ? { mentions: schedule.mentions } : {}),
            ...(schedule.everyone ? { everyone: true } : {}),
            repeat: schedule.repeat,
            ...(schedule.time !== undefined ? { time: schedule.time } : {}),
            ...(schedule.weekday !== undefined ? { weekday: schedule.weekday } : {}),
            ...(schedule.at !== undefined ? { at: schedule.at } : {}),
            timeZone: schedule.timeZone,
          }),
        };
      }
      case "forum.schedules.delete":
        return { schedules: await this.#forum().deleteSchedule(request.scheduleId) };
      case "user.get":
        return { name: await this.#user().name() };
      case "user.setName":
        return { name: await this.#user().setName(request.name) };
    }
  }

  async #open(
    botId: string,
    requested: number | undefined,
    afterReply: (() => void)[],
    subscriptionId: string | number,
  ): Promise<ConversationSnapshot> {
    const target = await this.#server.manager.get(botId);
    this.#server.onActivity?.(botId);
    const main = await target.main();
    const conversation = await target.conversation(requested);
    const key = `${botId}:${conversation.id}`;

    // Watch first, then read history: events after the snapshot are never missed, and the
    // client de-duplicates entries by id.
    const stream = await conversation.watch(ctx, { min: HISTORY_LIMIT, max: HISTORY_LIMIT * 2 });
    if (this.#socket.readyState !== WebSocket.OPEN) {
      await stream.stop();
      throw new Error("connection closed");
    }
    const prior = this.#subscriptions.get(key);
    const ids = prior?.ids ?? new Set<SubscriptionId>();
    ids.add(subscriptionId);
    const open = { stream, ids };
    this.#subscriptions.set(key, open);
    await prior?.stream.stop();
    const { page, origin } = await Promise.all([
      conversation.entries({}, HISTORY_LIMIT, undefined, ctx),
      conversation.id === main.id
        ? undefined
        : this.#server.manager.registry.getThread(botId, conversation.id),
    ])
      .then(async ([page, record]) => {
        let origin = record ? page.items.find((entry) => entry.id === record.forkedAt) : undefined;
        if (record && !origin) {
          origin = (
            await conversation.entries(
              { minEntryId: toEntryId(record.forkedAt), maxEntryId: toEntryId(record.forkedAt) },
              1,
              undefined,
              ctx,
            )
          ).items[0];
        }
        return { page, origin: origin ? displayEntry(origin) : undefined };
      })
      .catch(async (error) => {
        await stream.stop();
        if (this.#subscriptions.get(key) === open) {
          ids.delete(subscriptionId);
          this.#subscriptions.delete(key);
        }
        throw error;
      });
    const entries = page.items
      .map(displayEntry)
      .filter((entry): entry is DisplayEntry => entry !== undefined)
      .reverse();

    const conversationId = conversation.id;
    let previous = stream.value;
    afterReply.push(() => {
      if (this.#subscriptions.get(key) !== open) return;
      stream.start(async (call) => {
        if (this.#subscriptions.get(key) !== open) return;
        if (call.kind === "failed") {
          this.send({
            type: "event",
            botId,
            conversationId,
            event: { kind: "error", message: "Conversation updates temporarily unavailable" },
          });
          return;
        }
        let current = call.value;
        const last = previous.entries.at(-1)?.id;
        // Recover entries skipped when a slow listener falls behind the window.
        if (current.before !== undefined && (last === undefined || current.before > last)) {
          const recovered = [];
          let cursor: import("@earendil-works/pi-durable").Cursor | undefined;
          do {
            const page = await conversation.entries(
              {
                ...(last === undefined ? {} : { minEntryId: last }),
                maxEntryId: current.before,
                order: "ascending",
              },
              HISTORY_LIMIT,
              cursor,
              ctx,
            );
            recovered.push(...page.items);
            cursor = page.next;
          } while (cursor !== undefined);
          current = { ...current, entries: [...recovered, ...current.entries] };
        }
        for (const event of streamEvents(previous, current)) {
          this.send({ type: "event", botId, conversationId, event });
        }
        previous = call.value;
      });
    });
    void stream.closed.then((end) => {
      if (this.#subscriptions.get(key) !== open) return;
      this.#subscriptions.delete(key);
      // Reconnect reloads both the snapshot and its subscription after a failed watch.
      if (end.kind !== "stopped" && this.#socket.readyState === WebSocket.OPEN)
        this.#socket.close(1012, "Conversation subscription ended");
    });

    const streaming = assistantText(
      (stream.value.docs["pi.live"] as LiveState | undefined)?.generation?.message,
    );
    return {
      botId,
      conversationId,
      subscriptionId,
      mainConversationId: main.id,
      ...(origin ? { threadOrigin: origin } : {}),
      entries,
      running: (stream.value.docs["pi.live"] as LiveState | undefined)?.run !== undefined,
      ...(streaming ? { streaming } : {}),
    };
  }
}

function isHostReply(value: unknown): value is HostReply {
  if (!value || typeof value !== "object") return false;
  const { type, id } = value as { type?: unknown; id?: unknown };
  return (type === "host.result" || type === "host.error") && typeof id === "string";
}

class Server {
  /**
   * One submission per delivery id. A retry that overlaps the original joins it, a later one
   * finds it accepted, and only a retry after a crash in between can repeat it.
   */
  delivery<T>(id: string, submit: () => Promise<T>): Promise<T | { duplicate: true }> {
    const running = this.#deliveries.get(id) as Promise<T | { duplicate: true }> | undefined;
    if (running) return running;
    const registry = this.manager.registry;
    const work = (async (): Promise<T | { duplicate: true }> => {
      if (!(await registry.claimDelivery(id))) return { duplicate: true };
      try {
        const result = await submit();
        await registry.acceptDelivery(id);
        return result;
      } catch (error) {
        await registry.releaseDelivery(id);
        throw error;
      }
    })().finally(() => this.#deliveries.delete(id));
    this.#deliveries.set(id, work);
    return work;
  }

  readonly manager: BotManager;
  readonly host: HostChannel;
  readonly settings: SettingsService | undefined;
  readonly operations: RuntimeOperations | undefined;
  readonly onActivity: ((botId: string) => void) | undefined;
  readonly environment: string;
  readonly connections = new Set<Connection>();
  readonly #deliveries = new Map<string, Promise<unknown>>();
  readonly forum: Forum | undefined;
  readonly user: BotServerOptions["user"];
  readonly log: (message: string) => void;

  constructor(options: BotServerOptions) {
    this.manager = options.manager;
    this.host = options.host;
    this.settings = options.settings;
    this.operations = options.operations;
    this.onActivity = options.onActivity;
    this.environment = options.environment ?? "none";
    this.forum = options.forum;
    this.user = options.user;
    this.log = options.log ?? (() => {});
  }

  broadcast(message: ServerMessage): void {
    for (const connection of this.connections) connection.send(message);
  }

  viewing(botId: string): boolean {
    for (const connection of this.connections) if (connection.watching(botId)) return true;
    return false;
  }

  threadsChanged(botId: string): void {
    this.broadcast({ type: "threads.changed", botId });
  }

  memoryChanged(botId: string): void {
    this.broadcast({ type: "memory.changed", botId });
  }
}

/**
 * Listen for the server's WebSocket on the Unix socket `options.socket` (any request path). The
 * socket's private directory is the only gate: there is no bearer and no handshake.
 */
export async function startServer(options: BotServerOptions): Promise<BotServer> {
  const state = new Server(options);
  const log = state.log;
  const http = createServer((_request, response) => {
    response.writeHead(404, { "content-type": "text/plain" }).end("not found");
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
  http.on("upgrade", (request, socket, head) => {
    wss.handleUpgrade(request, socket, head, (ws) => {
      state.connections.add(new Connection(ws, state));
    });
  });

  // A socket left by a runtime that did not exit cleanly would refuse the listen.
  await rm(options.socket, { force: true });
  await new Promise<void>((resolvePromise, reject) => {
    http.once("error", reject);
    http.listen(options.socket, () => {
      http.off("error", reject);
      resolvePromise();
    });
  });
  await chmod(options.socket, 0o600);
  log(`bots runtime listening on ${options.socket}`);

  return {
    socket: options.socket,
    botsChanged: () => state.broadcast({ type: "bots.changed" }),
    groupsChanged: () => state.broadcast({ type: "groups.changed" }),
    threadsChanged: (botId) => state.threadsChanged(botId),
    memoryChanged: (botId) => state.memoryChanged(botId),
    broadcast: (message) => state.broadcast(message),
    forumPost(post) {
      for (const connection of state.connections) {
        if (connection.inForumRoom(post.roomId)) connection.send({ type: "forum.post", post });
      }
    },
    forumThinking(roomId, botIds) {
      for (const connection of state.connections) {
        if (connection.inForumRoom(roomId)) connection.send({ type: "forum.thinking", roomId, botIds });
      }
    },
    viewing: (botId) => state.viewing(botId),
    async close() {
      await Promise.all([...state.connections].map((connection) => connection.dispose()));
      for (const client of wss.clients) client.terminate();
      wss.close();
      await new Promise<void>((done) => http.close(() => done()));
      await rm(options.socket, { force: true });
    },
  };
}
