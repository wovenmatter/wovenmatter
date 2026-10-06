#pragma once
// Installed only in a main-frame V8 context. The router binds replies to that
// context; native code independently validates the actual frame and form origin.
static constexpr char kWovenPasswordForms[] = R"JS(
(function(query) {
  let credential = null;
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  const visible = input => !input.disabled && !input.readOnly && input.getClientRects().length > 0;
  const passwordInputs = form => Array.from(form.elements).filter(i => i instanceof HTMLInputElement && i.type === 'password' && visible(i));
  const usernameInput = (form, password) => {
    const fields = Array.from(form.elements).filter(i => i instanceof HTMLInputElement && visible(i));
    return fields.find(i => i.autocomplete.toLowerCase().split(/\s+/).includes('username')) ||
      fields.filter(i => ['text', 'email'].includes(i.type) && (!password || (i.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING))).pop();
  };
  const sameOrigin = action => {
    try { return new URL(action || location.href, location.href).origin === location.origin; }
    catch { return false; }
  };
  const set = (input, value) => {
    valueSetter.call(input, value);
    input.dispatchEvent(new Event('input', {bubbles: true}));
    input.dispatchEvent(new Event('change', {bubbles: true}));
  };
  const fill = value => {
    const manual = value?.manual === true;
    if (value) credential = value;
    if (!credential || credential.origin !== location.origin) return;
    for (const form of document.forms) {
      if (!sameOrigin(form.action)) continue;
      const fields = passwordInputs(form);
      // Never put an existing secret into sign-up/reset/confirmation fields.
      if (fields.length !== 1 || fields[0].autocomplete.toLowerCase().split(/\s+/).includes('new-password')) continue;
      const password = fields[0], username = usernameInput(form, password);
      if (!manual && (password.value || (username && username.value && username.value !== credential.username))) continue;
      if (username && (manual || !username.value)) set(username, credential.username);
      set(password, credential.password);
    }
  };
  const send = (request, success) => query({request: JSON.stringify(request), onSuccess: success || (() => {}), onFailure: () => {}});
  document.addEventListener('submit', event => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    const action = event.submitter?.getAttribute('formaction') || form.action || location.href;
    if (!sameOrigin(action)) return;
    const fields = passwordInputs(form).filter(i => i.value);
    if (!fields.length) return;
    const fresh = fields.filter(i => i.autocomplete.toLowerCase().split(/\s+/).includes('new-password'));
    let password = fresh[0] || fields[0];
    if (fresh.some(i => i.value !== password.value)) return;
    if (!fresh.length && fields.length > 1) {
      if (fields.length < 2 || fields.at(-1).value !== fields.at(-2).value) return;
      password = fields.at(-1);
    }
    const username = usernameInput(form, fields[0]);
    if (password.value.length > 4096 || (username?.value.length || 0) > 1024) return;
    send({action: 'offer', username: username?.value || '', password: password.value,
          formAction: new URL(action, location.href).href});
  }, true);
  const ready = () => {
    send({action: 'lookup'}, text => { try { fill(JSON.parse(text)); } catch {} });
    let scheduled = false;
    new MutationObserver(() => {
      if (scheduled || !credential) return;
      scheduled = true; setTimeout(() => { scheduled = false; fill(); }, 100);
    }).observe(document.documentElement, {childList: true, subtree: true});
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, {once: true});
  else ready();
  return fill;
})
)JS";
