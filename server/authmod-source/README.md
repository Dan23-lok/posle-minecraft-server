# AuthMod — Forge 1.20.1 server authentication

This is an MIT-licensed fork of d-society1/AuthMod (https://github.com/d-society1/AuthMod). It is intended for a small Forge server that permits offline launcher profiles.

## Commands

- /register <personalPassword> <inviteCode> — register a nickname once.
- /login <personalPassword> — unlock the current player session.
- /changepassword <oldPassword> <newPassword> — change your own password.
- /owner <allowed command> — after login, the exact configured owner may run one command with temporary permission; see restrictions below.
- /authmod changepassword <player> <newPassword> and /authmod resetpassword <player> — operator-only recovery commands.

The server owner creates authmod_invite_code.txt in the server working directory before starting Forge. The file must contain at least 16 characters and must stay private. If it is missing or unreadable, new registrations are disabled. Each player chooses a separate password of 12–120 characters by default.

Unauthenticated players are placed in spectator mode and ordinary movement, interaction, inventory drops, chat and commands other than /login and /register are blocked. They are disconnected after 300 seconds. A wrong password delays the next verification on that live connection by 1, 2, 4, then 8 seconds by default; the fifth verified wrong password kicks that connection. Attempts entered during a delay are rejected without checking the password or counting toward five. One player's failures do not lock another connection using the same nickname. A successful login resets the connection's limiter and unlocks only that player session, even when two offline nicknames differ only in letter case. The mod itself never grants persistent OP. In an isolated test, a TACZ gun-draw packet reached its handler before AuthMod login; third-party packet behavior is not fully blocked by these Forge event handlers.

New passwords are stored as salted PBKDF2-HMAC-SHA256 hashes (120,000 iterations) in authmod_data.json. The data format is compatible with earlier AuthMod versions; legacy plaintext entries are upgraded after their first successful login. Protect the data file and its parent directory with operating-system access controls and backups.

## Configuration

Forge writes world/serverconfig/authmod-server.toml for each world. The defaults are minPasswordLength=12, maxLoginAttempts=5, loginTimeoutSeconds=300, lockoutSeconds=60, and language=auto. Minecraft 1.20.1 limits a complete client command packet to 256 UTF-16 code units, excluding the leading `/`. New passwords are capped at 120 so `/changepassword` fits even when both old and new passwords are 120 characters. Registration additionally caps the password at `min(120, 246 - invitation length)`; the recommended 48-character invitation leaves the full 120-character password budget. Existing passwords accepted by earlier builds can still be verified up to the previous 256-character safety cap; a password of up to 250 characters fits `/login `. A user changing a longer legacy password may need to choose a shorter replacement so the full `/changepassword old new` command fits. The `lockoutSeconds` key is retained for configuration compatibility; it caps the delay on one connection and no longer locks a nickname globally.

`ownerUsername` defaults to empty. The production world sets the exact-case owner name privately and has `ops.json=[]`. After successful login, `/owner` permits only `gamemode`, `tp`, `teleport`, `give`, `time`, `weather`, `fill`, `setblock`, `summon`, `kill`, `effect`, and `gamerule`. The policy rejects nested commands, NBT, command blocks, namespaced aliases, and control characters. Account recovery remains a local console operation.

The mod is installed only on the server; its displayTest permits clients without it. It requires Forge 47.4.0+ on Minecraft 1.20.1. Use Java 17.

## Limits

Offline mode does not prove ownership of a nickname. Passwords are entered as Minecraft commands and should be unique to this server; confidentiality of those commands through the current Minecraft/Playit route has not been verified. Production now runs the codex8 JAR with no persistent OP entry, but owner login has not yet been tested in the owner's TLauncher after that change. Per-connection delays prevent one nickname from locking out the owner, but repeated new connections can still invoke synchronous PBKDF2 and consume server ticks. A shared global rate limit could also delay the owner under attack; nickname or proxy-IP limits would reintroduce an owner lockout. TACZ and potentially other mods accept custom packets outside AuthMod's pre-login event checks. This mod does not protect against network floods or vulnerabilities in other mods.

## Build and test

Run gradlew.bat clean build on Windows or ./gradlew clean build on other systems with JDK 17. Gradle downloads the Forge toolchain. The reobfuscated JAR is written to build/libs/authmod-1.5.2-codex8-staging.jar; regression tests run as part of build. The production JAR was matched to this build by SHA-256 and started with the saved world; the owner's client login remains a separate verification gate.

License: MIT. Original author: dQryyx / d-society1. This fork adds invite-only registration, fail-closed data handling, session isolation, a login timeout, and stronger default password length.
