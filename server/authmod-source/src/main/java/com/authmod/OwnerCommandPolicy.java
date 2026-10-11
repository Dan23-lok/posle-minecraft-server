package com.authmod;

import java.util.Locale;
import java.util.Set;

/** Commands that may run with temporary owner permissions after AuthMod login. */
final class OwnerCommandPolicy {
    private static final Set<String> ALLOWED = Set.of(
            "gamemode", "tp", "teleport", "give", "time", "weather", "fill",
            "setblock", "summon", "kill", "effect", "gamerule"
    );

    private OwnerCommandPolicy() {
    }

    static boolean permits(String configuredOwner, String playerName, boolean authenticated, String command) {
        if (!authenticated || configuredOwner == null || configuredOwner.isBlank()
                || playerName == null || !configuredOwner.equals(playerName) || command == null
                || !command.equals(command.trim()) || command.isEmpty()) return false;

        // No namespaced aliases or nested commands. NBT and control characters are excluded so
        // this wrapper cannot place a command block/minecart carrying a later /op command.
        String head = command.split("\\s+", 2)[0].toLowerCase(Locale.ROOT);
        if (head.indexOf(':') >= 0 || !ALLOWED.contains(head)) return false;
        if (command.indexOf('{') >= 0 || command.indexOf('}') >= 0
                || command.indexOf('"') >= 0 || command.indexOf('\'') >= 0
                || command.indexOf('\\') >= 0 || command.indexOf('/') >= 0) return false;
        for (int i = 0; i < command.length(); i++) {
            if (Character.isISOControl(command.charAt(i))) return false;
        }

        String lower = command.toLowerCase(Locale.ROOT);
        return !lower.contains("command_block") && !lower.contains("commandblock")
                && !lower.contains("structure_block") && !lower.contains("jigsaw");
    }
}
