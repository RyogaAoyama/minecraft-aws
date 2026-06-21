#!/bin/bash
#
# fetch-mods.sh - mods.txt を基に Modrinth から MOD を一括ダウンロードし、
#                 解決した版を mods.lock に固定する（pip install + pip freeze 相当）。
#
# 設計:
#   - 宣言ファイル mods.txt（人が編集）→ 本スクリプトで mods/ へ一括 DL → mods.lock で版固定。
#   - 冪等な宣言的同期: 実行後の mods/ は「解決済みセットそのもの」になる。
#       * 既に期待 sha512 と一致するファイルは再DLしない（スキップ）。
#       * 不足分のみダウンロードする。
#       * 解決済みセットに無い jar（旧バージョン等の残骸）は prune（削除）する。
#       * 安全策として、1件も解決できなかった場合は prune しない（全消し事故防止）。
#   - 生成した mods/ を S3 の world/ へ上げて運用する（docs/mods.md 参照）。
#   - 実行環境は macOS の bash 3.2 を想定。連想配列(declare -A)/mapfile は使わない。
#   - JSON 処理は jq があれば jq、無ければ python3 にフォールバック（どちらも無ければエラー）。
#   - Modrinth API には User-Agent ヘッダ必須。
#
# 終了コード: 全件成功で 0、1件でも失敗があれば 1（失敗は集計して最後に一覧表示）。

set -euo pipefail

# -----------------------------------------------------------------------------
# 定数
# -----------------------------------------------------------------------------
MODRINTH_API="https://api.modrinth.com/v2"
USER_AGENT="minecraft-aws/1.0 (github)"
GAME_VERSION="1.21.11"
LOADER="fabric"

# -----------------------------------------------------------------------------
# ヘルプ
# -----------------------------------------------------------------------------
function usage {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
    -o dir       出力ディレクトリ（MOD jar の保存先）。デフォルト ./mods
    -m manifest  宣言ファイル。デフォルト ./mods.txt
    -g version   対象MCバージョン（デフォルト 1.21.11）
    -f, --frozen mods.lock のみで再現ダウンロード（mods.txt は読まない）
    -h           ヘルプ
EOM
    exit 2
}

# -----------------------------------------------------------------------------
# オプション解析（getopts はロングオプション非対応のため --frozen は前処理で吸収）
# -----------------------------------------------------------------------------
OUT_DIR="./mods"
MANIFEST="./mods.txt"
FROZEN=0

ARGS=()
for arg in "$@"; do
    case "$arg" in
    --frozen) FROZEN=1 ;;
    *) ARGS+=("$arg") ;;
    esac
done
# 前処理後の引数で getopts を回す（空配列でも安全に展開する）。
set -- ${ARGS+"${ARGS[@]}"}

while getopts o:m:g:fh OPT; do
    case "$OPT" in
    o) OUT_DIR="$OPTARG" ;;
    m) MANIFEST="$OPTARG" ;;
    g) GAME_VERSION="$OPTARG" ;;
    f) FROZEN=1 ;;
    h | \?) usage ;;
    esac
done

# lock ファイルは manifest と同じディレクトリに置く（既定では ./mods.lock）。
LOCK_FILE="$(dirname "$MANIFEST")/mods.lock"

# -----------------------------------------------------------------------------
# 依存ツールの判定（jq 優先 / python3 フォールバック）
# -----------------------------------------------------------------------------
JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
    JSON_TOOL="jq"
elif command -v python3 >/dev/null 2>&1; then
    JSON_TOOL="python3"
else
    echo "error->json tool not found->install jq or python3" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "error->curl not found" >&2
    exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
    echo "error->shasum not found（sha512 検証に必要）" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 失敗の集計（bash3.2 のため通常配列で保持）
# -----------------------------------------------------------------------------
FAILURES=()

# 失敗を記録する。
# 引数: $1 対象（slug 等） / $2 理由
function record_failure {
    FAILURES+=("$1: $2")
}

