# Junie

> An LLM-agnostic coding agent built for real-world development — by JetBrains.

Junie is an AI coding agent that lives in your terminal, integrates with your IDE and CI/CD pipelines, and helps you ship code faster. Give it a task in natural language — fix a bug, implement a feature, review a PR — and Junie handles the rest. Like your real coding buddy. 


## Get started

### Install

**macOS / Linux** (recommended):

```bash
curl -fsSL https://junie.jetbrains.com/install.sh | bash
```

**macOS (Homebrew):**

```bash
brew tap jetbrains-junie/junie
brew update
brew install junie
```

<details>
<summary>Other channels</summary>

**EAP** — early access, may be unstable:

```bash
curl -fsSL https://junie.jetbrains.com/install-eap.sh | bash
```

**Nightly** — latest features first, but expect rough edges:

```bash
curl -fsSL https://junie.jetbrains.com/install-nightly.sh | bash
```

</details>

> **Note:** npm install (`npm install -g @jetbrains/junie-cli`) is deprecated. Please use one of the methods above.

### GitHub integration

Set up a GitHub Action to let Junie respond to issues, PRs, and CI failures automatically:

```bash
junie /install-github-action
```

See the full cookbook: **[Junie on GitHub](https://junie.jetbrains.com/docs/junie-on-github.html)**.

## Documentation

See the full documentation at **[junie.jetbrains.com/docs](https://junie.jetbrains.com/docs)**.

## Reporting bugs

- Use the `/feedback` command inside the agent
- Or [open an issue](https://github.com/niceplaces/junie/issues) on this repository

## Community

Join us on Discord: **[jb.gg/junie-discord](https://jb.gg/junie-discord)**

## License

© JetBrains s.r.o. All rights reserved.

Use is subject to [JetBrains AI Service Terms of Service](https://www.jetbrains.com/legal/docs/terms/jetbrains-ai-service/).
