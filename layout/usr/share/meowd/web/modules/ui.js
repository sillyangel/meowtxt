import { state, TAPBACK_EMOJI, $ } from './state.js';
import { api } from './api.js';
import {
  escapeHtml,
  initialsFor,
  formatRelTime,
  formatFullTime,
  mediaUrl,
  handleAvatarUrl,
  chatAvatarHtml,
  setHeaderAvatar,
  classifyAttachment,
} from './utils.js';

export function updateHeaderPinButton() {
  const btn = $('pin-chat-btn');
  if (!state.activeChat || state.composingNew) {
    btn.classList.add('hidden');
    return;
  }
  btn.classList.remove('hidden');
  btn.classList.toggle('active', !!state.activeChat.pinned);
  btn.title = state.activeChat.pinned
    ? 'Unpin Conversation (Synced with iMessage)'
    : 'Pin Conversation (Synced with iMessage)';
}

export function getLatestQuietOutboundMessage() {
  for (let i = state.messages.length - 1; i >= 0; i--) {
    const m = state.messages[i];
    if (!m.reaction && m.itemType === 0 && m.fromMe) {
      if (m.wasDeliveredQuietly && !m.didNotifyRecipient) return m;
      return null;
    }
  }
  return null;
}

export function updateDNDBanner() {
  const banner = $('dnd-banner');
  if (!state.activeChat || state.composingNew) {
    banner.classList.add('hidden');
    return;
  }
  const quietMsg = getLatestQuietOutboundMessage();
  const isDnd = !!state.activeChat.dnd || !!quietMsg;
  if (!isDnd) {
    banner.classList.add('hidden');
    return;
  }
  banner.classList.remove('hidden');
  const name = state.activeChat.title || state.activeChat.identifier;
  $('dnd-banner-text').textContent = `${name} has notifications silenced`;
  const btn = $('dnd-banner-action');
  if (quietMsg) {
    btn.textContent = 'Notify Anyway 🔔';
    btn.classList.remove('active');
  } else if (state.notifyAnyway) {
    btn.textContent = 'Will Notify on Send 🔔';
    btn.classList.add('active');
  } else {
    btn.textContent = 'Notify Next Message 🔔';
    btn.classList.remove('active');
  }
}

export function setChatTyping(chatGuid, sender, name, typing) {
  const existing = state.typingByChat[chatGuid];
  if (existing?.timer) clearTimeout(existing.timer);
  if (typing) {
    const timer = setTimeout(() => {
      delete state.typingByChat[chatGuid];
      updateTypingUI(chatGuid);
    }, 60000);
    state.typingByChat[chatGuid] = { sender, name: name || state.names[sender] || sender, timer };
  } else {
    delete state.typingByChat[chatGuid];
  }
  updateTypingUI(chatGuid);
}

export function updateTypingUI(chatGuid) {
  renderPinnedSection();
  renderChatList();
  if (state.activeChat && state.activeChat.guid === chatGuid) {
    const t = state.typingByChat[chatGuid];
    const row = $('typing-indicator-row');
    const sub = $('header-subtitle');
    if (t) {
      row.classList.remove('hidden');
      $('typing-indicator-label').textContent = state.activeChat.isGroup && t.name ? `${t.name} is typing…` : '';
      sub.textContent = state.activeChat.isGroup && t.name ? `${t.name} is typing…` : 'typing…';
      sub.classList.add('typing-active');
      const container = $('messages-container');
      container.scrollTop = container.scrollHeight;
    } else {
      row.classList.add('hidden');
      sub.textContent = (state.activeChat.participants || []).join(', ') || state.activeChat.identifier;
      sub.classList.remove('typing-active');
    }
  }
}

