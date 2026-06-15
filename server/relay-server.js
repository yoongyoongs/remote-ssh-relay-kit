const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const CONFIG = {
  bind: process.env.API_BIND || "0.0.0.0",
  port: Number(process.env.API_PORT || 8787),
  relayHost: process.env.RELAY_HOST || "127.0.0.1",
  relaySshPort: Number(process.env.RELAY_SSH_PORT || 22),
  relayUser: process.env.RELAY_USER || "tunnel",
  enrollCodes: new Set(
    (process.env.ENROLL_CODES || "CHANGE-ME")
      .split(",")
      .map(function (value) { return value.trim(); })
      .filter(Boolean),
  ),
  bootstrapTokens: new Set(
    (process.env.BOOTSTRAP_TOKENS || process.env.BOOTSTRAP_TOKEN || "")
      .split(",")
      .map(function (value) { return value.trim(); })
      .filter(Boolean),
  ),
  adminPublicKey: (process.env.ADMIN_PUBLIC_KEY || "").trim(),
  portStart: Number(process.env.PORT_RANGE_START || 24000),
  portEnd: Number(process.env.PORT_RANGE_END || 24999),
  statePath: process.env.STATE_PATH || path.join(__dirname, "state", "devices.json"),
  authKeysPath: process.env.AUTH_KEYS_PATH || "",
  leaseHours: Number(process.env.LEASE_HOURS || 24),
  bootstrapLeaseMinutes: Number(process.env.BOOTSTRAP_LEASE_MINUTES || 10),
};

function nowIso() {
  return new Date().toISOString();
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    try {
      fs.mkdirSync(dirPath, { recursive: true });
    } catch (error) {
      if (error.code !== "EEXIST") {
        throw error;
      }
    }
  }
}

function ensureStateFile() {
  const dir = path.dirname(CONFIG.statePath);
  ensureDir(dir);
  if (!fs.existsSync(CONFIG.statePath)) {
    const initial = { devices: [], bootstrapCodes: [] };
    fs.writeFileSync(CONFIG.statePath, JSON.stringify(initial, null, 2));
  }
}

function loadState() {
  ensureStateFile();
  const parsed = JSON.parse(fs.readFileSync(CONFIG.statePath, "utf8"));
  return {
    devices: Array.isArray(parsed.devices) ? parsed.devices : [],
    bootstrapCodes: Array.isArray(parsed.bootstrapCodes) ? parsed.bootstrapCodes : [],
  };
}

function saveState(state) {
  ensureStateFile();
  fs.writeFileSync(CONFIG.statePath, JSON.stringify(state, null, 2));
}

function allocatePort(devices) {
  const used = new Set(
    devices
      .filter(function (device) { return device.status === "active"; })
      .map(function (device) { return device.relayPort; }),
  );
  let port = CONFIG.portStart;
  for (; port <= CONFIG.portEnd; port += 1) {
    if (!used.has(port)) {
      return port;
    }
  }
  throw new Error("No relay ports available in configured range.");
}

function generateBootstrapCode() {
  return "AUTO-" + crypto.randomBytes(6).toString("hex").toUpperCase();
}

function pruneBootstrapCodes(state) {
  const now = Date.now();
  state.bootstrapCodes = state.bootstrapCodes.filter(function (entry) {
    return entry && entry.expiresAt && Date.parse(entry.expiresAt) > now;
  });
}

function isStaticEnrollCode(code) {
  return CONFIG.enrollCodes.has(code.trim());
}

function consumeBootstrapCode(state, code) {
  pruneBootstrapCodes(state);
  const normalized = code.trim();
  const index = state.bootstrapCodes.findIndex(function (entry) {
    return entry.code === normalized;
  });
  if (index === -1) {
    return false;
  }
  state.bootstrapCodes.splice(index, 1);
  return true;
}

