import { defineCorePlugin } from "..";
import { AR_WORDS_BLOB } from "./ar-words";
import { useProxy } from "@core/vendetta/storage";
import { awaitStorage, createStorage } from "@lib/api/storage";
import { intercept } from "@lib/api/flux";
import { readFile as nativeReadFile, writeFile as nativeWriteFile } from "@lib/api/native/fs";
import { findByStoreName } from "@metro";
import { messageUtil } from "@metro/common";
import { Card, Text } from "@metro/common/components";
import { ScrollView, TextInput as RNTextInput } from "react-native";
import React from "react";

// Chat Auto — watches a configured channel for the games bot's word-game
// images, reads them through OCR.space and answers as the user.
// Everything is controlled from the native floating button: tap toggles,
// long-press opens a native menu (server / channel / bot / speed / enabled).
// JS <-> native talk through JSON files in Documents/rain:
//   chatauto-options.json  JS -> native : guilds/channels/bots + current pick
//   chatauto-choice.json   native -> JS : user selections from the menu
//   chatauto-state.json    native -> JS : master on/off flag
//   chatauto-req/res.json  JS -> native : type/clear/setEnabled/hello

interface ServerCfg { channelId?: string; botId?: string; enabled?: boolean; speed?: "normal" | "insane"; }
interface PluginCfg { servers: Record<string, ServerCfg>; channelModes: Record<string, string>; }
interface SettingsShape { cfg: PluginCfg; ocrKeys: string; activeGuildId?: string; }

const storage = createStorage<SettingsShape>("plugins/storage/kettu.chatauto.json");

const DEFAULT_OCR_KEYS = [
    "K8508311493100988957", "K8303912305601488957", "K8186259044999588957",
    "K8577479258120688957", "K8910301043576188957", "K8482272248515588957",
].join(",");

// ---------- Arabic helpers (same semantics as the PC pipeline) ----------

const AR_DIACRITICS = /[ً-ْٰـ]/g;
const AR_LETTER = /[ء-ي]/;

function arNorm(s: string): string {
    return String(s || "")
        .replace(AR_DIACRITICS, "")
        .replace(/[أإآٱ]/g, "ا")
        .replace(/ى/g, "ي")
        .replace(/ة/g, "ه")
        .replace(/ؤ/g, "و")
        .replace(/ئ/g, "ي")
        .replace(/ء/g, "")
        .replace(/ا+$/, "ه") // fold trailing alef so ة/ه/ا endings vote together
        .replace(/\s+/g, "")
        .trim();
}

function hasArabic(s: string): boolean { return /[؀-ۿ]/.test(s || ""); }

// Game-UI words only — never valid answers. A line made of nothing else is dropped.
const CHAT_STOP = new Set([
    "اسرع", "يكتب", "كتابه", "كتابة", "تفكيك", "فكك", "لديك", "ثانيه", "ثواني",
    "متبقي", "الوقت", "يلا", "جاوب", "اكتب", "الكلمه", "كلمه", "سريعه", "بسرعه",
    "الان", "فورا", "لعبة", "الالعاب", "اضغط", "ابدأ", "بدأ", "الجواب", "صح",
    "غلط", "نقاط", "جولة", "الجولة", "انت", "اللاعب", "مستني", "انتظر",
].map(arNorm));

// Words that veto a whole candidate line — mode/instruction text is never an answer.
const CHAT_ANSWER_BAD = new Set([
    "اسرع", "يكتب", "كتابه", "تفكيك", "فكك", "لديك", "ثانيه", "ثواني", "متبقي",
    "جاوب", "الكلمه", "كلمه", "سريعه", "بسرعه", "الجواب", "نقاط", "جولة",
    "العاب", "اللاعاب", "اللاعبه", "مرحبا", "هلا", "اهلا", "كلمه السر",
].map(arNorm));

const COUNTDOWN_RE = /لديك|ثانيه|ثواني|متبقي|الوقت/;

// ---------- Arabic dictionary: validate + repair OCR answers ----------
// norm -> raw display form (first = most frequent). Built once at startup.
const DICT = new Map<string, string>();
try {
    for (const w of AR_WORDS_BLOB.split(" ")) {
        if (!w) continue;
        const n = arNorm(w);
        if (n.length >= 2 && !DICT.has(n)) DICT.set(n, w);
    }
} catch { /* dictionary optional */ }

