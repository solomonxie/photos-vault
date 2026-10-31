import type { Bucket } from '../bucket/client';
import { sha256Hex } from '../bucket/sigv4';
import type { Engine } from '../sync/engine';
import type { Editor } from '../ui/edits';
import { readExif } from './exif';

export type UploadState = 'waiting' | 'hashing' | 'uploading' | 'done' | 'duplicate' | 'failed';

export interface UploadJob {
  file: File;
  state: UploadState;
  progress: number;
  error?: string;
  /// The photo this became (or already was, for a duplicate).
  id?: string;
}

const thumbEdge = 512;
const partSize = 8 * 1024 * 1024;
const multipartOver = 32 * 1024 * 1024;
/// Hashing reads the whole file into memory; past this, no duplicate check.
const hashUnder = 512 * 1024 * 1024;

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

/// `YYYYMMDDHHMMSS`, local time: the phone's `objectStamp`.
export const objectStamp = (ms: number) => {
  const d = new Date(ms);
  return `${pad(d.getFullYear(), 4)}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
};

/// The phone's ordinary object name (lib/vault/object_key.dart): stamp, then
/// the first 16 bytes of SHA-256 of the record id. Named this way the phone
/// knows the object as this record's own, never a stray to flag.
export const baseName = async (id: string, takenAt: number) =>
  `${objectStamp(takenAt)}_${(await sha256Hex(id)).slice(0, 32)}`;

const extOf = (name: string) => {
  const m = /\.([A-Za-z0-9]{1,5})$/.exec(name);
  return m ? `.${m[1]!.toLowerCase()}` : '';
};

/// A ~512 px JPEG: from the image itself, or a video's first frame. Null
/// for what Chrome can't decode (HEIC): the phone renders that one later.
async function thumbnail(file: File, video: boolean): Promise<{ blob: Blob; w: number; h: number } | null> {
  try {
    let source: CanvasImageSource;
    let w: number;
    let h: number;
    if (video) {
      const el = document.createElement('video');
      el.muted = true;
      el.preload = 'auto';
      el.src = URL.createObjectURL(file);
      await new Promise<void>((ok, fail) => {
        el.onloadeddata = () => ok();
        el.onerror = () => fail(new Error('video'));
      });
      el.currentTime = Math.min(0.1, el.duration || 0);
      await new Promise<void>((ok) => (el.onseeked = () => ok()));
      source = el;
      w = el.videoWidth;
      h = el.videoHeight;
      URL.revokeObjectURL(el.src);
    } else {
      const bmp = await createImageBitmap(file);
      source = bmp;
      w = bmp.width;
      h = bmp.height;
    }
    const scale = Math.min(1, thumbEdge / Math.max(w, h));
    const canvas = new OffscreenCanvas(Math.round(w * scale), Math.round(h * scale));
    canvas.getContext('2d')!.drawImage(source, 0, 0, canvas.width, canvas.height);
    return { blob: await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.75 }), w, h };
  } catch {
    return null;
  }
}

/// Browser uploads, two at a time. Per file: original up → thumbnail up →
/// both proven by HEAD → only then the `add` op, so no device ever sees a
/// photo whose bytes aren't in the bucket.
///
/// Kept in memory: a tab closed mid-way drops the queue (the objects already
/// sent are unreferenced and the phone's bucket check lists them).
export class Uploader {
  jobs: UploadJob[] = [];
  paused = false;
  private running = 0;

  constructor(
    private bucket: Bucket,
    private engine: Engine,
    private editor: Editor,
    private onChange: () => void,
  ) {}

  add(files: File[]) {
    const media = files.filter((f) => /^(image|video)\//.test(f.type) || /\.(heic|heif|dng|mov|mp4)$/i.test(f.name));
    this.jobs.push(...media.map((file): UploadJob => ({ file, state: 'waiting', progress: 0 })));
    this.onChange();
    this.pump();
  }

  retry(job: UploadJob) {
    job.state = 'waiting';
    job.error = undefined;
    this.pump();
  }

  clearDone() {
    this.jobs = this.jobs.filter((j) => j.state !== 'done' && j.state !== 'duplicate');
    this.onChange();
  }

  pump() {
    while (!this.paused && this.running < 2) {
      const job = this.jobs.find((j) => j.state === 'waiting');
      if (!job) return;
      this.running++;
      void this.run(job).finally(() => {
        this.running--;
        this.onChange();
        this.pump();
      });
    }
  }

  /// Every original hash the library knows, for spotting a re-upload.
  private known(): Map<string, string> {
    const out = new Map<string, string>();
    for (const ent of this.engine.state.listed()) {
      if (ent.e !== 'asset') continue;
      for (const f of ['original_hash', 'content_hash']) {
        const v = ent.fields.get(f)?.x;
        if (typeof v === 'string' && /^[0-9a-f]{64}$/.test(v)) out.set(v, ent.id);
      }
    }
    return out;
  }

  private async run(job: UploadJob) {
    const { file } = job;
    try {
      job.state = 'hashing';
      this.onChange();
      const video = file.type.startsWith('video/') || /\.(mov|mp4)$/i.test(file.name);
      const hash = file.size < hashUnder ? await sha256Hex(new Uint8Array(await file.arrayBuffer())) : null;
      const already = hash ? this.known().get(hash) : undefined;
      if (already) {
        job.state = 'duplicate';
        job.id = already;
        return;
      }
      const exif = video ? {} : readExif(new Uint8Array(await file.slice(0, 512 * 1024).arrayBuffer()));
      const takenAt = exif.takenAt ?? file.lastModified;
      const id = `web:${crypto.randomUUID()}`;
      const stem = await baseName(id, takenAt);
      const originalKey = `originals/${stem}${extOf(file.name) || (video ? '.mov' : '.jpg')}`;
      const thumbKey = `thumbnails/${stem}.jpg`;

      job.state = 'uploading';
      this.onChange();
      await this.putOriginal(job, originalKey);
      const thumb = await thumbnail(file, video);
      if (thumb) await this.bucket.put(thumbKey, thumb.blob, 'image/jpeg');

      const there = await this.bucket.head(originalKey);
      if (!there || there.size !== file.size) throw new Error(`original not confirmed (${there?.size ?? 'missing'})`);
      if (thumb && !(await this.bucket.head(thumbKey))) throw new Error('thumbnail not confirmed');

      await this.editor.edit([
        {
          e: 'asset',
          id,
          o: 'add',
          x: {
            created_at: takenAt,
            original_key: originalKey,
            thumbnail_key: thumb ? thumbKey : null,
            content_hash: hash ?? id,
            original_hash: hash,
            is_video: video ? 1 : 0,
            is_live_photo: 0,
            width: thumb?.w ?? null,
            height: thumb?.h ?? null,
            latitude: exif.lat ?? null,
            longitude: exif.lng ?? null,
            description: '',
            location: null,
            is_favorite: 0,
            is_archived: 0,
            deleted_at: null,
          },
        },
      ]);
      job.id = id;
      job.progress = 1;
      job.state = 'done';
    } catch (e) {
      job.state = 'failed';
      job.error = e instanceof Error ? e.message : String(e);
    }
  }

  private async putOriginal(job: UploadJob, key: string) {
    const { file } = job;
    const type = file.type || 'application/octet-stream';
    if (file.size <= multipartOver) {
      await this.bucket.put(key, file, type);
      job.progress = 1;
      return;
    }
    const uploadId = await this.bucket.multipartStart(key, type);
    const etags: string[] = [];
    for (let at = 0, part = 1; at < file.size; at += partSize, part++) {
      etags.push(await this.bucket.multipartPart(key, uploadId, part, file.slice(at, at + partSize)));
      job.progress = Math.min(1, (at + partSize) / file.size);
      this.onChange();
    }
    await this.bucket.multipartComplete(key, uploadId, etags);
  }
}