# -----------------------------------------------------------------------------
# JSON 抽出ヘルパ（jq / python3 を吸収。呼び出し側はツール非依存）
# -----------------------------------------------------------------------------

# Modrinth API を GET し、本文を標準出力へ返す。
# 引数: $1 パス（先頭スラッシュ含む。例 /project/lithium/version?...）
# 戻り値: HTTP 200 系で 0、それ以外は 1（本文は破棄）。
function api_get {
    local path="$1"
    local body status
    # 本文と HTTP ステータスを 1 リクエストで取得する。
    body="$(curl -sS -w $'\n%{http_code}' \
        -H "User-Agent: $USER_AGENT" \
        "${MODRINTH_API}${path}" 2>/dev/null)" || return 1
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
        printf '%s' "$body"
        return 0
    fi
    return 1
}

# version 群の JSON(配列) から、対象 MC/loader 向けの最新 release を 1 件選んで
# version_id を返す。release が無ければ任意の最新版にフォールバックする。
# 入力: 標準入力に version 配列 JSON
# 出力: version_id（無ければ空文字で 1）
function pick_latest_version_id {
    if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '
            [ .[]
              | select(.game_versions | index("'"$GAME_VERSION"'"))
              | select(.loaders | index("'"$LOADER"'")) ]
            as $all
            | ( [ $all[] | select(.version_type == "release") ]
                | sort_by(.date_published) | reverse | .[0].id ) //
              ( $all | sort_by(.date_published) | reverse | .[0].id ) //
              empty
        '
    else
        python3 - "$GAME_VERSION" "$LOADER" <<'PY'
import json, sys
gv, loader = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
cands = [v for v in data
         if gv in v.get("game_versions", []) and loader in v.get("loaders", [])]
if not cands:
    sys.exit(0)
def key(v):
    return v.get("date_published", "")
releases = [v for v in cands if v.get("version_type") == "release"]
pool = releases if releases else cands
pool.sort(key=key, reverse=True)
print(pool[0]["id"])
PY
    fi
}

# version JSON(単一オブジェクト) から、ダウンロード対象ファイルの
# 「filename / url / sha512」をタブ区切り 1 行で返す（primary を優先）。
# 入力: 標準入力に version オブジェクト JSON
# 出力: "filename\turl\tsha512"（取得できなければ空で 1）
function extract_primary_file {
    if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '
            ( [ .files[] | select(.primary == true) ][0] // .files[0] )
            | "\(.filename)\t\(.url)\t\(.hashes.sha512)"
        '
    else
        python3 - <<'PY'
import json, sys
v = json.load(sys.stdin)
files = v.get("files", [])
if not files:
    sys.exit(1)
primary = next((f for f in files if f.get("primary")), files[0])
print("\t".join([
    primary.get("filename", ""),
    primary.get("url", ""),
    primary.get("hashes", {}).get("sha512", ""),
]))
PY
    fi
}

# version JSON(単一オブジェクト) から version_id を返す。
function extract_version_id {
    if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '.id'
    else
        python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
    fi
}

# version JSON(単一オブジェクト) から required な依存 project_id を改行区切りで返す。
# 入力: 標準入力に version オブジェクト JSON
function extract_required_dep_project_ids {
    if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '.dependencies[]? | select(.dependency_type == "required") | .project_id // empty'
    else
        python3 - <<'PY'
import json, sys
v = json.load(sys.stdin)
for d in v.get("dependencies", []):
    if d.get("dependency_type") == "required" and d.get("project_id"):
        print(d["project_id"])
PY
    fi
}

# project JSON(単一オブジェクト) から slug を返す。
function extract_project_slug {
    if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '.slug'
    else
        python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])'
    fi
}

# -----------------------------------------------------------------------------
# ダウンロード + sha512 検証
# -----------------------------------------------------------------------------