// OCR-confusable letter groups in normalized space. A swap is only accepted
// when the result is a real dictionary word, so wrong guesses can't slip in.
const CONFUSE: Record<string, string> = {};
for (const g of [["ق", "ف"], ["ت", "ث"], ["س", "ش"], ["ض", "ص"], ["ط", "ظ"],
                 ["ج", "ح"], ["د", "ذ"], ["ز", "ر"], ["ب", "ن"]]) {
    for (const c of g) CONFUSE[c] = (CONFUSE[c] || "") + g.filter(x => x !== c).join("");
}

// Returns the dictionary display form for a normalized word, or null.
// Tries exact match, then 1/2/3 letter confusable swaps (short words only
// beyond the first pass) — every candidate must exist in DICT.
function dictFix(n: string): string | null {
    const exact = DICT.get(n);
    if (exact) return exact;
    const L = n.length;
    if (L < 2 || L > 16) return null;
    const altsAt = (i: number) => CONFUSE[n[i]] || "";
    // single swap
    for (let i = 0; i < L; i++) {
        for (const a of altsAt(i)) {
            const v = n.slice(0, i) + a + n.slice(i + 1);
            const hit = DICT.get(v);
            if (hit) return hit;
        }
    }
    // two swaps — only for short words to bound the search
    if (L <= 7) {
        for (let i = 0; i < L; i++) for (let j = i + 1; j < L; j++) {
            for (const a of altsAt(i)) for (const b of altsAt(j)) {
                const v = n.slice(0, i) + a + n.slice(i + 1, j) + b + n.slice(j + 1);
                const hit = DICT.get(v);
                if (hit) return hit;
            }
        }
    }
    // three swaps — very short words only
    if (L <= 4) {
        for (let i = 0; i < L; i++) for (let j = i + 1; j < L; j++) for (let k = j + 1; k < L; k++) {
            for (const a of altsAt(i)) for (const b of altsAt(j)) for (const c of altsAt(k)) {
                const v = n.slice(0, i) + a + n.slice(i + 1, j) + b + n.slice(j + 1, k) + c + n.slice(k + 1);
                const hit = DICT.get(v);
                if (hit) return hit;
            }
        }
    }
    return null;
}

// Validate + repair a candidate's display text against the dictionary.
// ok=true means every word resolved (exact or repaired); send is what to type.
function dictValidate(disp: string, mode: "fast" | "tafkeek" | null): { ok: boolean; send: string } {
    if (mode === "tafkeek") {
        const joined = disp.replace(/\s+/g, "");
        if (joined.length < 2) return { ok: false, send: disp };
        const fixed = dictFix(arNorm(joined));
        return fixed ? { ok: true, send: fixed } : { ok: false, send: disp };
    }
    const words = disp.split(/\s+/).filter(Boolean);
    if (!words.length) return { ok: false, send: disp };
    let allOk = true;
    const out = words.map(w => {
        const n = arNorm(w);
        const hit = DICT.get(n) || dictFix(n);
        if (hit) return hit;
        allOk = false;
        return w;
    });
    return { ok: allOk, send: out.join(" ") };
}

interface OcrWord { WordText?: string; Left?: number; Top?: number; Height?: number; Width?: number; }
interface OcrLine { Words?: OcrWord[]; MinTop?: number; }
interface OcrResultJson { ParsedResults?: { TextOverlay?: { Lines?: OcrLine[] }; Text?: string }[]; }
interface OcrResult { mode: "fast" | "tafkeek" | null; countdown: boolean; answer: { key: string; disp: string } | null; }

function detectMode(normText: string): "fast" | "tafkeek" | null {
    if (/تفكيك|فكك/.test(normText)) return "tafkeek";
    if (/اسرع/.test(normText) && /يكتب/.test(normText)) return "fast";
    return null;
}

function isStopWord(w: string) { return CHAT_STOP.has(arNorm(w)); }
function isBadWord(w: string) { return CHAT_ANSWER_BAD.has(arNorm(w)); }

// ---------- OCR ----------

let ocrKeyIdx = 0;
function nextOcrKey(): string {
    const keys = String(storage.ocrKeys || "").split(/[,;\s]+/).filter(Boolean);
    if (!keys.length) return "";
    const k = keys[ocrKeyIdx % keys.length];
    ocrKeyIdx = (ocrKeyIdx + 1) % keys.length;
    return k;
}

