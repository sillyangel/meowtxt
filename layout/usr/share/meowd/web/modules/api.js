import { state, $ } from './state.js';

export function showAuthModal(msg = '') {
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

export async function api(path, opts = {}) {
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