# URL からファイルを取得し、sha512 を照合する。検証失敗時はファイルを残さない。
# 引数: $1 url / $2 保存先パス / $3 期待 sha512
# 戻り値: 成功 0 / 失敗 1
function download_and_verify {
    local url="$1" dest="$2" expected="$3"
    # 冪等性: 既に期待 sha512 と一致するファイルがあれば再DLしない（省通信）。
    if [ -f "$dest" ]; then
        local current
        current="$(shasum -a 512 "$dest" | awk '{print $1}')"
        if [ "$current" = "$expected" ]; then
            echo "  already present (sha512 OK)"
            return 0
        fi
    fi
    if ! curl -sSL -H "User-Agent: $USER_AGENT" -o "$dest" "$url"; then
        rm -f "$dest"
        echo "  download failed"
        return 1
    fi
    local actual
    actual="$(shasum -a 512 "$dest" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        rm -f "$dest"
        echo "  sha512 MISMATCH (expected ${expected:0:16}..., got ${actual:0:16}...)"
        return 1
    fi
    echo "  sha512 OK"
    return 0
}

# -----------------------------------------------------------------------------
# lock 行の蓄積（後でソートして mods.lock に書き出す）
# -----------------------------------------------------------------------------
LOCK_LINES=()

# lock 行を 1 件追加する（TSV: slug version_id filename sha512 url）。
function add_lock_line {
    LOCK_LINES+=("$1	$2	$3	$4	$5")
}

# 蓄積した lock 行を安定フォーマットで mods.lock に書き出す（slug 昇順）。
function write_lock_file {
    {
        echo "# mods.lock - fetch-mods.sh が生成（手で編集しない）。再現用に版を完全固定。"
        echo "# 形式(TSV): slug<TAB>version_id<TAB>filename<TAB>sha512<TAB>download_url"
        echo "# mc: $GAME_VERSION / loader: $LOADER"
        echo "# 再現DL: sh/fetch-mods.sh --frozen -o <出力先>"
        if [ "${#LOCK_LINES[@]}" -gt 0 ]; then
            printf '%s\n' "${LOCK_LINES[@]}" | LC_ALL=C sort
        fi
    } >"$LOCK_FILE"
    echo "lock written: $LOCK_FILE (${#LOCK_LINES[@]} entries)"
}

# -----------------------------------------------------------------------------
# 通常モード: mods.txt の 1 行を処理する
# -----------------------------------------------------------------------------

