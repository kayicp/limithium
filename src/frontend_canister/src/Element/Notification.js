import { html } from 'lit-html';

export default class Notif {
	toasts = []
	popup = null

	constructor(pubsub){
		this.pubsub = pubsub;
	}

	#render() {
		this.pubsub.emit('render');
	}

	showToast({ type = 'info', title = '', message = '', timeout = 5000 } = {}) {
		const id = Date.now().toString(36) + Math.random().toString(36).slice(2,6);
		this.toasts.unshift({ id, type, title, message });
		// auto-dismiss
		if (timeout > 0) {
			setTimeout(() => this.closeToast(id), timeout);
		}
		this.#render(); // re-render UI (keeps it simple)
		return id;
	}

	successToast(title, message) {
		this.pubsub.emit('refresh');
		this.showToast({ type: 'success', title, message});
	}

	errorToast(title, err) {
		const message = err instanceof Error ? err.message : String(err);
		this.showToast({ type: 'error', title, message });
	}

	closeToast(id) {
		const before = this.toasts.length;
		this.toasts = this.toasts.filter(t => t.id !== id);
		if (this.toasts.length !== before) this.#render();
	}

	showPopup({ type = 'info', title = '', message = '', actions = [] } = {}) {
		this.popup = { type, title, message, actions };
		this.#render();
	}

	successPopup(title, message) {
		this.pubsub.emit('refresh');
		this.showPopup({ type: 'success', title, message });
	}

	errorPopup(title, err) {
		const message = err instanceof Error ? err.message : String(err);
		this.showPopup({ type : 'error', title, message });
	}

	closePopup() {
		this.popup = null;
		this.#render();
	}

	draw() {
		/* build toast nodes (top-right) */
			const toastNodes = this.toasts.map(t => {
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
								@click=${() => this.closeToast(t.id)}
								aria-label="Close"
							>✕</button>
						</div>
					</div>
				`;
			});
		
			/* popup node (single). renders when this.popup not null */
			const popupNode = this.popup ? html`
				<div class="fixed inset-0 z-50 flex items-center justify-center">
					<div class="absolute inset-0 bg-black/50" @click=${() => { this.closePopup(); }}></div>
					<div class="relative z-10 w-full max-w-lg mx-4">
						<div class="bg-slate-800 ring-1 ring-slate-700 rounded-md p-4 text-sm">
							<div class="flex items-start justify-between gap-3">
								<div class="min-w-0">
									<div class="text-xs text-slate-400">${this.popup.type.toUpperCase()}</div>
									<div class="font-semibold text-slate-100 text-sm truncate">${this.popup.title}</div>
									<div class="text-xs text-slate-200 mt-1">${this.popup.message}</div>
								</div>
								<div class="flex-shrink-0">
									<button class="text-xs px-2 py-1 rounded-md bg-slate-700 hover:bg-slate-600 text-slate-100" @click=${() => this.closePopup()}>Close</button>
								</div>
							</div>
		
							${this.popup.actions && this.popup.actions.length ? html`
								<div class="mt-3 flex gap-2 justify-end">
									${this.popup.actions.map(a => html`
										<button
											class="px-3 py-1 text-xs rounded-md bg-slate-700 hover:bg-slate-600 text-slate-100"
											@click=${() => { 
												try {
													a.onClick && a.onClick(); 
												} catch(e){ 
													console.error(e) 
												} ; 
												this.closePopup(); 
											}}
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
}