# UDEV Gothic Installer for Termux

Termux に UDEV Gothic を入れて `~/.termux/font.ttf` へ反映するインストーラです。

![Demo Screenshot](assets/termux-demo.svg)

## Features

- Latest release を自動取得
- 対話モードで variant/family/size/width/style を選択
- `--preset` で一発指定（例: `nf`, `35nflg-bold`）
- ZIP キャッシュ対応（`~/.cache/udevgothic`）

## Quick Start

```bash
pkg install -y curl unzip findutils
curl -fsSL https://raw.githubusercontent.com/dev100kg/TUDEVG/main/install-udevgothic-termux.sh | bash -s
```

非対話で一発適用する場合:

```bash
curl -fsSL https://raw.githubusercontent.com/dev100kg/TUDEVG/main/install-udevgothic-termux.sh | bash -s -- --preset nf --yes
```

ローカル実行:

```bash
chmod +x install-udevgothic-termux.sh
./install-udevgothic-termux.sh
```

## Options

```bash
./install-udevgothic-termux.sh [options]
```

- `-f, --font NAME` font file name を直接指定（完全一致 or 一意の部分一致）
- `-p, --preset PRESET` preset 指定（例: `nf`, `nflg`, `35nf`, `35nflg-bold`, `hs`）
- `-l, --list` 利用可能 package と preset 例を表示
- `-y, --yes` 確認プロンプトをスキップ
- `-h, --help` ヘルプ表示

## Preset Examples

```bash
./install-udevgothic-termux.sh --preset nf --yes
./install-udevgothic-termux.sh --preset nflg --yes
./install-udevgothic-termux.sh --preset 35nflg-bold --yes
./install-udevgothic-termux.sh --preset hs --yes
```

## Cache

- Cache dir: `~/.cache/udevgothic`
- 同じ ZIP は再ダウンロードせず再利用

```bash
rm -rf ~/.cache/udevgothic
```

## Notes

- `--font` と `--preset` を同時指定した場合は `--font` を優先
- 非対話実行時は `--yes` 推奨
