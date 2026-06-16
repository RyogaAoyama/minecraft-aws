#!/bin/bash
#
# build-server.sh - Fabric サーバー一式を「Java なし・純ダウンロード」で組み立てる。
#
# 設計:
#   - Fabric の起動用ランチャー jar(fabric-server-launch.jar) を meta API から直接 curl で取得する。
#     インストーラ(Java製)を一切使わない。vanilla server / libraries は「インスタンスの初回起動時」に
#     ランチャー自身が自動DLする（EC2 には Corretto 21 が入っているため Java はそこで足りる）。
#   - mods は fetch-mods.sh --frozen で mods.lock 通りに用意する（冪等・残骸prune込み）。
#   - 版は pin する: MC=GAME_VERSION、loader/installer は通常モードで stable 最新を解決し
#     server.lock に固定、--frozen で server.lock から完全再現する（fetch-mods.sh と同じ思想）。
#   - 冪等: 既に期待 sha512 と一致するランチャーがあれば再DLしない。
#   - 実行環境は macOS の bash 3.2 / GitHub Actions(ubuntu) の双方を想定。JSONは jq→python3 フォールバック。
#
# 出力(-o dir): fabric-server-launch.jar と mods/ を配置する。
#   server.properties / eula.txt / cwagent 設定はインスタンス側 install.sh が生成・配置するため含めない。
#
# 終了コード: 成功で 0、失敗で 1。

set -euo pipefail

# -----------------------------------------------------------------------------
# 定数
# -----------------------------------------------------------------------------
FABRIC_META="https://meta.fabricmc.net/v2"
USER_AGENT="minecraft-aws/1.0 (github)"
GAME_VERSION="1.21.11"
LAUNCHER_NAME="fabric-server-launch.jar"

# -----------------------------------------------------------------------------
# ヘルプ
# -----------------------------------------------------------------------------
function usage {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
    -o dir       出力ディレクトリ（サーバー一式の生成先）。デフォルト ./my-fabric-server
    -g version   対象MCバージョン（デフォルト 1.21.11）
    -l version   Fabric loader バージョン（省略時 stable 最新を解決）
    -i version   Fabric installer バージョン（省略時 stable 最新を解決）
    -f, --frozen server.lock のみで再現ビルド（loader/installer を解決しない）
    -h           ヘルプ
EOM
    exit 2
}

# -----------------------------------------------------------------------------
# オプション解析（getopts はロングオプション非対応のため --frozen は前処理で吸収）
# -----------------------------------------------------------------------------
OUT_DIR="./my-fabric-server"
LOADER_VERSION=""
INSTALLER_VERSION=""
FROZEN=0

ARGS=()
for arg in "$@"; do
    case "$arg" in
    --frozen) FROZEN=1 ;;
    *) ARGS+=("$arg") ;;
    esac
done
set -- ${ARGS+"${ARGS[@]}"}

while getopts o:g:l:i:fh OPT; do
    case "$OPT" in
    o) OUT_DIR="$OPTARG" ;;
    g) GAME_VERSION="$OPTARG" ;;
    l) LOADER_VERSION="$OPTARG" ;;
    i) INSTALLER_VERSION="$OPTARG" ;;
    f) FROZEN=1 ;;
    h | \?) usage ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# server.lock はリポジトリ直下に置く（mods.lock と同様に commit し、CI の --frozen で参照する）。
# 出力先(OUT_DIR)は jar 等のビルド成果物専用（コミットしない＝.gitignore）。
LOCK_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/server.lock"

# -----------------------------------------------------------------------------
# 依存ツール（jq 優先 / python3 フォールバック）
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
for t in curl shasum; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "error->$t not found" >&2
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Modrinth/Fabric 共通: GET して本文を返す（HTTP 200 系で 0）。
# 引数: $1 完全URL
# -----------------------------------------------------------------------------
function http_get {
    local url="$1" body status
    body="$(curl -sS -w $'\n%{http_code}' -H "User-Agent: $USER_AGENT" "$url" 2>/dev/null)" || return 1
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
        printf '%s' "$body"
        return 0
    fi
    return 1
}

