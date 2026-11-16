import { createHash } from "node:crypto";

/**
 * Settings → GitHub for bots (docs/architecture/GITHUB_IDENTITY.md): the public half of the
 * user's GitHub SSH key while the bot is on, and the commit identity, from the Woven server that
 * runs this runtime (`POST /v1/bots-host/git`). The key itself never enters the container: git
 * there signs through the in-container relay (helper/ssh-agent.mjs), which asks the machine's
 * signing agent. The runtime writes the files below; git reads them through the container's
 * environment. Keep the contents identical to remote/src/github-identity.mjs and the Mac's
 * GitHubGitFiles.
 */
export type GitSetup = {
  readonly publicKey: string | null;
  readonly identity: { readonly name: string; readonly email: string } | null;
};

export const NO_GIT: GitSetup = { publicKey: null, identity: null };

/**
 * The container's /dev/shm, a tmpfs every container has: the key never reaches the container's
 * disk, the storage volume, or the snapshot an update commits, in containers of any age. It is
 * empty after every container start and written again before the agent runs.
 */
export const CONTAINER_GIT_DIRECTORY = "/dev/shm/woven-github";

// GitHub's published SSH host keys (https://api.github.com/meta, `ssh_keys`).
export const GITHUB_KNOWN_HOSTS = `github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
`;

const quoted = (path: string) => `"${path}"`;
// ASCII control characters (line breaks included) are dropped: a value never starts a new section.
const gitQuoted = (value: string) =>
  `"${value.replace(/[\u0000-\u001f\u007f]/g, "").replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
const join = (directory: string, name: string) => `${directory.replace(/\/$/, "")}/${name}`;

/** The relay's socket, which github.conf names as github.com's agent. */
export const gitAgentSocket = (directory = CONTAINER_GIT_DIRECTORY) => join(directory, "agent.sock");

/** File name → contents, or null to remove it. Only the public key is ever written. */
export function gitFiles(setup: GitSetup, directory = CONTAINER_GIT_DIRECTORY): Record<string, string | null> {
  // With a key, github.com gets it alone; every other host keeps the user's own settings.
  const files: Record<string, string | null> = {
    ssh_config: setup.publicKey
      ? `# Written by Woven Matter (Settings → GitHub).
Include ${quoted(join(directory, "github.conf"))}
Match host "!github.com,*"
  Include ~/.ssh/config
  Include /etc/ssh/ssh_config
`
      : `# Written by Woven Matter (Settings → GitHub). No key is set: your own SSH settings apply.
Include ~/.ssh/config
Include /etc/ssh/ssh_config
`,
    known_hosts: GITHUB_KNOWN_HOSTS,
    id_github: null,
    "id_github.pub": null,
    "github.conf": null,
    gitconfig: null,
  };
  if (setup.publicKey) {
    files["id_github.pub"] = `${setup.publicKey}\n`;
    files["github.conf"] = `Host github.com
  HostName github.com
  User git
  IdentityAgent ${quoted(gitAgentSocket(directory))}
  IdentityFile ${quoted(join(directory, "id_github.pub"))}
  IdentitiesOnly yes
  UserKnownHostsFile ${quoted(join(directory, "known_hosts"))}
  StrictHostKeyChecking yes
`;
  }
  const identity = setup.identity;
  let text = "";
  if (identity && (identity.name || identity.email)) {
    text += "[user]\n";
    if (identity.name) text += `\tname = ${gitQuoted(identity.name)}\n`;
    if (identity.email) text += `\temail = ${gitQuoted(identity.email)}\n`;
  }
  // With a key, HTTPS remotes on GitHub use it too.
  if (setup.publicKey) text += '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n';
  if (text) files.gitconfig = text;
  return files;
}

/**
 * The variables every process in a bot's container starts with (the container's own `Env`, and
 * the agent's). Until the files are written (a container that just started), ssh runs as usual
 * rather than failing on a missing `-F` file. git appends ` "$@"` to a command with shell syntax.
 */
export function gitEnvironment(directory = CONTAINER_GIT_DIRECTORY): Record<string, string> {
  return {
    GIT_SSH_COMMAND: `f='${join(directory, "ssh_config")}'; [ -f "$f" ] && set -- -F "$f" "$@"; exec ssh`,
    GIT_SSH_VARIANT: "ssh",
    GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: "include.path",
    GIT_CONFIG_VALUE_0: join(directory, "gitconfig"),
  };
}

/** Run as the bot user with the JSON `{directory, files}` on stdin; writes privately, atomically. */
export const WRITE_GIT_FILES = [
  "node",
  "-e",
  [
    "const fs=require('fs'),path=require('path');let input='';",
    "process.stdin.on('data',d=>input+=d).on('end',()=>{",
    "const {directory,files}=JSON.parse(input);",
    "fs.mkdirSync(directory,{recursive:true,mode:0o700});fs.chmodSync(directory,0o700);",
    "for(const [name,text] of Object.entries(files)){const file=path.join(directory,name);",
    "if(text===null){fs.rmSync(file,{force:true});continue}",
    "const temporary=file+'.'+process.pid+'.tmp';fs.writeFileSync(temporary,text,{mode:0o600});fs.renameSync(temporary,file)}})",
  ].join(""),
] as const;

export function validGitSetup(value: unknown): GitSetup {
  if (!value || typeof value !== "object") return NO_GIT;
  const record = value as Record<string, unknown>;
  const identity = record.identity as Record<string, unknown> | null | undefined;
  const key = typeof record.publicKey === "string" ? record.publicKey.trim() : "";
  // One `<type> <base64> [comment]` line: never a second line in github.conf's files.
  const publicKey = /^[a-z0-9@.-]+ [A-Za-z0-9+/=]+( [^\r\n]*)?$/.test(key) && key.length <= 16_384 ? key : null;
  const name = typeof identity?.name === "string" ? identity.name : "";
  const email = typeof identity?.email === "string" ? identity.email : "";
  const control = /[\u0000-\u001f\u007f]/;
  return {
    publicKey,
    identity: (name || email) && !control.test(name) && !control.test(email) ? { name, email } : null,
  };
}

export const gitDigest = (setup: GitSetup) => createHash("sha256").update(JSON.stringify(setup)).digest("hex");

/**
 * Each bot's setup, asked of the host at most once a minute per bot, failures included (like
 * credentials, it is cached in memory only). The host answers without the key for a bot the
 * user keeps it from. A failed request keeps the last answer, so a host restart never strips
 * a bot's key; with no answer yet it is undefined and nothing is written.
 */
export class HostGitSource {
  readonly #fetch: (botId: string) => Promise<GitSetup>;
  readonly #ttlMs: number;
  readonly #bots = new Map<string, { value: GitSetup | undefined; at: number; pending?: Promise<GitSetup | undefined> }>();

  constructor(fetch: (botId: string) => Promise<GitSetup>, ttlMs = 60_000) {
    this.#fetch = fetch;
    this.#ttlMs = ttlMs;
  }

  current(botId: string): Promise<GitSetup | undefined> {
    let entry = this.#bots.get(botId);
    if (!entry) this.#bots.set(botId, (entry = { value: undefined, at: 0 }));
    const bot = entry;
    if (bot.at && Date.now() - bot.at < this.#ttlMs) return Promise.resolve(bot.value);
    bot.pending ??= this.#fetch(botId)
      .then((value) => {
        bot.value = value;
        bot.at = Date.now();
        return value;
      })
      .catch(() => {
        bot.at = Date.now();
        return bot.value;
      })
      .finally(() => {
        bot.pending = undefined;
      });
    return bot.pending;
  }
}
