# AuthMod — Forge 1.20.1 server authentication

This is an MIT-licensed fork of d-society1/AuthMod (https://github.com/d-society1/AuthMod). It is intended for a small Forge server that permits offline launcher profiles.

## Commands

- /register <personalPassword> <inviteCode> — register a nickname once.
- /login <personalPassword> — unlock the current player session.
- /changepassword <oldPassword> <newPassword> — change your own password.
- /authmod changepassword <player> <newPassword> and /authmod resetpassword <player> — operator-only recovery commands.

The server owner creates authmod_invite_code.txt in the server working directory before starting Forge. The file must contain at least 16 characters and must stay private. If it is missing or unreadable, new registrations are disabled. Each player chooses a separate password of at least 12 characters by default.

Unauthenticated players are placed in spectator mode and ordinary movement, interaction, inventory drops, chat and commands other than /login and /register are blocked. They are disconnected after 120 seconds. Three failed login attempts lock a nickname for 60 seconds by default. A successful login unlocks only that specific player connection, even when two offline nicknames differ only in letter case. The mod never grants OP.

New passwords are stored as salted PBKDF2-HMAC-SHA256 hashes (120,000 iterations) in authmod_data.json. The data format is compatible with earlier AuthMod versions; legacy plaintext entries are upgraded after their first successful login. Protect the data file and its parent directory with operating-system access controls and backups.

## Configuration

Forge writes world/serverconfig/authmod-server.toml for each world. The defaults are minPasswordLength=12, maxLoginAttempts=3, lockoutSeconds=60, and language=auto.

The mod is installed only on the server; its displayTest permits clients without it. It requires Forge 47.4.0+ on Minecraft 1.20.1. Use Java 17.

## Limits

Offline mode does not prove ownership of a nickname. Passwords are entered as Minecraft commands and should be unique to this server. Do not grant OP to offline-mode nicknames; use the local server console for administration. This mod does not protect against network floods or vulnerabilities in other mods.

## Build and test

Run gradlew.bat clean build on Windows or ./gradlew clean build on other systems with JDK 17. Gradle downloads the Forge toolchain. The reobfuscated JAR is written to build/libs/authmod-1.5.1-codex3.jar; regression tests run as part of build.

License: MIT. Original author: dQryyx / d-society1. This fork adds invite-only registration, fail-closed data handling, session isolation, a login timeout, and stronger default password length.