export async function loadChats(autoSelectFirst = true) {
  const res = await api('/api/chats?limit=150');
  state.chats = res.chats || [];
  state.pinnedIdentifiers = res.pinnedIdentifiers || [];
  const seenPinIdx = new Set();
  for (const c of state.chats) {
    Object.assign(state.names, c.names || {});
    Object.assign(state.avatars, c.avatars || {});
    if (c.pinned && c.pinIndex !== null && c.pinIndex !== undefined) {
      if (seenPinIdx.has(c.pinIndex)) c.pinned = false;
      else seenPinIdx.add(c.pinIndex);
    }
  }
  if (state.activeChat) {
    const updated = state.chats.find((c) => c.guid === state.activeChat.guid);
    if (updated) {
      state.activeChat = updated;
      updateHeaderPinButton();
    }
  }
  renderPinnedSection();
  renderChatList();
  if (autoSelectFirst && !state.activeChat && !state.composingNew && state.chats.length) {
    selectChat(state.chats[0]);
  }
}

export function upsertChat(chat) {
  Object.assign(state.names, chat.names || {});
  Object.assign(state.avatars, chat.avatars || {});
  const idx = state.chats.findIndex((c) => c.guid === chat.guid);
  if (idx !== -1) state.chats.splice(idx, 1);
  state.chats.unshift(chat);
  if (state.activeChat && state.activeChat.guid === chat.guid) {
    chat.unread = 0;
    state.activeChat = chat;
    setHeaderAvatar(chat);
    updateHeaderPinButton();
  }
  renderPinnedSection();
  renderChatList();
}

export function renderPinnedSection() {
  const sec = $('pinned-section');
  const q = $('search-input').value.trim();
  const pinnedChats = state.chats
    .filter((c) => c.pinned)
    .sort((a, b) => (a.pinIndex ?? 999) - (b.pinIndex ?? 999));

  if (!pinnedChats.length || q.length > 0) {
    sec.classList.add('hidden');
    sec.innerHTML = '';
    return;
  }

  sec.classList.remove('hidden');
  sec.innerHTML = '';
  for (const c of pinnedChats) {
    const card = document.createElement('div');
    const active = state.activeChat && state.activeChat.guid === c.guid && !state.composingNew;
    const isTyping = !!state.typingByChat[c.guid];
    card.className = `pin-card${active ? ' active' : ''}`;
    card.title = `${c.title} (Right-click to unpin)`;
    card.innerHTML = `
      <div class="pin-avatar-wrap">
        ${chatAvatarHtml(c, 'pin-avatar')}
        ${c.unread > 0 ? `<span class="pin-unread-badge">${c.unread}</span>` : ''}
        ${c.dnd ? `<span class="pin-dnd-badge" title="Focus / Do Not Disturb active">🌙</span>` : ''}
        ${isTyping ? `<span class="pin-typing-badge"><span class="dot"></span><span class="dot"></span><span class="dot"></span></span>` : ''}
      </div>
      <div class="pin-title">${escapeHtml(c.title)}</div>
    `;
    card.addEventListener('click', () => selectChat(c));
    card.addEventListener('contextmenu', async (e) => {
      e.preventDefault();
      const { togglePinChat } = await import('./actions.js');
      togglePinChat(c);
    });
    sec.appendChild(card);
  }
}

