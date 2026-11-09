// Lab supervision-branch stand-in for the documented Pi branch dispatch handshake
// (.pi/extensions/lib/fm-branch-dispatch.ts). It accepts each eligible offer the
// way a live branch does and keeps its settlement pending until the lab releases
// that wake, so the watcher's delivery to the branch can be held on demand.
import { appendFileSync, existsSync } from "node:fs";

const log = process.env.FM_LAB_HOLD_LOG as string;
const ctl = process.env.FM_LAB_CTL as string;

function record(entry: Record<string, unknown>): void {
  appendFileSync(log, `${JSON.stringify({ ts: Date.now(), ...entry })}\n`);
}

export default function (pi: any) {
  let offers = 0;
  pi.events.on("fm-branch-supervision:dispatch", (offer: any) => {
    offers += 1;
    const n = offers;
    record({ event: "offer", n, eligible: offer.eligible, message: offer.message });
    if (!offer.eligible) return;
    const release = `${ctl}/released-${n}`;
    const settlement = new Promise<void>((resolve) => {
      const timer = setInterval(() => {
        if (!existsSync(release)) return;
        clearInterval(timer);
        record({ event: "settled", n });
        resolve();
      }, 20);
    });
    offer.accept(settlement);
    record({ event: "accepted", n, message: offer.message });
  });
}
