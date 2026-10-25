// Browser-only affordances. Application state and rendering live in Elixir.
const Hooks = {
  Transcript: {
    mounted() { this.follow = true; this.el.addEventListener('scroll', () => { this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 100; }); this.el.scrollTop = this.el.scrollHeight; },
    updated() { if (this.follow) this.el.scrollTop = this.el.scrollHeight; }
  },
  Draft: {
    mounted() {
      this.el.value = sessionStorage.getItem('session-desk-draft') || this.el.value;
      this.el.addEventListener('input', () => sessionStorage.setItem('session-desk-draft', this.el.value));
      this.el.addEventListener('keydown', event => { if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); this.el.form.requestSubmit(); } });
      this.handleEvent('clear_draft', () => { this.el.value = ''; sessionStorage.removeItem('session-desk-draft'); });
    }
  }
};
const token = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new window.LiveView.LiveSocket('/live', window.Phoenix.Socket, {params: {_csrf_token: token}, hooks: Hooks});
liveSocket.connect();
window.liveSocket = liveSocket;
