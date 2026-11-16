# Agent Usage Card

A shareable GitHub profile card for your last seven days of Claude Code and Codex CLI usage.

![Sample card showing seven days of Claude Code and Codex token totals](preview.svg)

## Quick start

Install Node.js 24 with npm, then run:

```sh
git clone https://github.com/MinSang22Kim/agent-usage-card.git
cd agent-usage-card
node card.mjs --demo
```

This writes `agent-usage.svg` using sample data. To generate a card from the CLI logs on your machine:

```sh
node card.mjs
```

The first live run downloads the pinned [ccusage](https://github.com/ccusage/ccusage) package through npm. ccusage then summarizes local usage with offline price lookup and cost reporting disabled. The card contains daily token totals, usage days, and token shares for Claude Code and Codex. It does not include prompts, costs, project paths, or model names. Review the card before committing it to a public repository.

## Add it to your profile

Copy `agent-usage.svg` into your GitHub profile README repository and add this line to its README:

```md
![My Claude Code and Codex usage](./agent-usage.svg)
```

Run the same command on your computer whenever you want to refresh it. To write straight to your profile checkout, pass `--out` with the destination path:

```sh
node card.mjs --out "../YOUR-USERNAME/agent-usage.svg"
```

Days use your computer's local time zone and include today. Only usage present in the local CLI logs can be counted, and totals reflect the token categories reported by ccusage. ChatGPT website usage and subscription limits are outside this card's scope.
