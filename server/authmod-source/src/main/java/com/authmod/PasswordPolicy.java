package com.authmod;

/** Minecraft's command packet limit and safe bounds for new and existing passwords. */
public final class PasswordPolicy {
    public static final int MAX_COMMAND_LENGTH = 256;
    /** Preserve verification and hashing of older passwords already accepted by codex6. */
    public static final int MAX_LENGTH = 256;
    /** "changepassword " + old + " " + new fits when both new passwords are this long. */
    public static final int MAX_NEW_LENGTH = (MAX_COMMAND_LENGTH - "changepassword ".length() - 1) / 2;

    private PasswordPolicy() {
    }

    public static boolean withinMaxLength(String password) {
        return password != null && password.length() <= MAX_LENGTH;
    }

    public static boolean withinNewPasswordLength(String password) {
        return password != null && password.length() <= MAX_NEW_LENGTH;
    }

    public static int maxRegistrationPasswordLength(String inviteCode) {
        if (inviteCode == null) return 0;
        int packetBudget = MAX_COMMAND_LENGTH - "register ".length() - 1 - inviteCode.length();
        return Math.max(0, Math.min(MAX_NEW_LENGTH, packetBudget));
    }

    public static boolean fitsRegisterCommand(String password, String inviteCode) {
        return withinNewPasswordLength(password)
                && password.length() <= maxRegistrationPasswordLength(inviteCode);
    }

    public static int maxChangePasswordLength(String oldPassword) {
        if (oldPassword == null) return 0;
        int packetBudget = MAX_COMMAND_LENGTH - "changepassword ".length() - 1 - oldPassword.length();
        return Math.max(0, Math.min(MAX_NEW_LENGTH, packetBudget));
    }

    public static boolean fitsChangeCommand(String oldPassword, String newPassword) {
        return oldPassword != null && withinNewPasswordLength(newPassword)
                && newPassword.length() <= maxChangePasswordLength(oldPassword);
    }

    public static boolean fitsLoginCommand(String password) {
        return withinMaxLength(password)
                && "login ".length() + password.length() <= MAX_COMMAND_LENGTH;
    }
}
