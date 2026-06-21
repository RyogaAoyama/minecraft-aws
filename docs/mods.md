# MOD の宣言的ダウンロード（mods.txt / fetch-mods.sh / mods.lock）

サーバーに入れる MOD を **宣言ファイルに書く → 一括ダウンロード → 版を固定** する仕組みです。
Python の `requirements.txt`（宣言）+ `pip freeze` / lockfile（版固定）に相当します。

各 MOD を手で Modrinth から探してダウンロードする手間をなくし、
**いつでも同じ版を再現できる**ようにすることが目的です。

---

## 全体の流れ

```
mods.txt              # 人が編集する宣言（必要な MOD を列挙）
   │  sh/fetch-mods.sh
   ▼
mods/  +  mods.lock    # MOD jar 一式 と 版固定ファイル（自動生成）
   │  aws s3 sync
   ▼
s3://minecraft-world-prd/world/mods/    # 「真の保管庫」。起動時にインスタンスへ同期される
```

- `mods/` と `mods.lock` は `fetch-mods.sh` が生成する**成果物**です（手で編集しない）。
- S3 の `world/` が真の保管庫である設計は維持します。**毎起動でのダウンロードはしません。**
  ローカル（macOS）で `mods/` を生成し、それを `world/` へ上げる運用です。

---

## 前提ツール

- `bash`（macOS 標準の 3.2 系で動作。`set -euo pipefail`）
- `curl`、`shasum`（macOS 標準）
- JSON 処理: **`jq` があれば `jq`、無ければ `python3`** に自動フォールバック（どちらも無ければエラー）
- Modrinth API（`https://api.modrinth.com/v2`）へのネットワーク到達

---

## mods.txt の書き方

リポジトリ直下の `mods.txt` を編集します。

```
# 行頭 # と行末 # はコメント。空行は無視。
# mc: 1.21.11
# loader: fabric

fabric-api          # 版指定なし → 1.21.11/fabric 向けの最新 release を自動選択
lithium==ABC123XY   # slug==version_id で版を完全固定（再現性最優先）
```

- 1 行 1 MOD。`slug` だけ書くと対象 MC/loader 向けの**最新 release** を自動選択します。
- `slug==<version_id>` と書くと、その Modrinth version で**完全固定**します。
- 対象は **MC 1.21.11 / Fabric 固定**（サブバージョン混在不可）。`fetch-mods.sh` のデフォルトも同じです。
- **サーバーに必要な MOD のみ**を列挙します。
  クライアント専用 MOD（Sodium / Iris などの描画系）は入れません。

### slug の確認方法

slug は推測ではなく Modrinth で実在を確認します。

```bash
curl -s -H 'User-Agent: minecraft-aws/1.0 (github)' \
  https://api.modrinth.com/v2/project/<slug>
```

200（JSON）が返れば実在します。404 の場合、`fetch-mods.sh` は
「Modrinth に project が無い（CurseForge 限定の可能性）」と明示して失敗します。

---

## 使い方

### 通常ダウンロード（mods.txt 基準）

```bash
# デフォルト: ./mods へ DL し、./mods.lock を生成
sh/fetch-mods.sh

# 出力先を指定（例: ローカルの Fabric サーバーディレクトリへ直接生成）
sh/fetch-mods.sh -o ./my-fabric-server/mods
```

動作:

1. `mods.txt` を 1 行ずつ解析する。
2. `slug==version_id` ならその version、`slug` のみなら Modrinth API で
   `1.21.11 / fabric` 向け候補を取得し、`release` 優先・公開日降順で最新を選ぶ。
3. version の primary ファイルを `-o` 先へダウンロードし、**sha512 を検証**する
   （Modrinth が返す hash と `shasum -a 512` を照合。不一致ならファイルを残さず失敗）。
   **既に期待 sha512 と一致するファイルがあれば再ダウンロードせずスキップ**する（省通信）。
4. 解決結果（slug / version_id / filename / sha512 / download_url）を
   `mods.lock` に **slug 昇順の TSV** で保存する。
5. 各 version の `required` 依存が `mods.txt` に無ければ**警告**する
   （自動追加はしない。必要なら自分で `mods.txt` に追記する）。
6. **残骸排除（prune）**: 解決済みセットに無い `*.jar`（旧バージョン等）を `-o` 先から削除し、
   `mods/` を解決済みセットそのものに揃える。

1 件失敗しても全体は止めず、最後に**失敗一覧**をまとめて表示します
（1 件でも失敗があれば終了コードは 1）。

### 冪等性（残骸ゼロ・宣言的同期）

`fetch-mods.sh` は **何度実行しても `mods/` が「解決済みセットそのもの」になる**よう設計されています
（`s3 sync --delete` や Terraform のような宣言的同期）。

- **不足**していれば**ダウンロード**して補完する。
- **正しいファイル**は sha512 確認のみで**再DLしない**。
- **余分なファイル**（過去の別バージョン等の残骸）は**削除**する。

そのため、MC バージョンを切り替えた後など `mods/` に旧版が混在していても、再実行するだけで
**自動的に正しい構成へ収束**します。

> 安全策: ネットワーク全断などで **1 件も解決できなかった場合は prune を行いません**
> （空の解決結果で `mods/` を丸ごと削除する事故を防ぐため）。

### S3 へ反映（真の保管庫へ）

`mods/` を生成したら、Fabric サーバー一式と一緒に `world/` へ上げます。

```bash
# ローカルの Fabric サーバーディレクトリごと world/ へ同期
aws --profile <profile> --region ap-northeast-1 s3 sync \
  ./my-fabric-server/ s3://minecraft-world-prd/world/
```

`fetch-mods.sh -o ./my-fabric-server/mods` で **サーバーディレクトリの mods/ に直接生成**しておけば、
そのまま上記の `s3 sync` 一発で `world/mods/` に反映できます。

### 再現ダウンロード（frozen / mods.lock 基準）

`mods.lock` の version_id / url / sha512 だけで再現します（CI や再構築の完全再現用）。
`mods.txt` は読みません。

```bash
sh/fetch-mods.sh --frozen -o ./my-fabric-server/mods
```

---

## 版の固定と更新の運用

- **固定**: `mods.lock` をコミットしておけば、`--frozen` で誰でも同じ版を再現できます。
- **更新**: `mods.txt` の `slug`（版指定なし）行を `fetch-mods.sh` で再解決すると、
  その時点の最新 release に更新され、`mods.lock` も更新されます。
  更新したくない MOD は `slug==<version_id>` で固定してください。
- **特定 MOD だけ固定**: 動作確認済みの版を `mods.lock` で調べ、
  `mods.txt` を `slug==<version_id>` に書き換えます。

---

## クライアント側の注意（重要）

ワールド生成・構造物系 MOD（Terralith / Tectonic / CTOV / Towns & Towers など）は
**クライアント側にも同じ MOD・同じ版が必要**です。
サーバーだけに入れても、クライアントに無いと接続できない／生成物が正しく表示されません。

`mods.txt` は「サーバー必須セット」を管理します。
プレイヤーは同じ MOD（+ Sodium 等のクライアント専用最適化は任意）を各自のクライアントへ導入してください。
配布時は `mods.lock` の version_id を共有すると、版ずれを防げます。

---

## 既知の制約

- 対象は **Modrinth のみ**。CurseForge 限定 MOD は対象外です
  （slug が Modrinth に無ければ明示エラーで案内します）。
- 依存の**自動追加はしません**（警告のみ）。前提 MOD（Fabric API / Lithostitched 等）は
  `mods.txt` に明示的に列挙してください（既に列挙済み）。