# JSON 配列から「最初に stable==true な要素の .<path>」を返す簡易抽出。
# 引数: $1 JSON / $2 jq式 / $3 pythonキー操作（評価式: 変数 d=配列）
function json_first_stable {
    local json="$1" jq_expr="$2" py_expr="$3"
    if [ "$JSON_TOOL" = "jq" ]; then
        printf '%s' "$json" | jq -r "$jq_expr"
    else
        printf '%s' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print($py_expr)"
    fi
}

# -----------------------------------------------------------------------------
# loader / installer の解決
# -----------------------------------------------------------------------------
function resolve_versions {
    if [ -z "$LOADER_VERSION" ]; then
        echo "[resolve] loader (stable latest for $GAME_VERSION)"
        local loaders_json
        loaders_json="$(http_get "$FABRIC_META/versions/loader/$GAME_VERSION")" || {
            echo "error->failed to fetch loader list for $GAME_VERSION" >&2
            exit 1
        }
        # 配列は新しい順。stable 最優先、無ければ先頭。
        LOADER_VERSION="$(json_first_stable "$loaders_json" \
            '([ .[] | select(.loader.stable) ][0] // .[0]) | .loader.version' \
            '([x for x in d if x[\"loader\"][\"stable\"]] or d)[0][\"loader\"][\"version\"]')"
    fi
    if [ -z "$INSTALLER_VERSION" ]; then
        echo "[resolve] installer (stable latest)"
        local inst_json
        inst_json="$(http_get "$FABRIC_META/versions/installer")" || {
            echo "error->failed to fetch installer list" >&2
            exit 1
        }
        INSTALLER_VERSION="$(json_first_stable "$inst_json" \
            '([ .[] | select(.stable) ][0] // .[0]) | .version' \
            '([x for x in d if x[\"stable\"]] or d)[0][\"version\"]')"
    fi
    if [ -z "$LOADER_VERSION" ] || [ "$LOADER_VERSION" = "null" ] || \
       [ -z "$INSTALLER_VERSION" ] || [ "$INSTALLER_VERSION" = "null" ]; then
        echo "error->failed to resolve loader/installer version" >&2
        exit 1
    fi
    echo "  game=$GAME_VERSION loader=$LOADER_VERSION installer=$INSTALLER_VERSION"
}

# server.lock から版を読む（frozen モード）。
function read_lock {
    if [ ! -f "$LOCK_FILE" ]; then
        echo "error->lock not found->$LOCK_FILE（先に通常モードで生成してください）" >&2
        exit 1
    fi
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
        game) GAME_VERSION="$v" ;;
        loader) LOADER_VERSION="$v" ;;
        installer) INSTALLER_VERSION="$v" ;;
        esac
    done <"$LOCK_FILE"
    if [ -z "$LOADER_VERSION" ] || [ -z "$INSTALLER_VERSION" ]; then
        echo "error->lock is incomplete->$LOCK_FILE" >&2
        exit 1
    fi
    echo "[frozen] game=$GAME_VERSION loader=$LOADER_VERSION installer=$INSTALLER_VERSION"
}

