# Prism Launcher JVM設定手順書

Prism Launcherでメモリ割り当てとAikar's Flagsを設定し、Minecraftの動作を軽量化する手順。

## 前提条件

- Prism Launcherがインストール済みであること
- Java 21以降がインストール済みであること（Minecraft 1.20.5+の場合）

## 1. 設定画面を開く

1. Prism Launcherを起動する
2. 設定したいインスタンスを**右クリック** → **「編集」** を選択する
3. 左メニューから **「設定」** を選択する
4. **「Java」** タブを選択する
5. **「Javaのインストール」** と **「メモリ」** のチェックボックスをONにする

## 2. メモリを設定する

「メモリ」セクションで以下を入力する。

| 項目 | 設定値 | 備考 |
|------|--------|------|
| 最小メモリ割り当て（-Xms） | `8192` MiB | 最大と同じ値にする |
| 最大メモリ割り当て（-Xmx） | `8192` MiB | 下記の目安を参照 |

### メモリ割り当ての目安

| プレイ内容 | 推奨値 |
|-----------|--------|
| バニラ / 軽量MOD | 2048〜4096 MiB |
| 中規模MODパック | 4096〜8192 MiB |
| 大規模MODパック（100個以上） | 8192 MiB〜 |

### 注意事項

- **最小と最大は必ず同じ値にする**。異なる値にするとJVMがメモリのリサイズを繰り返し、カクつきの原因になる
- PCの搭載メモリの半分を超えないようにする（16GB搭載なら最大8192MiB）
- 割り当てすぎるとGC（ガベージコレクション）の負荷が増えて逆に重くなる

## 3. Aikar's Flagsを設定する

同じ「Java」タブ内の **「JVM引数」** 欄に以下をそのままコピー＆ペーストする。

```
-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1
```

> 既存のJVM引数がある場合は、既存の内容を削除してから貼り付ける。

## 4. 設定を保存してテストする

1. 設定画面を閉じる（自動保存される）
2. インスタンスを起動する
3. ワールドに入り、以下を確認する
   - F3キーでデバッグ画面を開き、左上のメモリ使用量が設定値と一致しているか
   - チャンク読み込み時やエンティティが多い場面でカクつきが軽減されているか

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| 起動しない・クラッシュする | メモリ割り当てを減らす（PC搭載メモリの半分以下にする） |
| 起動は成功するがまだ重い | 描画最適化MOD（Sodium等）を導入する |
| `Unrecognized VM option` エラー | Javaのバージョンが古い可能性がある。Java 17以上に更新する |