async function ocrSpace(imageUrl: string, engine: string, key: string): Promise<OcrResultJson | null> {
    const fd = new FormData();
    fd.append("apikey", key);
    fd.append("url", imageUrl);
    fd.append("language", "auto");
    fd.append("isOverlayRequired", "true");
    fd.append("scale", "true");
    fd.append("OCREngine", engine);
    let ctrl: AbortController | null = null, timer: any = null;
    try { ctrl = new AbortController(); timer = setTimeout(() => ctrl!.abort(), 15000); } catch { /* no abort */ }
    try {
        const opts: RequestInit = { method: "POST", body: fd };
        if (ctrl) opts.signal = ctrl.signal;
        const res = await fetch("https://api.ocr.space/parse/image", opts);
        return await res.json();
    } catch { return null; }
    finally { if (timer) clearTimeout(timer); }
}

interface OcrWordGeo { t: string; n: string; l: number; tp: number; h: number; w: number; }

// Row-level UI detection: a visual row that carries game chrome (mode label,
// countdown, instruction text) is dropped as a whole — its leftover words can
// never become the answer. Answer rows keep only real content words.
function isUiRow(jn: string, js: string): boolean {
    if (/تفكيك|فكك/.test(jn)) return true;
    if (/اسرع/.test(jn) && /يكتب/.test(jn)) return true;
    if (COUNTDOWN_RE.test(js) || /\d+\s*(ثانيه|ثواني)/.test(js)) return true;
    // Branding/games-label rows — "ألعاب", "ألعاب فريدة", greetings etc.
    if (/^العاب|اللاعاب|اللاعبه|^مرحبا|^هلا|^اهلا/.test(jn)) return true;
    return false;
}