# -----------------------------------------------------------------------------
# ランチャー jar の取得（冪等: 既存が期待 sha と一致すればスキップ）
# -----------------------------------------------------------------------------
function fetch_launcher {
    local url="$FABRIC_META/versions/loader/$GAME_VERSION/$LOADER_VERSION/$INSTALLER_VERSION/server/jar"
    local dest="$OUT_DIR/$LAUNCHER_NAME"
    local expected=""

    # frozen かつ lock に sha があれば、それを期待値に使う。
    if [ -f "$LOCK_FILE" ]; then
        expected="$(grep '^launcher_sha512=' "$LOCK_FILE" 2>/dev/null | cut -d= -f2- || true)"
    fi

    # スキップは frozen モード限定。ランチャーは固定名のため、resolve モードで
    # loader/installer が更新された際に古い jar を sha 一致と誤判定して取り損ねるのを防ぐ
    # （resolve モードは毎回取得し直す＝常に最新。175KB と軽量なので負荷も無視できる）。
    if [ "$FROZEN" -eq 1 ] && [ -n "$expected" ] && [ -f "$dest" ]; then
        local cur
        cur="$(shasum -a 512 "$dest" | awk '{print $1}')"
        if [ "$cur" = "$expected" ]; then
            echo "[launcher] already present (sha512 OK): $LAUNCHER_NAME"
            LAUNCHER_SHA512="$expected"
            return 0
        fi
    fi

    echo "[launcher] download: $url"
    if ! curl -sSL -H "User-Agent: $USER_AGENT" -o "$dest" "$url"; then
        rm -f "$dest"
        echo "error->launcher download failed" >&2
        exit 1
    fi
    # ダウンロード物が jar（ZIP）であることを最低限ガードする（HTMLエラー等を弾く）。
    case "$(head -c 2 "$dest" 2>/dev/null)" in
    PK) : ;;
    *)
        rm -f "$dest"
        echo "error->downloaded launcher is not a valid jar (zip) file" >&2
        exit 1
        ;;
    esac

    LAUNCHER_SHA512="$(shasum -a 512 "$dest" | awk '{print $1}')"
    # frozen で lock に期待 sha があったのに一致しなければ再現性破れ＝失敗扱い。
    if [ "$FROZEN" -eq 1 ] && [ -n "$expected" ] && [ "$LAUNCHER_SHA512" != "$expected" ]; then
        rm -f "$dest"
        echo "error->launcher sha512 mismatch in frozen mode" >&2
        exit 1
    fi
    echo "  saved: $dest"
    echo "  sha512: ${LAUNCHER_SHA512:0:16}..."
}

# server.lock を書き出す。
function write_lock {
    {
        echo "# server.lock - build-server.sh が生成（手で編集しない）。Fabric ランチャーの版を固定。"
        echo "# 再現ビルド: sh/build-server.sh --frozen -o <出力先>"
        echo "game=$GAME_VERSION"
        echo "loader=$LOADER_VERSION"
        echo "installer=$INSTALLER_VERSION"
        echo "launcher_sha512=$LAUNCHER_SHA512"
    } >"$LOCK_FILE"
    echo "lock written: $LOCK_FILE"
}

# -----------------------------------------------------------------------------
# メイン
# -----------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
LAUNCHER_SHA512=""

echo "=== build-server (Java不要・純ダウンロード) ==="
echo "  output: $OUT_DIR"
echo "  mode  : $([ "$FROZEN" -eq 1 ] && echo frozen || echo resolve)"
echo "  json  : $JSON_TOOL"
echo ""

if [ "$FROZEN" -eq 1 ]; then
    read_lock
else
    resolve_versions
fi

fetch_launcher

# mods は fetch-mods.sh に委譲（--frozen で mods.lock 通り＝冪等・残骸prune込み）。
echo ""
echo "=== mods (delegate to fetch-mods.sh --frozen) ==="
bash "$SCRIPT_DIR/fetch-mods.sh" --frozen -g "$GAME_VERSION" -o "$OUT_DIR/mods"

# resolve モードでのみ lock を更新（frozen は再現確認のみで lock を書き換えない）。
if [ "$FROZEN" -eq 0 ]; then
    echo ""
    write_lock
fi

echo ""
echo "=== build complete ==="
echo "  $OUT_DIR/$LAUNCHER_NAME"
echo "  $OUT_DIR/mods/ ($(ls -1 "$OUT_DIR/mods/"*.jar 2>/dev/null | wc -l | tr -d ' ') jars)"
echo ""
echo "次: vanilla server / libraries はインスタンス初回起動時にランチャーが自動DLします。"
echo "    この一式を world/ へ: aws s3 sync $OUT_DIR/ s3://minecraft-world-prd/world/ （--delete は付けない）"
