#!/usr/bin/env python3
"""An MCP server over the mcastsyslog REST API.

The viewer is doing the work — receiving, parsing, indexing, analysing. This is
a thin adapter so an agent can ask it the same questions a person asks the
window, and it deliberately stays thin: every tool here is one HTTP call to a
documented endpoint, so there is no second implementation of what a filter means
that could drift from the first.

Standard library only. It has to run wherever Claude Code runs, and a plugin
that needs `pip install` before it works is a plugin that does not work.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("MCASTSYSLOG_API", "http://127.0.0.1:8514").rstrip("/")
TIMEOUT = float(os.environ.get("MCASTSYSLOG_TIMEOUT", "20"))
PROTOCOL_VERSION = "2024-11-05"


# --------------------------------------------------------------------------
# Talking to the viewer


class ViewerUnreachable(Exception):
    pass


def call(path, params=None):
    query = urllib.parse.urlencode(
        {k: v for k, v in (params or {}).items() if v not in (None, "", [])},
        doseq=True,
    )
    url = f"{API}/api/v1/{path.lstrip('/')}" + (f"?{query}" if query else "")
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            return json.loads(error.read().decode("utf-8"))
        except Exception:
            return {"error": f"HTTP {error.code} from {url}"}
    except urllib.error.URLError as error:
        raise ViewerUnreachable(
            f"Could not reach the mcastsyslog viewer at {API} ({error.reason}). "
            "Is the app running, and is the REST API switched on in "
            "Settings → REST API?"
        ) from error


def filter_params(arguments, *, allow_limit=True):
    """The filter parameters every endpoint shares.

    Passed through rather than reinterpreted: the API documents what each one
    means, and this should not be a second opinion about it.
    """
    params = {
        "host": arguments.get("host"),
        "tag": arguments.get("tag"),
        "severity": arguments.get("severity"),
        "min_severity": arguments.get("min_severity"),
        "flag": arguments.get("flag"),
        "q": arguments.get("q"),
        "mode": arguments.get("mode"),
        "from": arguments.get("from_time"),
        "to": arguments.get("to_time"),
        "last": arguments.get("last"),
        "order": arguments.get("order"),
    }
    if allow_limit:
        params["limit"] = arguments.get("limit")
    return params


# --------------------------------------------------------------------------
# Tools

FILTERS = {
    "host": {"type": "string", "description": "One or more hostnames, comma-separated."},
    "tag": {"type": "string", "description": "One or more workload tags, comma-separated (stormpump, stormblock, registry, kernel…)."},
    "severity": {"type": "string", "description": "Exact severities, comma-separated, by name or 0-7."},
    "min_severity": {"type": "string", "description": "Everything at least this severe: emergency, alert, critical, error, warning, notice, info, debug."},
    "flag": {"type": "string", "description": "Require a flag: malformed, clock_unset, collapsed_repeat, rate_limited."},
    "q": {"type": "string", "description": "Search text."},
    "mode": {"type": "string", "enum": ["tokens", "substring"], "description": "tokens (default) matches whole words and word prefixes from the index — instant. substring reads the messages and finds anything, including inside a token; it is a scan, so bound it with `last`."},
    "from_time": {"type": "string", "description": "Lower time bound: RFC 3339, 'YYYY-MM-DD HH:MM:SS', an epoch number, or a relative span like -15m."},
    "to_time": {"type": "string", "description": "Upper time bound, same forms."},
    "last": {"type": "string", "description": "A span ending now instead of from/to: 15m, 2h, 1d."},
    "order": {"type": "string", "enum": ["sender", "receive"], "description": "Which of the two times to sort and bound by. sender is the order things happened on the node; receive is the order we heard them."},
}


def with_filters(extra=None, *, limit_default=100):
    properties = dict(FILTERS)
    properties["limit"] = {
        "type": "integer",
        "description": f"How many events to return (default {limit_default}, maximum 10000).",
    }
    properties.update(extra or {})
    return {"type": "object", "properties": properties}


TOOLS = [
    {
        "name": "search_logs",
        "description": (
            "Search and retrieve syslog events from the stormcos fleet. Filters compose. "
            "Returns the newest matching events unless `since_id` is given, in which case it "
            "returns what is new after that id, oldest first — that is how to tail."
        ),
        "inputSchema": with_filters({
            "since_id": {
                "type": "integer",
                "description": "Only events after this id, oldest first. Use `next_since_id` from a previous result to continue a tail.",
            },
        }),
    },
    {
        "name": "watch_logs",
        "description": (
            "Follow the log for a bounded period and return what arrived. Polls with a cursor "
            "rather than holding a connection open, so it cannot hang. Returns as soon as "
            "`max_events` have arrived, or when `seconds` is up — whichever comes first. Call it "
            "again with the returned `next_since_id` to keep following."
        ),
        "inputSchema": with_filters({
            "seconds": {"type": "number", "description": "How long to watch, 1-120 (default 20)."},
            "max_events": {"type": "integer", "description": "Return early once this many have arrived (default 50)."},
            "since_id": {"type": "integer", "description": "Start after this id. Omitted means start from now, not from the beginning of history."},
        }),
    },
    {
        "name": "analyse_sequence",
        "description": (
            "A deep dive of a whole sequence — a boot, a run, a window of the fleet's life. "
            "Returns a narrative plus the phases it passed through, the order workloads came up, "
            "the gaps, the first time each severity appeared, what was unusual, and what every "
            "other node was saying at each fault. This is the tool to reach for when the question "
            "is 'what happened', rather than 'find me this line'."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "host": {"type": "string", "description": "Narrow to one or more nodes, comma-separated. Omit to read the whole fleet."},
                "last": {"type": "string", "description": "The span to read, e.g. 1h, 30m, 2d (default 1h)."},
                "at": {"type": "string", "description": "Centre on a moment instead of a span."},
                "window": {"type": "number", "description": "Seconds either side of `at` (default 300)."},
                "from_time": {"type": "string", "description": "Explicit lower bound."},
                "to_time": {"type": "string", "description": "Explicit upper bound."},
            },
        },
    },
    {
        "name": "node_lifecycle",
        "description": (
            "Boots, clock syncs, faults and silences per node, derived from the stream — nothing "
            "is asked of a node. A node sends the nil timestamp until NTP comes up in the "
            "initramfs, so the frame where that stops is the moment the clock came up. A run "
            "reported as `cut_off` stopped mid-stream and said nothing about why: a crash, a "
            "power cut and a severed cable look identical from outside, and this does not pretend "
            "to tell them apart."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "host": {"type": "string", "description": "Narrow to one or more nodes, comma-separated."},
                "last": {"type": "string", "description": "The span to look over, e.g. 6h (default 24h)."},
                "gap": {"type": "string", "description": "Silence that ends a run, e.g. 90s (default 90s). Raise it for a quiet fleet."},
            },
        },
    },
    {
        "name": "logs_around_moment",
        "description": (
            "Everything every node said around one instant. This is the view multicast exists "
            "for: one node's failure is usually visible in another node's log first, and neither "
            "node knows about the other. Give it a timestamp from a ticket, a bug report or "
            "another tool."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "at": {"type": "string", "description": "The moment: RFC 3339, 'YYYY-MM-DD HH:MM:SS', or an epoch number."},
                "window": {"type": "number", "description": "Seconds either side (default 30)."},
                "min_severity": FILTERS["min_severity"],
                "tag": FILTERS["tag"],
            },
            "required": ["at"],
        },
    },
    {
        "name": "log_summary",
        "description": "A rollup of whatever the filters match: counts by severity, host and tag, the flags, and how many lines the nodes held back and never put on the wire.",
        "inputSchema": with_filters(),
    },
    {
        "name": "fleet_status",
        "description": "Every node as a row: event rate, worst severity, when it was last heard from, and whether its clock is unset.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "window": {"type": "string", "description": "The span to measure over, e.g. 5m, 1h (default 5m)."},
            },
        },
    },
    {
        "name": "store_stats",
        "description": "What the viewer holds and how it is doing: event count, disk use, retention policy, whether it is listening and over which interfaces.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_hosts",
        "description": "Every node ever heard from, including ones that have gone silent.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_tags",
        "description": "Every workload tag ever heard.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "log_types",
        "description": "The type definitions: severities and their numbers, the flags and what each means, search modes, lifecycle markers and run endings, and the fields on an event.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "clear_logs",
        "description": (
            "Delete every event the viewer has stored. Destructive and irreversible. The nodes "
            "keep their own files and the viewer will fill up again from the group, but this "
            "record is gone. Refused unless the user has switched it on in Settings → REST API, "
            "and never available when the API is serving to other machines. Ask the user before "
            "calling this."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "confirm": {"type": "boolean", "description": "Must be true. A guard against calling this by accident."},
            },
            "required": ["confirm"],
        },
    },
]


def run_tool(name, arguments):
    if name == "search_logs":
        params = filter_params(arguments)
        params["since_id"] = arguments.get("since_id")
        return call("events", params)

    if name == "watch_logs":
        return watch(arguments)

    if name == "analyse_sequence":
        return call("analysis", {
            "host": arguments.get("host"),
            "last": arguments.get("last"),
            "at": arguments.get("at"),
            "window": arguments.get("window"),
            "from": arguments.get("from_time"),
            "to": arguments.get("to_time"),
        })

    if name == "node_lifecycle":
        return call("lifecycle", {
            "host": arguments.get("host"),
            "last": arguments.get("last"),
            "gap": arguments.get("gap"),
        })

    if name == "logs_around_moment":
        return call("around", {
            "at": arguments.get("at"),
            "window": arguments.get("window"),
            "min_severity": arguments.get("min_severity"),
            "tag": arguments.get("tag"),
        })

    if name == "log_summary":
        return call("summary", filter_params(arguments, allow_limit=False))

    if name == "fleet_status":
        return call("fleet", {"window": arguments.get("window")})

    if name == "store_stats":
        stats = call("stats")
        stats["health"] = call("health")
        return stats

    if name == "list_hosts":
        return call("hosts")

    if name == "list_tags":
        return call("tags")

    if name == "log_types":
        return call("types")

    if name == "clear_logs":
        if not arguments.get("confirm"):
            return {"error": "clear_logs needs confirm: true. Nothing was deleted."}
        return call("clear", {"confirm": "yes"})

    return {"error": f"no such tool: {name}"}


def watch(arguments):
    """Follow the log for a bounded period.

    A cursor rather than a held-open stream: an MCP tool call returns once, and a
    tool that can hang is worse than one that returns a little late. Asking twice
    with the same cursor gives the same answer, which a stream cannot promise.
    """
    seconds = max(1.0, min(float(arguments.get("seconds") or 20), 120.0))
    max_events = max(1, min(int(arguments.get("max_events") or 50), 1000))
    params = filter_params(arguments, allow_limit=False)

    since = arguments.get("since_id")
    if since is None:
        # Start from now. Watching should show what happens next, not replay
        # everything that already happened.
        since = call("health").get("newest_id", 0)

    collected = []
    deadline = time.monotonic() + seconds
    polls = 0
    while True:
        polls += 1
        params["since_id"] = since
        params["limit"] = max_events - len(collected)
        page = call("events", params)
        if "error" in page:
            return page
        collected.extend(page.get("events", []))
        since = page.get("next_since_id", since)
        if len(collected) >= max_events or time.monotonic() >= deadline:
            break
        time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))

    return {
        "events": collected,
        "returned": len(collected),
        "next_since_id": since,
        "watched_seconds": round(seconds - max(0.0, deadline - time.monotonic()), 1),
        "polls": polls,
        "note": (
            "Call watch_logs again with this next_since_id to keep following. "
            "Nothing arrived in the window if `returned` is 0 — the fleet was quiet, "
            "which is not the same as the viewer being broken; check store_stats."
        ),
    }


# --------------------------------------------------------------------------
# MCP over stdio


def respond(message_id, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(message):
    method = message.get("method")
    message_id = message.get("id")

    if method == "initialize":
        respond(message_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "mcastsyslog", "version": "0.2.0"},
        })
        return

    if method in ("notifications/initialized", "notifications/cancelled"):
        return

    if method == "tools/list":
        respond(message_id, {"tools": TOOLS})
        return

    if method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        try:
            result = run_tool(name, arguments)
            payload = json.dumps(result, indent=2)
            is_error = isinstance(result, dict) and "error" in result
        except ViewerUnreachable as unreachable:
            payload = str(unreachable)
            is_error = True
        except Exception as failure:  # a tool that crashes the server helps nobody
            payload = f"{type(failure).__name__}: {failure}"
            is_error = True
        respond(message_id, {
            "content": [{"type": "text", "text": payload}],
            "isError": is_error,
        })
        return

    if message_id is not None:
        respond(message_id, error={"code": -32601, "message": f"unknown method: {method}"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            handle(message)
        except Exception as failure:
            if isinstance(message, dict) and message.get("id") is not None:
                respond(message["id"], error={"code": -32603, "message": str(failure)})


if __name__ == "__main__":
    main()
