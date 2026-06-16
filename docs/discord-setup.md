# Discord 連携セットアップ手順（ゼロから）

Minecraft サーバーを Discord のスラッシュコマンド `/start` で起動し、
起動完了やアラームを Discord へ通知できるようにするための手順です。

前提:

- AWS スタック一式がデプロイ済み（特に `fnc`= `cloudformation/Function.yml`）。
  Function URL は `minecraft-discord-function-url` として Export されています。
- 本プロジェクトは秘密情報をリポジトリに置きません。
  Discord の **Public Key / Bot Token / Webhook URL** は、SSM Parameter Store(SecureString) に
  手動登録するか、コマンド登録時のみ一時的に使います。

登録する SSM パラメータ（すべて SecureString）:

| パラメータ名 | 用途 | 取得元 |
|---|---|---|
| `RCON_PASSWORD` | RCON パスワード（任意の強いランダム文字列） | 自分で生成 |
| `DISCORD_PUBLIC_KEY` | Interactions 署名検証用の公開鍵 | Discord App の General Information |
| `DISCORD_WEBHOOK` | 通知先チャンネルの Webhook URL | Discord チャンネル設定 |

---

## 1. Discord Application を作成する

1. [Discord Developer Portal](https://discord.com/developers/applications) を開く。
2. **New Application** をクリックし、名前（例: `minecraft-aws`）を付けて作成。
3. 左メニュー **General Information** で以下を控える:
   - **Application ID**（= スラッシュコマンド登録に使う）
   - **Public Key**（= Interactions 署名検証に使う）

## 2. Bot Token を取得する（コマンド登録時のみ使用）

スラッシュコマンドのグローバル登録に Bot Token が必要です。常駐 Bot は不要です。

1. 左メニュー **Bot** → **Reset Token** で Bot Token を生成し控える。
   - この Token はコマンド登録の curl でのみ使い、登録後は破棄してよい（SSM 登録は不要）。
2. 左メニュー **Installation**（または **OAuth2**）で、`applications.commands` スコープを付けて
   サーバーにアプリを追加しておく（コマンドをサーバーで使えるようにするため）。

## 3. SSM に Public Key を登録する

Application の **Public Key** を SecureString として登録します。

```bash
aws ssm put-parameter \
  --profile <profile> --region ap-northeast-1 \
  --name DISCORD_PUBLIC_KEY \
  --type SecureString \
  --value "<Discord Application Public Key>" \
  --overwrite
```

## 4. スラッシュコマンド `/start` をグローバル登録する

`APPLICATION_ID` と `BOT_TOKEN` を埋めて実行します（グローバルコマンドは反映に最大1時間かかる場合あり）。

```bash
APPLICATION_ID="<Application ID>"
BOT_TOKEN="<Bot Token>"

curl -X POST \
  "https://discord.com/api/v10/applications/${APPLICATION_ID}/commands" \
  -H "Authorization: Bot ${BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
        "name": "start",
        "type": 1,
        "description": "Minecraftサーバーを起動します"
      }'
```

続けて、最新の MOD 構成でサーバーを作り直す `/restart` も登録します。
MOD を更新（S3 の `world/` を更新）した後の反映に使います。

```bash
curl -X POST \
  "https://discord.com/api/v10/applications/${APPLICATION_ID}/commands" \
  -H "Authorization: Bot ${BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
        "name": "restart",
        "type": 1,
        "description": "最新のMOD構成でサーバーを再起動します"
      }'
```

## 5. Interactions Endpoint URL を設定する

Lambda Function URL を Discord の Interactions Endpoint に設定します。

1. Function URL を取得する（CloudFormation の Export から）:

   ```bash
   aws cloudformation list-exports \
     --profile <profile> --region ap-northeast-1 \
     --query "Exports[?Name=='minecraft-discord-function-url'].Value" \
     --output text
   ```

2. Developer Portal → **General Information** → **Interactions Endpoint URL** に
   上記 URL を貼り付け **Save Changes**。
   - 保存時に Discord が PING(type=1) を送り、Lambda が署名検証して PONG を返せれば成功します。
   - **失敗する場合**: SSM の `DISCORD_PUBLIC_KEY` が App の Public Key と一致しているか、
     `fnc` スタックがデプロイ済みかを確認してください。

## 6. 通知用 Webhook を作成し SSM に登録する

起動完了・アラーム・EIP 失敗などの通知を受け取るチャンネルの Webhook を作ります。

1. 通知したいチャンネルの **設定 → 連携サービス → ウェブフック → 新しいウェブフック** を作成し、
   **ウェブフック URL をコピー** する。
2. SSM に登録する:

   ```bash
   aws ssm put-parameter \
     --profile <profile> --region ap-northeast-1 \
     --name DISCORD_WEBHOOK \
     --type SecureString \
     --value "<Discord Webhook URL>" \
     --overwrite
   ```

## 7. RCON パスワードを SSM に登録する

サーバー側のアイドル監視・保存制御に使う RCON パスワードを登録します（任意の強いランダム文字列）。

```bash
aws ssm put-parameter \
  --profile <profile> --region ap-northeast-1 \
  --name RCON_PASSWORD \
  --type SecureString \
  --value "$(openssl rand -base64 24)" \
  --overwrite
```

---

## 動作確認

1. Discord のサーバーで `/start` を実行する。
2. 「🟢 起動を開始しました。…」と即時応答が返る。
3. 数分後、インスタンス側スクリプトから「🟢 起動が完了しました。接続先: `<EIP>:25565`」が
   Webhook 経由で通知される。
4. その IP:25565 へ Minecraft クライアントから接続する。

通知が来ない/起動しない場合は `docs/runbook.md` の「初回起動前チェックリスト」を参照してください。
