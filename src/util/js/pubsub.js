class PubSub extends EventTarget {
	on(type, listener, options) { this.addEventListener(type, listener, options); }
  off(type, listener, options) { this.removeEventListener(type, listener, options); }
  emit(type, detail, options = {}) {
    const ev = new CustomEvent(type, { detail, ...options });
    return this.dispatchEvent(ev);
  }
  once(type) {
    return new Promise(resolve => {
      const handler = e => {
        this.removeEventListener(type, handler);
        resolve(e.detail);
      };
      this.addEventListener(type, handler, { once: true });
    });
  }
}

export default PubSub;