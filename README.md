# Junie
**An LLM-agnostic coding agent built for real-world development — by JetBrains.**

Junie is an AI coding agent that lives in your terminal, integrates with your IDE and CI/CD pipelines, and helps you ship code faster. Give it a task in natural language — fix a bug, implement a feature, review a PR — and Junie handles the rest. Like your real coding buddy.

Learn more at the **[official website](https://junie.jetbrains.com/).**

![Junie CLI Screenshot](./assets/junie-cli.gif)

## ✦ Gemini 3 Flash — free for up to 7 days
Includes up to $50 usage per user. Subject to the overall program limit. Limited-time offer.

<br>

## 🚀 Get started

### 📦 Install

For more installation options and details, see the [quickstart](https://junie.jetbrains.com/docs/junie-cli.html#step-1-install-junie-cli) guide.

**macOS / Linux**:

```bash
curl -fsSL https://junie.jetbrains.com/install.sh | bash
```

**Windows:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://junie.jetbrains.com/install.ps1')"
```

<details>
<summary>Alternative options</summary>

**macOS (Homebrew):**

```bash
brew tap jetbrains-junie/junie
brew install junie
```

**npm:**

```bash
npm install -g @jetbrains/junie
```

</details>

### 🔑 Authentication

You can use Junie with one of the following methods:

- **JetBrains Account** — OAuth login using your JetBrains account 
- **Junie API Key** — get your key from [Junie Tokens](https://junie.jetbrains.com/cli) page
- **Bring Your Own Key (BYOK)** — use your own model provider: Anthropic, OpenAI, Google, xAI, OpenRouter, or Copilot

See the [authentication](https://junie.jetbrains.com/docs/junie-cli.html#step-3-authenticate) page for details.

### 💡 Quick Examples

#### Build a new project

```bash
junie
> Build a web dashboard that shows open issues, recent commits, and CI status for this repository
```

#### Analyze a project
```bash
junie
> Review the current changes in this branch and highlight potential bugs, performance issues, and missing tests
```

#### Fix bugs
```bash
junie
> Fix the failing tests in the auth module and add a regression test
```

See the full documentation and supported features on the official [documentation](https://junie.jetbrains.com/docs) page.

### 🐙 GitHub integration

To set up a GitHub Action to let Junie respond to issues, PRs, and CI failures automatically, simply run this command inside the agent:

```
/install-github-action
```

See the full cookbook: [Junie on GitHub](https://junie.jetbrains.com/docs/junie-on-github.html).

## 🐛 Reporting bugs

Use the `/feedback` command inside the agent, or [open an issue](https://github.com/jetbrains/junie/issues) in this repository.

## 👥 Community

Join the official [Junie Discord](https://jb.gg/junie-discord) server to connect with the team and other developers using Junie.

## 📄 License

© JetBrains s.r.o. All rights reserved.

Use is subject to [JetBrains AI Service Terms of Service](https://www.jetbrains.com/legal/docs/terms/jetbrains-ai-service/).
