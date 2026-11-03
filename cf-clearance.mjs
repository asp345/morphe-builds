import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const [chrome, url, userAgent] = process.argv.slice(2);
const port = await new Promise((resolve) => {
  const srv = createServer().listen(0, "127.0.0.1", () => {
    const { port } = srv.address();
    srv.close(() => resolve(port));
  });
});
const profile = mkdtempSync(join(tmpdir(), "cf-"));
const proc = spawn(chrome, [
  "--headless=new", "--disable-gpu", `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`, `--user-agent=${userAgent}`, "about:blank",
], { stdio: "ignore" });

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

  await send("Page.navigate", { url });
  let title = "";
  for (let i = 0; i < 60 && (!title || /just a moment/i.test(title)); i++) {
    await sleep(1000);
    title = (await send("Runtime.evaluate", { expression: "document.title", returnByValue: true })).result.value;
  }
  const clearance = (await send("Network.getAllCookies")).cookies.find((c) => c.name === "cf_clearance");
  if (!clearance) throw new Error(`no cf_clearance cookie (page title: ${title})`);
  console.log(clearance.value);
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  ws?.close();
  proc.kill("SIGKILL");
  await new Promise((resolve) => (proc.exitCode !== null || proc.signalCode !== null ? resolve() : proc.once("exit", resolve)));
  rmSync(profile, { recursive: true, force: true });
}
