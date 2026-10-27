import { state, $ } from './state.js';
import { api, showAuthModal } from './api.js';
import { escapeHtml } from './utils.js';
import {
  loadNotificationPrefs,
  syncNotifCheckboxes,
  updateNotifHeaderBtn,
} from './notifications.js';

let settingsBound = false;

export function bindSettingsModal() {
  if (settingsBound) return;
  settingsBound = true;

  $('enable-browser-notif-btn').addEventListener('click', async () => {
    if (!('Notification' in window)) {
      alert('Native browser Notification API requires HTTPS, localhost, or an Installed/Isolated Web App (IWA). Live in-app notification banners are still active!');
      return;
    }
    const perm = await Notification.requestPermission();
    syncNotifCheckboxes();
    if (perm === 'granted') {
      await api('/api/notifications/test', {
        method: 'POST',
        json: {
          type: 'read',
          title: 'meowtxt Notifications Enabled',
          body: 'You will now receive notifications when messages are sent, delivered, or read.',
        },
      });
    }
  });

  $('test-notif-btn').addEventListener('click', async () => {
    await api('/api/notifications/test', {
      method: 'POST',
      json: {
        type: 'read',
        title: 'Read by cielo',
        body: 'Test notification — sent, delivered & read alerts are working!',
        chat: state.activeChat?.guid,
      },
    });
  });

  for (const [id, key] of [
    ['notif-opt-received', 'received'],
    ['notif-opt-sent', 'sent'],
    ['notif-opt-delivered', 'delivered'],
    ['notif-opt-read', 'read'],
  ]) {
    $(id).addEventListener('change', async (e) => {
      state.notifPrefs[key] = e.target.checked;
      updateNotifHeaderBtn();
      await api('/api/notifications', {
        method: 'POST',
        json: { [key]: e.target.checked },
      });
    });
  }

  $('notif-opt-foreground').addEventListener('change', (e) => {
    state.notifPrefs.foreground = e.target.checked;
    localStorage.setItem('meow_notif_fg', e.target.checked ? '1' : '0');
  });

  $('info-close').addEventListener('click', () => $('info-modal').classList.add('hidden'));
  $('logout-btn').addEventListener('click', () => {
    $('info-modal').classList.add('hidden');
    showAuthModal();
  });
}

export async function openSettingsModal() {
  bindSettingsModal();
  const [st] = await Promise.all([
    api('/api/status'),
    loadNotificationPrefs().catch(() => {}),
  ]);
  state.status = st;
  $('status-details').innerHTML = `
    <div><strong>Connected to imagent:</strong> ${st.connected ? 'Yes' : 'No'}</div>
    <div><strong>iMessage Active:</strong> ${st.iMessageActive ? 'Yes' : 'No'}</div>
    <div><strong>Token Auth Required:</strong> ${st.requireAuth === false ? 'Off (Configured in iOS Settings)' : 'On'}</div>
    <div><strong>Sending From:</strong> ${escapeHtml(st.sendingFrom || '—')}</div>
    <div><strong>Vetted Aliases:</strong> ${escapeHtml((st.aliases || []).join(', ') || '—')}</div>
  `;
  const origin = location.origin;
  $('api-examples').textContent = [
    `# Status`,
    `curl -H "Authorization: Bearer ${state.token}" ${origin}/api/status`,
    ``,
    `# List conversations (includes pinned, dnd, avatarUrl)`,
    `curl -H "Authorization: Bearer ${state.token}" "${origin}/api/chats?limit=20"`,
    ``,
    `# Configure Web / Webhook Notifications (received, sent, delivered, read)`,
    `curl -X POST ${origin}/api/notifications \\`,
    `  -H "Authorization: Bearer ${state.token}" \\`,
    `  -H "Content-Type: application/json" \\`,
    `  -d '{"events":{"received":true,"sent":true,"delivered":true,"read":true}}'`,
    ``,
    `# Trigger Test Notification`,
    `curl -X POST ${origin}/api/notifications/test \\`,
    `  -H "Authorization: Bearer ${state.token}" \\`,
    `  -H "Content-Type: application/json" \\`,
    `  -d '{"type":"read","title":"Read by cielo","body":"Web notifications are working!"}'`,
    ``,
    `# Stream live events (message, updated, chat, typing, pinned, dnd, notification)`,
    `curl -N -H "Authorization: Bearer ${state.token}" ${origin}/api/events`,
  ].join('\n');
  $('info-modal').classList.remove('hidden');
}