function parseOcrResult(json: OcrResultJson | null): OcrResult {
    const res: OcrResult = { mode: null, countdown: false, answer: null };
    const parsed = json && json.ParsedResults && json.ParsedResults[0];
    if (!parsed) return res;
    const lines = (parsed.TextOverlay && parsed.TextOverlay.Lines) || [];

    // Collect every Arabic word with its on-image geometry.
    const allW: OcrWordGeo[] = [];
    for (const line of lines) {
        for (const wd of (line.Words || [])) {
            const t = (wd.WordText || "").replace(/[‎‏‪-‮]/g, "").trim();
            if (!t || !hasArabic(t)) continue;
            allW.push({
                t,
                n: arNorm(t),
                l: wd.Left || 0,
                tp: wd.Top || 0,
                h: wd.Height || 0,
                w: wd.Width || 0,
            });
        }
    }
    if (!allW.length) return res;

    // Arabic reading order: top-to-bottom rows, right-to-left inside a row.
    const reading = allW.slice().sort((a, b) => a.tp - b.tp || b.l - a.l);
    const joinedN = reading.map(w => w.n).join("");
    const joinedSp = reading.map(w => w.n).join(" ");
    res.mode = detectMode(joinedN);
    res.countdown = COUNTDOWN_RE.test(joinedSp) || /\d+\s*(ثانيه|ثواني)/.test(joinedSp);

    // Cluster words into visual rows by vertical position.
    const hs = allW.map(w => w.h).filter(h => h > 0).sort((a, b) => a - b);
    const medH = hs.length ? hs[Math.floor(hs.length / 2)] : 20;
    const tol = Math.max(6, medH * 0.55);
    const rows: { top: number; words: OcrWordGeo[] }[] = [];
    for (const w of reading) {
        const last = rows[rows.length - 1];
        if (last && Math.abs(w.tp - last.top) <= tol) last.words.push(w);
        else rows.push({ top: w.tp, words: [w] });
    }

    // Positional anchor: the game-type label (تفكيك / اسرع يكتب) sits above the
    // answer in every layout of these games — anything ABOVE it is title,
    // branding or decoration and can never be the answer.
    let modeTop = Infinity;
    for (const row of rows) {
        const jn = row.words.map(w => w.n).join("");
        if (/تفكيك|فكك/.test(jn) || (/اسرع/.test(jn) && /يكتب/.test(jn))) {
            modeTop = Math.min(modeTop, row.top);
        }
    }

    interface Cand { key: string; disp: string; score: number; dictOk: boolean; }
    const cands: Cand[] = [];
    const letterRows: OcrWordGeo[][] = [];

    for (const row of rows) {
        const jn = row.words.map(w => w.n).join("");
        const js = row.words.map(w => w.n).join(" ");
        if (isUiRow(jn, js)) continue;
        // Row must contain at least one plausible answer word to survive.
        const hasContent = row.words.some(w =>
            w.n.length > 0 && AR_LETTER.test(w.t) && !isStopWord(w.t) && !isBadWord(w.t));
        if (!hasContent) continue;

        const kept = row.words.filter(w => {
            if (!w.n.length || !AR_LETTER.test(w.t)) return false;
            if (res.mode !== "tafkeek" && w.n.length < 2) return false;
            if (isStopWord(w.t) || isBadWord(w.t)) return false;
            return true;
        });
        if (!kept.length) continue;
        // Letter-heavy rows feed the tafkeek grid merge from ANY position —
        // the letters are the answer wherever they sit on the image.
        const singles = kept.filter(w => w.n.length <= 1).length;
        if (kept.length >= 2 && singles / kept.length >= 0.6) letterRows.push(kept);
        // Word candidates only at/below the mode label — above it is chrome.
        if (row.top < modeTop - tol) continue;
        const ordered = kept.slice().sort((a, b) => b.l - a.l);
        const rawDisp = ordered.map(w => w.t).join(" ");
        const dv = dictValidate(rawDisp, res.mode);
        const key = arNorm(dv.send);
        if (key.length < 2) continue;
        const avgH = kept.reduce((s, w) => s + w.h, 0) / kept.length;
        const chars = dv.send.replace(/\s/g, "").length;
        cands.push({ key, disp: dv.send, dictOk: dv.ok,
                     score: kept.length * 15 + avgH * 2 + chars * 2 + (dv.ok ? 1000 : 0) });
    }

    // tafkeek: letters may be laid out in a grid across several rows —
    // merge every letter-heavy row into one candidate in reading order.
    if (res.mode === "tafkeek" && letterRows.length) {
        const all = letterRows.flat().sort((a, b) => a.tp - b.tp || b.l - a.l);
        const rawDisp = all.map(w => w.t).join(" ");
        const dv = dictValidate(rawDisp, "tafkeek");
        const key = arNorm(dv.send);
        if (key.length >= 2) {
            // tafkeek answers ARE letters — a letter-grid candidate outranks
            // every word-row candidate (titles/branding can't compete).
            cands.push({ key, disp: dv.send, dictOk: dv.ok,
                         score: all.length * 30 + 60 + (dv.ok ? 1000 : 0) + 5000 });
        }
    }

    if (cands.length) {
        cands.sort((a, b) => b.score - a.score);
        res.answer = { key: cands[0].key, disp: cands[0].disp };
    }
    return res;
}

// ---------- Pipeline ----------

const seenMessages = new Set<string>();
const seenQueue: string[] = [];
function markSeen(id: string): boolean {
    if (seenMessages.has(id)) return false;
    seenMessages.add(id); seenQueue.push(id);
    if (seenQueue.length > 500) { const old = seenQueue.shift(); if (old) seenMessages.delete(old); }
    return true;
}

function channelCfg(channelId: string): { guildId: string; cfg: ServerCfg } | null {
    const servers = (storage.cfg && storage.cfg.servers) || {};
    for (const gid in servers) {
        const cfg = servers[gid];
        if (cfg && cfg.channelId === channelId) return { guildId: gid, cfg };
    }
    return null;
}

function buildAnswer(r: OcrResult): { content: string; mode: "fast" | "tafkeek" } | null {
    if (!r.answer || !r.mode) return null;
    if (r.mode === "tafkeek") {
        const letters = r.answer.disp.replace(/\s+/g, "").split("").filter(ch => AR_LETTER.test(ch));
        if (letters.length < 2) return null;
        return { content: letters.join(" "), mode: r.mode };
    }
    return { content: r.answer.disp, mode: r.mode };
}

function saveCfg() { storage.cfg = JSON.parse(JSON.stringify(storage.cfg || {})); }

function selectedChannelId(): string | null {
    try {
        stores();
        return call0(_scs, "getChannelId") || null;
    } catch { return null; }
}

