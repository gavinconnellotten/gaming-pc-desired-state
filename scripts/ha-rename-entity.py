#!/usr/bin/env python3
"""
ha-rename-entity.py — rename Home Assistant entities via the websocket API.

Why this exists as a script rather than a one-off
-------------------------------------------------
Entity renames are **websocket-only**. Home Assistant's REST API can read
states, delete config entries and call services, but the entity registry is not
exposed over it — so `curl` cannot do this and neither can Ansible.

It is worth having because the situation recurs: an integration names entities
after the device it discovered, and when three integrations discover the SAME
device you get `media_player.shield`, `_2` and `_3` with nothing to tell them
apart. An automation written against the wrong one fails in a way that looks
like the device is broken.

Safety
------
- **Dry run by default.** Pass --apply to actually change anything.
- Refuses to rename onto an entity_id that already exists.
- Reports the current friendly name before changing it, so a mistake is
  visible in the output rather than discovered later.

Renaming an entity_id breaks anything referencing the old one — automations,
scripts, dashboards, and this repo's packages. CHECK FIRST:

    grep -rn "media_player.shield" /homeassistant/automations.yaml \\
        /homeassistant/scripts.yaml /homeassistant/packages/

Token: ~/.config/homeassistant/api-token (user-owned 0600). See CLAUDE.md for
why it is user-owned rather than root-owned.

Usage:
    ./scripts/ha-rename-entity.py --list shield
    ./scripts/ha-rename-entity.py old.id new.id "Friendly Name" [--apply]
"""

import asyncio
import json
import os
import sys

import aiohttp

HA_URL = os.environ.get("HA_URL", "http://192.168.68.117:8123")
TOKEN_PATH = os.path.expanduser(
    os.environ.get("HA_TOKEN_FILE", "~/.config/homeassistant/api-token")
)


def load_token() -> str:
    try:
        with open(TOKEN_PATH) as fh:
            token = fh.read().strip()
    except OSError as exc:
        sys.exit(f"ERROR: cannot read {TOKEN_PATH}: {exc}")
    if not token:
        sys.exit(f"ERROR: {TOKEN_PATH} is empty")
    return token


class HA:
    """Minimal websocket client — auth, then request/response by id."""

    def __init__(self, session, ws, token):
        self.ws, self._token, self._id = ws, token, 0

    async def authenticate(self):
        msg = await self.ws.receive_json()
        if msg.get("type") != "auth_required":
            sys.exit(f"ERROR: unexpected greeting: {msg}")
        await self.ws.send_json({"type": "auth", "access_token": self._token})
        msg = await self.ws.receive_json()
        if msg.get("type") != "auth_ok":
            sys.exit(f"ERROR: authentication failed: {msg}")

    async def call(self, **payload):
        self._id += 1
        await self.ws.send_json({"id": self._id, **payload})
        while True:
            msg = await self.ws.receive_json()
            # Ignore anything that is not the reply to this request.
            if msg.get("id") == self._id and msg.get("type") == "result":
                if not msg.get("success"):
                    sys.exit(f"ERROR: {payload.get('type')} failed: {msg.get('error')}")
                return msg.get("result")


async def run(args):
    token = load_token()
    async with aiohttp.ClientSession() as session:
        ws_url = HA_URL.replace("http://", "ws://").replace("https://", "wss://")
        async with session.ws_connect(f"{ws_url}/api/websocket") as ws:
            ha = HA(session, ws, token)
            await ha.authenticate()
            registry = await ha.call(type="config/entity_registry/list")
            by_id = {e["entity_id"]: e for e in registry}

            if args.list is not None:
                needle = args.list.lower()
                hits = [e for e in registry if needle in e["entity_id"].lower()]
                if not hits:
                    print(f"no entities matching '{args.list}'")
                    return
                for e in sorted(hits, key=lambda x: x["entity_id"]):
                    name = e.get("name") or e.get("original_name") or "-"
                    print(f"  {e['entity_id']:<36} {e.get('platform',''):<18} {name}")
                return

            old, new, friendly = args.old, args.new, args.name
            if old not in by_id:
                sys.exit(f"ERROR: {old} is not in the entity registry")
            if new != old and new in by_id:
                sys.exit(f"ERROR: {new} already exists — refusing to collide")

            cur = by_id[old]
            cur_name = cur.get("name") or cur.get("original_name") or "-"
            print(f"  {old}")
            print(f"    -> entity_id: {new}")
            print(f"    -> name:      {cur_name}  ->  {friendly}")

            if not args.apply:
                print("    (dry run — pass --apply to make the change)")
                return

            await ha.call(
                type="config/entity_registry/update",
                entity_id=old,
                new_entity_id=new,
                name=friendly,
            )
            # Verify from the registry rather than trusting the reply.
            #
            # Handle old == new explicitly. Renaming only the friendly name is a
            # legitimate call, and asserting "the old entity_id is gone" then
            # fails on a change that worked perfectly — which it did, on
            # remote.shield, 2026-09-12.
            after = {e["entity_id"]: e for e in
                     await ha.call(type="config/entity_registry/list")}
            if new not in after:
                sys.exit(f"ERROR: {new} is not in the registry after the rename")
            if new != old and old in after:
                sys.exit(f"ERROR: {old} still exists after renaming to {new}")
            got = after[new].get("name")
            if got != friendly:
                sys.exit(f"ERROR: name is {got!r}, expected {friendly!r}")
            print("    applied and verified")


def main():
    import argparse

    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("old", nargs="?", help="current entity_id")
    p.add_argument("new", nargs="?", help="new entity_id")
    p.add_argument("name", nargs="?", help="new friendly name")
    p.add_argument("--list", metavar="SUBSTRING",
                   help="list matching entities and exit")
    p.add_argument("--apply", action="store_true",
                   help="actually make the change (default is a dry run)")
    args = p.parse_args()

    if args.list is None and not (args.old and args.new and args.name):
        p.error("give old, new and name — or use --list")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
