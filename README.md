# bootstrap

WSL 上の Debian を想定した、dotfiles 初期化用 bootstrap script です。

GitHub CLI で GitHub にログインし、dotfiles repository を clone したあと、repository 内に Ansible playbook があれば実行し、最後に chezmoi の変更を適用します。

## 想定環境

- WSL
- Debian
- apt が使える Linux

実機 Linux でも実行できますが、この script は WSL 向けです。実機 Linux で実行した場合は警告を表示し、続行するかを `y/N` で確認します。

Debian 以外の apt 系 Linux でも実行できますが、互換性は保証しません。その場合も警告を表示し、続行するかを `y/N` で確認します。

## 使い方

bootstrap repository を clone して実行する場合:

```bash
sudo apt update
sudo apt install git
git clone https://github.com/yourname/bootstrap.git
cd bootstrap
bash bootstrap.sh
```

clone せずに one-liner で実行する場合:

```bash
sudo apt-get update && sudo apt-get install -y curl && bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourname/bootstrap/main/bootstrap.sh)"
```

dotfiles repository を事前指定する場合:

```bash
sudo apt-get update && sudo apt-get install -y curl && DOTFILES_REPO=yourname/dotfiles bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourname/bootstrap/main/bootstrap.sh)"
```

`chezmoi apply` の確認も省略したい場合は、`BOOTSTRAP_YES=1` を指定します。

```bash
sudo apt-get update && sudo apt-get install -y curl && BOOTSTRAP_YES=1 DOTFILES_REPO=yourname/dotfiles bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourname/bootstrap/main/bootstrap.sh)"
```

実行すると、以下を順に行います。

1. WSL かどうかを確認
2. Debian または apt 系 Linux かどうかを確認
3. `git`, `curl`, `gh`, `ansible`, `xdg-utils` を apt で install
4. `chezmoi` が未 install の場合、`~/.local/bin` に install
5. GitHub CLI で GitHub に login
6. GitHub の SSH host key を `~/.ssh/known_hosts` に登録
7. dotfiles repository を chezmoi の source directory に clone
8. repository 内に Ansible playbook があれば実行
9. 確認後に `chezmoi apply` を実行

script 本体の序盤で `sudo -v` を実行し、apt に必要な sudo credential を用意します。実行中は sudo timestamp が切れないように keep-alive します。Ansible playbook は `--ask-become-pass` 付きで実行し、`become: true` の task に必要な sudo password は Ansible に直接入力します。SSH key の生成や passphrase 入力は GitHub CLI と OpenSSH の標準挙動に任せ、script から passphrase を自動投入しません。

GitHub CLI の認証では、WSL からブラウザを開くために `xdg-utils` を install し、`xdg-open` を使います。`xdg-open` が無い場合は `/mnt/c/Windows/explorer.exe` を使います。script 内では `GH_BROWSER` を設定し、あわせて `gh config set browser` で GitHub CLI の browser 設定を永続化します。

ブラウザが開かない場合は、GitHub CLI が表示する URL と code を使って認証してください。

認証後、script は GitHub 公式ドキュメントに掲載されている SSH host key を `~/.ssh/known_hosts` に登録します。これにより、初回 clone 時の `Are you sure you want to continue connecting (yes/no/[fingerprint])?` という確認で止まらないようにしています。

## Repository と clone 先

dotfiles repository は `owner/repo` 形式で入力します。

```text
chezmoi source repository to clone (owner/repo): yourname/dotfiles
```

clone 先の default は chezmoi の標準的な source directory です。script は clone 先を対話確認せず、この default をそのまま使います。

```bash
${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi
```

通常は以下になります。

```bash
~/.local/share/chezmoi
```

環境変数で事前指定することもできます。

```bash
DOTFILES_REPO=yourname/dotfiles ./bootstrap.sh
```

clone 先を変えたい場合だけ、`DOTFILES_DIR` を指定します。

```bash
DOTFILES_REPO=yourname/dotfiles DOTFILES_DIR="$HOME/src/dotfiles" ./bootstrap.sh
```

clone 開始後に失敗した場合は、今回作成した clone 先だけを削除して終了します。既存 directory がある場合は clone を開始せずに停止するため、既存 file や既存 SSH key は削除しません。

## Ansible playbook の自動実行

clone 後、次のいずれかの file が存在すれば、最初に見つかったものを `ansible-playbook` で実行します。

```text
ansible/playbook.yml
ansible/playbook.yaml
ansible/site.yml
ansible/site.yaml
playbook.yml
playbook.yaml
site.yml
site.yaml
```

`ansible/inventory` が存在する場合は、その inventory file を `-i ansible/inventory` として指定します。存在しない場合は `localhost` を local connection で実行します。

たとえば `zsh`, `starship`, `tmux`, `neovim` など、dotfiles を適用する前に必要な package は Ansible 側で install できます。

`become: true` を使う task に対応するため、script は `ansible-playbook --ask-become-pass` を使います。これにより、sudo timestamp の再利用可否に依存せず、Ansible が必要な sudo password を取得できます。

## chezmoi apply

Ansible の実行後、script は `Apply chezmoi changes?` と確認し、`y` を入力した場合だけ `chezmoi apply` を実行します。`BOOTSTRAP_YES=1` を指定した場合は、この確認を省略して `chezmoi apply` を実行します。
