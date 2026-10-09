import { bindGeneration } from './binding.mjs';

// Pi reports expanded queue contents before it emits message_start. Keep that
// native queue identity here; matching the original slash-command text would
// lose the binding after template or skill expansion.
export class PiBindings {
  constructor(directory, reply) {
    this.directory = directory;
    this.reply = reply;
    this.queues = { steering: [], followUp: [] };
    this.removed = [];
  }
  submit(context) { this.submitted = context?.captureID ?? ''; }
  observe(message) {
    if (message.type === 'extension_ui_request' && message.method === 'notify'
        && typeof message.message === 'string' && message.message.startsWith('wovenmatter_cli:')) {
      message = JSON.parse(message.message.slice('wovenmatter_cli:'.length));
    }
    if (message.type === 'wovenmatter_cli') {
      if (message.event === 'input') {
        this.input = message.source === 'rpc' ? this.submitted : '';
        this.removed = [];
      } else if (message.event === 'start') {
        this.start = this.input ?? '';
        this.input = undefined;
      } else if (message.event === 'consume') {
        const index = this.removed.findIndex(item => item.text === message.text);
        const capture = index >= 0 ? this.removed.splice(index, 1)[0].capture : this.start ?? '';
        this.start = undefined;
        bindGeneration(this.directory, message.generation, capture);
        this.reply({ generation: message.generation });
      }
      return true;
    }
    if (message.type === 'queue_update') {
      for (const name of ['steering', 'followUp']) {
        const old = this.queues[name], next = message[name] ?? [];
        if (next.length < old.length) {
          const count = old.length - next.length;
          // Native queue consumption removes the oldest matching entry.
          const retained = old.slice(count);
          if (retained.every((item, index) => item.text === next[index])) {
            this.removed.push(...old.slice(0, count));
            this.queues[name] = retained;
          } else this.queues[name] = next.map(text => ({ text, capture: '' }));
        } else {
          this.queues[name] = next.map((text, index) => old[index]?.text === text
            ? old[index] : { text, capture: this.input ?? '' });
        }
      }
      this.input = undefined;
    }
    if (message.type === 'response' && message.command === 'clear_queue') this.removed = [];
    if (message.type === 'response' && (message.success === false || message.data?.disposition === 'handled')) {
      this.input = undefined;
      this.start = undefined;
    }
    return false;
  }
}
