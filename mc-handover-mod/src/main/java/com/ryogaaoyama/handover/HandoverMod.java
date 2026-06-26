package com.ryogaaoyama.handover;

import com.mojang.brigadier.arguments.IntegerArgumentType;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.minecraft.network.packet.s2c.common.ServerTransferS2CPacket;
import net.minecraft.server.command.CommandManager;
import net.minecraft.server.command.ServerCommandSource;
import net.minecraft.server.network.ServerPlayerEntity;
import net.minecraft.text.Text;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import static net.minecraft.server.command.CommandManager.argument;
import static net.minecraft.server.command.CommandManager.literal;

public class HandoverMod implements ModInitializer {
    public static final String MOD_ID = "handover";
    private static final Logger LOG = LoggerFactory.getLogger(MOD_ID);

    @Override
    public void onInitialize() {
        CommandRegistrationCallback.EVENT.register((dispatcher, registryAccess, environment) -> {
            // /transfer-all <host> <port>
            //   接続中の全プレイヤーへバニラ Transfer S2C パケットを送り、
            //   指定の host:port へ自動再接続させる。RCON 経由で発火する想定。
            //
            //   バニラにも `/transfer <hostname> <port>` が存在するが、本コマンドは
            //   名前が明示的に「all」を含むため運用上の意図が読み取りやすい。
            dispatcher.register(literal("transfer-all")
                // ADMINS_CHECK 相当: バニラ /transfer と同等のパーミッション。
                .requires(CommandManager.requirePermissionLevel(CommandManager.ADMINS_CHECK))
                .then(argument("host", StringArgumentType.string())
                    .then(argument("port", IntegerArgumentType.integer(1, 65535))
                        .executes(ctx -> {
                            String host = StringArgumentType.getString(ctx, "host");
                            int port = IntegerArgumentType.getInteger(ctx, "port");
                            return transferAll(ctx.getSource(), host, port);
                        }))));
        });
        LOG.info("[handover] /transfer-all コマンドを登録しました");
    }

    private static int transferAll(ServerCommandSource source, String host, int port) {
        var server = source.getServer();
        var packet = new ServerTransferS2CPacket(host, port);
        int count = 0;
        for (ServerPlayerEntity player : server.getPlayerManager().getPlayerList()) {
            player.networkHandler.sendPacket(packet);
            count++;
        }
        final int finalCount = count;
        LOG.info("[handover] {} 人を {}:{} へ Transfer しました", finalCount, host, port);
        source.sendFeedback(() -> Text.literal(
            String.format("[handover] %d 人を %s:%d へ Transfer しました", finalCount, host, port)), true);
        return finalCount;
    }
}
