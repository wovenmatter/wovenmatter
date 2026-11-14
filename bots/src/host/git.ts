import { createHash } from "node:crypto";

/**
 * Settings → GitHub for bots (docs/architecture/GITHUB_IDENTITY.md): the user's GitHub SSH key
 * and commit identity, from the Woven server that runs this runtime (`POST /v1/bots-host/git`).
 * The runtime writes them into each bot's container as the files below; git in the container
 * reads them through the environment the agent starts with. Keep the contents identical to
 * remote/src/github-identity.mjs and the Mac's GitHubGitFiles.
 */
export type GitSetup = {
  readonly sshKey: { readonly privateKey: string; readonly publicKey: string } | null;
  readonly identity: { readonly name: string; readonly email: string } | null;
};

export const NO_GIT: GitSetup = { sshKey: null, identity: null };

/**
 * A tmpfs mount in the container's home: the key never reaches the container's disk, the
 * storage volume, or the snapshot an update commits. It is empty after every container start
 * and written again before the agent runs.
 */
export const CONTAINER_GIT_DIRECTORY = "/home/bot/.woven-github";
export const CONTAINER_GIT_TMPFS = "rw,nosuid,nodev,noexec,size=1m,uid=1000,gid=1000,mode=0700";

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

/** File name → contents, or null to remove it. */
export function gitFiles(setup: GitSetup, directory = CONTAINER_GIT_DIRECTORY): Record<string, string | null> {
  // With a key, github.com gets it alone; every other host keeps the user's own settings.
  const files: Record<string, string | null> = {
    ssh_config: setup.sshKey
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
  if (setup.sshKey) {
    const key = setup.sshKey.privateKey;
    files.id_github = key.endsWith("\n") ? key : `${key}\n`;
    files["id_github.pub"] = `${setup.sshKey.publicKey}\n`;
    files["github.conf"] = `Host github.com
  HostName github.com
  User git
  IdentityFile ${quoted(join(directory, "id_github"))}
  IdentitiesOnly yes
  UserKnownHostsFile ${quoted(join(directory, "known_hosts"))}
  StrictHostKeyChecking yes
`;
  }
  const identity = setup.identity;
  if (identity && (identity.name || identity.email)) {
    let text = "[user]\n";
    if (identity.name) text += `\tname = ${gitQuoted(identity.name)}\n`;
    if (identity.email) text += `\temail = ${gitQuoted(identity.email)}\n`;
    files.gitconfig = text;
  }
  return files;
}

/** The variables the agent (and so every command a bot runs) starts with. */
export function gitEnvironment(directory = CONTAINER_GIT_DIRECTORY): Record<string, string> {
  return {
    GIT_SSH_COMMAND: `ssh -F '${join(directory, "ssh_config")}'`,
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
  const key = record.sshKey as Record<string, unknown> | null | undefined;
  const identity = record.identity as Record<string, unknown> | null | undefined;
  const sshKey =
    key && typeof key.privateKey === "string" && typeof key.publicKey === "string" && key.privateKey.startsWith("-----BEGIN ")
      ? { privateKey: key.privateKey, publicKey: key.publicKey.trim() }
      : null;
  const name = typeof identity?.name === "string" ? identity.name : "";
  const email = typeof identity?.email === "string" ? identity.email : "";
  const control = /[\u0000-\u001f\u007f]/;
  return {
    sshKey,
    identity: (name || email) && !control.test(name) && !control.test(email) ? { name, email } : null,
  };
}

export const gitDigest = (setup: GitSetup) => createHash("sha256").update(JSON.stringify(setup)).digest("hex");

/**
 * The setup, asked of the host at most once a minute, failures included (like credentials, it
 * is cached in memory only). A failed request keeps the last answer, so a host restart never
 * strips a bot's key; with no answer yet it is undefined and nothing is written.
 */
export class HostGitSource {
  readonly #fetch: () => Promise<GitSetup>;
  readonly #ttlMs: number;
  #value: GitSetup | undefined;
  #at = 0;
  #pending: Promise<GitSetup | undefined> | undefined;

  constructor(fetch: () => Promise<GitSetup>, ttlMs = 60_000) {
    this.#fetch = fetch;
    this.#ttlMs = ttlMs;
  }

  current(): Promise<GitSetup | undefined> {
    if (this.#at && Date.now() - this.#at < this.#ttlMs) return Promise.resolve(this.#value);
    this.#pending ??= this.#fetch()
      .then((value) => {
        this.#value = value;
        this.#at = Date.now();
        return value;
      })
      .catch(() => {
        this.#at = Date.now();
        return this.#value;
      })
      .finally(() => {
        this.#pending = undefined;
      });
    return this.#pending;
  }
}
