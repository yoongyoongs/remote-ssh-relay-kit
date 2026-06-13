import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CONFIG = {
  bind: process.env.API_BIND || "0.0.0.0",
  port: Number(process.env.API_PORT || 8787),
  relayHost: process.env.RELAY_HOST || "127.0.0.1",
  relaySshPort: Number(process.env.RELAY_SSH_PORT || 22),
  relayUser: process.env.RELAY_USER || "tunnel",
  enrollCodes: new Set(
    (process.env.ENROLL_CODES || "CHANGE-ME")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  ),
  portStart: Number(process.env.PORT_RANGE_START || 24000),
  portEnd: Number(process.env.PORT_RANGE_END || 24999),
  statePath: process.env.STATE_PATH || path.join(__dirname, "state", "devices.json"),
  authKeysPath: process.env.AUTH_KEYS_PATH || "",
  leaseHours: Number(process.env.LEASE_HOURS || 24),
};

function nowIso() {
  return new Date().toISOString();
}

function ensureStateFile() {
  const dir = path.dirname(CONFIG.statePath);
  fs.mkdirSync(dir, { recursive: true });
  if (!fs.existsSync(CONFIG.statePath)) {
    const initial = { devices: [] };
    fs.writeFileSync(CONFIG.statePath, JSON.stringify(initial, null, 2));
  }
}

function loadState() {
  ensureStateFile();
  return JSON.parse(fs.readFileSync(CONFIG.statePath, "utf8"));
}

function saveState(state) {
  ensureStateFile();
  fs.writeFileSync(CONFIG.statePath, JSON.stringify(state, null, 2));
}

function allocatePort(devices) {
  const used = new Set(
    devices.filter((device) => device.status === "active").map((device) => device.relayPort),
  );
  for (let port = CONFIG.portStart; port <= CONFIG.portEnd; port += 1) {
    if (!used.has(port)) {
      return port;
    }
  }
  throw new Error("No relay ports available in configured range.");
}

function rebuildAuthorizedKeys(devices) {
  if (!CONFIG.authKeysPath) {
    return;
  }

  const active = devices
    .filter((device) => device.status === "active")
    .sort((left, right) => left.deviceId.localeCompare(right.deviceId));

  const lines = [
    "# Managed by remote-ssh-relay-kit",
    "# Do not edit manually.",
  ];

  for (const device of active) {
    const options = `restrict,port-forwarding,permitlisten="0.0.0.0:${device.relayPort}"`;
    lines.push(`${options} ${device.devicePublicKey} ${device.deviceId}`);
  }

  fs.mkdirSync(path.dirname(CONFIG.authKeysPath), { recursive: true });
  fs.writeFileSync(CONFIG.authKeysPath, `${lines.join("\n")}\n`);
}

function sendJson(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

function readJsonBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve(raw ? JSON.parse(raw) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function makeDeviceRecord(body, existing, devices) {
  const relayPort = existing?.relayPort ?? allocatePort(devices);
  const createdAt = existing?.createdAt ?? nowIso();
  const expiresAt = new Date(Date.now() + CONFIG.leaseHours * 60 * 60 * 1000).toISOString();
  return {
    deviceRecordId: existing?.deviceRecordId ?? `dev_${body.device_id}`,
    deviceId: body.device_id,
    deviceName: body.device_name || body.device_id,
    osType: body.os_type,
    localUser: body.local_user,
    devicePublicKey: body.device_public_key.trim(),
    relayPort,
    status: "active",
    createdAt,
    lastSeenAt: nowIso(),
    expiresAt,
  };
}

async function handleEnroll(request, response) {
  const body = await readJsonBody(request);
  const required = [
    body.enroll_code,
    body.device_id,
    body.device_public_key,
    body.os_type,
    body.local_user,
  ];

  if (!required.every(Boolean) || body.ssh_ready !== true) {
    return sendJson(response, 400, {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message: "Missing required fields or SSH is not ready.",
    });
  }

  if (!CONFIG.enrollCodes.has(body.enroll_code.trim())) {
    return sendJson(response, 403, {
      ok: false,
      errorCode: "INVALID_ENROLL_CODE",
      message: "The enrollment code is invalid or expired.",
    });
  }

  const state = loadState();
  const existing = state.devices.find((device) => device.deviceId === body.device_id);
  const record = makeDeviceRecord(body, existing, state.devices);

  state.devices = state.devices.filter((device) => device.deviceId !== body.device_id);
  state.devices.push(record);
  saveState(state);
  rebuildAuthorizedKeys(state.devices);

  return sendJson(response, 200, {
    ok: true,
    relay_host: CONFIG.relayHost,
    relay_ssh_port: CONFIG.relaySshPort,
    relay_user: CONFIG.relayUser,
    remote_port: record.relayPort,
    device_record_id: record.deviceRecordId,
    tunnel_options: {
      remote_bind_address: "0.0.0.0",
      local_host: "127.0.0.1",
      local_port: 22,
    },
    connect_command: `ssh -p ${record.relayPort} ${record.localUser}@${CONFIG.relayHost}`,
  });
}

async function handleHeartbeat(request, response) {
  const body = await readJsonBody(request);
  if (!body.device_record_id) {
    return sendJson(response, 400, { ok: false, errorCode: "INVALID_REQUEST" });
  }

  const state = loadState();
  const index = state.devices.findIndex((device) => device.deviceRecordId === body.device_record_id);
  if (index === -1) {
    return sendJson(response, 404, { ok: false, errorCode: "NOT_FOUND" });
  }

  state.devices[index] = {
    ...state.devices[index],
    lastSeenAt: nowIso(),
    status: "active",
  };
  saveState(state);
  return sendJson(response, 200, { ok: true });
}

async function handleRevoke(request, response) {
  const body = await readJsonBody(request);
  if (!body.device_record_id) {
    return sendJson(response, 400, { ok: false, errorCode: "INVALID_REQUEST" });
  }

  const state = loadState();
  const index = state.devices.findIndex((device) => device.deviceRecordId === body.device_record_id);
  if (index === -1) {
    return sendJson(response, 404, { ok: false, errorCode: "NOT_FOUND" });
  }

  state.devices[index] = {
    ...state.devices[index],
    status: "revoked",
    lastSeenAt: nowIso(),
  };
  saveState(state);
  rebuildAuthorizedKeys(state.devices);
  return sendJson(response, 200, { ok: true });
}

const server = http.createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      return sendJson(response, 200, { ok: true, service: "remote-ssh-relay" });
    }
    if (request.method === "POST" && request.url === "/api/enroll") {
      return handleEnroll(request, response);
    }
    if (request.method === "POST" && request.url === "/api/heartbeat") {
      return handleHeartbeat(request, response);
    }
    if (request.method === "POST" && request.url === "/api/revoke") {
      return handleRevoke(request, response);
    }

    return sendJson(response, 404, { ok: false, errorCode: "NOT_FOUND" });
  } catch (error) {
    return sendJson(response, 500, {
      ok: false,
      errorCode: "INTERNAL_ERROR",
      message: error.message,
    });
  }
});

server.listen(CONFIG.port, CONFIG.bind, () => {
  console.log(`Remote SSH relay listening on http://${CONFIG.bind}:${CONFIG.port}`);
});
