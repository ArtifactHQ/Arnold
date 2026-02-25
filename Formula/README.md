# Arnold Pipeline Homebrew Formula

## Install from the local formula

```bash
brew install --formula Formula/arnold.rb
```

## Verify the installation

```bash
arnold version    # prints arnold_pipeline 0.1.0
arnold doctor     # checks environment health and dependencies
```

## Start the MCP server as a background service

```bash
brew services start arnold    # starts the MCP stdio server
brew services stop arnold     # stops the service
brew services info arnold     # check service status
```

## Uninstall

```bash
brew services stop arnold     # stop the service first
brew uninstall arnold
```

## Data locations

| Path | Purpose |
|------|---------|
| `~/.arnold_pipeline/pipeline.sqlite3` | Pipeline run database |
| `~/.arnold_pipeline/config.yml` | User configuration |

## Future

This formula will be published to a Homebrew tap at `ArtifactHQ/homebrew-tap`,
enabling installation via:

```bash
brew tap ArtifactHQ/homebrew-tap
brew install arnold
```
