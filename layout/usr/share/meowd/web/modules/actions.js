import { state, $ } from './state.js';
import { api } from './api.js';
import { escapeHtml, initialsFor, withToken } from './utils.js';
import {
  renderPinnedSection,
  renderChatList,
  renderMessages,
  updateHeaderPinButton,
  updateDNDBanner,
  getLatestQuietOutboundMessage,
  loadChats,
  selectChat,
} from './ui.js';

export async function togglePinChat(chat) {
  if (!chat) return;
  const nextPinned = !chat.pinned;
  chat.pinned = nextPinned;
  renderPinnedSection();
  renderChatList();
  updateHeaderPinButton();
  const res = await api('/api/pin', {
    method: 'POST',
    json: { chat: chat.guid, pinned: nextPinned },
  });
  if (!res.ok) {
    chat.pinned = !nextPinned;
    alert(res.error || 'Could not update pinned state');
  }
  await loadChats(false);
}

export async function notifyMessage(msg) {
  if (!msg) return;
  const res = await api('/api/notify', {
    method: 'POST',
    json: { chat: msg.chat, message: msg.guid },
  });
  if (res.ok) {
    msg.didNotifyRecipient = true;
    updateDNDBanner();
    renderMessages(false);
  } else {
    alert(res.error || 'Could not send Notify Anyway command');
  }
}

export async function editMessagePrompt(msg) {
  const next = prompt('Edit iMessage:', msg.text || '');
  if (next === null || next.trim() === '' || next === msg.text) return;
  const res = await api('/api/edit', {
    method: 'POST',
    json: { chat: msg.chat, message: msg.guid, text: next.trim() },
  });
  if (!res.ok) alert(res.error || 'Failed to edit message');
}

export async function unsendMessagePrompt(msg) {
  if (!confirm('Unsend this iMessage?')) return;
  const res = await api('/api/unsend', {
    method: 'POST',
    json: { chat: msg.chat, message: msg.guid },
  });
  if (!res.ok) alert(res.error || 'Failed to unsend message');
}

export async function sendReaction(msg, type) {
  await api('/api/react', {
    method: 'POST',
    json: { chat: msg.chat, message: msg.guid, type },
  });
}

export function setReply(msg) {
  state.replyTo = { guid: msg.guid, text: msg.text || 'Attachment' };
  $('reply-bar-text').textContent = state.replyTo.text;
  $('reply-bar').classList.remove('hidden');
  $('message-input').focus();
}

export function clearReply() {
  state.replyTo = null;
  $('reply-bar').classList.add('hidden');
}

export function clearAttachment() {
  state.attachment = null;
  $('file-input').value = '';
  $('attachment-bar').classList.add('hidden');
}

export function openLightbox(src) {
  $('lightbox-img').src = src;
  $('lightbox').classList.remove('hidden');
}

export async function sendCurrentMessage() {
  const text = $('message-input').value.trim();
  const effect = $('effect-select').value || undefined;
  const chatGuid = state.composingNew ? undefined : state.activeChat?.guid;
  const to = state.composingNew
    ? $('recipient-input').value.split(',').map((s) => s.trim()).filter(Boolean)
    : undefined;

  if (!chatGuid && (!to || !to.length)) {
    $('recipient-input').focus();
    return;
  }
  if (!text && !state.attachment) return;

  $('send-btn').disabled = true;
  try {
    let res;
    if (state.attachment) {
      const q = new URLSearchParams({ filename: state.attachment.name });
      if (chatGuid) q.set('chat', chatGuid);
      if (to) q.set('to', to.join(','));
      if (text) q.set('text', text);
      const headers = state.token ? { Authorization: `Bearer ${state.token}` } : {};
      const raw = await fetch(`/api/send-file?${q.toString()}`, {
        method: 'POST',
        headers,
        body: state.attachment,
      });
      res = await raw.json();
    } else {
      res = await api('/api/send', {
        method: 'POST',
        json: {
          chat: chatGuid,
          to,
          text,
          effect,
          replyTo: state.replyTo?.guid,
          notifyAnyway: state.notifyAnyway || undefined,
        },
      });
    }

    if (!res.ok) {
      alert(res.error || 'Failed to send');
      return;
    }

    $('message-input').value = '';
    $('message-input').style.height = 'auto';
    $('effect-select').value = '';
    state.notifyAnyway = false;
    updateDNDBanner();
    clearReply();
    clearAttachment();

    if (state.composingNew && res.chat) {
      await loadChats(false);
      const created = state.chats.find((c) => c.guid === res.chat);
      if (created) selectChat(created);
    }
  } finally {
    $('send-btn').disabled = false;
  }
}

