import { html } from 'lit-html';

/* ---------------------------
	Notifications: toast & popup
	Paste this near the top of main.js (after imports)
	--------------------------- */

const NOTIFS = {
	toasts: [],   // newest first
	popup: null,  // single popup object or null
};

// add a toast (returns id)
function notifyToast({ type = 'info', title = '', message = '', timeout = 4000 } = {}) {
	const id = Date.now().toString(36) + Math.random().toString(36).slice(2,6);
	NOTIFS.toasts.unshift({ id, type, title, message });
	// auto-dismiss
	if (timeout > 0) {
		setTimeout(() => removeToast(id), timeout);
	}
	// _render(); // re-render UI (keeps it simple)
	return id;
}

// remove a toast by id
function removeToast(id) {
	const before = NOTIFS.toasts.length;
	NOTIFS.toasts = NOTIFS.toasts.filter(t => t.id !== id);
	// if (NOTIFS.toasts.length !== before) _render();
}

// show a popup (single). actions is array: { label, onClick } where onClick is a function.
function showPopup({ type = 'info', title = '', message = '', actions = [] } = {}) {
	NOTIFS.popup = { type, title, message, actions };
	// _render();
}

// close popup
function closePopup() {
	NOTIFS.popup = null;
	// _render();
}

export function renderNotifications() {
	/* build toast nodes (top-right) */
  const toastNodes = NOTIFS.toasts.map(t => {
    // color variants
    const bg = t.type === 'success' ? 'bg-emerald-600' : (t.type === 'error' ? 'bg-rose-600' : 'bg-slate-700');
    return html`
      <div
        class="flex items-start gap-3 p-3 rounded-md shadow-md ring-1 ring-slate-700 min-w-[240px] max-w-sm text-white ${bg}"
        role="status" aria-live="polite"
      >
        <div class="flex-1 min-w-0">
          ${t.title ? html`<div class="font-semibold text-xs truncate">${t.title}</div>` : html``}
          <div class="text-xs mt-0.5 truncate">${t.message}</div>
        </div>
        <div class="flex flex-col items-end gap-1">
          <button
            class="text-xs px-2 py-1 rounded-md bg-slate-800/30 hover:bg-slate-800/40"
            @click=${() => removeToast(t.id)}
            aria-label="Close"
          >✕</button>
        </div>
      </div>
    `;
  });

  /* popup node (single). renders when NOTIFS.popup not null */
  const popupNode = NOTIFS.popup ? html`
    <div class="fixed inset-0 z-50 flex items-center justify-center">
      <div class="absolute inset-0 bg-black/50" @click=${() => { closePopup(); }}></div>
      <div class="relative z-10 w-full max-w-lg mx-4">
        <div class="bg-slate-800 ring-1 ring-slate-700 rounded-md p-4 text-sm">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="text-xs text-slate-400">${NOTIFS.popup.type.toUpperCase()}</div>
              <div class="font-semibold text-slate-100 text-sm truncate">${NOTIFS.popup.title}</div>
              <div class="text-xs text-slate-200 mt-1">${NOTIFS.popup.message}</div>
            </div>
            <div class="flex-shrink-0">
              <button class="text-xs px-2 py-1 rounded-md bg-slate-700 hover:bg-slate-600 text-slate-100" @click=${() => closePopup()}>Close</button>
            </div>
          </div>

          ${NOTIFS.popup.actions && NOTIFS.popup.actions.length ? html`
            <div class="mt-3 flex gap-2 justify-end">
              ${NOTIFS.popup.actions.map(a => html`
                <button
                  class="px-3 py-1 text-xs rounded-md bg-slate-700 hover:bg-slate-600 text-slate-100"
                  @click=${() => { try { a.onClick && a.onClick(); } catch(e){ console.error(e) } ; closePopup(); }}
                >${a.label}</button>
              `)}
            </div>
          ` : html``}
        </div>
      </div>
    </div>
  ` : html``;

	return html`<!-- TOASTS container (top-right) -->
	<div class="fixed top-4 right-4 z-50 flex flex-col items-end gap-2 pointer-events-none">
		${toastNodes.map(node => html`<div class="pointer-events-auto">${node}</div>`)}
	</div>

	<!-- POPUP (modal) -->
	${popupNode}`
}

// expose globally so other modules can call: window.notifyToast(...)
window.notifyToast = notifyToast;
window.removeToast = removeToast;
window.showPopup = showPopup;
window.closePopup = closePopup;