function rebuildAuthorizedKeys(devices) {
  if (!CONFIG.authKeysPath) {
    return;
  }

  const active = devices
    .filter(function (device) { return device.status === "active"; })
    .sort(function (left, right) { return left.deviceId.localeCompare(right.deviceId); });

  const lines = [
    "# Managed by remote-ssh-relay-kit",
    "# Do not edit manually.",
  ];

  active.forEach(function (device) {
    // `permitlisten` is not supported by some older OpenSSH builds on commodity cloud images.
    // Keep the key restricted in a way that still allows reverse port forwarding to work there.
    const options = "no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,port-forwarding";
    lines.push(options + " " + device.devicePublicKey + " " + device.deviceId);
  });

  ensureDir(path.dirname(CONFIG.authKeysPath));
  fs.writeFileSync(CONFIG.authKeysPath, lines.join("\n") + "\n");
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
  return new Promise(function (resolve, reject) {
    const chunks = [];
    request.on("data", function (chunk) { chunks.push(chunk); });
    request.on("end", function () {
      try {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve(raw ? JSON.parse(raw) : {});
      } catch (error) {
        error.code = "INVALID_JSON";
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function makeDeviceRecord(body, existing, devices) {
  const relayPort = existing && existing.relayPort ? existing.relayPort : allocatePort(devices);
  const createdAt = existing && existing.createdAt ? existing.createdAt : nowIso();
  const expiresAt = new Date(Date.now() + CONFIG.leaseHours * 60 * 60 * 1000).toISOString();
  return {
    deviceRecordId: existing && existing.deviceRecordId ? existing.deviceRecordId : "dev_" + body.device_id,
    deviceId: body.device_id,
    deviceName: body.device_name || body.device_id,
    osType: body.os_type,
    localUser: body.local_user,
    devicePublicKey: body.device_public_key.trim(),
    relayPort: relayPort,
    status: "active",
    createdAt: createdAt,
    lastSeenAt: nowIso(),
    expiresAt: expiresAt,
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

  const state = loadState();
  const normalizedEnrollCode = body.enroll_code.trim();
  const matchedBootstrapCode = consumeBootstrapCode(state, normalizedEnrollCode);
  const matchedStaticCode = isStaticEnrollCode(normalizedEnrollCode);
  if (!matchedStaticCode && !matchedBootstrapCode) {
    return sendJson(response, 403, {
      ok: false,
      errorCode: "INVALID_ENROLL_CODE",
      message: "The enrollment code is invalid or expired.",
    });
  }

  const existing = state.devices.find(function (device) { return device.deviceId === body.device_id; });
  const record = makeDeviceRecord(body, existing, state.devices);

  state.devices = state.devices.filter(function (device) { return device.deviceId !== body.device_id; });
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
    connect_command: "ssh -p " + record.relayPort + " " + record.localUser + "@" + CONFIG.relayHost,
  });
}

async function handleBootstrap(request, response) {
  const body = await readJsonBody(request);
  if (!body.bootstrap_token) {
    return sendJson(response, 400, {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message: "Missing bootstrap token.",
    });
  }

  if (!CONFIG.bootstrapTokens.has(body.bootstrap_token.trim())) {
    return sendJson(response, 403, {
      ok: false,
      errorCode: "INVALID_BOOTSTRAP_TOKEN",
      message: "The bootstrap token is invalid.",
    });
  }

  if (!CONFIG.adminPublicKey) {
    return sendJson(response, 500, {
      ok: false,
      errorCode: "ADMIN_PUBLIC_KEY_NOT_CONFIGURED",
      message: "The relay server does not have an admin public key configured.",
    });
  }

  const state = loadState();
  pruneBootstrapCodes(state);
  const enrollCode = generateBootstrapCode();
  const expiresAt = new Date(Date.now() + CONFIG.bootstrapLeaseMinutes * 60 * 1000).toISOString();
  state.bootstrapCodes.push({
    code: enrollCode,
    deviceName: body.device_name || "",
    osType: body.os_type || "",
    localUser: body.local_user || "",
    createdAt: nowIso(),
    expiresAt: expiresAt,
  });
  saveState(state);

  return sendJson(response, 200, {
    ok: true,
    enroll_code: enrollCode,
    admin_public_key: CONFIG.adminPublicKey,
    relay_host: CONFIG.relayHost,
    relay_ssh_port: CONFIG.relaySshPort,
    relay_user: CONFIG.relayUser,
    expires_at: expiresAt,
  });
}

async function handleHeartbeat(request, response) {
  const body = await readJsonBody(request);
  if (!body.device_record_id) {
    return sendJson(response, 400, { ok: false, errorCode: "INVALID_REQUEST" });
  }

  const state = loadState();
  const index = state.devices.findIndex(function (device) { return device.deviceRecordId === body.device_record_id; });
  if (index === -1) {
    return sendJson(response, 404, { ok: false, errorCode: "NOT_FOUND" });
  }

  state.devices[index] = Object.assign({}, state.devices[index], {
    lastSeenAt: nowIso(),
    status: "active",
  });
  saveState(state);
  return sendJson(response, 200, { ok: true });
}

async function handleRevoke(request, response) {
  const body = await readJsonBody(request);
  if (!body.device_record_id) {
    return sendJson(response, 400, { ok: false, errorCode: "INVALID_REQUEST" });
  }

  const state = loadState();
  const index = state.devices.findIndex(function (device) { return device.deviceRecordId === body.device_record_id; });
  if (index === -1) {
    return sendJson(response, 404, { ok: false, errorCode: "NOT_FOUND" });
  }

  state.devices[index] = Object.assign({}, state.devices[index], {
    status: "revoked",
    lastSeenAt: nowIso(),
  });
  saveState(state);
  rebuildAuthorizedKeys(state.devices);
  return sendJson(response, 200, { ok: true });
}

function handleRequestError(response, error) {
  if (response.writableEnded) {
    return;
  }

  if (error && error.code === "INVALID_JSON") {
    return sendJson(response, 400, {
      ok: false,
      errorCode: "INVALID_JSON",
      message: "Request body is not valid JSON.",
    });
  }

  console.error("[relay-server]", error && error.stack ? error.stack : error);
  return sendJson(response, 500, {
    ok: false,
    errorCode: "INTERNAL_ERROR",
    message: error.message,
  });
}

const server = http.createServer(function (request, response) {
  try {
    if (request.method === "GET" && request.url === "/health") {
      sendJson(response, 200, { ok: true, service: "remote-ssh-relay" });
      return;
    }
    if (request.method === "POST" && request.url === "/api/enroll") {
      Promise.resolve(handleEnroll(request, response)).catch(function (error) {
        handleRequestError(response, error);
      });
      return;
    }
    if (request.method === "POST" && request.url === "/api/bootstrap") {
      Promise.resolve(handleBootstrap(request, response)).catch(function (error) {
        handleRequestError(response, error);
      });
      return;
    }
    if (request.method === "POST" && request.url === "/api/heartbeat") {
      Promise.resolve(handleHeartbeat(request, response)).catch(function (error) {
        handleRequestError(response, error);
      });
      return;
    }
    if (request.method === "POST" && request.url === "/api/revoke") {
      Promise.resolve(handleRevoke(request, response)).catch(function (error) {
        handleRequestError(response, error);
      });
      return;
    }

    sendJson(response, 404, { ok: false, errorCode: "NOT_FOUND" });
    return;
  } catch (error) {
    handleRequestError(response, error);
    return;
  }
});

server.listen(CONFIG.port, CONFIG.bind, function () {
  console.log("Remote SSH relay listening on http://" + CONFIG.bind + ":" + CONFIG.port);
});
