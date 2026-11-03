import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const [chrome, url, userAgent] = process.argv.slice(2);

const WINDOW = { width: 1280, height: 900 };
const CHECKBOX = { x: 214, y: 339 };
const CLICK_INTERVAL = 6000;

async function startXvfb() {
  for (let n = 99; n < 130; n++) {
    if (existsSync(`/tmp/.X11-unix/X${n}`)) continue;
    const proc = spawn("Xvfb", [`:${n}`, "-screen", "0", "1280x900x24", "-nolisten", "tcp"], {
      stdio: "ignore",
    });
    let exited = false;
    proc.once("exit", () => (exited = true));
    for (let i = 0; i < 100 && !exited; i++) {
      if (existsSync(`/tmp/.X11-unix/X${n}`)) return { proc, display: `:${n}` };
      await sleep(50);
    }
    proc.kill("SIGKILL");
  }
  throw new Error("could not start Xvfb");
}

const xdotool = (env, args) =>
  new Promise((resolve, reject) => {
    const proc = spawn("xdotool", args, { env, stdio: "ignore" });
    proc.once("error", () => reject(new Error("'xdotool' is not installed")));
    proc.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`xdotool ${args.join(" ")} failed`))));
  });

const port = await new Promise((resolve) => {
  const srv = createServer().listen(0, "127.0.0.1", () => {
    const { port } = srv.address();
    srv.close(() => resolve(port));
  });
});
const profile = mkdtempSync(join(tmpdir(), "cf-"));
const xvfb = await startXvfb();
const env = { ...process.env, DISPLAY: xvfb.display };
const proc = spawn(
  chrome,
  [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    `--user-agent=${userAgent}`,
    `--window-size=${WINDOW.width},${WINDOW.height}`,
    "--window-position=0,0",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-dev-shm-usage",
    "about:blank",
  ],
  { stdio: "ignore", env }
);

let ws;
try {
  let page;
  for (let i = 0; i < 100 && !page; i++) {
    try {
      page = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page");
    } catch {
      await sleep(200);
    }
  }
  if (!page) throw new Error("chrome did not start");
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    pending.get(msg.id)?.(msg);
    pending.delete(msg.id);
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    pending.set(++id, (msg) => (msg.error ? reject(new Error(`${method}: ${msg.error.message}`)) : resolve(msg.result)));
    ws.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression) =>
    (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result.value;

  await send("Network.enable");
  await send("Page.navigate", { url });
  const origin = await evaluate("({x: screenX, y: screenY + outerHeight - innerHeight})");

  let clearance;
  let title = "";
  let lastClick = 0;
  for (let i = 0; i < 90; i++) {
    await sleep(1000);
    clearance = (await send("Network.getAllCookies")).cookies.find((c) => c.name === "cf_clearance");
    title = await evaluate("document.title");
    if (clearance && title && !/just a moment/i.test(title)) break;
    if (!/just a moment/i.test(title)) continue;
    if (Date.now() - lastClick < CLICK_INTERVAL) continue;
    lastClick = Date.now();
    const x = origin.x + CHECKBOX.x;
    const y = origin.y + CHECKBOX.y;
    await xdotool(env, ["mousemove", "--sync", String(x - 37), String(y - 22)]);
    await sleep(400);
    await xdotool(env, ["mousemove", "--sync", String(x - 2), String(y + 3)]);
    await sleep(300);
    await xdotool(env, ["mousemove", "--sync", String(x), String(y)]);
    await sleep(400);
    await xdotool(env, ["click", "1"]);
  }
  if (!title || /just a moment/i.test(title)) throw new Error(`page title is still '${title}'`);
  if (!clearance) throw new Error("no cf_clearance cookie");
  console.log(clearance.value);
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  ws?.close();
  proc.kill("SIGKILL");
  xvfb.proc.kill("SIGKILL");
  await new Promise((resolve) => (proc.exitCode !== null || proc.signalCode !== null ? resolve() : proc.once("exit", resolve)));
  await new Promise((resolve) => (xvfb.proc.exitCode !== null || xvfb.proc.signalCode !== null ? resolve() : xvfb.proc.once("exit", resolve)));
  rmSync(profile, { recursive: true, force: true });
}