export function renderChatList(filterChats = null, searchMsgs = null) {
  const el = $('chat-list');
  el.innerHTML = '';

  if (searchMsgs) {
    for (const m of searchMsgs) {
      const row = document.createElement('div');
      row.className = 'chat-item';
      const who = m.fromMe ? 'Me' : (state.names[m.sender] || m.sender || m.chat);
      const avUrl = !m.fromMe ? handleAvatarUrl(m.sender) : null;
      const avHtml = avUrl
        ? `<div class="avatar"><img src="${escapeHtml(avUrl)}" alt="${escapeHtml(initialsFor(who))}" loading="lazy"></div>`
        : `<div class="avatar">${escapeHtml(initialsFor(who))}</div>`;
      row.innerHTML = `
        ${avHtml}
        <div class="chat-item-body">
          <div class="chat-item-top">
            <span class="chat-item-title">${escapeHtml(who)}</span>
            <span class="chat-item-time">${formatRelTime(m.date)}</span>
          </div>
          <div class="chat-item-preview">${escapeHtml(m.text || '')}</div>
        </div>`;
      row.addEventListener('click', async () => {
        const found = state.chats.find((c) => c.guid === m.chat);
        if (found) selectChat(found);
        else {
          const r = await api(`/api/chat?guid=${encodeURIComponent(m.chat)}`);
          if (r.chat) selectChat(r.chat);
        }
      });
      el.appendChild(row);
    }
    return;
  }

  const list = filterChats || state.chats.filter((c) => !c.pinned);
  for (const c of list) {
    const row = document.createElement('div');
    const active = state.activeChat && state.activeChat.guid === c.guid && !state.composingNew;
    const isTyping = !!state.typingByChat[c.guid];
    row.className = `chat-item${active ? ' active' : ''}`;
    const preview = isTyping ? 'typing…' : (c.lastMessage?.text || 'No messages');
    row.innerHTML = `
      ${c.unread > 0 ? '<span class="unread-dot"></span>' : ''}
      ${chatAvatarHtml(c, 'avatar')}
      <div class="chat-item-body">
        <div class="chat-item-top">
          <span class="chat-item-title">${escapeHtml(c.title)}${c.dnd ? '<span class="chat-dnd-pill" title="Focus / Do Not Disturb active">🌙</span>' : ''}</span>
          <span class="chat-item-time">${formatRelTime(c.lastMessage?.date)}</span>
        </div>
        <div class="chat-item-preview${isTyping ? ' typing-text' : ''}">${escapeHtml(preview)}</div>
      </div>
      <button class="chat-pin-btn${c.pinned ? ' pinned' : ''}" title="${c.pinned ? 'Unpin conversation' : 'Pin conversation'}">📌</button>`;
    row.addEventListener('click', (e) => {
      if (e.target.closest('.chat-pin-btn')) return;
      selectChat(c);
    });
    row.querySelector('.chat-pin-btn').addEventListener('click', async (e) => {
      e.stopPropagation();
      const { togglePinChat } = await import('./actions.js');
      togglePinChat(c);
    });
    el.appendChild(row);
  }
}

export async function selectChat(chat) {
  state.composingNew = false;
  state.notifyAnyway = false;
  const hadUnread = chat.unread > 0;
  state.activeChat = chat;
  chat.unread = 0;
  $('app').classList.add('chat-open');
  $('new-recipient-bar').classList.add('hidden');
  $('chat-header-info').classList.remove('hidden');
  setHeaderAvatar(chat);
  $('header-title').textContent = chat.title;
  updateHeaderPinButton();
  state.replyTo = null;
  $('reply-bar').classList.add('hidden');
  updateTypingUI(chat.guid);
  updateDNDBanner();

  const res = await api(`/api/messages?chat=${encodeURIComponent(chat.guid)}&limit=60`);
  Object.assign(state.names, res.names || {});
  Object.assign(state.avatars, res.avatars || {});
  if (res.dnd !== undefined && state.activeChat && state.activeChat.guid === chat.guid) {
    state.activeChat.dnd = !!res.dnd;
  }
  state.messages = (res.messages || []).slice().reverse();
  $('load-more-wrap').classList.toggle('hidden', (res.messages || []).length < 60);
  updateDNDBanner();
  renderMessages(true);
  if (hadUnread) {
    api('/api/read', { method: 'POST', json: { chat: chat.guid } }).catch(() => {});
  }
}

