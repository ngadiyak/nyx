# Prompt: Nyx Remote Sessions

Design and implement a personal-use Nyx feature for relay-based remote terminal sessions.

Context: I use agent chats and terminal sessions across multiple machines, and each machine has different local context: repos, running processes, agent history, dev servers, files, and credentials. I want Nyx on machine 1 to attach to an existing Nyx/agent session on machine 2 through a relay server, without requiring direct network connectivity between the machines.

Available relay host: `89.124.111.196`. I have root SSH access to this server, and it can host the custom server-side relay component.

Server-side code should live in a separate project/repository, likely `nyx-server`: https://github.com/ngadiyak/nyx-server. Keep Nyx focused on the macOS client, PTY ownership, UI, and local device/session state; keep the relay service, deployment files, and server operations in `nyx-server`.

Core idea:
- Both machines connect outbound to a relay server over WebSocket/TLS.
- The relay only routes messages and session metadata.
- Machine 2 owns the real PTY, shell, agent process, cwd, and filesystem context.
- Machine 1 can list, attach to, observe, and optionally control remote sessions from the Nyx UI.

Prioritize this as "agent-native remote context switching", not as an SSH replacement.

MVP:
1. Device identity with a persistent local keypair.
2. One-time pairing/allowlist between trusted devices.
3. Relay service that tracks online devices and routes session messages.
4. Remote session list showing machine, cwd, repo, branch, active process, last command, and last activity.
5. Attach/detach to an existing remote PTY without killing it on disconnect.
6. One active writer at a time, with observer mode for other attached clients.
7. Minimal audit log on the host machine showing who attached and when.

Non-goals for v1:
- File transfer.
- Clipboard sync.
- Sudo/password helpers.
- Multi-user teams.
- Replacing SSH.
- Server-side command execution.

Keep the protocol simple, explicit, and secure enough for personal machines. Prefer an architecture that can later evolve toward end-to-end encrypted PTY payloads where the relay cannot read terminal contents.
