# Home Assistant capture

Written by `scripts/capture-homeassistant.sh`. Read-only, redacted.

| File | Contents |
|---|---|
| `10-platform.txt` | Core, OS and Supervisor versions |
| `20-addons.txt` | Add-ons, versions, and update policy |
| `25-addon-options.json` | Every add-on's options |
| `30-voice.txt` | Assist pipeline and the Claude agent's settings |
| `40-music.txt` | Players, areas, storage mounts |
| `50-blueprints.txt` | Blueprints present |
| `yaml/` | configuration, scripts, automations, scenes |

**Enforced** by `roles/homeassistant`: add-on options and Supervisor
properties only. Everything else here is captured for drift detection;
the restore path is the weekly config backup, not this repo.

`secrets.yaml` is never read.
