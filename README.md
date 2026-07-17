# bootstrap

Debian/Ubuntu の初期環境へ個人用 dotfiles を導入する bootstrap script です。

GitHub CLI で GitHub にログインし、dotfiles repository を clone したあと、repository 内に Ansible playbook があれば実行し、最後に chezmoi の変更を適用します。

## 対応環境

| Distribution | Version | Environment | Architecture |
| --- | --- | --- | --- |
| Debian | 12 / 13 | native Linux | amd64 |
| Ubuntu | 22.04 / 24.04 / 26.04 LTS | native Linux | amd64 |
| Ubuntu | 22.04 / 24.04 / 26.04 LTS | WSL 2 | amd64 |

Debian on WSL、WSL 1、Ubuntu の非 LTS release、上記以外のバージョン、amd64 以外の architecture、他の distribution は非対応です。script は `/etc/os-release`、APT architecture、kernel release を調べ、非対応環境では sudo や APT を実行する前に停止します。

## 使い方

bootstrap repository を clone して実行する場合:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/yourname/bootstrap.git
cd bootstrap
bash bootstrap.sh
```

clone せずに one-liner で実行する場合:

```bash
sudo apt-get update && sudo apt-get install -y curl && bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourname/bootstrap/main/bootstrap.sh)"
```

dotfiles repository と `chezmoi apply` の許可を事前指定する場合:

```bash
sudo apt-get update && sudo apt-get install -y curl && BOOTSTRAP_YES=1 DOTFILES_REPO=yourname/dotfiles bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourname/bootstrap/main/bootstrap.sh)"
```

実行すると、以下を順に行います。

1. 対応 OS、version、native/WSL 2、amd64 を確認
2. sudo credential を初期化
3. Ubuntu では Universe repository を有効化
4. `git`, `curl`, `gh`, `ansible`, `xdg-utils` を APT で install
5. `chezmoi` が未 install の場合、`~/.local/bin` に install
6. GitHub CLI で GitHub に login
7. GitHub の SSH host key を `~/.ssh/known_hosts` に登録
8. dotfiles repository を chezmoi の source directory に clone
9. repository 内に Ansible playbook があれば実行
10. 確認後に `chezmoi apply` を実行

script 本体の序盤で `sudo -v` を実行し、APT に必要な sudo credential を用意します。実行中は sudo timestamp が切れないように keep-alive します。Ansible playbook は `--ask-become-pass` 付きで実行し、`become: true` の task に必要な sudo password は Ansible に直接入力します。

SSH key の生成や passphrase 入力は GitHub CLI と OpenSSH の標準動作に任せ、script から自動入力しません。

## GitHub のブラウザ認証

認証用 browser opener は実行環境に応じて選択します。

- Ubuntu WSL 2 では `/mnt/c/Windows/explorer.exe` を優先します。
- GUI session の Debian/Ubuntu 実機では `xdg-open` を使用します。
- `DISPLAY` と `WAYLAND_DISPLAY` がない headless 実機では opener を設定しません。
- 実行前から `GH_BROWSER` が設定されている場合は、その設定を優先します。

browser を開けない場合は、GitHub CLI が表示する URL と device code を別の端末で開いて認証してください。

認証後、script は GitHub 公式の SSH host key を `~/.ssh/known_hosts` に登録します。これにより、初回 clone 時の host key 確認で停止しないようにします。

## Repository と clone 先

dotfiles repository は `owner/repo` 形式で入力します。

```text
chezmoi source repository to clone (owner/repo): yourname/dotfiles
```

clone 先の default は次の chezmoi source directory です。

```bash
${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi
```

環境変数で repository と clone 先を事前指定できます。

```bash
DOTFILES_REPO=yourname/dotfiles ./bootstrap.sh
DOTFILES_REPO=yourname/dotfiles DOTFILES_DIR="$HOME/src/dotfiles" ./bootstrap.sh
```

clone 開始後に失敗した場合は、今回作成した clone 先だけを削除して終了します。既存 directory がある場合は clone を開始しないため、既存 file や SSH key は削除しません。

## Ansible と chezmoi

clone 後、`ansible/playbook.yml`、`ansible/site.yml`、repository root の `playbook.yml` / `site.yml` など、規定の候補から最初に見つかった playbook を実行します。

`ansible/inventory` があれば `-i ansible/inventory` として指定し、なければ `localhost` を local connection で実行します。`become: true` に対応するため、`ansible-playbook --ask-become-pass` を使用します。

Ansible の実行後は `Apply chezmoi changes?` と確認し、`y` の場合だけ `chezmoi apply` を実行します。`BOOTSTRAP_YES=1` を指定すると、この確認を省略します。

## テスト

OS/WSL 判定、Ubuntu Universe の有効化、browser 選択、非対応環境での早期停止は、fixture と command stub を使って実環境を変更せず検証できます。

```bash
bash tests/run.sh
bash -n bootstrap.sh tests/run.sh
shellcheck bootstrap.sh tests/run.sh
```
