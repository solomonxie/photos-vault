// chrome.i18n, with the key itself as a fallback (tests, a missing string).

export const t = (key: string, ...subs: (string | number)[]): string => {
  const s =
    typeof chrome !== 'undefined' && chrome.i18n
      ? chrome.i18n.getMessage(key, subs.map(String))
      : '';
  return s || key;
};

export const lang = () => (typeof chrome !== 'undefined' && chrome.i18n ? chrome.i18n.getUILanguage() : 'en');

export const dayLabel = (at: number, place: string) => {
  const d = new Date(at);
  const today = new Date();
  const yesterday = new Date(Date.now() - 86_400_000);
  const same = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  const date = same(d, today)
    ? t('today')
    : same(d, yesterday)
      ? t('yesterday')
      : d.toLocaleDateString(lang(), {
          weekday: 'short',
          month: 'short',
          day: 'numeric',
          year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric',
        });
  return place ? `${date} · ${place}` : date;
};

export const fullDate = (at: number) =>
  new Date(at).toLocaleString(lang(), {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });

export const count = (n: number) => n.toLocaleString(lang());

export const ago = (at: number) => {
  const s = Math.round((Date.now() - at) / 1000);
  if (s < 60) return t('justNow');
  const rtf = new Intl.RelativeTimeFormat(lang(), { numeric: 'auto' });
  if (s < 3600) return rtf.format(-Math.round(s / 60), 'minute');
  if (s < 86_400) return rtf.format(-Math.round(s / 3600), 'hour');
  return rtf.format(-Math.round(s / 86_400), 'day');
};

export const size = (bytes: number) => {
  const [n, unit] = bytes >= 1e9 ? [bytes / 1e9, 'gigabyte'] : bytes >= 1e6 ? [bytes / 1e6, 'megabyte'] : [bytes / 1e3, 'kilobyte'];
  return new Intl.NumberFormat(lang(), { style: 'unit', unit, maximumFractionDigits: 1 }).format(n);
};
