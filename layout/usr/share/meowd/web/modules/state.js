export const TAPBACK_EMOJI = {
  love: '❤️',
  like: '👍',
  dislike: '👎',
  laugh: '😂',
  emphasize: '‼️',
  question: '❓',
};

export const state = {
  token: localStorage.getItem('meow_token') || '',
  chats: [],
  pinnedIdentifiers: [],
  activeChat: null,     // chat object or null when composing new
  composingNew: false,
  messages: [],         // chronological (oldest -> newest)
  names: {},            // handle -> contact name
  avatars: {},          // handle -> true (has contact photo)
  typingByChat: {},     // chatGuid -> { sender, name, timer }
  replyTo: null,        // { guid, text }
  attachment: null,     // File
  notifyAnyway: false,  // pre-send DND override toggle
  notifPrefs: {
    received: true,
    sent: true,
    delivered: true,
    read: true,
    foreground: localStorage.getItem('meow_notif_fg') !== '0',
  },
  swReg: null,
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

export const $ = (id) => document.getElementById(id);