// ---------- Native overlay + composer typing (file IPC) ----------
// The injected bootstrap polls Documents/rain/chatauto-req.json and replies
// in chatauto-res.json, publishes button state in chatauto-state.json,
// reads guild/channel/bot lists from chatauto-options.json and watches
// chatauto-choice.json for menu selections made on the floating button.

const IPC_PREFIX = "rain/";
let ipcSeq = 0;

async function ipcWrite(name: string, obj: any): Promise<boolean> {
    try { await nativeWriteFile(name, JSON.stringify(obj), { prefix: IPC_PREFIX }); return true; }
    catch { return false; }
}

async function ipcWriteRaw(name: string, text: string): Promise<boolean> {
    try { await nativeWriteFile(name, text, { prefix: IPC_PREFIX }); return true; }
    catch { return false; }
}

async function ipcRead(name: string): Promise<string | null> {
    try { return await nativeReadFile(name, { prefix: IPC_PREFIX }); }
    catch { return null; }
}

async function ipcRequest(op: string, fields: any = {}, timeoutMs = 8000): Promise<any> {
    const id = (++ipcSeq) + "-" + Date.now();
    if (!await ipcWrite("chatauto-req.json", { id, op, ...fields })) return null;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const txt = await ipcRead("chatauto-res.json");
        if (txt) {
            try {
                const r = JSON.parse(txt);
                if (r && r.id === id) return r;
            } catch { /* partial write */ }
        }
        await new Promise(res => setTimeout(res, 120));
    }
    return null;
}

function finishAnswer(r: OcrResult, channelId: string): void {
    if (r.mode) {
        if (!storage.cfg.channelModes) storage.cfg.channelModes = {};
        storage.cfg.channelModes[channelId] = r.mode;
        saveCfg();
    }
    let mode = r.mode;
    if (!mode && r.countdown) mode = (storage.cfg.channelModes || {})[channelId] as any;
    if (!mode || (mode !== "fast" && mode !== "tafkeek")) return;
    const answer = buildAnswer({ ...r, mode });
    if (!answer) return;

    const sendIt = () => {
        try { messageUtil.sendMessage(channelId, { content: answer.content }); }
        catch { /* ignore */ }
    };

    // Real-keyboard path: only when this channel is the one open on screen.
    // The native side types char-by-char into the composer through real
    // UITextInput events (keyboard stays up); we then send via the normal
    // message path and ask the native side to clear the draft.
    void (async () => {
        let typed = false;
        try {
            const hit = channelCfg(channelId);
            if (selectedChannelId() === channelId) {
                const res = await ipcRequest("type", {
                    text: answer.content,
                    speed: hit && hit.cfg.speed === "insane" ? "insane" : "normal",
                }, 12000);
                typed = !!(res && res.ok);
            }
        } catch { /* fall through to direct send */ }
        if (typed) {
            const ms = 220 + Math.min(500, answer.content.length * 35);
            setTimeout(() => {
                sendIt();
                void ipcRequest("clear", {}, 4000);
            }, ms);
        } else {
            // No usable composer — still show the on-screen keyboard typing
            // the answer letter by letter, then deliver the message.
            const spd = channelCfg(channelId)?.cfg.speed === "insane" ? "insane" : "normal";
            try { await ipcRequest("animate", { text: answer.content, speed: spd }, 15000); }
            catch { /* keyboard is cosmetic — send anyway */ }
            setTimeout(() => sendIt(), 20 + Math.floor(Math.random() * 60));
        }
    })();
}

async function processImage(channelId: string, imageUrl: string, insane: boolean): Promise<void> {
    const hit = channelCfg(channelId);
    if (!hit || !hit.cfg.botId) return;
    const jobs = [ocrSpace(imageUrl, "1", nextOcrKey()), ocrSpace(imageUrl, "2", nextOcrKey())];

    const finish = (r: OcrResult | null) => { if (r) finishAnswer(r, channelId); };

    if (insane) {
        let settled = false;
        for (const j of jobs) {
            j.then(json => {
                if (settled || !json) return;
                const r = parseOcrResult(json);
                const known = r.mode || (r.countdown && (storage.cfg.channelModes || {})[channelId]);
                if (r.answer && known) { settled = true; finish(r); }
            }).catch(() => null);
        }
        const all = await Promise.all(jobs.map(j => j.catch(() => null)));
        if (!settled) {
            for (const json of all) {
                if (!json) continue;
                const r = parseOcrResult(json);
                if (r.answer) { finish(r); break; }
            }
        }
        return;
    }

    const [a, b] = await Promise.all(jobs.map(j => j.catch(() => null)));
    const ra = a ? parseOcrResult(a) : null;
    const rb = b ? parseOcrResult(b) : null;
    if (ra && ra.answer && rb && rb.answer && ra.answer.key === rb.answer.key) {
        finish(ra);
        return;
    }
    const solo = [ra, rb].filter(r => r && r.answer && r.mode);
    if (solo.length === 1) finish(solo[0]);
}

