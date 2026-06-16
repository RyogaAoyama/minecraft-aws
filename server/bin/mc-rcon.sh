#!/bin/bash
#
# RCON 実行の共通ラッパ。
# 他の管理スクリプトから `source` して `mc_rcon "<command>"` で呼び出す。
#
# RCON パスワードは SSM Parameter Store(SecureString) から都度取得し、
# 一時ファイルには残さず環境変数経由で mcrcon へ渡す（コマンドライン引数に
# パスワードを置くと `ps` で漏れるため、mcrcon の MCRCON_PASS 環境変数を使う）。
#
# 前提: 呼び出し元が事前に /etc/minecraft.env を source していること
#       （AWS_REGION / RCON_PORT / RCON_PASSWORD_SSM を参照する）。

# RCON パスワードを SSM から取得する。
# 取得値は標準出力へ返す（呼び出し側で変数に取る）。
#
# 引数: なし
# 出力: RCON パスワード（改行なし）
function mc_rcon_password {
    aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$RCON_PASSWORD_SSM" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text
}

# RCON コマンドを Minecraft サーバーへ送信し、応答を標準出力へ返す。
#
# 引数: $* 送信する RCON コマンド（例: "list"、"save-all flush"）
# 戻り値: mcrcon の終了コード
function mc_rcon {
    MCRCON_PASS="$(mc_rcon_password)" \
        mcrcon -H 127.0.0.1 -P "$RCON_PORT" "$@"
}