# mods.txt の 1 エントリを解決して DL・検証・lock 追記まで行う。
# 解決した slug を SOLVED_SLUGS / project_id を SOLVED_PROJECT_IDS に追記する
# （依存チェックで使う）。
# 引数: $1 slug / $2 version_id（空なら最新を自動選択）
function process_entry {
    local slug="$1" pinned="$2"
    local version_json version_id file_line filename url sha512 dest

    if [ -n "$pinned" ]; then
        echo "[fetch] $slug (pinned: $pinned)"
        version_json="$(api_get "/version/$pinned")" || {
            echo "  version not found: $pinned"
            record_failure "$slug" "pinned version_id $pinned が見つからない"
            return 0
        }
        version_id="$pinned"
    else
        echo "[fetch] $slug (resolve latest $GAME_VERSION/$LOADER)"
        # まず project の存在を確認し、404 を「CurseForge 限定の可能性」として案内する。
        if ! api_get "/project/$slug" >/dev/null; then
            echo "  project not found on Modrinth"
            record_failure "$slug" "Modrinth に project が無い（CurseForge 限定の可能性）"
            return 0
        fi
        local versions_json
        versions_json="$(api_get "/project/$slug/version?game_versions=%5B%22$GAME_VERSION%22%5D&loaders=%5B%22$LOADER%22%5D")" || {
            echo "  version list fetch failed"
            record_failure "$slug" "version 一覧の取得に失敗"
            return 0
        }
        version_id="$(printf '%s' "$versions_json" | pick_latest_version_id)"
        if [ -z "$version_id" ]; then
            echo "  no $GAME_VERSION/$LOADER version available"
            record_failure "$slug" "$GAME_VERSION/$LOADER 向けの version が無い"
            return 0
        fi
        echo "  selected version: $version_id"
        version_json="$(api_get "/version/$version_id")" || {
            echo "  version detail fetch failed"
            record_failure "$slug" "version 詳細の取得に失敗"
            return 0
        }
    fi

    file_line="$(printf '%s' "$version_json" | extract_primary_file)" || {
        echo "  no downloadable file in version"
        record_failure "$slug" "version にダウンロード可能ファイルが無い"
        return 0
    }
    filename="$(printf '%s' "$file_line" | cut -f1)"
    url="$(printf '%s' "$file_line" | cut -f2)"
    sha512="$(printf '%s' "$file_line" | cut -f3)"

    dest="$OUT_DIR/$filename"
    # 望ましい最終状態(KEEP)に登録する。DL失敗してもファイル名は意図したものなので
    # KEEP に入れておき、prune が古い別バージョンだけを消すようにする。
    KEEP_FILES+=("$filename")
    if ! download_and_verify "$url" "$dest" "$sha512"; then
        record_failure "$slug" "ダウンロード/検証に失敗"
        return 0
    fi

    add_lock_line "$slug" "$version_id" "$filename" "$sha512" "$url"
    SOLVED_SLUGS+=("$slug")

    # 依存チェック用に、この version が属する project_id を控える。
    local self_pid
    self_pid="$(printf '%s' "$version_json" | _version_project_id)"
    if [ -n "$self_pid" ]; then
        SOLVED_PROJECT_IDS+=("$self_pid")
    fi

    # required 依存の project_id を集める（後でまとめて警告判定する）。
    local dep_pid
    while IFS= read -r dep_pid; do
        if [ -n "$dep_pid" ]; then
            REQUIRED_DEP_IDS+=("$dep_pid")
        fi
    done <<EOF
$(printf '%s' "$version_json" | extract_required_dep_project_ids)
EOF

    # set -e の罠対策: ループ本体の最後の test が偽(=非0)だと、ここを呼ぶ
    # run_manifest の while 本体が非0 を返してスクリプトが無言で即終了する。
    # 失敗は record_failure で集計し最後に exit 1 する設計なので、本関数は常に 0 を返す。
    return 0
}

# version JSON から project_id を返す（依存照合用）。
function _version_project_id {
    if [ "$JSON_TOOL" = "jq" ]; then
        jq -r '.project_id'
    else
        python3 -c 'import json,sys; print(json.load(sys.stdin)["project_id"])'
    fi
}