// findByStoreName may return the store itself or nested module wrappers —
// unwrap named/default exports until we reach something callable.
function resolveStore(name: string): any {
    try {
        let s = findByStoreName(name);
        for (let i = 0; i < 4 && s; i++) {
            if (typeof s !== "object" && typeof s !== "function") break;
            const inner = (s as any)[name] || (s as any).default;
            if (!inner || inner === s) break;
            s = inner;
        }
        return s;
    } catch { return null; }
}

// ---------- Discord stores (resolved lazily, retried until Metro is ready) ----------

let _gs: any, _cs: any, _ms: any, _scs: any, _storesAt = 0;
function stores() {
    if (_gs && _cs && _ms) return;
    const now = Date.now();
    if (now - _storesAt < 2000) return;
    _storesAt = now;
    if (!_gs) _gs = resolveStore("GuildStore");
    if (!_cs) _cs = resolveStore("ChannelStore");
    if (!_ms) _ms = resolveStore("GuildMemberStore");
    if (!_scs) _scs = resolveStore("SelectedChannelStore");
}

function call0(obj: any, name: string, arg?: any): any {
    const f = obj && obj[name];
    if (typeof f !== "function") return null;
    try { return arg === undefined ? f.call(obj) : f.call(obj, arg); } catch { return null; }
}

function normList(v: any): any[] {
    if (!v) return [];
    let arr: any[];
    if (Array.isArray(v)) arr = v;
    else if (typeof v.toArray === "function") arr = v.toArray();
    else if (v._array) arr = v._array;
    else if (typeof v === "object") arr = Object.values(v);
    else return [];
    // Immutable Map#toArray yields [key, value] pairs — unwrap to values.
    if (arr.length && Array.isArray(arr[0]) && arr[0].length === 2 && arr[0][1] && typeof arr[0][1] === "object") {
        arr = arr.map(pair => pair[1]);
    }
    return arr;
}

function guilds(): any[] {
    try {
        stores();
        const raw = call0(_gs, "getGuilds");
        return normList(raw)
            .map((g: any) => g && g.toJS ? g.toJS() : g)
            .filter((g: any) => g && g.id && !g.unavailable)
            .sort((a: any, b: any) => (b.approximateMemberCount || b.memberCount || 0) - (a.approximateMemberCount || a.memberCount || 0));
    } catch { return []; }
}

function textChannels(guildId: string): any[] {
    try {
        stores();
        let raw = call0(_cs, "getChannels", guildId)
            || call0(_cs, "getMutableGuildChannelsForGuild", guildId);
        let all = false;
        if (!raw) { raw = call0(_cs, "getAllChannels"); all = true; }
        return normList(raw)
            .map((c: any) => c && c.toJS ? c.toJS() : c)
            .filter((c: any) => c && c.id && (c.type === 0 || c.type === 5)
                && (!all || String(c.guild_id || c.guildId || "") === String(guildId)))
            .sort((a: any, b: any) => (a.position || 0) - (b.position || 0));
    } catch { return []; }
}

function botMembers(guildId: string): any[] {
    try {
        stores();
        const raw = call0(_ms, "getMembers", guildId);
        const out: any[] = [];
        for (const m of normList(raw)) {
            const mm = m && m.toJS ? m.toJS() : m;
            if (mm && mm.user && mm.user.bot === true && mm.user.id) {
                out.push(mm.user);
                if (out.length >= 40) break;
            }
        }
        return out;
    } catch { return []; }
}

// ---------- Floating overlay state + menu choices (native file IPC) ----------

