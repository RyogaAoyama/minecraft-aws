# 運用 Runbook（Minecraft on AWS）

スポット EC2 + S3 母艦運用の Minecraft(Fabric 1.21.11) サーバーの構築・運用手順です。
リージョンは `ap-northeast-1`、命名は `minecraft-{resource}-prd` で統一しています。

---

## 初回起動前チェックリスト

以下は **順序依存** です。1つでも欠けると初回 `/start` が無言で失敗します。

1. **デプロイ用 S3 バケットを作成**（`cloudformation package` の前提）

   ```bash
   aws --profile <profile> --region ap-northeast-1 s3api create-bucket \
     --bucket minecraft-deploy-prd \
     --create-bucket-configuration LocationConstraint=ap-northeast-1
   ```

2. **スタック一式をデプロイ**

   ```bash
   sh/deploy-cfn-all.sh -e prd -p <profile>
   ```

   依存順（net → sec,rec → ins → mon,fnc）で自動デプロイされます。

3. **サーバー資産を world バケットへアップロード**（下記「世界 / MOD 資産のアップロード」参照）

4. **管理スクリプトを bootstrap へ同期**

   ```bash
   sh/sync-bootstrap.sh -p <profile>
   ```

5. **SSM Parameter Store に3種を登録**（すべて SecureString）
   - `RCON_PASSWORD`
   - `DISCORD_PUBLIC_KEY`
   - `DISCORD_WEBHOOK`

   登録手順は `docs/discord-setup.md` を参照。

6. **Discord のコマンド登録・Interactions Endpoint URL 設定**（`docs/discord-setup.md`）

→ ここまで揃って初めて `/start` が成功します。

---

## デプロイ手順

```bash
# 全スタックを依存順に並列デプロイ
sh/deploy-cfn-all.sh -e prd -p <profile>

# 個別スタックのデプロイ（コード: net|sec|rec|ins|mon|fnc）
sh/deploy-cfn.sh -c <code> -e prd -p <profile>
```

---

## CI/CD（GitHub Actions 自動デプロイ）

`main` への push（`cloudformation/` `sh/` `src/` `server/` `.github/`・`mods.txt`・`mods.lock`・
`server.lock` のいずれかが変更されたとき）で `.github/workflows/deploy.yml` が走り、以下を自動実行します。
docs だけの変更ではデプロイされません。

1. OIDC で AWS に認証（IAM ロールを assume）。
2. `sh/deploy-cfn-all.sh -e prd -p default` で全 CFn スタックを依存順にデプロイ。
   - 初回でも自動でデプロイ用バケットを用意するため、手動でのバケット作成は不要です。
3. `sh/build-server.sh --frozen` で Fabric ランチャー（curl）と MOD（`fetch-mods.sh --frozen`）を
   ダウンロードし、`world/` へ `s3 sync`（`--delete` なし）。**バイナリ/MOD はリポジトリに置かず CI が都度取得**します。
   `server.lock` / `mods.lock`（版固定）だけをコミットして再現性を担保します。
4. `sh/sync-bootstrap.sh -p default` で `server/` を world バケットの `bootstrap/` へ同期。
5. 開始・成功・失敗を Discord webhook へ通知。

> サーバーバイナリ/MOD jar は**コミットしません**（`.gitignore` で `my-fabric-server/` を除外）。
> Minecraft 本体や MOD の再配布を避け、リポジトリも肥大させないためです。CI が版ロックから都度取得します。

### 必要な GitHub Secrets（いずれも手動設定）

| Secret 名 | 用途 |
|---|---|
| `IAM_ROLE_ARN` | GitHub Actions が assume する IAM ロールの ARN |
| `DISCORD_WEBHOOK` | デプロイ通知先の Discord webhook URL |

### OIDC の AWS セットアップ（一度きり）

1. **GitHub OIDC プロバイダを作成**

   ```bash
   aws --profile aoyama-prd iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com
   ```

