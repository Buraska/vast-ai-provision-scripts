---
name: vast-ollama-open-webui
description: Start and connect a local Open WebUI instance to Ollama running on a Vast.ai SSH host. Use for private SSH-tunneled Ollama access, service setup, and troubleshooting; do not expose either service publicly.
---

# Local Open WebUI + Vast Ollama over SSH

Use the already-installed Open WebUI on the workstation and Ollama on the Vast host. Keep the model API loopback-only on the remote host; reach it through an SSH local-forward. Do not install a duplicate remote WebUI when a local WebUI is available.

## Setup

1. Inspect the workstation first: check `http://127.0.0.1:8080` and the `open-webui` process. Do not start a second UI if the existing instance responds.
2. On the Vast host, check `ollama --version`, `ollama list`, and `curl http://127.0.0.1:11434/api/version`. If Ollama is already installed but stopped, start it under Supervisor with `OLLAMA_HOST=127.0.0.1:11434`; use the host's existing Supervisor include directory and logging conventions. Keep `autostart` and `autorestart` enabled.
3. Create the SSH local forward from workstation port 11434 to remote loopback port 11434:

   ```powershell
   ssh -N -p <ssh-port> -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 11434:127.0.0.1:11434 root@<host>
   ```

   Keep that process running while using the UI. Do not forward Ollama on port 8080: 8080 is the WebUI port, while Ollama's API is 11434. If local port 11434 is occupied, select another local port `L`, use `-L L:127.0.0.1:11434`, and configure WebUI to `http://127.0.0.1:L`.
4. Verify the tunnel from the workstation with `curl.exe http://127.0.0.1:11434/api/version` and `/api/tags`. Confirm the remote API still listens only on `127.0.0.1:11434`.
5. In Open WebUI, go to **Admin Settings → Connections → Ollama** and set the API URL to `http://127.0.0.1:11434`, then save and refresh the model list. UI labels may vary by release. If the default connection is already set to this address, no UI change is needed.
6. Do not pull a model unless requested. An empty model list means the Ollama service is connected but no model is installed; user can choose one in WebUI or request a specific model.

7. For a “model not found” error, inspect `ollama list` and use the exact registry model reference (including its namespace and published tag). Download it with `ollama pull <namespace>/<model>:<tag>` only when the requested model is identifiable. A context length such as `12k` is not a model tag; configure context separately. Confirm the model appears in `/api/tags` through the SSH tunnel before selecting it in WebUI.

## Safety and troubleshooting

- Never bind Ollama to `0.0.0.0` or expose remote port 11434 publicly. The SSH tunnel is the access boundary.
- Never leave the SSH tunnel running without `-N`; keep its port-forward explicit and use keepalives.
- A WebUI `502`/connection error: check remote `supervisorctl status ollama`, remote `curl http://127.0.0.1:11434/api/version`, local tunnel listener, then workstation `curl.exe` to the forwarded endpoint.
- If a UI is not running, check for an existing process and avoid taking an occupied port before starting it. For a local install, launch the existing `open-webui serve`; keep Ollama reachable via the same tunnel. Do not deploy another WebUI on Vast without an explicit requirement.
- The Open WebUI URL is `http://127.0.0.1:8080`; the Ollama API URL configured in the UI is `http://127.0.0.1:11434`.
