package com.authmod;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PasswordCommandBudgetTest {
    @Test
    void newPasswordsFitTwoPasswordChangeCommands() {
        assertEquals(256, PasswordPolicy.MAX_COMMAND_LENGTH);
        assertEquals(120, PasswordPolicy.MAX_NEW_LENGTH);
        assertTrue(PasswordPolicy.withinNewPasswordLength("a".repeat(120)));
        assertFalse(PasswordPolicy.withinNewPasswordLength("a".repeat(121)));
        assertTrue(PasswordPolicy.fitsChangeCommand("a".repeat(120), "b".repeat(120)));
        assertFalse(PasswordPolicy.fitsChangeCommand("a".repeat(121), "b".repeat(120)));
        assertEquals(40, PasswordPolicy.maxChangePasswordLength("a".repeat(200)));
        assertTrue(PasswordPolicy.fitsChangeCommand("a".repeat(200), "b".repeat(40)));
        assertFalse(PasswordPolicy.fitsChangeCommand("a".repeat(200), "b".repeat(41)));
    }

    @Test
    void registrationBudgetIncludesInviteAndSpaces() {
        assertEquals(120, PasswordPolicy.maxRegistrationPasswordLength("i".repeat(126)));
        assertEquals(119, PasswordPolicy.maxRegistrationPasswordLength("i".repeat(127)));
        assertTrue(PasswordPolicy.fitsRegisterCommand("p".repeat(120), "i".repeat(126)));
        assertFalse(PasswordPolicy.fitsRegisterCommand("p".repeat(120), "i".repeat(127)));
    }

    @Test
    void legacyVerificationStillAcceptsOldPasswordThatFitsLoginPacket() {
        String old = "z".repeat(250);
        String stored = PasswordHasher.hash(old);
        assertTrue(PasswordPolicy.fitsLoginCommand(old));
        assertTrue(PasswordHasher.verify(old, stored));
        assertFalse(PasswordPolicy.withinNewPasswordLength(old));
        assertFalse(PasswordPolicy.fitsLoginCommand("z".repeat(251)));
    }

    @Test
    void accountWriteRejectsNewPasswordAboveUsableMaximum() {
        String account = "stage-overlong-new-password";
        assertThrows(IllegalArgumentException.class,
                () -> AuthData.setPlayerPassword(account, "p".repeat(121)));
        assertFalse(AuthData.isRegistered(account));
    }
}
