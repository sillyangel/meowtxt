(() => {
  const TAPBACK_EMOJI = {
    love: '❤️',
    like: '👍',
    dislike: '👎',
    laugh: '😂',
    emphasize: '‼️',
    question: '❓',
  };

  const state = {
    token: localStorage.getItem('meow_token') || '',
    chats: [],
    pinnedIdentifiers: [],
    activeChat: null,     // chat object or null when composing new
    composingNew: false,
    messages: [],         // chronological (oldest -> newest)
    names: {},            // handle -> contact name
    avatars: {},          // handle -> true (has contact photo)
    typingByChat: {},     // chatGuid -> { sender, name, timer }
    replyTo: null,        // {guid, text}
    attachment: null,     // File
    notifyAnyway: false,  // pre-send DND override toggle
    eventSource: null,
    typingTimer: null,
    status: null,
  };

  // Check URL query for ?token=...
  const urlParams = new URLSearchParams(location.search);
  if (urlParams.get('token')) {
    state.token = urlParams.get('token').trim();
    localStorage.setItem('meow_token', state.token);
    history.replaceState({}, '', location.pathname);
  }

  const $ = (id) => document.getElementById(id);

  async function api(path, opts = {}) {
    const headers = Object.assign({}, opts.headers || {});
    if (state.token) headers['Authorization'] = `Bearer ${state.token}`;
    if (opts.json !== undefined) {
      headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.json);
    }
    const res = await fetch(path, Object.assign({}, opts, { headers }));
    if (res.status === 401) {
      showAuthModal('Invalid or missing access token.');
      throw new Error('unauthorized');
    }
    return res.json();
  }

  function withToken(url) {
    if (!url) return '';
    const sep = url.includes('?') ? '&' : '?';
    return `${url}${sep}token=${encodeURIComponent(state.token)}`;
  }

  function mediaUrl(attId, { raw = false, thumb = false } = {}) {
    let u = `/api/attachment?id=${encodeURIComponent(attId)}`;
    if (raw) u += '&raw=1';
    if (thumb) u += '&thumb=1';
    return withToken(u);
  }

  function handleAvatarUrl(handle) {
    if (!handle || !state.avatars[handle]) return null;
    return withToken(`/api/avatar?handle=${encodeURIComponent(handle)}`);
  }

  function chatAvatarHtml(chat, extraClass = 'avatar') {
    const initials = escapeHtml(initialsFor(chat.title));
    if (chat.avatarUrl) {
      const src = escapeHtml(withToken(chat.avatarUrl));
      return `<div class="${extraClass}"><img src="${src}" alt="${initials}" loading="lazy" onerror="this.remove();this.parentElement.textContent='${initials}'"></div>`;
    }
    return `<div class="${extraClass}">${initials}</div>`;
  }

  function setHeaderAvatar(chat) {
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

  function formatRelTime(ms) {
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

  function formatFullTime(ms) {
    if (!ms) return '';
    return new Date(ms).toLocaleString([], {
      month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
    });
  }

  function initialsFor(title) {
    if (!title) return '💬';
    const clean = title.replace(/[^a-zA-Z0-9 ]/g, '').trim();
    if (!clean) return title.slice(0, 2).toUpperCase();
    const parts = clean.split(/\s+/);
    if (parts.length >= 2) return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
    return clean.slice(0, 2).toUpperCase();
  }

  // Auth Modal
  function showAuthModal(msg = '') {
    $('auth-modal').classList.remove('hidden');
    const err = $('auth-error');
    if (msg) {
      err.textContent = msg;
      err.classList.remove('hidden');
    } else {
      err.classList.add('hidden');
    }
    $('token-input').value = state.token;
    $('token-input').focus();
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

  // Fast parallel boot
  async function boot() {
    if (!state.token) {
      showAuthModal();
      return;
    }
    const [st] = await Promise.all([
      api('/api/status'),
      loadChats(),
    ]);
    state.status = st;
    $('account-pill').textContent = st.sendingFrom ? `iMessage • ${st.sendingFrom}` : 'iMessage';
    connectEvents();
  }

  function connectEvents() {
    if (state.eventSource) state.eventSource.close();
    const es = new EventSource(`/api/events?token=${encodeURIComponent(state.token)}`);
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
      const chat = JSON.parse(ev.data);
      upsertChat(chat);
    });
    es.addEventListener('pinned', async () => {
      await loadChats(false);
    });
    es.addEventListener('typing', (ev) => {
      const { chat, sender, name, typing } = JSON.parse(ev.data);
      setChatTyping(chat, sender, name, typing);
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

  function setChatTyping(chatGuid, sender, name, typing) {
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

  function updateTypingUI(chatGuid) {
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

  async function loadChats(autoSelectFirst = true) {
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

  function upsertChat(chat) {
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

  function renderPinnedSection() {
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
      card.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        togglePinChat(c);
      });
      sec.appendChild(card);
    }
  }

  function renderChatList(filterChats = null, searchMsgs = null) {
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
      row.querySelector('.chat-pin-btn').addEventListener('click', (e) => {
        e.stopPropagation();
        togglePinChat(c);
      });
      el.appendChild(row);
    }
  }

  async function togglePinChat(chat) {
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

  function updateHeaderPinButton() {
    const btn = $('pin-chat-btn');
    if (!state.activeChat || state.composingNew) {
      btn.classList.add('hidden');
      return;
    }
    btn.classList.remove('hidden');
    btn.classList.toggle('active', !!state.activeChat.pinned);
    btn.title = state.activeChat.pinned ? 'Unpin Conversation (Synced with iMessage)' : 'Pin Conversation (Synced with iMessage)';
  }

  $('pin-chat-btn').addEventListener('click', () => {
    if (state.activeChat) togglePinChat(state.activeChat);
  });

  function getLatestQuietOutboundMessage() {
    for (let i = state.messages.length - 1; i >= 0; i--) {
      const m = state.messages[i];
      if (!m.reaction && m.itemType === 0 && m.fromMe) {
        if (m.wasDeliveredQuietly && !m.didNotifyRecipient) return m;
        return null;
      }
    }
    return null;
  }

  function updateDNDBanner() {
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

  async function notifyMessage(msg) {
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

  async function editMessagePrompt(msg) {
    const next = prompt('Edit iMessage:', msg.text || '');
    if (next === null || next.trim() === '' || next === msg.text) return;
    const res = await api('/api/edit', {
      method: 'POST',
      json: { chat: msg.chat, message: msg.guid, text: next.trim() },
    });
    if (!res.ok) alert(res.error || 'Failed to edit message');
  }

  async function unsendMessagePrompt(msg) {
    if (!confirm('Unsend this iMessage?')) return;
    const res = await api('/api/unsend', {
      method: 'POST',
      json: { chat: msg.chat, message: msg.guid },
    });
    if (!res.ok) alert(res.error || 'Failed to unsend message');
  }

  async function selectChat(chat) {
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
    clearReply();
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

  function renderMessages(scrollToBottom = false) {
    const list = $('messages-list');
    list.innerHTML = '';

    // Fold tapbacks onto their target message GUID
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

      // Hover action bar (tapbacks + reply + notify/edit/unsend)
      const actions = document.createElement('div');
      actions.className = 'msg-actions';
      for (const [type, emoji] of Object.entries(TAPBACK_EMOJI)) {
        const b = document.createElement('button');
        b.textContent = emoji;
        b.title = type;
        b.addEventListener('click', () => sendReaction(m, type));
        actions.appendChild(b);
      }
      const replyBtn = document.createElement('button');
      replyBtn.textContent = '↩️';
      replyBtn.title = 'Reply';
      replyBtn.addEventListener('click', () => setReply(m));
      actions.appendChild(replyBtn);

      if (m.fromMe && !m.dateRetracted) {
        if ((m.wasDeliveredQuietly || state.activeChat?.dnd) && !m.didNotifyRecipient) {
          const notifyBtn = document.createElement('button');
          notifyBtn.textContent = '🔔';
          notifyBtn.title = 'Notify Anyway (Override DND)';
          notifyBtn.addEventListener('click', () => notifyMessage(m));
          actions.appendChild(notifyBtn);
        }
        if (m.text) {
          const editBtn = document.createElement('button');
          editBtn.textContent = '✏️';
          editBtn.title = 'Edit iMessage';
          editBtn.addEventListener('click', () => editMessagePrompt(m));
          actions.appendChild(editBtn);
        }
        const unsendBtn = document.createElement('button');
        unsendBtn.textContent = '🗑️';
        unsendBtn.title = 'Unsend iMessage';
        unsendBtn.addEventListener('click', () => unsendMessagePrompt(m));
        actions.appendChild(unsendBtn);
      }
      row.appendChild(actions);

      const contentCol = document.createElement('div');

      // Attachments (uses fast 640px ?thumb=1 preview for inline images, full res on lightbox click)
      if (m.attachments && m.attachments.length) {
        const attWrap = document.createElement('div');
        attWrap.className = 'msg-attachments';
        for (const a of m.attachments) {
          const mime = (a.mime || '').toLowerCase();
          if (mime.startsWith('image/')) {
            const img = document.createElement('img');
            img.className = 'att-img';
            img.loading = 'lazy';
            img.src = mediaUrl(a.id, { thumb: true });
            img.addEventListener('click', () => openLightbox(mediaUrl(a.id)));
            attWrap.appendChild(img);
          } else if (mime.startsWith('video/')) {
            const vid = document.createElement('video');
            vid.className = 'att-video';
            vid.controls = true;
            vid.src = mediaUrl(a.id, { raw: true });
            attWrap.appendChild(vid);
          } else if (mime.startsWith('audio/')) {
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

      // Text bubble
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

      // Tapback pills
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

      // Delivery / read / DND status on outbound messages
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
          btn.addEventListener('click', () => notifyMessage(m));
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

  async function sendReaction(msg, type) {
    await api('/api/react', {
      method: 'POST',
      json: { chat: msg.chat, message: msg.guid, type },
    });
  }

  function setReply(msg) {
    state.replyTo = { guid: msg.guid, text: msg.text || 'Attachment' };
    $('reply-bar-text').textContent = state.replyTo.text;
    $('reply-bar').classList.remove('hidden');
    $('message-input').focus();
  }

  function clearReply() {
    state.replyTo = null;
    $('reply-bar').classList.add('hidden');
  }
  $('reply-cancel').addEventListener('click', clearReply);

  // Attachments
  $('attach-btn').addEventListener('click', () => $('file-input').click());
  $('file-input').addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (!file) return;
    state.attachment = file;
    $('attachment-name').textContent = `${file.name} (${(file.size / 1024).toFixed(1)} KB)`;
    $('attachment-bar').classList.remove('hidden');
  });
  function clearAttachment() {
    state.attachment = null;
    $('file-input').value = '';
    $('attachment-bar').classList.add('hidden');
  }
  $('attachment-cancel').addEventListener('click', clearAttachment);

  // Sending
  async function sendCurrentMessage() {
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
        const raw = await fetch(`/api/send-file?${q.toString()}`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${state.token}` },
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

  // New conversation + contact autocomplete
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

  // Search
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

  // Mobile back button
  $('back-btn').addEventListener('click', () => {
    $('app').classList.remove('chat-open');
  });

  // Lightbox
  function openLightbox(src) {
    $('lightbox-img').src = src;
    $('lightbox').classList.remove('hidden');
  }
  $('lightbox-close').addEventListener('click', () => $('lightbox').classList.add('hidden'));
  $('lightbox').addEventListener('click', (e) => {
    if (e.target === $('lightbox')) $('lightbox').classList.add('hidden');
  });

  // Info / API Modal
  $('settings-btn').addEventListener('click', async () => {
    const st = await api('/api/status');
    state.status = st;
    $('status-details').innerHTML = `
      <div><strong>Connected to imagent:</strong> ${st.connected ? 'Yes' : 'No'}</div>
      <div><strong>iMessage Active:</strong> ${st.iMessageActive ? 'Yes' : 'No'}</div>
      <div><strong>Sending From:</strong> ${escapeHtml(st.sendingFrom || '—')}</div>
      <div><strong>Vetted Aliases:</strong> ${escapeHtml((st.aliases || []).join(', ') || '—')}</div>
    `;
    const origin = location.origin;
    $('api-examples').textContent = [
      `# Status`,
      `curl -H "Authorization: Bearer ${state.token}" ${origin}/api/status`,
      ``,
      `# List conversations (includes pinned state & avatarUrl)`,
      `curl -H "Authorization: Bearer ${state.token}" "${origin}/api/chats?limit=20"`,
      ``,
      `# Pin / Unpin a conversation (synced with iMessage app)`,
      `curl -X POST ${origin}/api/pin \\`,
      `  -H "Authorization: Bearer ${state.token}" \\`,
      `  -H "Content-Type: application/json" \\`,
      `  -d '{"chat":"iMessage;-;+13466771046","pinned":true}'`,
      ``,
      `# Send an iMessage`,
      `curl -X POST ${origin}/api/send \\`,
      `  -H "Authorization: Bearer ${state.token}" \\`,
      `  -H "Content-Type: application/json" \\`,
      `  -d '{"to":["friend@icloud.com"],"text":"Hello from meowtxt!"}'`,
      ``,
      `# Stream live events (message, updated, chat, typing, pinned)`,
      `curl -N -H "Authorization: Bearer ${state.token}" ${origin}/api/events`,
    ].join('\n');
    $('info-modal').classList.remove('hidden');
  });
  $('info-close').addEventListener('click', () => $('info-modal').classList.add('hidden'));
  $('logout-btn').addEventListener('click', () => {
    $('info-modal').classList.add('hidden');
    showAuthModal();
  });

  function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }

  boot().catch(() => {});
})();
