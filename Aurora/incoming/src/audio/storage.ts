import type { MixSettings, TrackAnalysis } from "../types";

const DB_NAME = "automix-dsp";
const STORE = "tracks";

export interface StoredTrack {
  id: string;
  title: string;
  artist: string;
  blob: Blob;
  analysis: TrackAnalysis | null;
  color: string;
  color2: string;
  addedAt: number;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) return reject(new Error("no idb"));
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE, { keyPath: "id" });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function saveTrack(t: StoredTrack): Promise<void> {
  try {
    const db = await openDb();
    await new Promise<void>((res, rej) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).put(t);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  } catch {
    /* хранилище недоступно — работаем в памяти */
  }
}

export async function updateAnalysis(id: string, analysis: TrackAnalysis): Promise<void> {
  try {
    const db = await openDb();
    await new Promise<void>((res, rej) => {
      const tx = db.transaction(STORE, "readwrite");
      const store = tx.objectStore(STORE);
      const g = store.get(id);
      g.onsuccess = () => {
        const rec = g.result as StoredTrack | undefined;
        if (rec) store.put({ ...rec, analysis });
      };
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  } catch {
    /* ignore */
  }
}

export async function loadTracks(): Promise<StoredTrack[]> {
  try {
    const db = await openDb();
    return await new Promise((res, rej) => {
      const tx = db.transaction(STORE, "readonly");
      const req = tx.objectStore(STORE).getAll();
      req.onsuccess = () => res((req.result as StoredTrack[]).sort((a, b) => a.addedAt - b.addedAt));
      req.onerror = () => rej(req.error);
    });
  } catch {
    return [];
  }
}

export async function deleteTrack(id: string): Promise<void> {
  try {
    const db = await openDb();
    await new Promise<void>((res, rej) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).delete(id);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  } catch {
    /* ignore */
  }
}

const SETTINGS_KEY = "automix-settings-v1";
export function loadSettings(fallback: MixSettings): MixSettings {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    return raw ? { ...fallback, ...JSON.parse(raw) } : fallback;
  } catch {
    return fallback;
  }
}
export function saveSettings(s: MixSettings) {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}