export function renderMessages(scrollToBottom = false) {
  const list = $('messages-list');
  list.innerHTML = '';

  const tapbacksByTarget = {};
  const byGuid = {};
  for (const m of state.messages) {
    byGuid[m.guid] = m;
    if (m.reaction && m.reaction.target) {
      const t = m.reaction.target;
      if (!tapbacksByTarget[t]) tapbacksByTarget[t] = [];
      if (m.reaction.remove) {
        const i = tapbacksByTarget[t].findIndex((r) => r.type === m.reaction.type && r.sender === m.sender);
        if (i !== -1) tapbacksByTarget[t].splice(i, 1);
      } else {
        tapbacksByTarget[t].push({ type: m.reaction.type, sender: m.sender, fromMe: m.fromMe });
      }
    }
  }

  const normalMsgs = state.messages.filter((m) => !m.reaction && m.itemType === 0);
  let lastTimestamp = 0;
  let lastOutboundIdx = -1;
  normalMsgs.forEach((m, i) => { if (m.fromMe) lastOutboundIdx = i; });

  normalMsgs.forEach((m, idx) => {
    if (!lastTimestamp || m.date - lastTimestamp > 30 * 60 * 1000) {
      const div = document.createElement('div');
      div.className = 'time-divider';
      div.textContent = formatFullTime(m.date);
      list.appendChild(div);
      lastTimestamp = m.date;
    }

    const row = document.createElement('div');
    row.className = `msg-row ${m.fromMe ? 'from-me' : 'from-them'}`;

    const senderName = state.names[m.sender] || m.sender || 'Unknown';
    if (!m.fromMe && state.activeChat?.isGroup) {
      const lbl = document.createElement('div');
      lbl.className = 'sender-label';
      lbl.textContent = senderName;
      row.appendChild(lbl);
    }

    const actions = document.createElement('div');
    actions.className = 'msg-actions';
    for (const [type, emoji] of Object.entries(TAPBACK_EMOJI)) {
      const b = document.createElement('button');
      b.textContent = emoji;
      b.title = type;
      b.addEventListener('click', async () => {
        const { sendReaction } = await import('./actions.js');
        sendReaction(m, type);
      });
      actions.appendChild(b);
    }
    const replyBtn = document.createElement('button');
    replyBtn.textContent = '↩️';
    replyBtn.title = 'Reply';
    replyBtn.addEventListener('click', async () => {
      const { setReply } = await import('./actions.js');
      setReply(m);
    });
    actions.appendChild(replyBtn);

    if (m.fromMe && !m.dateRetracted) {
      if ((m.wasDeliveredQuietly || state.activeChat?.dnd) && !m.didNotifyRecipient) {
        const notifyBtn = document.createElement('button');
        notifyBtn.textContent = '🔔';
        notifyBtn.title = 'Notify Anyway (Override DND)';
        notifyBtn.addEventListener('click', async () => {
          const { notifyMessage } = await import('./actions.js');
          notifyMessage(m);
        });
        actions.appendChild(notifyBtn);
      }
      if (m.text) {
        const editBtn = document.createElement('button');
        editBtn.textContent = '✏️';
        editBtn.title = 'Edit iMessage';
        editBtn.addEventListener('click', async () => {
          const { editMessagePrompt } = await import('./actions.js');
          editMessagePrompt(m);
        });
        actions.appendChild(editBtn);
      }
      const unsendBtn = document.createElement('button');
      unsendBtn.textContent = '🗑️';
      unsendBtn.title = 'Unsend iMessage';
      unsendBtn.addEventListener('click', async () => {
        const { unsendMessagePrompt } = await import('./actions.js');
        unsendMessagePrompt(m);
      });
      actions.appendChild(unsendBtn);
    }
    row.appendChild(actions);

    const contentCol = document.createElement('div');

    if (m.attachments && m.attachments.length) {
      const attWrap = document.createElement('div');
      attWrap.className = 'msg-attachments';
      for (const a of m.attachments) {
        const { isImage, isVideo, isAudio } = classifyAttachment(a);
        if (isImage) {
          const img = document.createElement('img');
          img.className = 'att-img';
          img.loading = 'lazy';
          img.src = mediaUrl(a.id, { thumb: true });
          img.addEventListener('click', async () => {
            const { openLightbox } = await import('./actions.js');
            openLightbox(mediaUrl(a.id));
          });
          attWrap.appendChild(img);
        } else if (isVideo) {
          const vid = document.createElement('video');
          vid.className = 'att-video';
          vid.controls = true;
          vid.src = mediaUrl(a.id, { raw: true });
          attWrap.appendChild(vid);
        } else if (isAudio) {
          const aud = document.createElement('audio');
          aud.className = 'att-audio';
          aud.controls = true;
          aud.src = mediaUrl(a.id, { raw: true });
          attWrap.appendChild(aud);
        } else {
          const link = document.createElement('a');
          link.className = 'att-file';
          link.href = mediaUrl(a.id, { raw: true });
          link.target = '_blank';
          link.textContent = `📎 ${a.name || 'Attachment'}`;
          attWrap.appendChild(link);
        }
      }
      contentCol.appendChild(attWrap);
    }

    const hasText = (m.text && m.text.trim().length > 0) || m.subject || m.dateRetracted > 0;
    if (hasText) {
      const bubble = document.createElement('div');
      bubble.className = `msg-bubble${m.dateRetracted > 0 ? ' retracted' : ''}`;

      if (m.replyTo && byGuid[m.replyTo]) {
        const q = document.createElement('div');
        q.className = 'msg-reply-quote';
        q.textContent = byGuid[m.replyTo].text || 'Attachment';
        bubble.appendChild(q);
      }
      if (m.subject) {
        const s = document.createElement('span');
        s.className = 'msg-subject';
        s.textContent = m.subject;
        bubble.appendChild(s);
      }
      const body = document.createElement('span');
      body.textContent = m.dateRetracted > 0 ? 'Message unsent' : (m.text || '');
      bubble.appendChild(body);
      contentCol.appendChild(bubble);
    }

    if (!m.fromMe && state.activeChat?.isGroup) {
      const line = document.createElement('div');
      line.className = 'msg-content-line';
      const mini = document.createElement('div');
      mini.className = 'sender-mini-avatar';
      const avUrl = handleAvatarUrl(m.sender);
      if (avUrl) {
        mini.innerHTML = `<img src="${escapeHtml(avUrl)}" alt="${escapeHtml(initialsFor(senderName))}" loading="lazy">`;
      } else {
        mini.textContent = initialsFor(senderName);
      }
      line.appendChild(mini);
      line.appendChild(contentCol);
      row.appendChild(line);
    } else {
      row.appendChild(contentCol);
    }

    const reactions = tapbacksByTarget[m.guid];
    if (reactions && reactions.length) {
      const pills = document.createElement('div');
      pills.className = 'tapback-pills';
      for (const r of reactions) {
        const p = document.createElement('span');
        p.className = 'tapback-pill';
        p.textContent = TAPBACK_EMOJI[r.type] || '👍';
        pills.appendChild(p);
      }
      row.appendChild(pills);
    }

    if (m.fromMe && (idx === lastOutboundIdx || m.error !== 0 || m.wasDeliveredQuietly || m.didNotifyRecipient)) {
      const st = document.createElement('div');
      st.className = `msg-status${m.error !== 0 ? ' error' : ''}`;
      if (m.error !== 0) {
        st.textContent = `Not Delivered (${m.error})`;
        row.appendChild(st);
      } else if (m.didNotifyRecipient) {
        st.className = 'msg-dnd-row';
        st.textContent = m.read ? `Read ${formatRelTime(m.dateRead)} · 🔔 Notified` : 'Delivered · 🔔 Notified';
        row.appendChild(st);
      } else if (m.wasDeliveredQuietly || (idx === lastOutboundIdx && state.activeChat?.dnd && !m.read)) {
        const dndRow = document.createElement('div');
        dndRow.className = 'msg-dnd-row';
        const lbl = document.createElement('span');
        lbl.textContent = '🌙 Delivered Quietly · ';
        const btn = document.createElement('button');
        btn.className = 'notify-anyway-link';
        btn.textContent = 'Notify Anyway 🔔';
        btn.addEventListener('click', async () => {
          const { notifyMessage } = await import('./actions.js');
          notifyMessage(m);
        });
        dndRow.appendChild(lbl);
        dndRow.appendChild(btn);
        row.appendChild(dndRow);
      } else if (idx === lastOutboundIdx) {
        if (m.read) st.textContent = `Read ${formatRelTime(m.dateRead)}`;
        else if (m.delivered) st.textContent = 'Delivered';
        else if (m.sent) st.textContent = 'Sent';
        else st.textContent = 'Sending…';
        row.appendChild(st);
      }
    }

    list.appendChild(row);
  });

  if (scrollToBottom) {
    const container = $('messages-container');
    container.scrollTop = container.scrollHeight;
  }
}