let actionsBound = false;
export function bindInteractiveActions() {
  if (actionsBound) return;
  actionsBound = true;

  $('pin-chat-btn').addEventListener('click', () => {
    if (state.activeChat) togglePinChat(state.activeChat);
  });

  $('dnd-banner-action').addEventListener('click', async () => {
    if (!state.activeChat) return;
    const quietMsg = getLatestQuietOutboundMessage();
    if (quietMsg) {
      await notifyMessage(quietMsg);
    } else {
      state.notifyAnyway = !state.notifyAnyway;
      updateDNDBanner();
    }
  });

  $('load-more-btn').addEventListener('click', async () => {
    if (!state.activeChat || !state.messages.length) return;
    const oldest = state.messages[0].date;
    const res = await api(`/api/messages?chat=${encodeURIComponent(state.activeChat.guid)}&before=${oldest}&limit=60`);
    Object.assign(state.names, res.names || {});
    Object.assign(state.avatars, res.avatars || {});
    const older = (res.messages || []).slice().reverse();
    $('load-more-wrap').classList.toggle('hidden', older.length < 60);
    state.messages = older.concat(state.messages);
    renderMessages(false);
  });

  $('reply-cancel').addEventListener('click', clearReply);

  $('attach-btn').addEventListener('click', () => $('file-input').click());
  $('file-input').addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (!file) return;
    state.attachment = file;
    $('attachment-name').textContent = `${file.name} (${(file.size / 1024).toFixed(1)} KB)`;
    $('attachment-bar').classList.remove('hidden');
  });
  $('attachment-cancel').addEventListener('click', clearAttachment);

  $('send-btn').addEventListener('click', sendCurrentMessage);
  $('message-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendCurrentMessage();
    }
  });
  $('message-input').addEventListener('input', () => {
    const el = $('message-input');
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 120)}px`;
    if (state.activeChat && !state.composingNew) {
      if (!state.typingTimer) {
        api('/api/typing', { method: 'POST', json: { chat: state.activeChat.guid, typing: true } }).catch(() => {});
      }
      clearTimeout(state.typingTimer);
      state.typingTimer = setTimeout(() => {
        state.typingTimer = null;
        if (state.activeChat) {
          api('/api/typing', { method: 'POST', json: { chat: state.activeChat.guid, typing: false } }).catch(() => {});
        }
      }, 2500);
    }
  });

  $('new-chat-btn').addEventListener('click', () => {
    state.composingNew = true;
    state.activeChat = null;
    state.messages = [];
    $('app').classList.add('chat-open');
    $('chat-header-info').classList.add('hidden');
    $('pin-chat-btn').classList.add('hidden');
    $('new-recipient-bar').classList.remove('hidden');
    $('recipient-input').value = '';
    $('messages-list').innerHTML = '<div class="empty-state">Enter a recipient above and send an iMessage.</div>';
    $('recipient-input').focus();
    renderPinnedSection();
    renderChatList();
  });

  $('recipient-input').addEventListener('input', async () => {
    const raw = $('recipient-input').value;
    const lastPart = raw.split(',').pop().trim();
    const box = $('contact-suggestions');
    if (!lastPart) {
      box.classList.add('hidden');
      return;
    }
    const res = await api(`/api/contacts?q=${encodeURIComponent(lastPart)}`);
    const contacts = res.contacts || [];
    if (!contacts.length) {
      box.classList.add('hidden');
      return;
    }
    box.innerHTML = '';
    for (const c of contacts) {
      for (const h of c.handles || []) {
        const item = document.createElement('div');
        item.className = 'suggestion-item';
        const avHtml = c.hasAvatar
          ? `<div class="sender-mini-avatar"><img src="${escapeHtml(withToken(`/api/avatar?handle=${encodeURIComponent(h)}`))}" alt=""></div>`
          : `<div class="sender-mini-avatar">${escapeHtml(initialsFor(c.name))}</div>`;
        item.innerHTML = `<div class="suggestion-left">${avHtml}<span>${escapeHtml(c.name)}</span></div><span class="suggestion-handle">${escapeHtml(h)}</span>`;
        item.addEventListener('click', () => {
          const parts = raw.split(',').slice(0, -1).map((s) => s.trim()).filter(Boolean);
          parts.push(h);
          $('recipient-input').value = parts.join(', ');
          box.classList.add('hidden');
          $('message-input').focus();
        });
        box.appendChild(item);
      }
    }
    box.classList.remove('hidden');
  });

  let searchDebounce = null;
  $('search-input').addEventListener('input', () => {
    const q = $('search-input').value.trim();
    $('search-clear').classList.toggle('hidden', !q);
    clearTimeout(searchDebounce);
    renderPinnedSection();
    if (!q) {
      renderChatList();
      return;
    }
    const matchedChats = state.chats.filter((c) =>
      c.title.toLowerCase().includes(q.toLowerCase()) ||
      (c.participants || []).some((p) => p.toLowerCase().includes(q.toLowerCase()))
    );
    renderChatList(matchedChats);
    searchDebounce = setTimeout(async () => {
      const res = await api(`/api/search?q=${encodeURIComponent(q)}&limit=40`);
      Object.assign(state.names, res.names || {});
      if (res.messages && res.messages.length) {
        renderChatList(null, res.messages);
      }
    }, 250);
  });

  $('search-clear').addEventListener('click', () => {
    $('search-input').value = '';
    $('search-clear').classList.add('hidden');
    renderPinnedSection();
    renderChatList();
  });

  $('back-btn').addEventListener('click', () => {
    $('app').classList.remove('chat-open');
  });

  $('lightbox-close').addEventListener('click', () => $('lightbox').classList.add('hidden'));
  $('lightbox').addEventListener('click', (e) => {
    if (e.target === $('lightbox')) $('lightbox').classList.add('hidden');
  });
}