2. **assume 用 IAM ロールを作成**。信頼ポリシーで `sub` を当リポジトリの `main` ブランチに、
   `aud` を `sts.amazonaws.com` に制限します（`<ACCOUNT_ID>` は対象アカウント ID に置換）。

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
             "token.actions.githubusercontent.com:sub": "repo:RyogaAoyama/minecraft-aws:ref:refs/heads/main"
           }
         }
       }
     ]
   }
   ```

3. **ロールに権限ポリシーを付与**。デプロイには CloudFormation / EC2 / IAM / S3 / SNS / Lambda /
   Events(EventBridge) / CloudWatch / SSM 等が必要です。加えてデプロイ用バケットの自動作成のため
   `s3:CreateBucket` / `s3:HeadBucket` も必要です。個人利用なので簡便に広めの管理ポリシーでも動きますが、
   可能なら最小権限に絞るのが望ましいです。

4. 作成したロールの ARN を GitHub Secret `IAM_ROLE_ARN` に、Discord webhook URL を
   `DISCORD_WEBHOOK` に登録します。

### 注意

- 手動デプロイ（`sh/deploy-cfn-all.sh -e prd -p aoyama-prd`）も従来どおり可能です。
- world / MOD 資産のアップロードと SSM パラメータ登録は CI 対象外で、従来どおり手動です。

---

## 世界 / MOD 資産のアップロード

world バケット `minecraft-world-prd` の **`world/` プレフィックス** が「真の保管庫」です。
インスタンス起動時にここから `/opt/minecraft/server/` へ同期され、停止/定期で逆同期されます。

サーバー一式は **`sh/build-server.sh`（Java 不要・純ダウンロード）** で組み立てます。

### ビルド（Java 不要）

`minecraft.service` は **`fabric-server-launch.jar`（固定名）** を起動します。
これは Fabric の meta API が配布する **自己ブートストラップ型のランチャー** で、`curl` で直接取得します
（Fabric インストーラ＝Java 製プログラムは使いません）。**vanilla server 本体と libraries は、
インスタンスの初回起動時にこのランチャー自身が自動ダウンロード**します（EC2 には Corretto 21 が入っているため Java はそこで足ります）。

```bash
# ランチャー(curl) + mods(fetch-mods.sh --frozen) を ./my-fabric-server/ に生成。
# 版は server.lock / mods.lock に固定（--frozen で完全再現）。
sh/build-server.sh -o ./my-fabric-server          # 最新 loader/installer を解決し lock 生成
sh/build-server.sh --frozen -o ./my-fabric-server # lock 通りに再現（CI と同じ）
```

### アップロードする一式

> **通常は CI が自動でやります**（上記「CI/CD」）。以下は**手動デプロイ時のみ**の手順です。

`build-server.sh` の出力（`my-fabric-server/` → `world/` 直下へ同期）:

- `fabric-server-launch.jar`（起動用ランチャー / 固定名 / 自己ブートストラップ）
- `mods/`（`mods.lock` 通りの MOD jar 群）

`server.lock` はリポジトリ直下に commit する**版固定ファイル**で、`world/` へは上げません。
`server.jar` / `libraries/` も**事前同梱しません**（初回起動時にインスタンスが取得）。
`eula.txt` と `server.properties` も **アップロード不要**です
（インスタンス側 install.sh が `server/config/` のテンプレから生成します）。

```bash
# ビルド（版は server.lock / mods.lock で固定。実体はコミットせず都度DL）
sh/build-server.sh --frozen -o ./my-fabric-server

# world/ へアップロード（重要: --delete は付けない。world/ にはセーブデータも同居するため）
aws --profile <profile> --region ap-northeast-1 s3 sync \
  ./my-fabric-server/ s3://minecraft-world-prd/world/
