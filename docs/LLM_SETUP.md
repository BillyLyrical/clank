# LLM Setup

Clank supports 7 LLM providers. Configuration uses a layered precedence:

    CLI flags  >  environment variables  >  ~/.clank/config.json  >  defaults

API keys are never written to the database or logs.

## Config File

Clank stores its config and data in `~/.clank/`:

```
~/.clank/
  config.json     # provider settings (optional)
  clank.db        # session store, world model, metrics
```

Create `~/.clank/config.json` to avoid passing flags every time:

```json
{
  "provider": "lmstudio",
  "model": "local-model",
  "base_url": "http://localhost:1234/v1"
}
```

With LM Studio, start the local server and load a model first, then clank
connects automatically — no API key needed.

For cloud providers, add your key:

```json
{
  "provider": "openai",
  "model": "gpt-4o",
  "api_key": "sk-..."
}
```

All fields are optional — anything missing falls back to defaults.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CLANK_PROVIDER` | Provider name (see table below) |
| `CLANK_MODEL` | Model identifier |
| `CLANK_BASE_URL` | API endpoint URL |
| `CLANK_API_KEY` | Authentication key |

## Providers

### LM Studio (default)

Local model server. No API key needed.

```bash
# Start LM Studio, load a model, then:
clank

# Or explicitly:
clank --provider lmstudio --model local-model
```

| Setting | Default |
|---------|---------|
| base_url | `http://localhost:1234/v1` |
| model | `local-model` |
| api_key | *(none)* |

### Ollama

Local model server. No API key needed.

```bash
CLANK_PROVIDER=ollama CLANK_MODEL=codellama clank
```

| Setting | Default |
|---------|---------|
| base_url | `http://localhost:11434/v1` |
| model | `local-model` |
| api_key | *(none)* |

### OpenAI

Requires an API key.

```bash
CLANK_PROVIDER=openai CLANK_MODEL=gpt-4o CLANK_API_KEY=sk-... clank
```

| Setting | Default |
|---------|---------|
| base_url | `https://api.openai.com/v1` |
| model | `local-model` |
| api_key | *(required)* |

### Anthropic

Requires an API key. Uses the Messages API (not chat completions).

```bash
CLANK_PROVIDER=anthropic CLANK_MODEL=claude-sonnet-4-20250514 CLANK_API_KEY=sk-ant-... clank
```

| Setting | Default |
|---------|---------|
| base_url | `https://api.anthropic.com` |
| model | `local-model` |
| api_key | *(required)* |

### Google Gemini

Requires an API key from Google AI Studio.

```bash
CLANK_PROVIDER=gemini CLANK_MODEL=gemini-2.5-flash CLANK_API_KEY=AIza... clank
```

| Setting | Default |
|---------|---------|
| base_url | `https://generativelanguage.googleapis.com` |
| model | `local-model` |
| api_key | *(required)* |

### Azure OpenAI

Requires an Azure OpenAI resource and deployment.

```bash
clank --provider azure \
      --base-url https://myresource.openai.azure.com/openai/deployments/mydeploy \
      --api-key YOUR_AZURE_KEY \
      --model gpt-4o
```

| Setting | Default |
|---------|---------|
| base_url | *(required — include deployment in path)* |
| model | `local-model` |
| api_key | *(required)* |
| api_version | `2024-10-21-preview` |

### OpenAI-Compatible

Any endpoint that serves `/v1/chat/completions` — OpenRouter, vLLM, LocalAI, etc.

```bash
clank --provider openai-compat \
      --base-url https://openrouter.ai/api/v1 \
      --api-key YOUR_KEY \
      --model anthropic/claude-sonnet-4-20250514
```

| Setting | Default |
|---------|---------|
| base_url | `http://localhost:1234/v1` |
| model | `local-model` |
| api_key | *(depends on endpoint)* |

## CLI Flags

Every setting can be passed on the command line:

```bash
clank --provider openai \
      --model gpt-4o \
      --base-url https://api.openai.com/v1 \
      --api-key sk-... \
      --stream
```

Full flag list:

```
--provider NAME     lmstudio | openai | openai-compat | ollama | anthropic | gemini | azure
--model NAME        model identifier (e.g. gpt-4o, claude-sonnet-4-20250514)
--base-url URL      API endpoint
--api-key KEY       authentication key
--db PATH           SQLite database path (default ~/.clank/clank.db)
-w, --wit DIR       extra wit directory (repeatable)
--resume ID         resume a previous session
--stream            stream tokens to stdout
-h, --help          show help
```

## Testing Your Connection

```bash
# List known providers and active config:
clank providers

# Probe the endpoint for available models:
clank providers test
```

## One-Shot Mode

Pass a prompt after flags to run without entering the REPL:

```bash
clank --provider openai --model gpt-4o "explain what a monad is"
```

## Security Notes

- API keys can be passed via env vars, CLI flags, or `~/.clank/config.json`
- Keys are never stored in the SQLite database
- Keys are redacted in all log output (shown as `sk***ey`)
- Prefer `~/.clank/config.json` over CLI flags to avoid shell history leakage