let overlayEnabled = true;
async function refreshOverlayState() {
    const txt = await ipcRead("chatauto-state.json");
    if (!txt) return;
    try {
        const s = JSON.parse(txt);
        if (s && typeof s.enabled === "boolean") overlayEnabled = s.enabled;
    } catch { /* partial write */ }
}

let lastChoiceRaw: string | null = null;
async function pollChoice() {
    const txt = await ipcRead("chatauto-choice.json");
    if (!txt || txt === lastChoiceRaw) return;
    lastChoiceRaw = txt;
    try {
        const c = JSON.parse(txt);
        const gid = String(c.guildId || "");
        if (!gid) return;
        const servers = { ...((storage.cfg && storage.cfg.servers) || {}) };
        const prev = servers[gid] || {};
        servers[gid] = {
            ...prev,
            channelId: c.channelId ? String(c.channelId) : prev.channelId,
            botId: c.botId ? String(c.botId) : prev.botId,
            speed: c.speed === "insane" ? "insane" : "normal",
            enabled: c.enabled !== false,
        };
        storage.cfg = { ...(storage.cfg || { servers: {}, channelModes: {} }), servers };
        storage.activeGuildId = gid;
        saveCfg();
    } catch { /* bad json */ }
}

// What the native menu needs: every guild with its text channels and known
// bots, plus the currently-selected ids (for display + per-guild restore).
async function writeOptions() {
    try {
        const gl = guilds();
        const guildsOut = gl.slice(0, 40).map(g => ({
            id: g.id,
            name: g.name || "Server",
            channels: textChannels(g.id).slice(0, 60)
                .map(c => ({ id: c.id, name: c.name || c.id })),
            bots: botMembers(g.id).slice(0, 40)
                .map(b => ({ id: b.id, name: b.username || b.globalName || b.id })),
        }));
        const servers = (storage.cfg && storage.cfg.servers) || {};
        const gids = Object.keys(servers);
        const activeGid = storage.activeGuildId || gids[0] || (gl[0] && gl[0].id) || "";
        const ac = activeGid ? (servers[activeGid] || {}) : {};
        const activeGuild = gl.find(g => g.id === activeGid);
        const chs = activeGid ? textChannels(activeGid) : [];
        const bts = activeGid ? botMembers(activeGid) : [];
        const ch = chs.find(c => c.id === ac.channelId);
        const bt = bts.find(b => b.id === ac.botId);
        const saved: Record<string, any> = {};
        for (const gid of gids) {
            const s = servers[gid] || {};
            saved[gid] = {
                channelId: s.channelId || "",
                botId: s.botId || "",
                speed: s.speed || "normal",
            };
        }
        const payload = {
            guilds: guildsOut,
            active: {
                guildId: activeGid,
                guildName: (activeGuild && activeGuild.name) || "",
                channelId: ac.channelId || "",
                channelName: (ch && ch.name) || "",
                botId: ac.botId || "",
                botName: (bt && (bt.username || bt.globalName)) || "",
                speed: ac.speed || "normal",
                enabled: !!ac.enabled,
            },
            saved,
        };
        await ipcWriteRaw("chatauto-options.json", JSON.stringify(payload));
    } catch { /* stores not ready yet */ }
}

// ---------- Plugin ----------

let stopIntercept: (() => void) | undefined;
let overlayTimer: any = null;
let optionsTimer: any = null;

