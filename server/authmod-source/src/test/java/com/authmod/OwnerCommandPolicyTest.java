package com.authmod;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class OwnerCommandPolicyTest {
    @Test
    void ownerMustBeConfiguredAndLoggedInOnCurrentSession() {
        assertFalse(OwnerCommandPolicy.permits("", "AuthStage7", true, "gamemode creative"));
        assertFalse(OwnerCommandPolicy.permits("AuthStage7", "AuthStage7", false, "gamemode creative"));
        assertFalse(OwnerCommandPolicy.permits("AuthStage7", "authstage7", true, "gamemode creative"));
        assertFalse(OwnerCommandPolicy.permits("AuthStage7", "OtherPlayer", true, "gamemode creative"));
        assertTrue(OwnerCommandPolicy.permits("AuthStage7", "AuthStage7", true, "gamemode creative"));
    }

    @Test
    void adminCommandsCannotPersistOpOrReenterWrapper() {
        for (String forbidden : new String[] {
                "owner gamemode creative", "op AuthStage7", "deop AuthStage7",
                "execute run op AuthStage7", "function example:grant_op",
                "authmod changepassword AuthStage7 secret", "changepassword old new",
                "login secret", "register secret invite", "minecraft:op AuthStage7",
                "/op AuthStage7", "  op AuthStage7", "gamemode\n/op AuthStage7",
                "give @s minecraft:command_block", "setblock ~ ~ ~ minecraft:repeating_command_block",
                "summon minecraft:command_block_minecart ~ ~ ~",
                "summon minecraft:zombie ~ ~ ~ {Command:\"op AuthStage7\"}"
        }) {
            assertFalse(OwnerCommandPolicy.permits("AuthStage7", "AuthStage7", true, forbidden), forbidden);
        }
        assertTrue(OwnerCommandPolicy.permits("AuthStage7", "AuthStage7", true, "tp 0 80 0"));
        assertTrue(OwnerCommandPolicy.permits("AuthStage7", "AuthStage7", true, "time set day"));
    }
}
