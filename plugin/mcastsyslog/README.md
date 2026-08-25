# mcastsyslog — Claude plugin

Lets Claude read a stormcos fleet's multicast syslog: search it, follow it,
analyse a boot or a crash, and see what every node was saying at one moment.

## What it needs

The **mcastsyslog** viewer running on the same Mac, with its REST API switched
on (Settings → REST API — it is on by default, bound to `127.0.0.1`).

The plugin talks to that API over loopback. It reads; it cannot reach a node,
and neither can the viewer.

## Install

```sh
/plugin marketplace add /path/to/mcastsyslog/plugin
/plugin install mcastsyslog
```

Or point Claude Code at the MCP server directly:

```sh
claude mcp add mcastsyslog -- python3 /path/to/mcastsyslog/plugin/mcastsyslog/mcp/server.py
```

Set `MCASTSYSLOG_API` if the viewer is not on `http://127.0.0.1:8514`.

Standard library only — no `pip install`.

## Tools

| Tool | What it answers |
|---|---|
| `search_logs` | retrieve and search, with every filter the window has |
| `watch_logs` | follow the log for a bounded period and return what arrived |
| `analyse_sequence` | a deep dive of a whole sequence — the one to reach for when the question is "what happened" |
| `node_lifecycle` | boots, clock syncs, faults and silences per node |
| `logs_around_moment` | what every node was saying at one instant |
| `log_summary` | a rollup by severity, host and tag |
| `fleet_status` | nodes as rows: rate, worst severity, last seen |
| `store_stats` | what the viewer holds, and whether it is listening |
| `list_hosts` / `list_tags` | the directories |
| `log_types` | severities, flags, markers — so nothing has to be guessed |
| `clear_logs` | destructive; off unless the user switches it on |

## Commands

- `/mcastsyslog:whats-wrong` — what is going wrong across the fleet right now
- `/mcastsyslog:boot [host]` — walk through a node's most recent boot
- `/mcastsyslog:moment <timestamp>` — what every node was saying at one moment
- `/mcastsyslog:watch [severity]` — follow the log for a minute and report

## Following the log

An MCP tool call returns once, so there is no held-open stream. Following works
with a cursor instead: every result carries a `next_since_id`, and passing it
back asks "what is new since then".

`watch_logs` does that in a loop for a bounded period and returns what arrived.
It cannot hang, and asking twice with the same cursor gives the same answer —
which a stream cannot promise. Humans and browsers can still use the API's
Server-Sent Events endpoint at `/api/v1/stream`.

## What it will not do

The viewer is a listener. It never sends anything to a node, never writes to
one, and never asks one for anything — a viewer that could would be a viewer
that could slow a node down, which is the failure the whole multicast path
exists to avoid. Nothing in this plugin changes that.

The one thing it can destroy is the viewer's own record of what it heard, via
`clear_logs`, and only when the user has switched that on. The nodes keep their
own files regardless.