export default defineCorePlugin({
    manifest: {
        id: "kettu.chatauto",
        version: "1.1.0",
        type: "plugin",
        spec: 3,
        main: "",
        display: {
            name: "Chat Auto",
            description: "Auto-answers the Arabic word games in a chosen channel",
            authors: [{ name: "owner" }],
        },
    },
    async start() {
        await awaitStorage(storage);
        if (!storage.cfg) storage.cfg = { servers: {}, channelModes: {} };
        if (!storage.cfg.servers) storage.cfg.servers = {};
        if (!storage.cfg.channelModes) storage.cfg.channelModes = {};
        if (!storage.ocrKeys) storage.ocrKeys = DEFAULT_OCR_KEYS;

        stopIntercept = intercept(payload => {
            try {
                if (payload.type !== "MESSAGE_CREATE") return undefined;
                const msg = payload.message || payload;
                const channelId = msg.channel_id || msg.channelId || payload.channelId;
                if (!channelId) return undefined;
                const hit = channelCfg(channelId);
                if (!hit || !hit.cfg.botId || !overlayEnabled) return undefined;
                const authorId = msg.author && msg.author.id;
                if (!authorId || authorId !== hit.cfg.botId) return undefined;
                if (!markSeen(String(msg.id))) return undefined;
                const attachments = msg.attachments || [];
                const img = attachments.find((a: any) =>
                    (a.content_type || "").indexOf("image/") === 0 ||
                    /\.(png|jpe?g|webp|gif)(\?|$)/i.test(a.filename || a.url || "") ||
                    (a.width && a.height));
                if (!img) return undefined;
                const url = img.proxy_url || img.url;
                if (!url) return undefined;
                const insane = hit.cfg.speed === "insane";
                void processImage(channelId, url, insane);
            } catch { /* never break dispatch */ }
            return undefined;
        });

        void refreshOverlayState();
        void pollChoice();
        void writeOptions();
        overlayTimer = setInterval(() => {
            void refreshOverlayState();
            void pollChoice();
        }, 1500);
        optionsTimer = setInterval(() => { void writeOptions(); }, 3000);
        // The native bootstrap shows the floating button by itself once the
        // window server is ready; "hello" just confirms the IPC is alive.
        void ipcRequest("hello", {}, 1500);
    },
    stop() {
        stopIntercept?.(); stopIntercept = undefined;
        if (overlayTimer) { clearInterval(overlayTimer); overlayTimer = null; }
        if (optionsTimer) { clearInterval(optionsTimer); optionsTimer = null; }
    },
    SettingsComponent() { return <ChatAutoSettings storage={storage} />; },
});

// ---------- Settings page (minimal — everything lives on the floating button) ----------

function ChatAutoSettings({ storage }: { storage: any }) {
    const state = useProxy(storage);
    const cfg: PluginCfg = state.cfg || { servers: {}, channelModes: {} };
    const servers = cfg.servers || {};
    const gid = state.activeGuildId || Object.keys(servers)[0] || "";
    const sc = gid ? (servers[gid] || {}) : {};

    let gname = "", cname = "", bname = "";
    try {
        const gl = guilds();
        const g = gl.find(x => x.id === gid);
        gname = g ? (g.name || gid) : (gid || "—");
        if (g) {
            const ch = textChannels(g.id).find(c => c.id === sc.channelId);
            cname = ch ? `#${ch.name}` : (sc.channelId || "Not set");
            const bt = botMembers(g.id).find(b => b.id === sc.botId);
            bname = bt ? `@${bt.username || bt.globalName || bt.id}` : (sc.botId || "Not set");
        }
    } catch { /* stores unavailable */ }

    return (
        <ScrollView style={{ flex: 1 }} contentContainerStyle={{ padding: 16, gap: 12 }}>
            <Text variant="text-md/semibold">Chat Auto</Text>
            <Card style={{ padding: 12 }}>
                <Text variant="text-sm/medium" color="text-muted">
                    Control everything from the floating ⚡ button: a quick tap turns answering on/off — a long press opens the menu (server, channel, bot, speed).
                </Text>
            </Card>
            <Card style={{ padding: 12 }}>
                <Text variant="text-sm/medium">Server: {gname || "—"}</Text>
                <Text variant="text-sm/medium">Channel: {cname || "—"}</Text>
                <Text variant="text-sm/medium">Bot: {bname || "—"}</Text>
                <Text variant="text-sm/medium">Speed: {sc.speed === "insane" ? "Insane" : "Normal"}</Text>
            </Card>
            <Text variant="text-sm/semibold">OCR API Keys</Text>
            <RNTextInput
                style={{
                    backgroundColor: "#1e1f22",
                    color: "#dcddde",
                    borderRadius: 8,
                    borderWidth: 1,
                    borderColor: "#3f4147",
                    paddingHorizontal: 12,
                    paddingVertical: 10,
                    minHeight: 44,
                    fontSize: 14,
                }}
                placeholder="key1,key2,..."
                placeholderTextColor="#949ba4"
                multiline
                autoCapitalize="none"
                autoCorrect={false}
                value={state.ocrKeys || ""}
                onChangeText={(v: string) => { storage.ocrKeys = v; }}
            />
        </ScrollView>
    );
}
