package com.authmod;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import com.mojang.brigadier.context.CommandContext;
import com.mojang.brigadier.exceptions.CommandSyntaxException;
import com.mojang.brigadier.suggestion.SuggestionProvider;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ServerPlayer;
import net.minecraftforge.server.ServerLifecycleHooks;

import java.util.Locale;
import java.util.function.Consumer;

public class AuthCommands {

    /** Автодополнение по всем зарегистрированным именам (включая офлайн). */
    private static final SuggestionProvider<CommandSourceStack> REGISTERED_PLAYERS = (context, builder) -> {
        String remaining = builder.getRemaining().toLowerCase(Locale.ROOT);
        for (String name : AuthData.registeredPlayers()) {
            if (name.toLowerCase(Locale.ROOT).startsWith(remaining)) {
                builder.suggest(name);
            }
        }
        return builder.buildFuture();
    };

    public static void register(CommandDispatcher<CommandSourceStack> dispatcher) {
        dispatcher.register(Commands.literal("register")
                .executes(context -> {
                    ServerPlayer player = context.getSource().getPlayerOrException();
                    player.sendSystemMessage(Lang.msg(player, "authmod.usage.register"));
                    return 0;
                })
                .then(Commands.argument("password", StringArgumentType.word())
                        .executes(context -> {
                            ServerPlayer player = context.getSource().getPlayerOrException();
                            player.sendSystemMessage(Lang.msg(player, "authmod.usage.register"));
                            return 0;
                        })
                        .then(Commands.argument("inviteCode", StringArgumentType.word())
                        .executes(context -> {
                            ServerPlayer player = context.getSource().getPlayerOrException();
                            String password = StringArgumentType.getString(context, "password");
                            String inviteCode = StringArgumentType.getString(context, "inviteCode");
                            String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);

                            if (password.length() < AuthConfig.minPasswordLength()) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.password.too_short", AuthConfig.minPasswordLength()));
                                return 0;
                            }
                            if (!PasswordPolicy.withinNewPasswordLength(password)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.password.too_long", PasswordPolicy.MAX_NEW_LENGTH));
                                return 0;
                            }
                            if (!PasswordPolicy.fitsRegisterCommand(password, inviteCode)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.password.too_long", PasswordPolicy.maxRegistrationPasswordLength(inviteCode)));
                                return 0;
                            }

                            if (!InviteCode.verify(inviteCode)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.register.wrong_invite"));
                                return 0;
                            }

                            if (AuthData.isRegistered(username)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.register.already"));
                                player.sendSystemMessage(Lang.msg(player, "authmod.register.hint_login"));
                                return 0;
                            }

                            AuthEventHandler.RegistrationSubmission submission = AuthEventHandler.registerPlayer(
                                    player, password, inviteCode, result -> finishRegistration(player, result));
                            switch (submission) {
                                case ACCEPTED -> player.sendSystemMessage(Lang.msg(player, "authmod.register.checking"));
                                case ALREADY_PENDING -> player.sendSystemMessage(Lang.msg(player, "authmod.register.pending"));
                                case BUSY -> player.sendSystemMessage(Lang.msg(player, "authmod.register.busy"));
                                case RATE_LIMITED -> player.sendSystemMessage(Lang.msg(player, "authmod.register.rate_limited"));
                                case FULL -> player.sendSystemMessage(Lang.msg(player, "authmod.register.full"));
                                case ALREADY_REGISTERED -> player.sendSystemMessage(Lang.msg(player, "authmod.register.already"));
                                case INVALID_INVITE -> player.sendSystemMessage(Lang.msg(player, "authmod.register.wrong_invite"));
                                case TIMED_OUT -> player.sendSystemMessage(Lang.msg(player, "authmod.register.timed_out"));
                            }
                            return submission == AuthEventHandler.RegistrationSubmission.ACCEPTED ? 1 : 0;
                        })
                        )
                )
        );

        dispatcher.register(Commands.literal("login")
                .executes(context -> {
                    ServerPlayer player = context.getSource().getPlayerOrException();
                    player.sendSystemMessage(Lang.msg(player, "authmod.usage.login"));
                    return 0;
                })
                .then(Commands.argument("password", StringArgumentType.word())
                        .executes(context -> {
                            ServerPlayer player = context.getSource().getPlayerOrException();
                            String password = StringArgumentType.getString(context, "password");
                            String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);

                            if (!PasswordPolicy.withinMaxLength(password)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.password.too_long", PasswordPolicy.MAX_LENGTH));
                                return 0;
                            }

                            if (!AuthData.isRegistered(username)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.login.not_registered"));
                                player.sendSystemMessage(Lang.msg(player, "authmod.login.hint_register"));
                                return 0;
                            }

                            if (LoginLimiter.isLocked(player.connection)) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.limiter.too_many_attempts"));
                                player.sendSystemMessage(Lang.msg(player, "authmod.limiter.cooldown", LoginLimiter.remainingSeconds(player.connection)));
                                return 0;
                            }

                            long retryDelay = LoginLimiter.remainingSeconds(player.connection);
                            if (retryDelay > 0) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.limiter.cooldown", retryDelay));
                                return 0;
                            }

                            LoginVerificationQueue.Submission submission = AuthEventHandler.verifyLogin(
                                    player, password, result -> finishLogin(player, result));
                            if (submission == LoginVerificationQueue.Submission.ALREADY_PENDING) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.login.checking"));
                            } else if (submission == LoginVerificationQueue.Submission.BUSY) {
                                player.sendSystemMessage(Lang.msg(player, "authmod.login.busy"));
                            }
                            return 0;
                        })
                )
        );

        // No persistent OP entry is needed. The elevated source exists for this one command only.
        dispatcher.register(Commands.literal("owner")
                .then(Commands.argument("command", StringArgumentType.greedyString())
                        .executes(AuthCommands::ownerCommand))
        );

        // Смена собственного пароля игроком
        dispatcher.register(Commands.literal("changepassword")
                .executes(context -> {
                    ServerPlayer player = context.getSource().getPlayerOrException();
                    player.sendSystemMessage(Lang.msg(player, "authmod.usage.changepassword"));
                    return 0;
                })
                .then(Commands.argument("oldPassword", StringArgumentType.word())
                        .then(Commands.argument("newPassword", StringArgumentType.word())
                                .executes(AuthCommands::changeOwnPassword)
                        )
                )
        );

        // Административные команды: только операторы (permission level 2)
        dispatcher.register(Commands.literal("authmod")
                .executes(context -> {
                    reply(context.getSource(), "authmod.usage.authmod");
                    return 0;
                })
                .then(Commands.literal("changepassword")
                        .requires(source -> source.hasPermission(2))
                        .then(Commands.argument("player", StringArgumentType.word())
                                .suggests(REGISTERED_PLAYERS)
                                .then(Commands.argument("newPassword", StringArgumentType.word())
                                        .executes(AuthCommands::adminChangePassword)
                                )
                        )
                )
                .then(Commands.literal("resetpassword")
                        .requires(source -> source.hasPermission(2))
                        .then(Commands.argument("player", StringArgumentType.word())
                                .suggests(REGISTERED_PLAYERS)
                                .executes(AuthCommands::adminResetPassword)
                        )
                )
        );
    }

    private static int changeOwnPassword(CommandContext<CommandSourceStack> context) throws CommandSyntaxException {
        ServerPlayer player = context.getSource().getPlayerOrException();
        String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);
        String oldPassword = StringArgumentType.getString(context, "oldPassword");
        String newPassword = StringArgumentType.getString(context, "newPassword");

        if (!PasswordPolicy.withinMaxLength(oldPassword)) {
            player.sendSystemMessage(Lang.msg(player, "authmod.password.too_long", PasswordPolicy.MAX_LENGTH));
            return 0;
        }
        if (!PasswordPolicy.withinNewPasswordLength(newPassword)) {
            player.sendSystemMessage(Lang.msg(player, "authmod.password.too_long", PasswordPolicy.MAX_NEW_LENGTH));
            return 0;
        }
        if (!PasswordPolicy.fitsChangeCommand(oldPassword, newPassword)) {
            player.sendSystemMessage(Lang.msg(player, "authmod.password.too_long", PasswordPolicy.maxChangePasswordLength(oldPassword)));
            return 0;
        }

        if (newPassword.length() < AuthConfig.minPasswordLength()) {
            player.sendSystemMessage(Lang.msg(player, "authmod.password.too_short", AuthConfig.minPasswordLength()));
            return 0;
        }
        AuthEventHandler.ChangeSubmission submission = AuthEventHandler.changeOwnPassword(
                player, oldPassword, newPassword, outcome -> finishPasswordChange(player, username, outcome));
        switch (submission) {
            case ACCEPTED -> player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.checking"));
            case ALREADY_PENDING -> player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.pending"));
            case BUSY -> player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.busy"));
            case RATE_LIMITED -> player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.rate_limited"));
        }
        return submission == AuthEventHandler.ChangeSubmission.ACCEPTED ? 1 : 0;
    }

    private static void finishLogin(ServerPlayer player, AuthEventHandler.LoginOutcome result) {
        if (result == AuthEventHandler.LoginOutcome.SUCCESS) {
            LoginLimiter.reset(player.connection);
            player.sendSystemMessage(Lang.msg(player, "authmod.login.success"));
            player.sendSystemMessage(Lang.msg(player, "authmod.login.welcome"));
        } else if (result == AuthEventHandler.LoginOutcome.PASSWORD_CHANGED) {
            player.sendSystemMessage(Lang.msg(player, "authmod.login.changed"));
        } else {
            LoginLimiter.recordFailure(player.connection);
            if (LoginLimiter.isLocked(player.connection)) {
                player.connection.disconnect(Lang.msg(player, "authmod.limiter.kicked"));
            } else {
                player.sendSystemMessage(Lang.msg(player, "authmod.login.wrong_password"));
                player.sendSystemMessage(Lang.msg(player, "authmod.limiter.cooldown", LoginLimiter.remainingSeconds(player.connection)));
            }
        }
    }

    private static void finishRegistration(ServerPlayer player, AuthEventHandler.RegistrationOutcome result) {
        switch (result) {
            case SUCCESS -> {
                player.sendSystemMessage(Lang.msg(player, "authmod.register.success"));
                player.sendSystemMessage(Lang.msg(player, "authmod.register.play"));
            }
            case ALREADY_REGISTERED -> player.sendSystemMessage(Lang.msg(player, "authmod.register.already"));
            case INVALID_INVITE -> player.sendSystemMessage(Lang.msg(player, "authmod.register.wrong_invite"));
            case TIMED_OUT -> player.sendSystemMessage(Lang.msg(player, "authmod.register.timed_out"));
            case FULL -> player.sendSystemMessage(Lang.msg(player, "authmod.register.full"));
            case HASH_FAILED, SAVE_FAILED -> player.sendSystemMessage(Lang.msg(player, "authmod.error.data_save"));
        }
    }

    private static void finishPasswordChange(ServerPlayer player, String username,
                                             AuthEventHandler.ChangeOutcome outcome) {
        switch (outcome) {
            case SUCCESS -> {
                forEachOnlineMatch(username, other -> {
                    if (other != player) AuthEventHandler.forceRelock(other);
                });
                player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.success"));
            }
            case WRONG_OLD -> player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.wrong_old"));
            case CHANGED_DURING_CHECK -> player.sendSystemMessage(Lang.msg(player, "authmod.changepassword.changed"));
            case HASH_FAILED, SAVE_FAILED -> player.sendSystemMessage(Lang.msg(player, "authmod.error.data_save"));
        }
    }

    private static int ownerCommand(CommandContext<CommandSourceStack> context) throws CommandSyntaxException {
        ServerPlayer player = context.getSource().getPlayerOrException();
        String command = StringArgumentType.getString(context, "command");
        if (!OwnerCommandPolicy.permits(AuthConfig.ownerUsername(), player.getGameProfile().getName(),
                AuthEventHandler.isAuthenticated(player), command)) {
            player.sendSystemMessage(Component.literal("Owner command unavailable."));
            return 0;
        }
        // Do not log command contents: arguments may include private world coordinates.
        return player.server.getCommands().performPrefixedCommand(
                player.createCommandSourceStack().withPermission(4), command);
    }

    /** /authmod changepassword <player> <newPassword> — работает и с офлайн-игроками. */
    private static int adminChangePassword(CommandContext<CommandSourceStack> context) {
        String target = StringArgumentType.getString(context, "player").toLowerCase(Locale.ROOT);
        String newPassword = StringArgumentType.getString(context, "newPassword");

        if (!PasswordPolicy.withinNewPasswordLength(newPassword)) {
            reply(context.getSource(), "authmod.password.too_long", PasswordPolicy.MAX_NEW_LENGTH);
            return 0;
        }

        if (!AuthData.isRegistered(target)) {
            reply(context.getSource(), "authmod.admin.player_not_registered", target);
            return 0;
        }
        if (newPassword.length() < AuthConfig.minPasswordLength()) {
            reply(context.getSource(), "authmod.password.too_short", AuthConfig.minPasswordLength());
            return 0;
        }
        try {
            if (!AuthData.setPlayerPasswordAndSave(target, newPassword)) {
                reply(context.getSource(), "authmod.error.data_save");
                return 0;
            }
        } catch (RuntimeException e) {
            reply(context.getSource(), "authmod.error.data_save");
            return 0;
        }
        reply(context.getSource(), "authmod.admin.changepassword.success", target);

        forEachOnlineMatch(target, targetPlayer -> {
            AuthEventHandler.forceRelock(targetPlayer);
            targetPlayer.sendSystemMessage(Lang.msg(targetPlayer, "authmod.admin.changepassword.notice"));
        });
        return 1;
    }

    /** /authmod resetpassword <player> — удаляет регистрацию, игрок заново делает /register. */
    private static int adminResetPassword(CommandContext<CommandSourceStack> context) {
        String target = StringArgumentType.getString(context, "player").toLowerCase(Locale.ROOT);

        if (!AuthData.isRegistered(target)) {
            reply(context.getSource(), "authmod.admin.player_not_registered", target);
            return 0;
        }
        try {
            if (!AuthData.removePlayerAndSave(target)) {
                reply(context.getSource(), "authmod.error.data_save");
                return 0;
            }
        } catch (RuntimeException e) {
            reply(context.getSource(), "authmod.error.data_save");
            return 0;
        }
        reply(context.getSource(), "authmod.admin.resetpassword.success", target);

        forEachOnlineMatch(target, targetPlayer -> {
            targetPlayer.sendSystemMessage(Lang.msg(targetPlayer, "authmod.admin.resetpassword.notice"));
            AuthEventHandler.forceRelock(targetPlayer);
        });
        return 1;
    }

    /** Ответ игроку его языком, либо в консоль языком сервера. */
    private static void reply(CommandSourceStack source, String key, Object... args) {
        ServerPlayer player = source.getPlayer();
        if (player != null) {
            player.sendSystemMessage(Lang.msg(player, key, args));
        } else {
            source.sendSuccess(() -> Lang.consoleMsg(key, args), false);
        }
    }

    private static void forEachOnlineMatch(String username, Consumer<ServerPlayer> action) {
        var server = ServerLifecycleHooks.getCurrentServer();
        if (server == null) return;
        for (ServerPlayer player : server.getPlayerList().getPlayers()) {
            if (player.getGameProfile().getName().equalsIgnoreCase(username)) action.accept(player);
        }
    }
}
