# hopbox box
> An isolated Linux box you reached over SSH — root shell, network, a persistent home. This guide is for whoever is driving the box, human or AI.

You're inside a **hopbox** box: a Firecracker microVM (or container) spawned when you
connected. You have **root**, outbound internet, and a home directory your files land in
(`scp`/`sftp`/`rsync` paths are relative to it). It's isolated — a safe place to run
untrusted code.

## box-guest — this box's control CLI

`box-guest` is preinstalled and talks to hopbox about *this* box. The commands worth
knowing (run `box-guest` with no args for the full list):

- `box-guest info` — this box's name, image, status, resources, load.
- `box-guest skill` — print this guide (with the image's specifics appended below).
- `box-guest status working "building X"` — report what you're doing; shows in the fleet.
- `box-guest keep-alive 30m` — hold the box alive for a while (e.g. a long detached job).
- `box-guest auto-suspend off` — never suspend (verified accounts only).
- `box-guest idle 15m` — change this box's idle-suspend timeout.
- `box-guest run <cmd>` — run a command **detached**; the box stays alive until it
  finishes. `box-guest jobs` lists them; `box-guest logs <id>` shows output.
- `box-guest ask "Ship it?" -o yes -o no` — ask the human a structured question and block
  until they answer from their control plane; this box's "needs you" queue.
- `box-guest mcp` — run an MCP server (stdio) so an AI working *inside* this box can
  manage its own sandbox.

## Lifecycle — when this box sleeps, and when it dies

- **Named boxes** (`ssh myproj@host`) **auto-suspend** after ~5m idle: memory is
  snapshotted to disk and compute stops. Your next connection **resumes** it — kernel,
  processes, and open sockets intact. Nothing is lost on disconnect.
- A box left untouched for a long time is eventually **idle-reaped (deleted)** to bound
  storage — **unless the owner is a verified account**, whose boxes persist (the durable
  tier). `keep-alive` and `auto-suspend off` also hold a box against reaping.
- Your **persistent home** (`/home/dev`) survives suspend, resume, reap, and image
  rebuilds — files you keep there outlive the box itself. The rest of the filesystem is
  ephemeral.
- **Anonymous / browser boxes** are throwaway: reaped a short grace window after you
  disconnect.

`box-guest info` folds all of this into one status word (`running` / `suspended` /
`pinned` / `kept` / `ephemeral`) and tells you what happens next.

## Shared drive & secrets

- **`/wrk`** — a shared drive mounted in *every* box in your workspace. Stage inputs and
  collect outputs across a fan-out of boxes here.
- Secrets set on your account or workspace are injected as environment variables at spawn.

## Isolation

The box reaches the internet and the hopbox hub, but **not** the host's other services,
its LAN, or your tailnet. Untrusted code stays contained.
