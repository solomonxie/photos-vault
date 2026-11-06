import { clear, h } from '../ui/dom';
import { count, t } from '../ui/i18n';
import type { UploadJob, Uploader } from './uploader';

/// The docked panel, bottom-right; see docs/design/cloud-sync/uiux/upload.md.
export function uploadTray(up: Uploader, onView: (id: string) => void) {
  const el = h('div', { class: 'tray', hidden: true });
  let collapsed = false;

  const row = (j: UploadJob) => {
    const status =
      j.state === 'uploading'
        ? h('span', { class: 'bar' }, h('span', { class: 'fill', style: `width:${Math.round(j.progress * 100)}%` }))
        : j.state === 'failed'
          ? h('button', { class: 'link', onclick: () => up.retry(j) }, `↻ ${t('retry')}`)
          : j.state === 'duplicate'
            ? h('button', { class: 'link', onclick: () => j.id && onView(j.id) }, t('alreadyHere'))
            : h('span', { class: 'muted' }, j.state === 'done' ? '✓' : j.state === 'hashing' ? t('preparing') : t('waitingUpload'));
    return h(
      'div',
      { class: 'tray-row' },
      h('span', { class: 'tray-name', title: j.file.name }, j.file.name),
      status,
      j.error ? h('div', { class: 'tray-error' }, j.error) : null,
    );
  };

  const render = () => {
    const jobs = up.jobs;
    el.hidden = jobs.length === 0;
    if (jobs.length === 0) return clear(el);
    const done = jobs.filter((j) => j.state === 'done' || j.state === 'duplicate').length;
    const failed = jobs.filter((j) => j.state === 'failed').length;
    const left = jobs.length - done - failed;
    const title =
      left > 0
        ? up.paused
          ? t('uploadPaused', count(left))
          : !navigator.onLine
            ? t('uploadOffline', count(left))
            : t('uploadProgress', count(done + 1), count(jobs.length))
        : failed > 0
          ? t('uploadPartial', count(done), count(failed))
          : t('uploadDone', count(done));
    el.replaceChildren(
      h(
        'div',
        { class: 'tray-head' },
        h('span', {}, title),
        left > 0
          ? h(
              'button',
              {
                class: 'icon',
                onclick: () => {
                  up.paused = !up.paused;
                  up.pump();
                  render();
                },
              },
              up.paused ? '▶' : '⏸',
            )
          : null,
        h('button', { class: 'icon', onclick: () => ((collapsed = !collapsed), render()) }, collapsed ? '⌃' : '⌄'),
        left === 0 ? h('button', { class: 'icon', onclick: () => up.clearDone() }, '✕') : null,
        left > 0
          ? h(
              'div',
              { class: 'tray-total' },
              h('i', { style: `width:${Math.round(((done + jobs.reduce((n, j) => n + (j.state === 'uploading' ? j.progress : 0), 0)) / jobs.length) * 100)}%` }),
            )
          : null,
      ),
      collapsed ? '' : h('div', { class: 'tray-rows' }, ...jobs.map(row)),
    );
  };
  return { el, render };
}

/// Files dropped anywhere on the page go to the uploader; the tray is the only feedback.
export function dropZone(onFiles: (files: File[]) => void) {
  const hasFiles = (e: DragEvent) => [...(e.dataTransfer?.types ?? [])].includes('Files');
  window.addEventListener('dragover', (e) => hasFiles(e) && e.preventDefault());
  window.addEventListener('drop', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    onFiles([...(e.dataTransfer?.files ?? [])]);
  });
}

export function pickFiles(onFiles: (files: File[]) => void) {
  const input = h('input', { type: 'file', multiple: true, accept: 'image/*,video/*,.heic,.heif' });
  input.addEventListener('change', () => onFiles([...(input.files ?? [])]));
  input.click();
}
