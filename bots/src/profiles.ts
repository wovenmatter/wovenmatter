import { type PoolModel, PROFILE_ID, type Profile, type ProfileSet, parseModelRef } from "./config.ts";

export class ProfileError extends Error {}

/** The most main-model fallbacks a profile may list. */
export const MAX_FALLBACKS = 5;

/** What a client or Admin Bot sends to create or replace a profile. */
export type ProfileInput = {
  readonly id: string;
  readonly name: string;
  /** Omitted or "": no main model yet. */
  readonly main?: string;
  /** Ordered main-model fallbacks for usage limits, at most 5. */
  readonly fallbacks?: readonly string[];
  /** Memory extraction model; omitted, null or "": the active main model. */
  readonly memoryModel?: string | null;
  /** Model preferences: free text for choosing subagent models. */
  readonly guidance?: string;
  /** Additional subagent models with optional notes. */
  readonly pool?: readonly { model: string; useFor?: string }[];
};

/** What `ProfileStore` persists: the new set, and the set it replaces (only the change is written). */
export type ProfileWrite = ProfileSet & { readonly previous?: ProfileSet };

export type ProfileStoreOptions = {
  /** Writes the profiles to settings.json; omitted (tests): memory only. */
  readonly persist?: (set: ProfileWrite) => Promise<void>;
  /** Throws for a model this server does not know (Settings' model check). */
  readonly checkModel?: (ref: string) => void;
};

/**
 * The live model profiles. Changes apply without a restart: they are written to settings.json
 * and listeners re-apply the main model to the
 * affected bots, which takes effect from their next request.
 */
export class ProfileStore {
  #set: ProfileSet;
  readonly #options: ProfileStoreOptions;
  readonly #listeners = new Set<(previous: ProfileSet) => void | Promise<void>>();
  #queue: Promise<unknown> = Promise.resolve();

  constructor(set: ProfileSet, options: ProfileStoreOptions = {}) {
    this.#set = set;
    this.#options = options;
  }

  get defaultId(): string {
    return this.#set.defaultId;
  }

  list(): readonly Profile[] {
    return this.#set.profiles;
  }

  snapshot(): ProfileSet {
    return this.#set;
  }

  get(id: string): Profile | undefined {
    return this.#set.profiles.find((profile) => profile.id === id);
  }

  /** The profile a bot runs: its assigned one, or the default (also for a missing id). */
  resolve(id: string | undefined): Profile {
    const found = (id ? this.get(id) : undefined) ?? this.get(this.#set.defaultId);
    if (!found) throw new ProfileError("no default profile");
    return found;
  }

  /** Called after every change with the set before it. */
  onChange(listener: (previous: ProfileSet) => void | Promise<void>): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** Create (`create: true`, the id must be new) or replace a profile. */
  save(input: ProfileInput, options: { readonly create?: boolean } = {}): Promise<Profile> {
    return this.#change((set) => {
      const profile = this.#validate(input);
      const exists = set.profiles.some((entry) => entry.id === profile.id);
      if (options.create && exists)
        throw new ProfileError(`profile "${profile.id}" already exists`);
      if (!options.create && !exists) throw new ProfileError(`no profile "${profile.id}"`);
      const profiles = exists
        ? set.profiles.map((entry) => (entry.id === profile.id ? profile : entry))
        : [...set.profiles, profile];
      return { next: { ...set, profiles }, result: profile };
    });
  }

  /** Delete a profile. The default cannot be deleted; bots on it fall back to the default. */
  remove(id: string): Promise<void> {
    return this.#change((set) => {
      if (id === set.defaultId) throw new ProfileError("the default profile cannot be deleted");
      if (!set.profiles.some((entry) => entry.id === id))
        throw new ProfileError(`no profile "${id}"`);
      return {
        next: { ...set, profiles: set.profiles.filter((entry) => entry.id !== id) },
        result: undefined,
      };
    });
  }

  setDefault(id: string): Promise<void> {
    return this.#change((set) => {
      if (!set.profiles.some((entry) => entry.id === id))
        throw new ProfileError(`no profile "${id}"`);
      return { next: { ...set, defaultId: id }, result: undefined };
    });
  }

  #validate(input: ProfileInput): Profile {
    const id = input.id.trim();
    if (!PROFILE_ID.test(id)) {
      throw new ProfileError(
        `invalid profile id "${id}": lowercase letters, digits, - and _ (max 40)`,
      );
    }
    const name = input.name.trim();
    if (!name || name.length > 80) throw new ProfileError("profile name is required (max 80)");
    const check = (ref: string) => {
      try {
        parseModelRef(ref);
      } catch {
        throw new ProfileError(`invalid model "${ref}": expected provider/model-id`);
      }
      this.#options.checkModel?.(ref);
    };
    const main = input.main?.trim() || undefined;
    if (main) check(main);
    const fallbacks: string[] = [];
    for (const ref of input.fallbacks ?? []) {
      if (!main) throw new ProfileError("choose a main model before adding fallbacks");
      check(ref);
      if (ref === main) throw new ProfileError(`${ref} is the main model, not a fallback`);
      if (fallbacks.includes(ref)) throw new ProfileError(`fallbacks list ${ref} twice`);
      fallbacks.push(ref);
    }
    if (fallbacks.length > MAX_FALLBACKS) {
      throw new ProfileError(`at most ${MAX_FALLBACKS} fallback models`);
    }
    const pool: PoolModel[] = [];
    for (const entry of input.pool ?? []) {
      check(entry.model);
      if (pool.some((existing) => existing.model === entry.model)) {
        throw new ProfileError(`pool lists ${entry.model} twice`);
      }
      pool.push({ model: entry.model, useFor: (entry.useFor ?? "").trim().slice(0, 500) });
    }
    const memoryModel = input.memoryModel?.trim() || undefined;
    if (memoryModel) check(memoryModel);
    const guidance = input.guidance?.trim();
    if (guidance && guidance.length > 4000)
      throw new ProfileError("model preferences are too long (max 4000)");
    return {
      id,
      name,
      ...(main ? { main } : {}),
      ...(fallbacks.length ? { fallbacks } : {}),
      ...(memoryModel ? { memoryModel } : {}),
      ...(guidance ? { guidance } : {}),
      pool,
    };
  }

  /** Serialize changes: compute, persist, swap, notify. */
  #change<T>(compute: (set: ProfileSet) => { next: ProfileSet; result: T }): Promise<T> {
    const run = this.#queue.then(async () => {
      const previous = this.#set;
      const { next, result } = compute(previous);
      await this.#options.persist?.({ ...next, previous });
      this.#set = next;
      for (const listener of this.#listeners) await listener(previous);
      return result;
    });
    this.#queue = run.catch(() => {});
    return run;
  }
}

/** A profile as tools and clients see it. `main` is "" until a main model is chosen. */
export function describeProfile(profile: Profile, defaultId: string) {
  return {
    id: profile.id,
    name: profile.name,
    main: profile.main ?? "",
    ...(profile.fallbacks?.length ? { fallbacks: [...profile.fallbacks] } : {}),
    ...(profile.memoryModel ? { memoryModel: profile.memoryModel } : {}),
    ...(profile.guidance ? { guidance: profile.guidance } : {}),
    pool: profile.pool.map((entry) => ({ model: entry.model, useFor: entry.useFor })),
    ...(profile.id === defaultId ? { default: true } : {}),
  };
}
