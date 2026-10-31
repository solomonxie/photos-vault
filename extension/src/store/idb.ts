// The few IndexedDB calls the engine needs, as promises.

export const stores = ['meta', 'entities', 'outbox', 'sealed'] as const;
export type StoreName = (typeof stores)[number];

export const openDb = (name = 'photos-vault'): Promise<IDBDatabase> =>
  new Promise((resolve, reject) => {
    const req = indexedDB.open(name, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      db.createObjectStore('meta');
      db.createObjectStore('entities');
      db.createObjectStore('outbox', { autoIncrement: true });
      db.createObjectStore('sealed');
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });

export const request = <T>(r: IDBRequest<T>): Promise<T> =>
  new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });

/// One transaction over `names`; resolves once it has committed.
export const tx = <T>(
  db: IDBDatabase,
  names: StoreName[],
  body: (t: IDBTransaction) => T,
): Promise<T> =>
  new Promise((resolve, reject) => {
    const t = db.transaction(names, 'readwrite');
    let result: T;
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error ?? new Error('transaction aborted'));
    result = body(t);
  });

export const getAll = async <T>(db: IDBDatabase, name: StoreName) => {
  const t = db.transaction(name, 'readonly').objectStore(name);
  const [keys, values] = await Promise.all([request(t.getAllKeys()), request(t.getAll())]);
  return keys.map((k, i) => [k, values[i] as T] as const);
};
