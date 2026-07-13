
# copycat

Easy copying of many files at once in an easy to read (for humans and robots) way. Created to make sharing context between LLM chats easier.

## Why make this?

Sometimes I just need another set of eyes on something and when I dont have a person for that, a small LLM is usually more than nothing.

## Install

Use the included installer script from the repository root:

```bash
bash install.sh
```

The installer offers:

1. **Native install**: copies `copycat.sh` to `~/.local/bin/copycat`
2. **Alias install**: adds a `copycat` alias pointing to your current repo path

If the installer updates your shell config, reload it (or restart your terminal):

```bash
source ~/.bashrc   # Linux bash
source ~/.zshrc    # zsh
```