# 配列に値が含まれるか判定する。
# 引数: $1 探す値 / $2.. 配列要素
function contains {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# OUT_DIR から、望ましい最終状態(KEEP_FILES)に無い *.jar を削除し残骸を排除する。
# これにより「実行後の mods/ は常に解決済みセットそのもの」になり冪等性を担保する。
# 安全策: KEEP が空（=1件も解決できなかった/全件失敗）のときは何も消さない
#         （ネットワーク全断などで mods/ を丸ごと吹き飛ばす事故を防ぐ）。
function prune_out_dir {
    if [ "${#KEEP_FILES[@]}" -eq 0 ]; then
        echo "  skip prune: 解決済みセットが空のため削除しません（全件失敗の可能性）"
        return 0
    fi
    local f base
    for f in "$OUT_DIR"/*.jar; do
        # マッチ無し時はグロブが展開されず文字列のまま残るためスキップ。
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        if ! contains "$base" ${KEEP_FILES+"${KEEP_FILES[@]}"}; then
            echo "  prune stale: $base"
            rm -f "$f"
        fi
    done
    return 0
}

# required 依存のうち、manifest で解決した project に無いものを警告する（自動追加はしない）。
function warn_missing_dependencies {
    if [ "${#REQUIRED_DEP_IDS[@]}" -eq 0 ]; then
        return 0
    fi
    local dep slug missing=()
    # 重複を除いて未充足のみ抽出する。
    for dep in "${REQUIRED_DEP_IDS[@]}"; do
        if ! contains "$dep" ${SOLVED_PROJECT_IDS+"${SOLVED_PROJECT_IDS[@]}"}; then
            if ! contains "$dep" ${missing+"${missing[@]}"}; then
                missing+=("$dep")
            fi
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi
    echo ""
    echo "=== dependency warnings ==="
    for dep in "${missing[@]}"; do
        # project_id → slug を引いて読みやすく表示する（失敗しても id のまま出す）。
        slug="$(api_get "/project/$dep" 2>/dev/null | extract_project_slug 2>/dev/null || true)"
        echo "  warn: required dependency が mods.txt に未記載: ${slug:-$dep}"
    done
    echo "  （自動追加はしません。必要なら mods.txt に追記してください）"
}

# -----------------------------------------------------------------------------
# 通常モード本体: mods.txt を 1 行ずつ処理する
# -----------------------------------------------------------------------------
function run_manifest {
    if [ ! -f "$MANIFEST" ]; then
        echo "error->manifest not found->$MANIFEST" >&2
        exit 1
    fi
    echo "=== fetch-mods (manifest mode) ==="
    echo "  manifest: $MANIFEST"
    echo "  output  : $OUT_DIR"
    echo "  target  : $GAME_VERSION / $LOADER"
    echo "  json    : $JSON_TOOL"
    echo ""

    local raw line slug pinned
    while IFS= read -r raw || [ -n "$raw" ]; do
        # 行末コメントを除去 → 前後空白を除去。
        line="${raw%%#*}"
        line="$(printf '%s' "$line" | awk '{$1=$1};1')"
        [ -z "$line" ] && continue

        # slug==version_id を分解する（== が無ければ pinned は空）。
        case "$line" in
        *==*)
            slug="${line%%==*}"
            pinned="${line#*==}"
            ;;
        *)
            slug="$line"
            pinned=""
            ;;
        esac
        process_entry "$slug" "$pinned"
    done <"$MANIFEST"

    warn_missing_dependencies
    write_lock_file
}

# -----------------------------------------------------------------------------
# frozen モード本体: mods.lock の version_id/url/sha512 のみで再現 DL する
# -----------------------------------------------------------------------------
function run_frozen {
    if [ ! -f "$LOCK_FILE" ]; then
        echo "error->lock not found->$LOCK_FILE（先に通常モードで生成してください）" >&2
        exit 1
    fi
    echo "=== fetch-mods (frozen mode) ==="
    echo "  lock    : $LOCK_FILE"
    echo "  output  : $OUT_DIR"
    echo ""

    local raw slug version_id filename sha512 url dest
    while IFS=$'\t' read -r slug version_id filename sha512 url || [ -n "$slug" ]; do
        # コメント・空行はスキップ。
        case "$slug" in
        '#'* | '') continue ;;
        esac
        echo "[frozen] $slug ($version_id)"
        dest="$OUT_DIR/$filename"
        KEEP_FILES+=("$filename")
        if download_and_verify "$url" "$dest" "$sha512"; then
            :
        else
            record_failure "$slug" "frozen DL/検証に失敗"
        fi
    done <"$LOCK_FILE"
}

# -----------------------------------------------------------------------------
# メイン
# -----------------------------------------------------------------------------
mkdir -p "$OUT_DIR"

# 解決状態を保持する配列（process_entry / warn_missing_dependencies が参照）。
SOLVED_SLUGS=()
SOLVED_PROJECT_IDS=()
REQUIRED_DEP_IDS=()
# 望ましい最終状態のファイル名集合（prune の判定に使う）。
KEEP_FILES=()

if [ "$FROZEN" -eq 1 ]; then
    run_frozen
else
    run_manifest
fi

# 残骸排除: 解決済みセットに無い jar を削除し、mods/ を解決済みセットそのものに揃える。
echo ""
echo "=== prune stale jars (reconcile to resolved set) ==="
prune_out_dir

# 結果サマリ。
echo ""
if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "=== FAILED (${#FAILURES[@]}) ==="
    printf '  - %s\n' "${FAILURES[@]}"
    echo "一部の MOD が失敗しました。上記を確認してください。"
    exit 1
fi
echo "=== all mods fetched & verified ==="
