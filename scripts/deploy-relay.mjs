import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "ssh2";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.dirname(__dirname);
const serverDir = path.join(projectRoot, "server");

function parseArgs(argv) {
  const parsed = {};
  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const value = argv[index + 1] && !argv[index + 1].startsWith("--") ? argv[++index] : "true";
    parsed[key] = value;
  }
  return parsed;
}

function requireArg(args, key) {
  if (!args[key]) {
    throw new Error(`Missing required argument --${key}`);
  }
  return args[key];
}

function connectSsh(options) {
  return new Promise((resolve, reject) => {
    const client = new Client();
    client.on("ready", () => resolve(client));
    client.on("error", reject);
    client.connect(options);
  });
}

function execCommand(client, command) {
  return new Promise((resolve, reject) => {
    client.exec(command, (error, stream) => {
      if (error) {
        reject(error);
        return;
      }

      let stdout = "";
      let stderr = "";

      stream.on("data", (chunk) => {
        stdout += chunk.toString("utf8");
      });
      stream.stderr.on("data", (chunk) => {
        stderr += chunk.toString("utf8");
      });
      stream.on("close", (code) => {
        if (code === 0) {
          resolve({ stdout, stderr });
        } else {
          reject(new Error(`Remote command failed (${code}): ${stderr || stdout}`));
        }
      });
    });
  });
}

function openSftp(client) {
  return new Promise((resolve, reject) => {
    client.sftp((error, sftp) => {
      if (error) {
        reject(error);
        return;
      }
      resolve(sftp);
    });
  });
}

function uploadFile(sftp, localPath, remotePath) {
  return new Promise((resolve, reject) => {
    sftp.fastPut(localPath, remotePath, (error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

async function main() {
  const args = parseArgs(process.argv);
  const host = requireArg(args, "host");
  const username = args.user || "root";
  const password = requireArg(args, "password");
  const relayHost = args["relay-host"] || host;
  const relayUser = args["relay-user"] || "tunnel";
  const apiPort = Number(args["api-port"] || 8787);
  const relaySshPort = Number(args["relay-ssh-port"] || 22);
  const enrollCode = requireArg(args, "enroll-code");
  const portStart = Number(args["port-start"] || 24000);
  const portEnd = Number(args["port-end"] || 24999);

  const localFiles = [
    path.join(serverDir, "relay-server.mjs"),
    path.join(serverDir, "install-server.sh"),
    path.join(serverDir, "sshd_config.sample"),
    path.join(serverDir, "relay.env.sample"),
  ];

  const conn = await connectSsh({
    host,
    port: 22,
    username,
    password,
    readyTimeout: 20000,
  });

  try {
    console.log("Connected to relay host.");
    await execCommand(conn, "mkdir -p /root/remote-ssh-relay-deploy");
    const sftp = await openSftp(conn);
    for (const localFile of localFiles) {
      const remotePath = `/root/remote-ssh-relay-deploy/${path.basename(localFile)}`;
      await uploadFile(sftp, localFile, remotePath);
      console.log(`Uploaded ${path.basename(localFile)}`);
    }
    sftp.end();

    const relayEnv = [
      "API_BIND=0.0.0.0",
      `API_PORT=${apiPort}`,
      `RELAY_HOST=${relayHost}`,
      `RELAY_SSH_PORT=${relaySshPort}`,
      `RELAY_USER=${relayUser}`,
      `ENROLL_CODES=${enrollCode}`,
      `PORT_RANGE_START=${portStart}`,
      `PORT_RANGE_END=${portEnd}`,
      "STATE_PATH=/opt/remote-ssh-relay/state/devices.json",
      `AUTH_KEYS_PATH=/home/${relayUser}/.ssh/authorized_keys`,
      "LEASE_HOURS=24",
      "",
    ].join("\n");

    const remoteEnvPath = path.join(projectRoot, "tmp", "relay.generated.env");
    fs.mkdirSync(path.dirname(remoteEnvPath), { recursive: true });
    fs.writeFileSync(remoteEnvPath, relayEnv, "utf8");

    const sftp2 = await openSftp(conn);
    await uploadFile(sftp2, remoteEnvPath, "/root/remote-ssh-relay-deploy/relay.env");
    sftp2.end();
    console.log("Uploaded relay.env");

    const installCmd = [
      "set -euo pipefail",
      "cd /root/remote-ssh-relay-deploy",
      "chmod +x ./install-server.sh",
      "./install-server.sh",
      "install -m 600 ./relay.env /opt/remote-ssh-relay/relay.env",
      "if ! grep -q 'Match User tunnel' /etc/ssh/sshd_config; then cat ./sshd_config.sample >> /etc/ssh/sshd_config; fi",
      "systemctl daemon-reload",
      "systemctl enable --now remote-ssh-relay",
      "systemctl restart ssh || systemctl restart sshd",
      "systemctl restart remote-ssh-relay",
      "systemctl --no-pager --full status remote-ssh-relay | head -n 20",
      `curl -fsSL http://127.0.0.1:${apiPort}/health`,
    ].join(" && ");

    const { stdout } = await execCommand(conn, `bash -lc '${installCmd.replace(/'/g, `'\\''`)}'`);
    console.log(stdout);
  } finally {
    conn.end();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
