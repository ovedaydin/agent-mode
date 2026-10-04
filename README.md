# Agent Mode ☕

A tiny macOS menu bar app that keeps your Mac awake while AI coding agents are working, so long runs don't stall when the machine goes to sleep.

It notices when an agent like Claude Code or Codex is running and keeps the Mac awake on its own. When the agents finish, normal sleep comes back. You can also switch it on yourself.

## Features

- **Auto mode** (on by default): stays awake while any of these processes is running: `claude`, `codex`, `aider`, `gemini`, `cursor-agent`, `opencode`, `amp`, `goose`. It checks every 10 seconds.
- **Keep Awake**: on until you turn it off.
- **Keep Awake For**: 30 minutes, or 1, 2, 4 or 8 hours.
- **Keep Display On Too**: also stops the screen from sleeping.
- **Launch at Login**
- **Icon:** a filled cup means it's keeping the Mac awake; an empty cup means the Mac can sleep.

It uses the same macOS power assertion as the built-in `caffeinate` command. It needs no special permissions and doesn't touch the network.

## Install

Requires macOS 13 or later.

### Download

Get `Agent-Mode.zip` from the [latest release](https://github.com/ovedaydin/agent-mode/releases/latest), unzip it and move **Agent Mode.app** to /Applications.

The app isn't notarized, so macOS blocks it the first time you open it. To allow it, either right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Agent Mode.app"
```

### Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ovedaydin/agent-mode.git
cd agent-mode
./build.sh --install   # builds, copies to /Applications and launches it
```

Run `./build.sh` without `--install` to build `build/Agent Mode.app` without installing it.

## Configuration

To change which processes count as agents, list the process names (as shown by `ps -Ao comm`), then quit and reopen the app:

```sh
defaults write io.github.ovedaydin.agentmode agentProcessNames -array claude codex my-agent
```

To go back to the default list:

```sh
defaults delete io.github.ovedaydin.agentmode agentProcessNames
```

## Limits

Agent Mode stops *idle* sleep only. If you close the lid on battery, the Mac still sleeps. It stays awake with the lid closed only when it's plugged into power and an external display.

To check that it's working:

```sh
pmset -g assertions | grep "Agent Mode"
```

## License

[MIT](LICENSE)
