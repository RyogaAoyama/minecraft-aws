# server.properties パラメーター一覧（Minecraft Java Edition 1.21.x / Fabric）

本ドキュメントはテンプレート `server/config/server.properties.tmpl` で設定可能な
全パラメーターをまとめたものです。

## 変更タイミングについて

- **いつでも変更可**: サーバー再起動で反映される。既存ワールドに影響なし。
- **新規チャンクのみ反映**: 既に生成済みのチャンクには適用されない。未踏の新規チャンクにのみ反映される。
- **ワールド作成時のみ**: ワールド新規作成時にのみ適用される。既存ワールドでは変更しても無意味。

---

## ゲームプレイ

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `gamemode` | `survival` | survival / creative / adventure / spectator | いつでも | 新規参加プレイヤーのゲームモード |
| `difficulty` | `easy` | peaceful / easy / normal / hard | いつでも | ゲーム難易度 |
| `hardcore` | `false` | true / false | ワールド作成時のみ | ハードコアモード（死亡でスペクテイターに） |
| `pvp` | `true` | true / false | いつでも | プレイヤー同士のダメージ |
| `force-gamemode` | `false` | true / false | いつでも | ログイン時にサーバーのゲームモードを強制適用 |
| `allow-flight` | `false` | true / false | いつでも | サバイバルでの飛行許可（falseだと飛行5秒でキック） |
| `spawn-animals` | `true` | true / false | いつでも | 動物のスポーン |
| `spawn-monsters` | `true` | true / false | いつでも | 敵モブのスポーン |
| `spawn-npcs` | `true` | true / false | いつでも | 村人のスポーン |
| `spawn-protection` | `16` | 0〜整数 | いつでも | スポーン地点の保護範囲（ブロック半径）。0で無効 |
| `allow-nether` | `true` | true / false | いつでも | ネザーへのアクセス許可 |
| `generate-structures` | `true` | true / false | 新規チャンクのみ | 村・要塞等の構造物を生成するか |
| `enable-command-block` | `false` | true / false | いつでも | コマンドブロックの有効化 |

## ワールド生成

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `level-name` | `world` | 文字列 | ワールド作成時のみ | ワールドフォルダ名 |
| `level-seed` | （空） | 文字列/数値 | ワールド作成時のみ | ワールドシード値。空ならランダム |
| `level-type` | `minecraft\:normal` | normal / flat / large_biomes / amplified / single_biome_surface | ワールド作成時のみ | ワールド生成タイプ |
| `generator-settings` | `{}` | JSON文字列 | ワールド作成時のみ | フラットワールド等のカスタム生成設定 |
| `max-world-size` | `29999984` | 1〜29999984 | いつでも | ワールド境界の最大半径（ブロック） |
| `initial-enabled-packs` | `vanilla` | カンマ区切り | ワールド作成時のみ | 初期有効データパック |
| `initial-disabled-packs` | （空） | カンマ区切り | ワールド作成時のみ | 初期無効データパック |

## ネットワーク

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `server-port` | `25565` | 1〜65535 | いつでも | サーバーポート |
| `server-ip` | （空） | IP文字列 | いつでも | バインドするIP。空で全インターフェース |
| `network-compression-threshold` | `256` | -1〜整数 | いつでも | パケット圧縮閾値（バイト）。-1で無効 |
| `rate-limit` | `0` | 0〜整数 | いつでも | 1プレイヤーあたりの毎秒パケット上限。0で無制限 |
| `use-native-transport` | `true` | true / false | いつでも | Linux最適化トランスポート（epoll）使用 |
| `prevent-proxy-connections` | `false` | true / false | いつでも | VPN/プロキシ接続をブロック |
| `accepts-transfers` | `false` | true / false | いつでも | サーバー間転送の受け入れ |

## パフォーマンス

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `view-distance` | `10` | 2〜32 | いつでも | クライアントに送信するチャンク距離 |
| `simulation-distance` | `10` | 2〜32 | いつでも | Tickが処理されるチャンク距離 |
| `max-tick-time` | `60000` | -1〜整数(ms) | いつでも | 1tickの最大許容時間。超過でクラッシュ。-1で無効 |
| `sync-chunk-writes` | `true` | true / false | いつでも | チャンク書き込みの同期。falseで高速化だがデータ破損リスク |
| `max-chained-neighbor-updates` | `1000000` | 整数 | いつでも | 連鎖ブロック更新の上限 |
| `entity-broadcast-range-percentage` | `100` | 10〜1000(%) | いつでも | エンティティの送信範囲 |
| `region-file-compression` | `deflate` | deflate / lz4 / none | いつでも | リージョンファイルの圧縮方式 |

## セキュリティ・認証

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `online-mode` | `true` | true / false | いつでも | Mojangアカウント認証 |
| `white-list` | `false` | true / false | いつでも | ホワイトリストの有効化 |
| `enforce-whitelist` | `false` | true / false | いつでも | リストにない既接続者もキック |
| `enforce-secure-profile` | `true` | true / false | いつでも | Mojang署名付きプロフィールを要求 |
| `op-permission-level` | `4` | 1〜4 | いつでも | OPの権限レベル |
| `function-permission-level` | `2` | 1〜4 | いつでも | ファンクション実行時の権限レベル |
| `log-ips` | `true` | true / false | いつでも | プレイヤーIPをログに記録 |

## RCON・クエリ

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `enable-rcon` | `false` | true / false | いつでも | RCONの有効化 |
| `rcon.port` | `25575` | 1〜65535 | いつでも | RCONポート |
| `rcon.password` | （空） | 文字列 | いつでも | RCONパスワード |
| `enable-query` | `false` | true / false | いつでも | GameSpy4クエリプロトコルの有効化 |
| `query.port` | `25565` | 1〜65535 | いつでも | クエリポート |
| `broadcast-console-to-ops` | `true` | true / false | いつでも | コンソール出力をOP全員に送信 |
| `broadcast-rcon-to-ops` | `true` | true / false | いつでも | RCON出力をOP全員に送信 |

## プレイヤー管理

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `max-players` | `20` | 0〜整数 | いつでも | 最大同時接続人数 |
| `player-idle-timeout` | `0` | 0〜整数(分) | いつでも | 放置キックまでの時間。0で無効 |
| `hide-online-players` | `false` | true / false | いつでも | サーバーリストでプレイヤーを隠す |
| `motd` | `A Minecraft Server` | 文字列 | いつでも | サーバーリストに表示されるメッセージ |
| `enable-status` | `true` | true / false | いつでも | サーバーリストに表示するか |

## リソースパック

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `resource-pack` | （空） | URL | いつでも | リソースパックのダウンロードURL |
| `resource-pack-id` | （空） | UUID | いつでも | リソースパックのUUID |
| `resource-pack-sha1` | （空） | SHA1ハッシュ | いつでも | 検証用ハッシュ |
| `resource-pack-prompt` | （空） | 文字列 | いつでも | 適用を促すメッセージ |
| `require-resource-pack` | `false` | true / false | いつでも | リソースパック必須（拒否で切断） |

## その他

| パラメーター | デフォルト | 設定値 | 変更タイミング | 説明 |
|---|---|---|---|---|
| `enable-jmx-monitoring` | `false` | true / false | いつでも | JMX監視の有効化 |
| `text-filtering-config` | （空） | 文字列 | いつでも | テキストフィルタリング設定 |
