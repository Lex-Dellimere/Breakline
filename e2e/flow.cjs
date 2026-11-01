// full-stack check, driven from one headless chromium with a cdp virtual passkey: sign in,
// register a passkey, enrol the box (step-up), then open and lock the site while gw.sh
// probes real traffic from the clinic pc. with VIDEO=1 it records the browser and overlays
// a caption bar and a "clinic pc" panel. the panel only ever shows the probes' real output.
//
// env: PLAYWRIGHT_CORE (path to playwright-core), CHROME_BIN, VIDEO (optional)
const { chromium } = require(process.env.PLAYWRIGHT_CORE);
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const E = __dirname;
const RUN = path.join(E, ".run");
const SITE = fs.readFileSync(path.join(RUN, "seed.out"), "utf8").trim().replace(/^SITE=/, "");
const PASSWORD = fs.readFileSync(path.join(RUN, "secrets/demo_password"), "utf8").trim();
const VIDEO = process.env.VIDEO === "1";
const BASE = "http://localhost:4050";
const SHOTS = path.join(RUN, "shots");
fs.mkdirSync(SHOTS, { recursive: true });

const t0 = Date.now();
const step = (m) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s] ${m}`);
const gw = (...args) => {
  const out = execFileSync(path.join(E, "box/gw.sh"), args, { encoding: "utf8", timeout: 240000 });
  out.trim().split("\n").filter(Boolean).forEach((l) => console.log(`         gw ${args[0]}: ${l}`));
  return out;
};

// turns a probe line ("boot.net.anydesk.com=NXDOMAIN ... anydesk:6568=drop") into panel rows
function probeRows(line) {
  const v = Object.fromEntries(line.trim().split(/\s+/).map((kv) => kv.split("=")));
  const row = (label, ok, okText, badText) => ({ label, ok, text: ok ? okText : badText });
  return [
    row("AnyDesk name lookup", v["boot.net.anydesk.com"] === "NOERROR", "answered", "blocked"),
    row("AnyDesk relay server", v["rmm-ip:443"] === "pass", "connected", "blocked"),
    row("AnyDesk direct port 6568", v["anydesk:6568"] === "pass", "connected", "blocked"),
    row("An ordinary website", v["web:443"] === "pass", "works", "blocked"),
  ];
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME_BIN });
  global.__browser = browser;
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 }, colorScheme: "light" });
  const page = await ctx.newPage();
  // chromium restores the scroll position after a reload, after anything we do on load
  await page.addInitScript(() => {
    try { history.scrollRestoration = "manual"; } catch (_) {}
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  const cdp = await ctx.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: { protocol: "ctap2", transport: "internal", hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
  });

  // the recording: chromium's own screencast, one jpeg per changed frame with its time.
  // run.sh turns them into an mp4 with the system ffmpeg, holding each frame until the next
  const frames = [];
  const framesDir = path.join(RUN, "frames");
  if (VIDEO) {
    fs.rmSync(framesDir, { recursive: true, force: true });
    fs.mkdirSync(framesDir, { recursive: true });
    cdp.on("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
      const file = path.join(framesDir, `${String(frames.length).padStart(6, "0")}.jpg`);
      fs.writeFileSync(file, Buffer.from(data, "base64"));
      frames.push({ file, t: metadata.timestamp });
      try { await cdp.send("Page.screencastFrameAck", { sessionId }); } catch (_) {}
    });
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 85, maxWidth: 1280, maxHeight: 720 });
  }

  // the overlay: a caption bar and the clinic pc panel, re-drawn after every navigation
  const overlay = { caption: "", sub: "", rows: null, card: null };
  const draw = async () => {
    if (!VIDEO) return;
    await page.evaluate((o) => {
      document.getElementById("bl-overlay")?.remove();
      const root = document.createElement("div");
      root.id = "bl-overlay";
      root.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:99999;font-family:system-ui,sans-serif";
      if (o.card) {
        root.innerHTML = `<div style="position:absolute;inset:0;background:#0b1317;color:#e4eef1;display:flex;flex-direction:column;justify-content:center;padding:0 96px;gap:18px">
          <div style="font-size:15px;letter-spacing:.12em;text-transform:uppercase;color:#4cc3d2">${o.card.eyebrow}</div>
          <div style="font-size:52px;font-weight:700;line-height:1.1;max-width:900px">${o.card.title}</div>
          <div style="font-size:22px;color:#9bb0b7;max-width:900px;line-height:1.4">${o.card.body}</div></div>`;
      } else {
        const rows = (o.rows || []).map((r) => `<div style="display:flex;justify-content:space-between;gap:18px;padding:6px 0;border-top:1px solid #22343b">
          <span>${r.label}</span><b style="color:${r.ok ? "#5fd4ae" : "#ff8a7a"}">${r.text}</b></div>`).join("");
        root.innerHTML = (o.rows ? `<div style="position:absolute;right:20px;bottom:104px;width:330px;background:rgba(11,19,23,.94);color:#e4eef1;border-radius:12px;padding:14px 16px;font-size:14px;box-shadow:0 8px 30px rgba(0,0,0,.3)">
            <div style="font-size:12px;letter-spacing:.1em;text-transform:uppercase;color:#4cc3d2;margin-bottom:6px">Clinic PC, tested just now</div>${rows}</div>` : "") +
          (o.caption ? `<div style="position:absolute;left:0;right:0;bottom:0;background:rgba(11,19,23,.94);color:#fff;padding:16px 28px">
            <div style="font-size:22px;font-weight:650">${o.caption}</div>
            <div style="font-size:16px;color:#9bb0b7;margin-top:4px">${o.sub}</div></div>` : "");
      }
      document.body.appendChild(root);
    }, overlay);
  };
  const say = async (caption, sub = "", rows = overlay.rows) => {
    Object.assign(overlay, { caption, sub, rows, card: null });
    await draw();
  };
  const card = async (c, ms) => {
    overlay.card = c;
    await draw();
    if (VIDEO) await page.waitForTimeout(ms);
    overlay.card = null;
    await draw();
  };
  const pause = (ms) => (VIDEO ? page.waitForTimeout(ms) : Promise.resolve());
  // goto on the same url reloads, and chromium restores the scroll; start at the top so
  // the site's state badge and status card are in the shot
  const go = async (url) => {
    await page.goto(url);
    await page.evaluate(() => window.scrollTo(0, 0));
    await draw();
  };

  step("sign in as the seeded admin");
  await go(`${BASE}/sign-in`);
  await card({ eyebrow: "Breakline · real demo, not a mock-up",
    title: "A lock outside your RMM.",
    body: "This is the real cloud and a real gateway box, with a clinic PC behind it. Every result on screen comes from traffic the PC actually sent." }, 5000);
  await say("Sign in to the Breakline cloud", "An MSP's senior tech, or the client's practice manager");
  await page.fill('input[type="email"]', "e2e@breakline.test");
  await page.fill('input[type="password"]', PASSWORD);
  await Promise.all([page.waitForURL((u) => !u.pathname.startsWith("/sign-in"), { timeout: 15000 }),
    page.click('form button[type="submit"]')]);

  step("register a passkey");
  await go(`${BASE}/account/security`);
  await say("Add a passkey", "Opening access, approving and lifting a lock all need one");
  await page.waitForSelector("#add-passkey-form");
  // a fresh name per run: an earlier run's passkey (whose private key died with that
  // browser) would otherwise satisfy the wait before this one is registered
  const keyName = `Laptop ${Date.now().toString(36)}`;
  await page.fill('#add-passkey-form input[type="text"]', keyName);
  await page.click('#add-passkey-form button[type="submit"]');
  await page.waitForFunction((n) => (document.querySelector("#passkeys")?.textContent || "").includes(n),
    keyName, { timeout: 15000 });
  await pause(1500);

  step("enrol the box from the site page (passkey step-up)");
  await go(`${BASE}/sites/${SITE}`);
  await say("Enrol the gateway box", "A one-time code, confirmed with a passkey");
  await page.click("#enroll-gateway");
  await page.waitForSelector("#enroll-command", { timeout: 20000 });
  await page.locator("#enroll-command").scrollIntoViewIfNeeded();
  const command = (await page.textContent("#enroll-command")).trim();
  await page.screenshot({ path: `${SHOTS}/1-enrol.png` });
  step(`command: ${command.replace(/ [A-Z2-7]{4}(-[A-Z2-7]{4}){7} /, " <code> ").slice(0, 90)}…`);
  await say("Run this one command on the box", "It makes its own key; the cloud pins it. No certificates to manage.");
  await pause(3000);
  gw("enroll", ...command.replace(/^sudo /, "").split(/\s+/).slice(2));
  gw("start");

  step("wait for the box to connect and lock");
  await go(`${BASE}/sites/${SITE}`);
  await page.waitForFunction(() => /Connected/.test(document.querySelector("#site-connected")?.textContent || ""),
    null, { timeout: 60000 });
  await page.waitForFunction(() => /v\d+\s*applied/.test(document.body.textContent) &&
    /locked/i.test(document.querySelector("#site-state")?.textContent || ""), null, { timeout: 60000 });
  gw("wait-state", "locked");
  let probe = gw("probe", "locked");
  await go(`${BASE}/sites/${SITE}`);
  await say("Locked by default", "The remote-access tool can't reach the clinic. Ordinary internet still works.", probeRows(probe));
  await page.screenshot({ path: `${SHOTS}/2-locked.png` });
  step(`site: ${(await page.textContent("#site-state")).trim()}`);
  await pause(5000);

  step("open for 15 minutes (passkey step-up)");
  await say("Open a 15 minute window", "Approved with a passkey. The box applies the signed policy in seconds.");
  await page.click("#open-15");
  await page.waitForFunction(() => /open/i.test(document.querySelector("#site-state")?.textContent || ""),
    null, { timeout: 30000 });
  // the panel never shows results older than the state on the page
  await say("Opened: testing from the clinic PC", "Sending real traffic through the box now", null);
  gw("wait-state", "open");
  probe = gw("probe", "open");
  gw("guard");
  await go(`${BASE}/sites/${SITE}`);
  await say("Open, for 15 minutes only", "The box already knows when the window ends, and closes it then even if it crashes.", probeRows(probe));
  await page.screenshot({ path: `${SHOTS}/3-open.png` });
  await pause(5000);

  step("hold a live rmm session, then lock now");
  gw("session-start");
  await say("A technician is connected right now", "Watch what happens to that live session when the lock lands.");
  await pause(2500);
  await page.click("#lock-now");
  await page.waitForFunction(() => /locked/i.test(document.querySelector("#site-state")?.textContent || ""),
    null, { timeout: 30000 });
  await say("Locked: checking the live session and the clinic PC", "Sending real traffic through the box now", null);
  gw("wait-state", "locked");
  gw("session-cut");
  probe = gw("probe", "locked");
  await go(`${BASE}/sites/${SITE}`);
  await say("Locked again: the live session was cut", "The same happens automatically when your RMM shows up on CISA's exploited list.", probeRows(probe));
  await page.screenshot({ path: `${SHOTS}/4-locked-again.png` });
  await pause(5000);

  step("the record");
  await go(`${BASE}/sites/${SITE}/timeline`);
  await say("Every step is on the record", "A tamper-evident log, exportable as a PDF for clients and insurers.", null);
  await page.screenshot({ path: `${SHOTS}/5-timeline.png` });
  await pause(5000);
  await go(`${BASE}/audit`);
  step(`audit: ${(await page.textContent("main")).replace(/\s+/g, " ").match(/(intact|verified|broken)[^.]{0,80}/i)?.[0] || "?"}`);
  await card({ eyebrow: "Breakline · for Australian MSPs",
    title: "Free monitor-only pilot.",
    body: "Install on a small box or VM at one client site. It blocks nothing for the first weeks and shows you when your remote tools reach the site." }, 5000);

  console.log("page errors:", errors.length ? errors : "none");
  if (VIDEO) {
    await cdp.send("Page.stopScreencast");
    // ffmpeg's concat list: each frame shown until the next one arrived, the last for 2 s
    const list = frames.map((f, i) => {
      const next = frames[i + 1];
      const d = next ? Math.max(next.t - f.t, 0.001) : 2;
      return `file '${f.file}'\nduration ${d.toFixed(3)}`;
    });
    list.push(`file '${frames[frames.length - 1].file}'`);
    fs.writeFileSync(path.join(framesDir, "list.txt"), list.join("\n") + "\n");
    console.log(`frames: ${frames.length}`);
  }
  await ctx.close();
  await browser.close();
})().catch(async (e) => {
  console.error("FAILED:", e.message.split("\n").slice(0, 3).join(" | "));
  for (const c of (global.__browser?.contexts() || [])) {
    for (const [i, p] of c.pages().entries()) {
      try { await p.screenshot({ path: `${SHOTS}/fail-${i}.png`, fullPage: true }); } catch (_) {}
    }
  }
  process.exit(1);
});
