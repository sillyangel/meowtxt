import { state, $ } from './state.js';
import { api } from './api.js';
import { escapeHtml, withToken } from './utils.js';
import { selectChat } from './ui.js';

export function initServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker.register('/sw.js').then((reg) => {
    state.swReg = reg;
  }).catch(() => {});
  navigator.serviceWorker.addEventListener('message', (ev) => {
    if (ev.data?.type === 'meow:open-chat' && ev.data.chat) {
      const found = state.chats.find((c) => c.guid === ev.data.chat);
      if (found) selectChat(found);
    }
  });
}

export async function loadNotificationPrefs() {
  const res = await api('/api/notifications');
  if (res && res.events) {
    state.notifPrefs.received = !!res.events.received;
    state.notifPrefs.sent = !!res.events.sent;
    state.notifPrefs.delivered = !!res.events.delivered;
    state.notifPrefs.read = !!res.events.read;
  }
  syncNotifCheckboxes();
}

export function updateNotifHeaderBtn() {
  const btn = $('notif-btn');
  if (!btn) return;
  const anyOn = state.notifPrefs.received || state.notifPrefs.sent || state.notifPrefs.delivered || state.notifPrefs.read;
  btn.classList.toggle('active', anyOn);
}

export function syncNotifCheckboxes() {
  if ($('notif-opt-received')) $('notif-opt-received').checked = !!state.notifPrefs.received;
  if ($('notif-opt-sent')) $('notif-opt-sent').checked = !!state.notifPrefs.sent;
  if ($('notif-opt-delivered')) $('notif-opt-delivered').checked = !!state.notifPrefs.delivered;
  if ($('notif-opt-read')) $('notif-opt-read').checked = !!state.notifPrefs.read;
  if ($('notif-opt-foreground')) $('notif-opt-foreground').checked = !!state.notifPrefs.foreground;
  const permEl = $('notif-perm-status');
  if (permEl) {
    const perm = ('Notification' in window) ? Notification.permission : 'unsupported';
    permEl.textContent = perm === 'granted'
      ? 'Browser push notifications: Enabled ✓ (plus live in-app banners)'
      : perm === 'denied'
        ? 'Browser push permission denied — using live in-app notification banners.'
        : 'Push notifications for incoming, sent, delivered & read messages.';
  }
  updateNotifHeaderBtn();
}

export function showNotificationToast(payload) {
  const container = $('toast-container');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = 'notif-toast';
  const type = payload.type || 'received';
  const badgeLabel = type === 'read' ? 'Read' : type === 'sent' ? 'Sent' : type === 'delivered' ? 'Delivered' : 'iMessage';
  const iconHtml = payload.avatarUrl
    ? `<img src="${escapeHtml(withToken(payload.avatarUrl))}" alt="">`
    : `<img src="/favicon.svg" alt="">`;
  toast.innerHTML = `
    <div class="notif-toast-icon">${iconHtml}</div>
    <div class="notif-toast-body">
      <div class="notif-toast-top">
        <span class="notif-toast-title">${escapeHtml(payload.title || 'meowtxt')}</span>
        <span class="notif-toast-badge ${escapeHtml(type)}">${escapeHtml(badgeLabel)}</span>
      </div>
      <div class="notif-toast-text">${escapeHtml(payload.body || '')}</div>
    </div>
  `;
  toast.addEventListener('click', () => {
    toast.remove();
    if (payload.chat) {
      const found = state.chats.find((c) => c.guid === payload.chat);
      if (found) selectChat(found);
    }
  });
  container.appendChild(toast);
  setTimeout(() => {
    toast.remove();
  }, 4500);
}

export function dispatchWebNotification(payload) {
  const type = payload.type || 'received';
  if (state.notifPrefs[type] === false) return;

  const isFocused = document.visibilityState === 'visible' && document.hasFocus();
  if (!isFocused || state.notifPrefs.foreground) {
    showNotificationToast(payload);
  }

  if ('Notification' in window && Notification.permission === 'granted' && (!isFocused || state.notifPrefs.foreground)) {
    const icon = payload.avatarUrl ? withToken(payload.avatarUrl) : '/icon-192.png';
    const opts = {
      body: payload.body || '',
      icon,
      badge: '/icon-192.png',
      tag: payload.tag || payload.id || `meow-${type}`,
      data: { chat: payload.chat || null, type },
    };
    if (state.swReg && state.swReg.showNotification) {
      state.swReg.showNotification(payload.title || 'meowtxt', opts).catch(() => {
        try { new Notification(payload.title || 'meowtxt', opts); } catch (_) {}
      });
    } else {
      try {
        const n = new Notification(payload.title || 'meowtxt', opts);
        n.onclick = () => {
          window.focus();
          if (payload.chat) {
            const found = state.chats.find((c) => c.guid === payload.chat);
            if (found) selectChat(found);
          }
          n.close();
        };
      } catch (_) {}
    }
  }
}
