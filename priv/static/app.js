// Browser-only affordances. Application state and rendering live in Elixir.
const Hooks = {
  FilePreview: {
    mounted() { this.selection = this.el.dataset.selection; this.reveal = true; this.showPreview(); },
    updated() {
      if (this.selection !== this.el.dataset.selection) { this.selection = this.el.dataset.selection; this.reveal = true; }
      this.showPreview();
    },
    showPreview() {
      if (this.reveal && this.el.getAttribute('aria-busy') === 'false') {
        this.reveal = false;
        this.el.focus({preventScroll: true});
        this.el.scrollIntoView({block: 'nearest'});
      }
    }
  },
  Details: {
    beforeUpdate() { this.wasOpen = this.el.open; },
    updated() { this.el.open = this.wasOpen; }
  },
  Transcript: {
    mounted() { this.follow = true; this.el.addEventListener('scroll', () => { this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 100; }); this.el.scrollTop = this.el.scrollHeight; },
    updated() { if (this.follow) this.el.scrollTop = this.el.scrollHeight; }
  },
  Draft: {
    mounted() {
      this.key = 'session-desk-draft:' + this.el.dataset.sessionId;
      this.el.value = sessionStorage.getItem(this.key) || this.el.value;
      this.pushEvent('restore_draft', {session_id: this.el.dataset.sessionId, message: this.el.value});
      this.el.addEventListener('input', () => sessionStorage.setItem(this.key, this.el.value));
      this.el.addEventListener('keydown', event => { if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); this.el.form.requestSubmit(); } });
      this.handleEvent('clear_draft', ({session_id}) => { if(session_id === this.el.dataset.sessionId) { this.el.value = ''; sessionStorage.removeItem(this.key); } });
    }
  }
};
const token = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new window.LiveView.LiveSocket('/live', window.Phoenix.Socket, {params: {_csrf_token: token}, hooks: Hooks});
liveSocket.connect();
window.liveSocket = liveSocket;
