# Claude Code Hook Status Setup

Agent Halo reads Claude Code live state from:

```text
~/.agent-halo/claude-code-status.jsonl
```

Configure Claude Code hooks so each lifecycle event invokes:

```bash
/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py <EventName>
```

Example hook settings:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py PreToolUse"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py PostToolUse"
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py PostToolUseFailure"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py Notification"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py Stop"
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py StopFailure"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py SessionEnd"
          }
        ]
      }
    ]
  }
}
```

Expected behavior:

- After sending a normal prompt, Agent Halo shows `THINKING`.
- While Claude Code runs a tool, Agent Halo shows `WORKING`.
- If Claude Code asks the user to approve a tool, Agent Halo shows `WORKING` with `Awaiting permission` and stays there until you approve or deny.
- If a tool fails, Agent Halo briefly shows `WORKING` with `Tool failed`, then settles back to `THINKING` while Claude reasons over the error.
- When Claude Code finishes the turn, Agent Halo shows `DONE` for about 8 seconds.
- If the turn ends with an API error, Agent Halo shows `ERROR`.
- While Claude Code waits for the next user input, Agent Halo returns to `READY`.

Troubleshooting:

```bash
tail -f ~/.agent-halo/claude-code-status.jsonl
```

If no lines appear, Claude Code did not invoke the hook command. Re-check the hook settings path and confirm the script is executable:

```bash
chmod +x /Users/wjs/work/pyproj/AgentHalo/scripts/claude-code-status-hook.py
```
