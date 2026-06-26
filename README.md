# bootstrap

WSL 上の Debian を想定した、dotfiles 初期化用 bootstrap script です。

GitHub CLI で GitHub にログインし、chezmoi の source directory に dotfiles repository を clone するところまでを行います。

## 想定環境

- WSL
- Debian
- apt が使える Linux

実機 Linux でも実行できますが、この script は WSL 向けです。実機 Linux で実行した場合は警告を表示し、続行するかを `y/N` で確認します。

Debian 以外の apt 系 Linux でも実行できますが、互換性は保証しません。その場合も警告を表示し、続行するかを `y/N` で確認します。

## 使い方

```bash
./bootstrap.sh
```

実行すると、以下を順に行います。

1. WSL かどうかを確認
2. Debian または apt 系 Linux かどうかを確認
3. `git`, `curl`, `gh` を apt で install
4. `chezmoi` が未 install の場合、`~/.local/bin` に install
5. GitHub CLI で GitHub に login
6. dotfiles repository を chezmoi の source directory に clone

GitHub CLI の認証では、可能であればブラウザが開きます。開かない場合は、GitHub CLI が表示する URL と code を使って認証してください。

## Repository と clone 先

dotfiles repository は `owner/repo` 形式で入力します。

```text
chezmoi source repository to clone (owner/repo): yourname/dotfiles
```

clone 先の default は chezmoi の標準的な source directory です。

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

clone 先を変えたい場合は、`DOTFILES_DIR` を指定します。

```bash
DOTFILES_REPO=yourname/dotfiles DOTFILES_DIR="$HOME/src/dotfiles" ./bootstrap.sh
```

## clone 後

clone が終わったら、script は次の command を案内します。

```bash
chezmoi diff
chezmoi apply
```

`chezmoi` を `~/.local/bin` に install した場合は、script の案内では `~/.local/bin/chezmoi` のように実際の path を表示します。

まず `chezmoi diff` で変更内容を確認し、問題なければ `chezmoi apply` を実行してください。
