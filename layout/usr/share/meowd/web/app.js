import { state, $ } from './modules/state.js';
import { api } from './modules/api.js';
import {
  loadChats,
  upsertChat,
  setChatTyping,
  updateDNDBanner,
  renderPinnedSection,
  renderChatList,
  renderMessages,
} from './modules/ui.js';

function connectEvents() {
  if (state.eventSource) state.eventSource.close();
  const q = state.token ? `?token=${encodeURIComponent(state.token)}` : '';
  const es = new EventSource(`/api/events${q}`);
  state.eventSource = es;
  const dot = $('conn-dot');

  es.addEventListener('hello', () => {
    dot.className = 'status-dot online';
    dot.title = 'Connected to iPhone (live)';
  });
  es.onerror = () => {
    dot.className = 'status-dot offline';
    dot.title = 'Reconnecting…';
  };
  es.addEventListener('chat', (ev) => {
    upsertChat(JSON.parse(ev.data));
  });
  es.addEventListener('pinned', async () => {
    await loadChats(false);
  });
  es.addEventListener('typing', (ev) => {
    const { chat, sender, name, typing } = JSON.parse(ev.data);
    setChatTyping(chat, sender, name, typing);
  });
  es.addEventListener('notification', async (ev) => {
    const payload = JSON.parse(ev.data);
    const { dispatchWebNotification } = await import('./modules/notifications.js');
    dispatchWebNotification(payload);
  });
  es.addEventListener('dnd', (ev) => {
    const { handle, chat: chatGuid, dnd } = JSON.parse(ev.data);
    for (const c of state.chats) {
      if (c.guid === chatGuid || (handle && (c.identifier === handle || (c.participants || []).includes(handle)))) {
        c.dnd = !!dnd;
      }
    }
    if (state.activeChat && (state.activeChat.guid === chatGuid || state.activeChat.identifier === handle)) {
      state.activeChat.dnd = !!dnd;
      updateDNDBanner();
    }
    renderPinnedSection();
    renderChatList();
  });
  es.addEventListener('message', (ev) => {
    const { message, names, avatars } = JSON.parse(ev.data);
    Object.assign(state.names, names || {});
    Object.assign(state.avatars, avatars || {});
    if (!message.fromMe) {
      setChatTyping(message.chat, message.sender, null, false);
    }
    if (state.activeChat && message.chat === state.activeChat.guid) {
      if (!state.messages.some((m) => m.guid === message.guid)) {
        state.messages.push(message);
        if (message.wasDeliveredQuietly && !message.didNotifyRecipient) {
          state.activeChat.dnd = true;
        }
        updateDNDBanner();
        renderMessages(true);
      }
      if (!message.fromMe) api('/api/read', { method: 'POST', json: { chat: state.activeChat.guid } }).catch(() => {});
    }
  });
  es.addEventListener('updated', (ev) => {
    const { message, names, avatars } = JSON.parse(ev.data);
    Object.assign(state.names, names || {});
    Object.assign(state.avatars, avatars || {});
    if (state.activeChat && message.chat === state.activeChat.guid) {
      const idx = state.messages.findIndex((m) => m.guid === message.guid);
      if (idx !== -1) {
        state.messages[idx] = message;
        if (message.wasDeliveredQuietly && !message.didNotifyRecipient) {
          state.activeChat.dnd = true;
        }
        updateDNDBanner();
        renderMessages(false);
      }
    }
  });
}

async function boot() {
  const [st] = await Promise.all([
    api('/api/status'),
    loadChats(),
  ]);
  state.status = st;
  $('account-pill').textContent = st.sendingFrom ? `iMessage • ${st.sendingFrom}` : 'iMessage';
  connectEvents();

  // Lazy-load secondary modules (interactive composer/actions & notifications) after first paint
  const defer = window.requestIdleCallback || ((fn) => setTimeout(fn, 50));
  defer(async () => {
    const [{ bindInteractiveActions }, { initServiceWorker, loadNotificationPrefs, updateNotifHeaderBtn }] = await Promise.all([
      import('./modules/actions.js'),
      import('./modules/notifications.js'),
    ]);
    bindInteractiveActions();
    initServiceWorker();
    await loadNotificationPrefs().catch(() => {});
    updateNotifHeaderBtn();
  });
}

$('auth-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  state.token = $('token-input').value.trim();
  localStorage.setItem('meow_token', state.token);
  try {
    await boot();
    $('auth-modal').classList.add('hidden');
  } catch (_) {}
});

// Lazy-load settings modal only when clicked
const openLazySettings = async () => {
  const { openSettingsModal } = await import('./modules/settings.js');
  await openSettingsModal();
};
$('settings-btn').addEventListener('click', openLazySettings);
$('notif-btn').addEventListener('click', openLazySettings);

boot().catch(() => {});
