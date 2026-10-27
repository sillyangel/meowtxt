import { state, $ } from './state.js';

export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

export function withToken(url) {
  if (!url) return '';
  if (!state.token) return url;
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}token=${encodeURIComponent(state.token)}`;
}

export function mediaUrl(attId, { raw = false, thumb = false } = {}) {
  let u = `/api/attachment?id=${encodeURIComponent(attId)}`;
  if (raw) u += '&raw=1';
  if (thumb) u += '&thumb=1';
  return withToken(u);
}

export function handleAvatarUrl(handle) {
  if (!handle || !state.avatars[handle]) return null;
  return withToken(`/api/avatar?handle=${encodeURIComponent(handle)}`);
}

export function initialsFor(title) {
  if (!title) return '💬';
  const clean = title.replace(/[^a-zA-Z0-9 ]/g, '').trim();
  if (!clean) return title.slice(0, 2).toUpperCase();
  const parts = clean.split(/\s+/);
  if (parts.length >= 2) return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  return clean.slice(0, 2).toUpperCase();
}

export function chatAvatarHtml(chat, extraClass = 'avatar') {
  const initials = escapeHtml(initialsFor(chat.title));
  if (chat.avatarUrl) {
    const src = escapeHtml(withToken(chat.avatarUrl));
    return `<div class="${extraClass}"><img src="${src}" alt="${initials}" loading="lazy" onerror="this.remove();this.parentElement.textContent='${initials}'"></div>`;
  }
  return `<div class="${extraClass}">${initials}</div>`;
}

export function setHeaderAvatar(chat) {
  const el = $('header-avatar');
  const initials = initialsFor(chat.title);
  if (chat.avatarUrl) {
    el.innerHTML = `<img src="${escapeHtml(withToken(chat.avatarUrl))}" alt="${escapeHtml(initials)}">`;
    const img = el.querySelector('img');
    if (img) img.onerror = () => { el.textContent = initials; };
  } else {
    el.textContent = initials;
  }
}

export function formatRelTime(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  const now = new Date();
  const diff = now - d;
  if (diff < 60 * 1000) return 'now';
  if (d.toDateString() === now.toDateString()) {
    return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }
  if (diff < 7 * 86400 * 1000) {
    return d.toLocaleDateString([], { weekday: 'short' });
  }
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

export function formatFullTime(ms) {
  if (!ms) return '';
  return new Date(ms).toLocaleString([], {
    month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  });
}

export function classifyAttachment(a) {
  const mime = (a.mime || '').toLowerCase();
  const uti = (a.uti || '').toLowerCase();
  const name = (a.name || '').toLowerCase();
  const isImage = mime.startsWith('image/') ||
    uti.includes('image') || uti.includes('heic') || uti.includes('heif') ||
    uti.includes('avci') || uti.includes('jpeg') || uti.includes('png') ||
    /\.(heic|heif|heics|avci|jpg|jpeg|png|gif|webp|tif|tiff|bmp)$/i.test(name);
  const isVideo = !isImage && (
    mime.startsWith('video/') || uti.includes('movie') || uti.includes('video') ||
    /\.(mov|mp4|m4v)$/i.test(name)
  );
  const isAudio = !isImage && !isVideo && (
    mime.startsWith('audio/') || uti.includes('audio') ||
    /\.(m4a|mp3|wav|caf|amr)$/i.test(name)
  );
  return { isImage, isVideo, isAudio };
}
