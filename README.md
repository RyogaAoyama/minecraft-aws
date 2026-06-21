# minecraft-aws

Minecraft(Fabric 1.21.10) サーバーを **AWS のスポット EC2 + S3 母艦運用** で構築する IaC 一式です。
Discord のスラッシュコマンドで起動し、誰もログインしていなければ自動で停止してコストを抑えます。

## 特徴

- **遊ぶ時だけ起動**: Discord `/start` で Auto Scaling Group の desired を 0→1 にして起動。
- **自動停止**: 0人が10分継続したらワールドを保存し、インスタンスを自己終了（課金停止）。
- **S3 が真の保管庫**: 起動時に S3 → ローカル、停止/定期でローカル → S3 へ同期。
- **固定 IP**: Elastic IP で接続先を固定。
- **コスト最適化**: スポット(`c8g.xlarge` 他)・gp3 30GB・単一環境(prd)。
- **通知**: 起動完了・リソースアラーム・スポット起動失敗・EIP 失敗を Discord へ通知。
- **自動デプロイ**: `main` への push（GitHub Actions）で CFn スタック一式を自動デプロイ。

## アーキテクチャ（概略）

```
[Discord] --/start--> [Lambda Function URL (Ed25519署名検証)] --SetDesiredCapacity=1--> [ASG]
                                                                                            |
                                                                          launch spot EC2 (Graviton/AL2023)
                                                                                            |
   UserData → install.sh: EIP関連付け → Java21/CWAgent/mcrcon導入 → S3からworld同期 → MC起動 → timer起動
                                                                                            |
   - world-sync.timer (15分毎: save-all → S3同期)
   - idle-check.timer (毎分: RCON list → 0人10分継続で save+S3同期+自己終了)
   - spot-watch.service (3秒毎: 中断検知で save+S3同期)
   - minecraft.service ExecStop (停止時に必ず save+S3同期)
                                                                                            |
[CWAgent] -- mem/disk --> [CloudWatch Alarm] --> [SNS] --> [Lambda] --> [Discord Webhook]
```

## ディレクトリ構成

```
cloudformation/   CloudFormation テンプレ（net/sec/rec/ins/mon/fnc）+ config/parameters.txt
sh/               デプロイ・同期スクリプト（deploy-cfn.sh / deploy-cfn-all.sh / sync-bootstrap.sh / fetch-mods.sh）
src/              Lambda コード（discord-interaction / alarm-notify）
server/           インスタンス側（install.sh / bin 管理スクリプト / systemd ユニット / config テンプレ）
docs/             手順書（discord-setup.md / runbook.md / mods.md）
mods.txt          MOD 宣言ファイル（requirements.txt 相当）。fetch-mods.sh で mods/ を一括生成
mods.lock         fetch-mods.sh が生成する版固定ファイル（pip freeze 相当）
```

## 主要コマンド

```bash
# デプロイ用バケット作成（初回のみ）
aws --profile <profile> --region ap-northeast-1 s3api create-bucket \
  --bucket minecraft-deploy-prd \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

# スタック一式をデプロイ
sh/deploy-cfn-all.sh -e prd -p <profile>

# 管理スクリプトを world バケットの bootstrap/ へ同期
sh/sync-bootstrap.sh -p <profile>

# MOD を mods.txt から一括ダウンロード（mods/ 生成 + mods.lock で版固定）
sh/fetch-mods.sh -o ./my-fabric-server/mods
```

## セットアップ / 運用ドキュメント

- 初回構築・運用・既知リスク: [`docs/runbook.md`](docs/runbook.md)
- Discord 連携（App 作成・コマンド登録・Endpoint・Webhook）: [`docs/discord-setup.md`](docs/discord-setup.md)
- MOD の宣言的ダウンロード（mods.txt / fetch-mods.sh / mods.lock）: [`docs/mods.md`](docs/mods.md)

## 秘密情報の扱い

RCON パスワード / Discord Public Key / Discord Webhook URL はリポジトリに置かず、
SSM Parameter Store(SecureString) に登録して名前参照のみで利用します。

| パラメータ名 | 用途 |
|---|---|
| `/minecraft/prd/rcon-password` | RCON パスワード |
| `/minecraft/prd/discord-public-key` | Interactions 署名検証用の公開鍵 |
| `/minecraft/prd/discord-webhook-url` | 通知先 Discord Webhook URL |