```

> **なぜ `--delete` 禁止か**: `world/` はサーバーバイナリ/MOD と**稼働中のセーブデータが同居**する
> 「真の保管庫」です。`--delete` 付きで上書きするとセーブデータを消す恐れがあります。
> バイナリ/MOD の更新は上書き同期（追加・更新のみ）で行います。

---

## 管理スクリプトの同期

リポジトリの `server/` 配下（管理スクリプト・systemd ユニット・設定テンプレ）を
world バケットの `bootstrap/` プレフィックスへ同期します。

```bash
sh/sync-bootstrap.sh -p <profile>
```

インスタンス起動時、UserData が `bootstrap/` を `/opt/minecraft/bin/` へ展開し、
`bash /opt/minecraft/bin/install.sh` を実行します。
S3 は実行権限を保持しないため、install.sh が各スクリプトに `chmod +x` します。

`server/` を変更したら、必ず再度 `sync-bootstrap.sh` を実行してください。

---

## 運用

### 起動

Discord で `/start`。ASG の desired が 0→1 になり、スポット EC2 が起動します。
起動完了は Discord へ「🟢 起動が完了しました。接続先: `<EIP>:25565`」と通知されます。

### MOD 更新フロー

MOD は S3 の `world/mods/` が正本で、Minecraft サーバーは **起動時にしか mods を読みません**。
そのため MOD を更新したら、インスタンスを作り直して S3 最新を取り込んで起動し直す必要があります。
これを Discord `/restart` で行います。

1. **ローカルで MOD を更新**（`mods.txt` を編集し `sh/fetch-mods.sh` で `mods/` を再生成）

   ```bash
   sh/fetch-mods.sh -o ./my-fabric-server/mods
   ```

2. **world/ を更新**（更新した一式を world バケットへ同期）

   ```bash
   aws --profile <profile> --region ap-northeast-1 s3 sync \
     ./my-fabric-server/ s3://minecraft-world-prd/world/
   ```

3. **Discord `/restart` で反映**
   - **稼働中**: 現インスタンスを ASG から終了し、ASG が新インスタンスを起動します（desired は維持）。
     新インスタンスが起動時に S3 最新の MOD 構成を取り込みます。接続中のプレイヤーは一旦切断されます。
   - **停止中**: 起動を開始します（結果的に最新 MOD 構成で起動します）。
   - いずれも反映まで数分かかります。

> **注意**: サーバーの MOD 構成を変えたら、**全プレイヤーのクライアントも同じ MOD・同じ
> 1.21.11 に更新**しないと接続できません。MOD 更新時はプレイヤー全員のクライアント側更新も
> 合わせて行ってください。

### 自動停止（コスト最適化）

- `idle-check.timer` が毎分 RCON `list` で人数を確認します。
- **0人が `IdleStopMinutes` 分連続**（デフォルト 10 分。毎分×N回）で、ワールドを保存→S3同期→
  自インスタンスを ASG から終了し desired を 0 に戻します（課金停止）。
- 1人でもオンラインならカウンタはリセットされます。

### AFK プレイヤーの自動キック

- バニラの `server.properties` の `player-idle-timeout` で実装。
- **`PlayerIdleTimeoutMinutes` 分**（デフォルト 30 分）操作が無いプレイヤーをサーバーがキックします。
- AFK キックされたプレイヤーがいなくなった結果、サーバー全体が無人になれば、
  `idle-check.timer` 側のカウントが進んで最終的にサーバーが自動停止します。

### 待機時間のチューニング

「無人停止までの時間」と「AFK キックまでの時間」は CloudFormation パラメータで変更できます。
変更箇所は `cloudformation/Instance.yml` の `Parameters` セクション:

| パラメータ | デフォルト | 意味 | 0 にすると |
|---|---|---|---|
| `IdleStopMinutes` | 10 | 無人停止までの分数（`idle-check.sh`） | 不可（最小 1） |
| `PlayerIdleTimeoutMinutes` | 30 | AFK キックまでの分数（`player-idle-timeout`） | 機能無効化 |

反映フロー:
1. `cloudformation/Instance.yml` の `Default` を編集して push → GitHub Actions が CFn を更新
2. 起動中のインスタンスには即時反映されない。**次回起動時から有効**
3. 即時反映したい場合は Discord で `/start` 前に `/stop` で一度落とす

参照経路:
```
CFn パラメータ → UserData が /etc/minecraft.env に書き出す
  ├─ IDLE_STOP_MINUTES → idle-check.sh が IDLE_LIMIT として読む
  └─ PLAYER_IDLE_TIMEOUT_MINUTES → install.sh が server.properties.tmpl の
                                  __PLAYER_IDLE_TIMEOUT__ を置換
```

### 定期保存

- `world-sync.timer` が15分毎に `save-all` → S3 差分同期を行います。
- スポット中断時は `spot-watch.service`（3秒間隔ポーリング）と
  `minecraft.service` の `ExecStop` の二段でワールド保存を担保します。

### コスト感

- 課金されるのは「起動中のみ」。`c6g.xlarge` スポット相当の従量 + EBS(gp3 30GB) + EIP(未使用時のみ少額)。
- 想定利用（2人 / 1日3時間）なら、常時稼働比で大幅にコストを抑えられます。
- 放置してもアイドル10分で自動停止するため、消し忘れによる課金が起きにくい設計です。

### 接続先 IP

Elastic IP で固定されています。確認するには:

```bash
aws --profile <profile> --region ap-northeast-1 ec2 describe-addresses \
  --filters "Name=tag:Name,Values=minecraft-eip-prd" \
  --query "Addresses[0].PublicIp" --output text
```

### サーバーへの SSH 不要運用

SSH は塞いでおり、必要時は SSM Session Manager で接続します。

```bash
aws --profile <profile> --region ap-northeast-1 ssm start-session \
  --target <instance-id>
```

ログは `journalctl -u minecraft.service` 等で確認できます。

---

## 既知のリスク / 注意

- **world 肥大時の同期遅延**: ワールドが極端に大きくなると `s3 sync` が
  スポット中断猶予（約2分）に収まらない可能性があります。
  差分 sync + 15分毎の定期 sync で通常の差分を小さく保つ前提です。
  肥大が懸念される場合は world のプルーニングや view-distance の調整を検討してください。
- **スポット容量確保失敗**: 起動時にスポット容量が確保できないと
  EventBridge → 通知 Lambda 経由で Discord に「🟠 起動に失敗しました」と通知されます。
  容量が確保でき次第 ASG が自動でリトライします。
- **初回起動の順序依存**: 上記チェックリストの順序を守らないと `/start` が無言で失敗します。
