# claude-statusline

Configure your Claude Code statusline to show limits, directory and git info

## Demo

```text
╭─ Claude Statusline ───────────────────────────────────────────────╮
│ Opus 4.8  │ ctx:0% │ 5h:[█░░░░░░░] 14% 2h4m │ 7d:[░░░░░░░░] 3% 4d19h │
╰───────────────────────────────────────────────────────────────────╯
```
## Install

Run the command below to set it up

```bash
npx @fionitos/claude-statusline
```

It backups your old status line if any and copies the status line script to `~/.claude/statusline.sh` and configures your Claude Code settings.

## Requirements

- [jq](https://jqlang.github.io/jq/) — for parsing JSON
- curl — for fetching rate limit data
- git — for branch info

On macOS:

```bash
brew install jq
```

## Uninstall

```bash
npx @fionitos/claude-statusline --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it removes the script and cleans up your settings.

## License

MIT
